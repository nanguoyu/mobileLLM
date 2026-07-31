// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
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
        /// Version 2 means every valid Hugging Face LFS digest in `files` was checked before the
        /// corresponding `.part` was promoted into place. Version 1 manifests predate that guarantee.
        var version: Int
        /// Optional solely so version-1 manifests remain decodable. A missing revision means `main`.
        var revision: String?
        var files: [File]

        init(version: Int = 2, revision: String, files: [File]) {
            self.version = version
            self.revision = revision
            self.files = files
        }
    }

    /// Outcome of the one-time audit for manifests written by releases that recorded Hugging Face
    /// digests but did not verify them before declaring a download complete.
    public enum LegacyManifestAuditResult: Sendable, Equatable {
        /// There is no version-1 manifest to upgrade.
        case notRequired
        /// Every recorded file passed its size/hash checks and the manifest was atomically upgraded.
        case upgraded
        /// The manifest or one of the files it attests to is invalid.
        case invalid
        /// The snapshot changed while it was being audited, or the upgraded manifest could not be saved.
        case deferred
    }

    private static let manifestFilename = ".mobilellm-download-manifest.json"
    /// Fingerprint of a v1 manifest whose one-time audit failed. Matching it on a later launch avoids
    /// re-reading the same corrupt multi-GB files; replacing the manifest naturally invalidates the mark.
    private static let legacyAuditFailureFilename = ".mobilellm-legacy-audit-failure.json"
    /// Written before any destination/`.part` is reused. It identifies an interrupted download whose
    /// completion manifest does not exist yet, so a later request for another revision cannot append to it.
    private static let revisionMarkerFilename = ".mobilellm-download-revision.json"
    /// Coordinates manifest compare-and-replace with normal download commits. Hashing never holds this
    /// queue; only the small metadata transaction is serialized.
    private static let manifestCoordinationQueue = DispatchQueue(
        label: "org.mobilellm.model-manifest"
    )

    public let downloadBase: URL

    /// An optional injected `URLSession` used for BOTH the HF tree-listing request (`fetchHubFiles`) and
    /// the file downloads. Defaults to `nil` → the built-in `makeSession()` is used, so production behavior
    /// is unchanged. This is a strictly-additive test seam: a caller can pass a session whose
    /// `configuration.protocolClasses` stubs Hugging Face, making the whole
    /// fetch → stream → size-verify → manifest path (and the 206/200 resume branch) drivable offline.
    /// Mirrors how the web tools (`WebSearchTool`/`WebScraperTool`) already accept a `session:` — a
    /// `URLSession` is thread-safe (`@unchecked Sendable`), so storing it keeps `ModelDownloader` `Sendable`.
    private let injectedSession: URLSession?

    public init(downloadBase: URL, session: URLSession? = nil) {
        self.downloadBase = downloadBase
        self.injectedSession = session
    }

    /// The session used for network I/O: the injected one if provided, else a fresh default session.
    private func session() -> URLSession { injectedSession ?? Self.makeSession() }

    /// Where `repoId` materializes (`downloadBase/models/{repoId}`).
    public func localURL(repoId: String) -> URL {
        validatedLocalURL(repoId: repoId)
            ?? downloadBase.appending(component: "models").appending(component: ".invalid-repository")
    }

    /// Resolve a Hugging Face repository id without ever treating `.` / `..` or a backslash as local path
    /// structure. Hub ids normally have `owner/name` shape, but they arrive from remote metadata and remain
    /// untrusted until this check.
    private func validatedLocalURL(repoId: String) -> URL? {
        let segments = repoId.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(segments.count),
              segments.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
                      && !$0.contains("\\") && !$0.contains("\0")
              }) else {
            return nil
        }
        let modelsRoot = downloadBase.appending(component: "models")
        let destination = segments.reduce(modelsRoot) { $0.appending(component: $1) }
        let rootPath = modelsRoot.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath.hasPrefix(rootPath + "/") else { return nil }
        return destination
    }

    /// "Already fully downloaded?" for a FLAT repo. The root must exist with no in-progress
    /// `*.part` / `*.incomplete` markers; if a `model.safetensors.index.json` is present every shard
    /// it references must exist; and the written manifest (the authoritative record of what was
    /// fetched) must verify. When no manifest exists yet, at least the weights must be physically
    /// present so an empty directory never reads as "complete".
    public func isDownloaded(repoId: String, revision: String = "main") -> Bool {
        let fm = FileManager.default
        guard let root = validatedLocalURL(repoId: repoId) else { return false }
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
        return Self.verifyManifestIfPresent(at: root, revision: revision)
    }

    /// "Already fully downloaded?" for a SINGLE-FILE variant (e.g. one GGUF pulled from a multi-file
    /// repo). The named file must exist at the repo root with no in-progress `.part` sibling, and — when
    /// a download manifest recorded its expected size — match it. Used by the file-scoped install probe.
    public func isDownloaded(repoId: String, fileName: String, revision: String = "main") -> Bool {
        let fm = FileManager.default
        guard let root = validatedLocalURL(repoId: repoId) else { return false }
        // The fileName comes from remote catalog metadata — never let a "../…" escape the repo root.
        guard let file = Self.safeDestination(root: root, relativePath: fileName) else { return false }
        guard fm.fileExists(atPath: file.path) else { return false }
        if fm.fileExists(atPath: file.appendingPathExtension("part").path) { return false }
        return Self.verifyManifestIfPresent(
            at: root, revision: revision, requiredPaths: Set([fileName]))
    }

    /// "Already fully downloaded?" for a variant that needs SEVERAL named files from a shared repo (a
    /// GGUF weight file **plus** its vision projector mmproj). Every listed file must be present with no
    /// in-progress `.part`, and the manifest (if any) must verify. An empty list is treated as a whole-repo
    /// variant (delegates to `isDownloaded(repoId:)`). Used by the install probe so a half-fetched vision
    /// model — weights present but mmproj still downloading — never reads as installed.
    public func isDownloaded(repoId: String, fileNames: [String], revision: String = "main") -> Bool {
        guard !fileNames.isEmpty else { return isDownloaded(repoId: repoId, revision: revision) }
        guard let root = validatedLocalURL(repoId: repoId) else { return false }
        let fm = FileManager.default
        let requiredPaths = Set(fileNames)
        for fileName in requiredPaths {
            guard let file = Self.safeDestination(root: root, relativePath: fileName),
                  fm.fileExists(atPath: file.path),
                  !fm.fileExists(atPath: file.appendingPathExtension("part").path) else {
                return false
            }
        }
        return Self.verifyManifestIfPresent(
            at: root, revision: revision, requiredPaths: requiredPaths)
    }

    /// Perform an explicit cryptographic audit of a completed download. Routine install probes use the
    /// version-2 manifest's download-time attestation plus file sizes so launching the app never re-reads
    /// several gigabytes; callers that need to detect same-size post-download mutation can request this
    /// deeper check.
    public func verifyDownloadedIntegrity(repoId: String, revision: String = "main") -> Bool {
        guard let root = validatedLocalURL(repoId: repoId) else { return false }
        return Self.verifyManifestIfPresent(at: root, revision: revision,
                                     verifyHashes: true, requireManifest: true)
    }

    /// Hash a version-1 manifest away from the caller's executor and atomically promote it to version 2.
    /// Routine install probes deliberately remain metadata-only so a launch-time scan can never consume
    /// the main actor reading multi-gigabyte weights. This audit is safe to start in the background; its
    /// compare-before-write guard refuses to overwrite a manifest changed by a concurrent download.
    public func auditAndUpgradeLegacyManifest(
        repoId: String,
        revision: String = "main"
    ) async -> LegacyManifestAuditResult {
        guard let root = validatedLocalURL(repoId: repoId) else { return .invalid }
        return await Task.detached(priority: .utility) {
            Self.auditAndUpgradeLegacyManifest(at: root, revision: revision)
        }.value
    }

    /// Download (idempotent) and return the local model directory. `progress` reports 0…1.
    /// `matching` optionally restricts which files are fetched (empty = the whole repo).
    @discardableResult
    public func download(repoId: String, revision: String = "main", matching globs: [String] = [],
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        #if os(iOS)
        // On iOS a poisoned shared URLCache entry can replay a stale/empty repo file listing, making
        // a "success" download nothing. Force fresh metadata.
        URLCache.shared.removeAllCachedResponses()
        #endif

        guard let root = validatedLocalURL(repoId: repoId) else {
            throw ModelDownloadError.invalidURL(repoId)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let allFiles = try await fetchHubFiles(repoId: repoId, revision: revision)
        let modelFiles = allFiles.filter(Self.isModelFile)
        let selected = globs.isEmpty ? modelFiles : modelFiles.filter { Self.matchesAny(globs, $0.path) }
        guard !selected.isEmpty else { throw ModelDownloadError.emptyFileList(repoId) }
        if let unsafe = selected.first(where: {
            Self.safeDestination(root: root, relativePath: $0.path) == nil
        }) {
            // Validate the entire listing before `prepareRoot` may retire another revision's usable files.
            throw ModelDownloadError.unsafePath(unsafe.path)
        }

        // Do this only after a successful listing, so a transient metadata failure never destroys a usable
        // existing install. Once the requested revision is known to exist, however, no byte from another
        // revision may be reused — even a same-size non-LFS config or an apparently resumable `.part`.
        try Self.prepareRoot(root, for: revision)

        let totalBytes = max(1, selected.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var completedBytes: Int64 = 0
        let session = self.session()
        for file in selected {
            // `file.path` is taken verbatim from the HF tree API — sanitize it against zip-slip before
            // it becomes a write destination (a malicious repo could list "../../…").
            guard let destination = Self.safeDestination(root: root, relativePath: file.path) else {
                throw ModelDownloadError.unsafePath(file.path)
            }
            // A pre-existing LFS file may have come from a version-1 install that only checked size.
            // Verify it once before treating it as reusable; fresh downloads are hashed incrementally.
            if Self.fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256,
                                verifyHash: file.sha256 != nil) {
                completedBytes += file.size ?? Self.fileSize(destination)
                progress(min(1, Double(completedBytes) / Double(totalBytes)))
                continue
            }
            let baseBytes = completedBytes
            try await downloadFile(repoId: repoId, revision: revision, file: file, to: destination,
                                   session: session) { bytes in
                progress(min(1, Double(baseBytes + bytes) / Double(totalBytes)))
            }
            completedBytes += Self.fileSize(destination)
        }
        try Self.writeManifest(
            selected, revision: revision, at: root, mergingExisting: !globs.isEmpty)
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(Self.revisionMarkerFilename))
        // Only a whole-repo fetch is expected to satisfy the flat-repo completeness check.
        if globs.isEmpty, !isDownloaded(repoId: repoId, revision: revision) {
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
        for c in components where c == "." || c == ".." || c.contains("\\") {
            return nil   // ambiguous/current-dir, parent-traversal, or Windows escape
        }
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

    /// Build a Hugging Face URL by encoding every logical path segment independently. In particular a
    /// branch such as `release/ios 2` must occupy ONE revision segment (`release%2Fios%202`), while the
    /// slash between the repo owner/name and those between nested file components remain path separators.
    private static func hubURL(repoId: String, endpoint: String, revision: String,
                               filePath: String? = nil,
                               queryItems: [URLQueryItem] = []) -> URL? {
        let repoSegments = repoId.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(repoSegments.count),
              repoSegments.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
                      && !$0.contains("\\") && !$0.contains("\0")
              }),
              !revision.isEmpty, revision != ".", revision != "..",
              !revision.contains("\\") && !revision.contains("\0") else { return nil }

        var segments = endpoint == "tree" ? ["api", "models"] : []
        segments.append(contentsOf: repoSegments)
        segments.append(endpoint)
        // Deliberately append revision as one segment. `encodedPathSegment` escapes any slash it contains.
        segments.append(revision)
        if let filePath {
            let fileSegments = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !fileSegments.isEmpty,
                  fileSegments.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                          && !$0.contains("\\") && !$0.contains("\0")
                  }) else { return nil }
            segments.append(contentsOf: fileSegments)
        }
        let encoded = segments.map(encodedPathSegment)
        guard !encoded.contains(where: \.isEmpty) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url
    }

    /// RFC 3986 unreserved characters only. Using `.urlQueryAllowed` for a URL path is incorrect: it
    /// leaves `/`, `?`, and `#` with structural meaning and can silently change the requested revision.
    private static func encodedPathSegment(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// List the repo's files via HF's raw tree API — no swift-transformers. Includes LFS size/oid
    /// (sha256) when present so `fileMatches` can verify shards.
    private func fetchHubFiles(repoId: String, revision: String) async throws -> [HubFile] {
        guard let url = Self.hubURL(
            repoId: repoId, endpoint: "tree", revision: revision,
            queryItems: [URLQueryItem(name: "recursive", value: "1"),
                         URLQueryItem(name: "expand", value: "1")]
        ) else {
            throw ModelDownloadError.invalidURL("\(repoId)@\(revision)")
        }
        let (data, response) = try await self.session().data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelDownloadError.emptyFileList(repoId)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ModelDownloadError.emptyFileList(repoId)
        }
        var files: [HubFile] = []
        for item in json {
            guard (item["type"] as? String) == "file", let path = item["path"] as? String else { continue }
            let size = (item["size"] as? NSNumber)?.int64Value
            let lfs = item["lfs"] as? [String: Any]
            let rawOID = lfs?["oid"] as? String
            let sha256 = Self.normalizedSHA256(rawOID)
            if lfs != nil, sha256 == nil {
                throw ModelDownloadError.invalidIntegrityMetadata(path)
            }
            let lfsSize = (lfs?["size"] as? NSNumber)?.int64Value
            files.append(HubFile(path: path, size: lfsSize ?? size, sha256: sha256))
        }
        guard !files.isEmpty else { throw ModelDownloadError.emptyFileList(repoId) }
        return files
    }

    private func downloadFile(repoId: String, revision: String, file: HubFile, to destination: URL,
                              session: URLSession,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        if Self.fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256,
                            verifyHash: file.sha256 != nil) {
            progress(file.size ?? Self.fileSize(destination)); return
        }
        // Once an existing destination has failed size/hash verification, it must stop looking installed
        // even if the replacement request later fails. Leaving it beside a v2 manifest would let the fast
        // launch-time probe trust a file state we now know is corrupt.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard let url = Self.hubURL(repoId: repoId, endpoint: "resolve", revision: revision,
                                    filePath: file.path) else {
            throw ModelDownloadError.invalidURL("\(repoId)@\(revision)/\(file.path)")
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
        let result = try await Self.streamDownload(
            request: request, into: partURL, existingBytes: existingBytes,
            repoId: repoId, session: session, progress: progress)
        if let expectedSize = file.size, result.bytes != expectedSize {
            try? FileManager.default.removeItem(at: partURL)
            throw ModelDownloadError.sizeMismatch(file.path, expected: expectedSize, actual: result.bytes)
        }
        if let expectedSHA256 = file.sha256, result.sha256 != expectedSHA256 {
            try? FileManager.default.removeItem(at: partURL)
            throw ModelDownloadError.hashMismatch(file.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partURL, to: destination)
    }

    /// Stream a download into `partURL` chunk-by-chunk so a cancellation leaves a valid resumable
    /// partial. Uses a `URLSessionDataTask` with a PER-TASK delegate so the shared `session` is
    /// untouched. `existingBytes` is the size of any pre-existing `.part` we may resume.
    private struct StreamResult: Sendable {
        var bytes: Int64
        var sha256: String
    }

    private static func streamDownload(request: URLRequest, into partURL: URL, existingBytes: Int64,
                                       repoId: String, session: URLSession,
                                       progress: @escaping @Sendable (Int64) -> Void) async throws -> StreamResult {
        try Task.checkCancellation()
        let delegate = try StreamingDownloadDelegate(partURL: partURL, existingBytes: existingBytes,
                                                     repoId: repoId, progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<StreamResult, Error>) in
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
        /// The prefix (when resuming) is read exactly once before the request starts; every new network
        /// chunk is then fed to this hasher beside the file write. A fresh multi-GB download therefore has
        /// no completion-time second disk pass.
        private var hasher: SHA256
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

        var continuation: CheckedContinuation<StreamResult, Error>?

        init(partURL: URL, existingBytes: Int64, repoId: String,
             progress: @escaping @Sendable (Int64) -> Void) throws {
            self.partURL = partURL
            self.existingBytes = existingBytes
            self.repoId = repoId
            self.progress = progress
            self.writtenTotal = existingBytes
            var initialHasher = SHA256()
            if existingBytes > 0 {
                try ModelDownloader.updateSHA256(&initialHasher, withContentsOf: partURL)
            }
            self.hasher = initialHasher
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
                    lock.lock()
                    handle = h
                    writtenTotal = 0
                    hasher = SHA256()
                    lock.unlock()
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
                hasher.update(data: data)
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
            let digest = ModelDownloader.hex(hasher.finalize())
            lock.unlock()

            // Emit a final progress so the throttled value reflects the true `.part` size.
            progress(total)

            if let setup = setup {
                pending?.resume(throwing: setup)
            } else if let error = error {
                pending?.resume(throwing: error)
            } else {
                pending?.resume(returning: StreamResult(bytes: total, sha256: digest))
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

    /// Establish the revision identity of an app-managed repo directory before examining any cached file.
    /// A missing manifest/marker is a legacy `main` install; all new in-progress downloads carry a marker.
    private static func prepareRoot(_ directory: URL, for revision: String) throws {
        try manifestCoordinationQueue.sync {
            if !storedRevision(at: directory, isCompatibleWith: revision) {
                // The directory is scoped to this exact repo by `localURL(repoId:)`. Mixing revisions
                // inside it is never safe: config/tokenizer files can keep the same size while changing
                // contents, and a Range tail cannot be appended to a prefix from another Git object.
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let marker = directory.appendingPathComponent(revisionMarkerFilename)
            try JSONEncoder().encode(revision).write(to: marker, options: .atomic)
        }
    }

    private static func storedRevision(at directory: URL, isCompatibleWith requested: String) -> Bool {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        let markerURL = directory.appendingPathComponent(revisionMarkerFilename)
        var foundIdentity = false

        if fm.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data) else {
                return false
            }
            foundIdentity = true
            guard (manifest.revision ?? "main") == requested else { return false }
        }
        if fm.fileExists(atPath: markerURL.path) {
            guard let data = try? Data(contentsOf: markerURL),
                  let markerRevision = try? JSONDecoder().decode(String.self, from: data) else {
                return false
            }
            foundIdentity = true
            guard markerRevision == requested else { return false }
        }
        // Before revision markers existed, every download URL was hard-coded to main.
        return foundIdentity || requested == "main"
    }

    private static func writeManifest(_ files: [HubFile], revision: String, at directory: URL,
                                      mergingExisting: Bool) throws {
        try manifestCoordinationQueue.sync {
            var mergedFiles: [String: DownloadManifest.File] = [:]
            if mergingExisting {
                let existingURL = directory.appendingPathComponent(manifestFilename)
                if let data = try? Data(contentsOf: existingURL),
                   let existing = try? JSONDecoder().decode(DownloadManifest.self, from: data),
                   existing.version == 2,
                   (existing.revision ?? "main") == revision {
                    // Only v2 entries carry a download-time integrity attestation. Do not let an
                    // unrelated corrupt v1 entry poison a newly downloaded scoped variant.
                    for file in existing.files {
                        mergedFiles[file.path] = file
                    }
                }
            }
            for file in files {
                mergedFiles[file.path] = DownloadManifest.File(
                    path: file.path, size: file.size, sha256: file.sha256)
            }
            let manifest = DownloadManifest(
                version: 2,
                revision: revision,
                files: mergedFiles.values.sorted { $0.path < $1.path })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent(manifestFilename),
                options: .atomic
            )
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(legacyAuditFailureFilename)
            )
        }
    }

    private static func verifyManifestIfPresent(at directory: URL, revision: String,
                                                verifyHashes: Bool = false,
                                                requireManifest: Bool = false,
                                                requiredPaths: Set<String>? = nil) -> Bool {
        let url = directory.appendingPathComponent(manifestFilename)
        // A legacy no-manifest install can only be attributed to `main`; claiming it satisfies an
        // arbitrary pinned branch/commit would silently run the wrong weights.
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A marker means a download is in progress (or failed before its manifest commit). It is not
            // a completed legacy install, regardless of how many destination files already moved.
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(revisionMarkerFilename).path) {
                return false
            }
            return !requireManifest && revision == "main"
        }
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(DownloadManifest.self, from: data) else {
            return false
        }
        guard manifest.version == 1 || manifest.version == 2 else { return false }
        guard (manifest.revision ?? "main") == revision else { return false }
        // Version 1 recorded hashes without establishing that they matched. Keep routine probes fast and
        // conservative: the async legacy audit promotes a valid snapshot to v2, while an unaudited v1
        // install never becomes loadable merely because its byte counts happen to match.
        if manifest.version == 1, !verifyHashes { return false }
        let filesToVerify: [DownloadManifest.File]
        if let requiredPaths {
            var filesByPath: [String: DownloadManifest.File] = [:]
            for file in manifest.files {
                // Ambiguous duplicate entries are not a trustworthy attestation for a scoped probe.
                guard filesByPath.updateValue(file, forKey: file.path) == nil else { return false }
            }
            guard requiredPaths.allSatisfy({ filesByPath[$0] != nil }) else { return false }
            filesToVerify = requiredPaths.compactMap { filesByPath[$0] }
        } else {
            filesToVerify = manifest.files
        }
        // A routine presence probe is intentionally bounded to metadata. Version-1 manifests are audited
        // and upgraded by `auditAndUpgradeLegacyManifest`; doing that synchronous work here used to pin
        // the main actor for minutes while it re-read every installed model on each launch.
        let mustHash = verifyHashes
        for file in filesToVerify {
            guard let destination = safeDestination(root: directory, relativePath: file.path),
                  fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256,
                              verifyHash: mustHash) else {
                return false
            }
        }
        return true
    }

    private static func auditAndUpgradeLegacyManifest(
        at directory: URL,
        revision: String
    ) -> LegacyManifestAuditResult {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        let markerURL = directory.appendingPathComponent(revisionMarkerFilename)
        let failureURL = directory.appendingPathComponent(legacyAuditFailureFilename)
        guard fm.fileExists(atPath: manifestURL.path) else { return .notRequired }
        guard !fm.fileExists(atPath: markerURL.path) else { return .deferred }
        guard let originalData = try? Data(contentsOf: manifestURL) else { return .invalid }
        let fingerprint = hex(SHA256.hash(data: originalData))
        if let failureData = try? Data(contentsOf: failureURL),
           let failedFingerprint = try? JSONDecoder().decode(String.self, from: failureData),
           failedFingerprint == fingerprint {
            return .invalid
        }
        guard var manifest = try? JSONDecoder().decode(DownloadManifest.self, from: originalData) else {
            return recordLegacyAuditFailure(
                fingerprint: fingerprint,
                snapshot: originalData,
                at: directory
            )
        }
        guard (manifest.revision ?? "main") == revision else { return .notRequired }
        if manifest.version == 2 { return .notRequired }
        guard manifest.version == 1, !manifest.files.isEmpty else {
            return recordLegacyAuditFailure(
                fingerprint: fingerprint,
                snapshot: originalData,
                at: directory
            )
        }

        var seenPaths: Set<String> = []
        for file in manifest.files {
            guard seenPaths.insert(file.path).inserted,
                  let destination = safeDestination(root: directory, relativePath: file.path) else {
                return recordLegacyAuditFailure(
                    fingerprint: fingerprint,
                    snapshot: originalData,
                    at: directory
                )
            }
            // A non-nil but malformed digest must not silently degrade into a size-only attestation.
            if file.sha256 != nil, normalizedSHA256(file.sha256) == nil {
                return recordLegacyAuditFailure(
                    fingerprint: fingerprint,
                    snapshot: originalData,
                    at: directory
                )
            }
            guard fileMatches(destination, expectedSize: file.size, expectedSHA256: file.sha256,
                              verifyHash: true) else {
                return recordLegacyAuditFailure(
                    fingerprint: fingerprint,
                    snapshot: originalData,
                    at: directory
                )
            }
        }

        // Hashing can take minutes. Compare and replace under the same queue normal downloads use for
        // prepare/commit, so a stale v1 snapshot can never overwrite a newer manifest.
        return manifestCoordinationQueue.sync {
            guard !fm.fileExists(atPath: markerURL.path),
                  let currentData = try? Data(contentsOf: manifestURL),
                  currentData == originalData else {
                return .deferred
            }
            manifest.version = 2
            manifest.revision = revision
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                try? fm.removeItem(at: failureURL)
                return .upgraded
            } catch {
                return .deferred
            }
        }
    }

    private static func recordLegacyAuditFailure(
        fingerprint: String,
        snapshot: Data,
        at directory: URL
    ) -> LegacyManifestAuditResult {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(manifestFilename)
        let markerURL = directory.appendingPathComponent(revisionMarkerFilename)
        let failureURL = directory.appendingPathComponent(legacyAuditFailureFilename)
        return manifestCoordinationQueue.sync {
            guard !fm.fileExists(atPath: markerURL.path),
                  let currentData = try? Data(contentsOf: manifestURL),
                  currentData == snapshot else {
                return .deferred
            }
            if let data = try? JSONEncoder().encode(fingerprint) {
                try? data.write(to: failureURL, options: .atomic)
            }
            return .invalid
        }
    }

    private static func fileMatches(_ url: URL, expectedSize: Int64?, expectedSHA256: String?, verifyHash: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let expectedSize, fileSize(url) != expectedSize { return false }
        if verifyHash, let expectedSHA256 = normalizedSHA256(expectedSHA256) {
            guard (try? sha256Hex(of: url)) == expectedSHA256 else { return false }
        }
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private static func sha256Hex(of url: URL) throws -> String {
        var hasher = SHA256()
        try updateSHA256(&hasher, withContentsOf: url)
        return hex(hasher.finalize())
    }

    private static func updateSHA256(_ hasher: inout SHA256, withContentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
    }

    private static func normalizedSHA256(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Errors surfaced by the in-app model downloader so silent/partial failures become visible + retriable.
public enum ModelDownloadError: LocalizedError {
    case emptyFileList(String)
    case incompleteDownload(String)
    case invalidURL(String)
    case invalidIntegrityMetadata(String)
    case sizeMismatch(String, expected: Int64, actual: Int64)
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
        case .invalidIntegrityMetadata(let file):
            return "The model repo supplied invalid SHA-256 metadata for \(file). The file was not downloaded."
        case .sizeMismatch(let file, let expected, let actual):
            return "Size verification failed for \(file) (expected \(expected) bytes, received \(actual)). Tap download again to retry."
        case .hashMismatch(let file):
            return "SHA-256 verification failed for \(file). The downloaded bytes were discarded; tap download again to retry."
        case .unsafePath(let path):
            return "Refused an unsafe file path from the model repo: \(path)."
        }
    }
}
