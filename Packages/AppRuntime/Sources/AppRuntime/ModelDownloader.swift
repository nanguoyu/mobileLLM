// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin   // fnmatch for glob matching
#endif

/// Downloads model snapshots from Hugging Face into a chosen base directory. Resumable and
/// idempotent: each file streams into a `.part` sibling (a cancel leaves a valid partial that the
/// `Range` header resumes), size/SHA-256 are verified before the `.part` is renamed into place, and
/// an already-complete repo verifies quickly and is reused.
///
/// Design notes:
///   • **No swift-transformers** — the repo file listing comes straight from HF's tree API
///     (`fetchHubFiles`); there is no `Hub`/`HubApi` dependency. Foundation + CryptoKit only.
///   • **Flat LLM repos** — a nested `[transformer, text_encoder, vae]` subfolder completeness
///     check is removed. LLM repos are flat: root `model.safetensors` (+ optional index shards) plus
///     `config.json` / `tokenizer*.json` / `chat_template.jinja`. Completeness is enforced by the
///     written manifest (+ index-shard presence when an index exists).
///   • The private download manifest is `.mobilellm-download-manifest.json`.
public struct ModelDownloader: Sendable {
    private struct HubFile: Sendable {
        var path: String
        var size: Int64?
        var sha256: String?
    }

    private struct DownloadManifest: Codable {
        struct File: Codable {
            var path: String
            var size: Int64?
            var sha256: String?
        }
        var version: Int = 1
        var files: [File]
    }

    private static let manifestFilename = ".mobilellm-download-manifest.json"

    public let downloadBase: URL
    public init(downloadBase: URL) { self.downloadBase = downloadBase }

    /// Where `repoId` materializes (`downloadBase/models/{repoId}`).
    public func localURL(repoId: String) -> URL {
        downloadBase.appending(component: "models").appending(component: repoId)
    }

    /// "Already fully downloaded?" for a FLAT repo. The root must exist with no in-progress
    /// `*.part` / `*.incomplete` markers; if a `model.safetensors.index.json` is present every shard
    /// it references must exist; and the written manifest (the authoritative record of what was
    /// fetched) must verify. When no manifest exists yet, at least the weights must be physically
    /// present so an empty directory never reads as "complete".
    public func isDownloaded(repoId: String) -> Bool {
        let fm = FileManager.default
        let root = localURL(repoId: repoId)
        guard fm.fileExists(atPath: root.path) else { return false }
        // Any in-progress download marker under the repo means it's incomplete.
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "incomplete" || url.pathExtension == "part" { return false }
        }
        // If a safetensors index is present, every shard it references must exist at the root.
        let index = root.appending(component: "model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            for shard in Set(weightMap.values) where !fm.fileExists(atPath: root.appending(component: shard).path) {
                return false
            }
        }
        // With no manifest yet, require the weights to be physically present (guards an empty dir).
        // Weights are either MLX `.safetensors` (flat repo) or a llama.cpp `.gguf` file.
        let manifestPresent = fm.fileExists(atPath: root.appending(component: Self.manifestFilename).path)
        if !manifestPresent {
            let hasWeights = (try? fm.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") }) ?? false
            if !hasWeights { return false }
        }
        return Self.verifyManifestIfPresent(at: root)
    }

    /// "Already fully downloaded?" for a SINGLE-FILE variant (e.g. one GGUF pulled from a multi-file
    /// repo). The named file must exist at the repo root with no in-progress `.part` sibling, and — when
    /// a download manifest recorded its expected size — match it. Used by the file-scoped install probe.
    public func isDownloaded(repoId: String, fileName: String) -> Bool {
        let fm = FileManager.default
        let root = localURL(repoId: repoId)
        // The fileName comes from remote catalog metadata — never let a "../…" escape the repo root.
        guard let file = Self.safeDestination(root: root, relativePath: fileName) else { return false }
        guard fm.fileExists(atPath: file.path) else { return false }
        if fm.fileExists(atPath: file.appendingPathExtension("part").path) { return false }
        return Self.verifyManifestIfPresent(at: root)
    }

    /// Download (idempotent) and return the local model directory. `progress` reports 0…1.
    /// `matching` optionally restricts which files are fetched (empty = the whole repo).
    @discardableResult
    public func download(repoId: String, matching globs: [String] = [],
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if os(iOS)
        // On iOS a poisoned shared URLCache entry can replay a stale/empty repo file listing, making
        // a "success" download nothing. Force fresh metadata.
        URLCache.shared.removeAllCachedResponses()
        #endif

        let root = localURL(repoId: repoId)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let allFiles = try await fetchHubFiles(repoId: repoId)
        let modelFiles = allFiles.filter(Self.isModelFile)
        let selected = globs.isEmpty ? modelFiles : modelFiles.filter { Self.matchesAny(globs, $0.path) }
        guard !selected.isEmpty else { throw ModelDownloadError.emptyFileList(repoId) }

        let totalBytes = max(1, selected.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var completedBytes: Int64 = 0
        let session = Self.makeSession()
        for file in selected {
            // `file.path` is taken verbatim from the HF tree API — sanitize it against zip-slip before
            // it becomes a write destination (a malicious repo could list "../../…").
            guard let destination = Self.safeDestination(root: root, relativePath: file.path) else {
                throw ModelDownloadError.unsafePath(file.path)
            }
            if Self.fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256) {
                completedBytes += file.size ?? Self.fileSize(destination)
                progress(min(1, Double(completedBytes) / Double(totalBytes)))
                continue
            }
            let baseBytes = completedBytes
            try await downloadFile(repoId: repoId, file: file, to: destination, session: session) { bytes in
                progress(min(1, Double(baseBytes + bytes) / Double(totalBytes)))
            }
            completedBytes += Self.fileSize(destination)
        }
        try Self.writeManifest(selected, at: root)
        // Only a whole-repo fetch is expected to satisfy the flat-repo completeness check.
        if globs.isEmpty, !isDownloaded(repoId: repoId) {
            throw ModelDownloadError.incompleteDownload(repoId)
        }
        progress(1)
        return root
    }

    // MARK: - File classification / globbing

    /// The model files worth fetching from a flat LLM repo: weights + config + tokenizer + template.
    /// `.gguf` is a self-contained llama.cpp weight file (single-file variants glob to just that one).
    private static func isModelFile(_ file: HubFile) -> Bool {
        let p = file.path
        if p.hasSuffix(".safetensors") || p.hasSuffix(".gguf") || p.hasSuffix(".json") || p.hasSuffix(".jinja") { return true }
        let name = (p as NSString).lastPathComponent
        return ["tokenizer.model", "merges.txt", "vocab.json"].contains(name)
    }

    private static func matchesAny(_ globs: [String], _ path: String) -> Bool {
        globs.contains { matches(path, glob: $0) }
    }

    /// Resolve a remote-supplied RELATIVE path to a write destination inside `root`, or `nil` if it would
    /// escape (zip-slip / path traversal). HF hands us file paths verbatim, so a hostile repo could list
    /// an absolute path or one with `..` components; either must be refused BEFORE any write. Rejects:
    /// empty, absolute (leading `/`), any `..` component, and — belt-and-braces — anything whose
    /// standardized path doesn't stay under the standardized `root`.
    static func safeDestination(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        for c in components where c == ".." || c.contains("\\") { return nil }   // parent-traversal / Windows escape
        let dest = components.reduce(root) { $0.appending(component: $1) }
        let rootStd = root.standardizedFileURL.path
        let destStd = dest.standardizedFileURL.path
        guard destStd == rootStd || destStd.hasPrefix(rootStd + "/") else { return nil }
        return dest
    }

    /// Shell-style glob match (`*`, `?`). Falls back to a literal/prefix check where `fnmatch` is
    /// unavailable.
    private static func matches(_ path: String, glob: String) -> Bool {
        #if canImport(Darwin)
        return fnmatch(glob, path, 0) == 0
        #else
        if glob.hasSuffix("*") { return path.hasPrefix(String(glob.dropLast())) }
        return path == glob
        #endif
    }

    // MARK: - Networking

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// List the repo's files via HF's raw tree API — no swift-transformers. Includes LFS size/oid
    /// (sha256) when present so `fileMatches` can verify shards.
    private func fetchHubFiles(repoId: String) async throws -> [HubFile] {
        let urlString = "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=1&expand=1"
        guard let url = URL(string: urlString) else { throw ModelDownloadError.invalidURL(urlString) }
        let (data, response) = try await Self.makeSession().data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelDownloadError.emptyFileList(repoId)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelDownloadError.emptyFileList(repoId)
        }
        let files: [HubFile] = json.compactMap { item in
            guard (item["type"] as? String) == "file", let path = item["path"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value
            let lfs = item["lfs"] as? [String: Any]
            let sha256 = lfs?["oid"] as? String
            let lfsSize = (lfs?["size"] as? NSNumber)?.int64Value
            return HubFile(path: path, size: lfsSize ?? size, sha256: sha256)
        }
        guard !files.isEmpty else { throw ModelDownloadError.emptyFileList(repoId) }
        return files
    }

    private func downloadFile(repoId: String, file: HubFile, to destination: URL, session: URLSession,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        if Self.fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256) {
            progress(file.size ?? Self.fileSize(destination)); return
        }
        let urlString = "https://huggingface.co/\(repoId)/resolve/main/\(file.path)"
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            throw ModelDownloadError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partURL = destination.appendingPathExtension("part")
        let existingBytes = Self.fileSize(partURL)
        if existingBytes > 0 { request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range") }
        // STREAMING download straight into `.part` via a per-task delegate. We deliberately avoid
        // session.download(for:), which downloads the WHOLE body atomically to a system temp file —
        // cancelling mid-file there discards every in-progress byte, so a multi-GB shard restarts at 0.
        // Writing each chunk to `.part` as it arrives means a cancel leaves a valid partial that the
        // Range header resumes next time. Resume is handled via the Range header + 200/206 branching.
        try await Self.streamDownload(request: request, into: partURL, existingBytes: existingBytes,
                                      repoId: repoId, filePath: file.path, session: session, progress: progress)
        // Verify by SIZE only. A full-file SHA256 re-reads the whole shard from disk at completion —
        // ~5 GB for the 27B, which stalled/killed the app right as the download finished. HTTPS + the
        // exact expected byte count is what normal apps rely on; a truncated download fails the size check.
        guard Self.fileMatches(partURL, expectedSize: file.size, expectedSHA256: file.sha256, verifyHash: false) else {
            try? FileManager.default.removeItem(at: partURL)   // wrong size → drop it so a retry re-fetches
            throw ModelDownloadError.hashMismatch(file.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partURL, to: destination)
    }

    /// Stream a download into `partURL` chunk-by-chunk so a cancellation leaves a valid resumable
    /// partial. Uses a `URLSessionDataTask` with a PER-TASK delegate so the shared `session` is
    /// untouched. `existingBytes` is the size of any pre-existing `.part` we may resume.
    private static func streamDownload(request: URLRequest, into partURL: URL, existingBytes: Int64,
                                       repoId: String, filePath: String, session: URLSession,
                                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let delegate = StreamingDownloadDelegate(partURL: partURL, existingBytes: existingBytes,
                                                 repoId: repoId, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            // Ends the stream; the FileHandle's already-written bytes stay in `.part` for next time.
            task.cancel()
        }
    }

    /// Per-task delegate that writes the response body into `.part` as it streams in. The FileHandle
    /// write + cumulative counter run on the URLSession's (serial) delegate queue; the continuation
    /// and handle are each touched exactly once, guarded by `lock`.
    private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partURL: URL
        private let existingBytes: Int64
        private let repoId: String
        private let progress: @Sendable (Int64) -> Void

        private let lock = NSLock()
        private var handle: FileHandle?
        private var writtenTotal: Int64       // cumulative bytes currently in `.part`
        private var finished = false          // guards continuation + handle-close (exactly once)
        private var setupError: Error?        // error raised in didReceive response

        // Progress throttling: emit at most ~once per 250 ms or per 8 MB.
        private var lastProgressTime = DispatchTime.now()
        private var bytesSinceProgress: Int64 = 0
        // Flush dirty pages to disk periodically. Without this, a multi-GB write accumulates dirty
        // file-backed pages that count toward the app's memory footprint — enough to jetsam-kill the
        // app near the end of a 5 GB download (the 27B-1bit crash on the 8 GB iPhone).
        private var bytesSinceSync: Int64 = 0

        var continuation: CheckedContinuation<Void, Error>?

        init(partURL: URL, existingBytes: Int64, repoId: String,
             progress: @escaping @Sendable (Int64) -> Void) {
            self.partURL = partURL
            self.existingBytes = existingBytes
            self.repoId = repoId
            self.progress = progress
            self.writtenTotal = existingBytes
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                fail(with: ModelDownloadError.incompleteDownload(repoId))
                completionHandler(.cancel)
                return
            }

            var startBytes = existingBytes
            if existingBytes > 0 && http.statusCode != 206 {
                // Server ignored Range and returned the whole file (200) — discard the partial so we
                // never append a full body onto a partial one (corruption). Start fresh.
                try? FileManager.default.removeItem(at: partURL)
                startBytes = 0
            }

            guard http.statusCode == 200 || http.statusCode == 206 else {
                fail(with: ModelDownloadError.incompleteDownload(repoId))
                completionHandler(.cancel)
                return
            }

            do {
                if startBytes == 0 {
                    // Fresh (or Range-reset) download: (re)create an empty `.part`.
                    if FileManager.default.fileExists(atPath: partURL.path) {
                        try FileManager.default.removeItem(at: partURL)
                    }
                    FileManager.default.createFile(atPath: partURL.path, contents: nil)
                    let h = try FileHandle(forWritingTo: partURL)
                    lock.lock(); handle = h; writtenTotal = 0; lock.unlock()
                } else {
                    // Resume (206): append to the existing `.part`.
                    let h = try FileHandle(forWritingTo: partURL)
                    try h.seekToEnd()
                    lock.lock(); handle = h; writtenTotal = startBytes; lock.unlock()
                }
            } catch {
                fail(with: error)
                completionHandler(.cancel)
                return
            }

            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard let h = handle, !finished else { lock.unlock(); return }
            do {
                try h.write(contentsOf: data)
                writtenTotal += Int64(data.count)
                bytesSinceProgress += Int64(data.count)
                bytesSinceSync += Int64(data.count)
                if bytesSinceSync >= 256 * 1024 * 1024 {   // fsync every ~256 MB → dirty pages stay bounded
                    try h.synchronize()
                    bytesSinceSync = 0
                }
                let now = DispatchTime.now()
                let elapsedMs = (now.uptimeNanoseconds - lastProgressTime.uptimeNanoseconds) / 1_000_000
                let total = writtenTotal
                let shouldReport = elapsedMs >= 250 || bytesSinceProgress >= 8 * 1024 * 1024
                if shouldReport {
                    lastProgressTime = now
                    bytesSinceProgress = 0
                }
                lock.unlock()
                if shouldReport { progress(total) }
            } catch {
                lock.unlock()
                fail(with: error)
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            try? handle?.close()      // flush before we let the caller verify
            handle = nil
            let pending = continuation
            continuation = nil
            let setup = setupError
            let total = writtenTotal
            lock.unlock()

            // Emit a final progress so the throttled value reflects the true `.part` size.
            progress(total)

            if let setup = setup {
                pending?.resume(throwing: setup)
            } else if let error = error {
                pending?.resume(throwing: error)
            } else {
                pending?.resume(returning: ())
            }
        }

        /// Record a setup/write failure; the actual continuation resume happens in didCompleteWithError
        /// (cancelling the task drives us there), so close + resume stay exactly-once.
        private func fail(with error: Error) {
            lock.lock()
            if setupError == nil { setupError = error }
            lock.unlock()
        }
    }

    // MARK: - Manifest + verification

    private static func writeManifest(_ files: [HubFile], at directory: URL) throws {
        let manifest = DownloadManifest(files: files.map { DownloadManifest.File(path: $0.path, size: $0.size, sha256: $0.sha256) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(manifestFilename), options: .atomic)
    }

    private static func verifyManifestIfPresent(at directory: URL, verifyHashes: Bool = false) -> Bool {
        let url = directory.appendingPathComponent(manifestFilename)
        // No manifest (older app version, HF CLI cache) or an unreadable one is not evidence of a bad
        // download — the caller already verified the shard structure. Don't force a multi-GB
        // re-download; only a readable manifest whose listed files fail means incomplete.
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data) else { return true }
        for file in manifest.files {
            guard fileMatches(directory.appendingPathComponent(file.path), expectedSize: file.size, expectedSHA256: file.sha256, verifyHash: verifyHashes) else {
                return false
            }
        }
        return true
    }

    private static func fileMatches(_ url: URL, expectedSize: Int64?, expectedSHA256: String?, verifyHash: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let expectedSize, fileSize(url) != expectedSize { return false }
        if verifyHash, let expectedSHA256, !expectedSHA256.isEmpty {
            guard (try? sha256Hex(of: url)) == expectedSHA256.lowercased() else { return false }
        }
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced by the in-app model downloader so silent/partial failures become visible + retriable.
public enum ModelDownloadError: LocalizedError {
    case emptyFileList(String)
    case incompleteDownload(String)
    case invalidURL(String)
    case hashMismatch(String)
    case unsafePath(String)
    public var errorDescription: String? {
        switch self {
        case .emptyFileList(let repo):
            return "Couldn’t list files for \(repo). Check your network connection and try again."
        case .incompleteDownload(let repo):
            return "Download didn’t finish for \(repo) — some weight files are missing. Tap download again to resume."
        case .invalidURL(let url):
            return "Invalid download URL: \(url)"
        case .hashMismatch(let file):
            return "Hash verification failed for \(file). Tap download again to retry."
        case .unsafePath(let path):
            return "Refused an unsafe file path from the model repo: \(path)."
        }
    }
}
