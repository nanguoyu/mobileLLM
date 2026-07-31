// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import AppRuntime

/// End-to-end `ModelDownloader.download()` over a `URLProtocol` stub — the whole networked subsystem the
/// filesystem-probe tests can't reach: HF tree-listing JSON parsing + `isModelFile` selection, the
/// streaming download into `.part`, the size/SHA-256 verify → `moveItem` rename, `writeManifest`, cross-file
/// progress ending at 1.0, and every `ModelDownloadError` propagation path. Also the resume corruption
/// guard: a 206 must APPEND onto an existing `.part`, while a server that ignores `Range` and replies 200
/// must DISCARD the partial (never append a full body onto a partial one).
///
/// Driven through the strictly-additive `session:` seam on `ModelDownloader.init` — the stub session's
/// `configuration.protocolClasses` intercepts both the tree API and the resolve/download requests offline.
final class ModelDownloaderNetworkTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        HFMockProtocol.reset()
        base = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-dlnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        HFMockProtocol.reset()
    }

    private func downloader() -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HFMockProtocol.self]
        return ModelDownloader(downloadBase: base, session: URLSession(configuration: config))
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? -1
    }

    /// Capture the final progress value (the last one wins → the loop ends on `progress(1)`).
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: Double = -1
        var last: Double { lock.lock(); defer { lock.unlock() }; return _last }
        func record(_ v: Double) { lock.lock(); _last = v; lock.unlock() }
    }

    // MARK: - Happy path: fetch → stream → size-verify → manifest

    func testDownloadFetchesStreamsVerifiesAndWritesManifest() async throws {
        let dl = downloader()
        let progress = ProgressBox()
        let root = try await dl.download(repoId: "test/happy") { progress.record($0) }

        let fm = FileManager.default
        // Both listed model files landed at the right sizes.
        let config = root.appending(component: "config.json")
        let weights = root.appending(component: "model.safetensors")
        XCTAssertTrue(fm.fileExists(atPath: config.path), "config.json must land")
        XCTAssertTrue(fm.fileExists(atPath: weights.path), "model.safetensors must land")
        XCTAssertEqual(Self.fileSize(weights), 128, "the streamed weight file is the full declared size")
        // No leftover in-progress markers.
        XCTAssertFalse(fm.fileExists(atPath: weights.appendingPathExtension("part").path), "no .part remains")
        // The private manifest was written and the repo reads as fully downloaded.
        XCTAssertTrue(fm.fileExists(atPath: root.appending(component: ".mobilellm-download-manifest.json").path),
                      "the download manifest must be written")
        XCTAssertTrue(dl.isDownloaded(repoId: "test/happy"), "the repo verifies as complete")
        XCTAssertEqual(progress.last, 1.0, accuracy: 0.0001, "progress ends at 1.0")
    }

    // MARK: - Error propagation

    /// The tree API returning a non-200 (500) surfaces as `.emptyFileList` — a listing failure, not a silent
    /// empty success.
    func testTreeAPIFailureThrowsEmptyFileList() async {
        do {
            _ = try await downloader().download(repoId: "test/tree500") { _ in }
            XCTFail("a 500 on the tree API must throw")
        } catch let ModelDownloadError.emptyFileList(repo) {
            XCTAssertEqual(repo, "test/tree500")
        } catch {
            XCTFail("expected .emptyFileList, got \(error)")
        }
    }

    /// A repo whose listing selects no model files (only a README) throws `.emptyFileList` before any write.
    func testNoModelFilesThrowsEmptyFileList() async {
        do {
            _ = try await downloader().download(repoId: "test/nomodel") { _ in }
            XCTFail("a listing with no model files must throw")
        } catch let ModelDownloadError.emptyFileList(repo) {
            XCTAssertEqual(repo, "test/nomodel")
        } catch {
            XCTFail("expected .emptyFileList, got \(error)")
        }
    }

    /// A hostile repo listing a `../` path is refused with `.unsafePath` BEFORE anything is written — the
    /// zip-slip guard runs at the write-destination step.
    func testUnsafePathIsRejectedBeforeAnyWrite() async throws {
        let dl = downloader()
        do {
            _ = try await dl.download(repoId: "test/unsafe") { _ in }
            XCTFail("a ../ path must throw .unsafePath")
        } catch let ModelDownloadError.unsafePath(path) {
            XCTAssertTrue(path.contains(".."), "the offending traversal path is reported: \(path)")
        } catch {
            XCTFail("expected .unsafePath, got \(error)")
        }
        // Nothing escaped the repo root and no weights were written.
        let root = dl.localURL(repoId: "test/unsafe")
        let escaped = root.deletingLastPathComponent().appending(component: "evil.safetensors")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path), "no file may be written outside root")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(contents.contains { $0.hasSuffix(".safetensors") }, "no weight was written before the refusal")
    }

    /// A body shorter than its declared size fails the size check with an accurately named error; it is
    /// not mislabeled as a cryptographic hash failure.
    func testShortBodyFailsSizeVerifyAndRemovesPart() async throws {
        let dl = downloader()
        do {
            _ = try await dl.download(repoId: "test/short") { _ in }
            XCTFail("a truncated body must fail verification")
        } catch let ModelDownloadError.sizeMismatch(file, expected, actual) {
            XCTAssertTrue(file.contains("model.safetensors"), "the failing file is reported: \(file)")
            XCTAssertEqual(expected, 200)
            XCTAssertEqual(actual, 50)
        } catch {
            XCTFail("expected .sizeMismatch, got \(error)")
        }
        let part = dl.localURL(repoId: "test/short").appending(component: "model.safetensors.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "the wrong-size .part must be removed")
        let dest = dl.localURL(repoId: "test/short").appending(component: "model.safetensors")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "a truncated file must not be renamed into place")
    }

    /// Hugging Face LFS metadata is a content digest, not decoration. A valid file is accepted without a
    /// completion-time reread, recorded in a v2 manifest, and remains available for an explicit deep audit.
    func testLFSHashIsVerifiedAndManifestSupportsDeepAudit() async throws {
        let dl = downloader()
        let root = try await dl.download(repoId: "test/lfs-valid") { _ in }
        XCTAssertTrue(dl.isDownloaded(repoId: "test/lfs-valid"))
        XCTAssertTrue(dl.verifyDownloadedIntegrity(repoId: "test/lfs-valid"))
        let manifestData = try Data(
            contentsOf: root.appending(component: ".mobilellm-download-manifest.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual((manifest["version"] as? NSNumber)?.intValue, 2)
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual((files.first?["sha256"] as? String)?.count, 64)

        // Same size, different bytes: the routine probe trusts the download-time v2 attestation, while
        // the explicit cryptographic audit detects post-download mutation.
        let weights = root.appending(component: "model.safetensors")
        try Data(repeating: 0xDD, count: HFMockProtocol.weightSize).write(to: weights)
        XCTAssertTrue(dl.isDownloaded(repoId: "test/lfs-valid"))
        XCTAssertFalse(dl.verifyDownloadedIntegrity(repoId: "test/lfs-valid"))
    }

    /// A same-size payload with the wrong LFS digest is discarded before it can become the model file.
    func testLFSHashMismatchDiscardsPartAndDestination() async throws {
        let dl = downloader()
        // Simulate a same-size post-download mutation beside an otherwise trusted v2 manifest. Once the
        // downloader discovers the mismatch, even a failed replacement must not leave that file installed.
        let root = dl.localURL(repoId: "test/lfs-badhash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appending(component: "model.safetensors")
        try Data(repeating: 0xBB, count: HFMockProtocol.weightSize).write(to: destination)
        let expected = SHA256.hash(data: Data(repeating: 0xEE, count: HFMockProtocol.weightSize))
            .map { String(format: "%02x", $0) }.joined()
        let manifest = """
        {"version":2,"revision":"main","files":[
          {"path":"model.safetensors","size":\(HFMockProtocol.weightSize),"sha256":"\(expected)"}
        ]}
        """
        try Data(manifest.utf8).write(
            to: root.appending(component: ".mobilellm-download-manifest.json"))
        XCTAssertTrue(dl.isDownloaded(repoId: "test/lfs-badhash"),
                      "the routine probe trusts an unchanged-size v2 attestation")
        XCTAssertFalse(dl.verifyDownloadedIntegrity(repoId: "test/lfs-badhash"))

        do {
            _ = try await dl.download(repoId: "test/lfs-badhash") { _ in }
            XCTFail("same-size corrupt bytes must fail SHA-256 verification")
        } catch let ModelDownloadError.hashMismatch(file) {
            XCTAssertEqual(file, "model.safetensors")
        } catch {
            XCTFail("expected .hashMismatch, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path))
        XCTAssertFalse(dl.isDownloaded(repoId: "test/lfs-badhash"),
                       "a file known to be corrupt must not remain installed after replacement fails")
    }

    func testInvalidLFSOIDIsRejectedBeforeDownloadingBody() async {
        do {
            _ = try await downloader().download(repoId: "test/lfs-invalid-metadata") { _ in }
            XCTFail("malformed LFS integrity metadata must be rejected")
        } catch let ModelDownloadError.invalidIntegrityMetadata(file) {
            XCTAssertEqual(file, "model.safetensors")
        } catch {
            XCTFail("expected .invalidIntegrityMetadata, got \(error)")
        }
        XCTAssertEqual(HFMockProtocol.observedURLs.count, 1,
                       "invalid metadata must fail after listing, before any resolve request")
    }

    /// The revision is used for BOTH listing and resolution. It is encoded as one path segment so its
    /// slash/space cannot be mistaken for Hub routing structure.
    func testNonMainRevisionIsThreadedAndPathSegmentEncoded() async throws {
        let revision = "refs/pr 7"
        _ = try await downloader().download(repoId: "test/revision", revision: revision) { _ in }
        let urls = HFMockProtocol.observedURLs
        XCTAssertTrue(urls.contains {
            $0.contains("/api/models/test/revision/tree/refs%2Fpr%207?") &&
            $0.contains("recursive=1") && $0.contains("expand=1")
        }, "tree request must carry encoded revision; saw \(urls)")
        XCTAssertTrue(urls.contains {
            $0.contains("/test/revision/resolve/refs%2Fpr%207/model.safetensors")
        }, "resolve request must carry the same encoded revision; saw \(urls)")
        let manifestURL = downloader().localURL(repoId: "test/revision")
            .appending(component: ".mobilellm-download-manifest.json")
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual(manifest["revision"] as? String, revision)
        XCTAssertEqual((manifest["version"] as? NSNumber)?.intValue, 2)
        XCTAssertTrue(downloader().isDownloaded(repoId: "test/revision", revision: revision))
        XCTAssertFalse(downloader().isDownloaded(repoId: "test/revision", revision: "main"),
                       "a manifest for one revision must not satisfy another")
    }

    /// Revision identity governs local reuse as well as the HTTP URL. A same-size, non-LFS config from
    /// `main` must be fetched again when switching commits; size equality is not proof of identity.
    func testRevisionSwitchRedownloadsSameSizeNonLFSFiles() async throws {
        let dl = downloader()
        let root = try await dl.download(repoId: "test/revision-switch") { _ in }
        let config = root.appending(component: "config.json")
        XCTAssertEqual(try Data(contentsOf: config), Data(repeating: 0xBB, count: 20))

        let revision = "release/v2"
        _ = try await dl.download(
            repoId: "test/revision-switch", revision: revision) { _ in }

        XCTAssertEqual(try Data(contentsOf: config), Data(repeating: 0xCC, count: 20),
                       "same-size config bytes from main must not be reused for release/v2")
        XCTAssertTrue(HFMockProtocol.observedURLs.contains {
            $0.contains("/test/revision-switch/resolve/release%2Fv2/config.json")
        }, "the new revision's non-LFS config must actually be resolved")
        XCTAssertTrue(dl.isDownloaded(repoId: "test/revision-switch", revision: revision))
        XCTAssertFalse(dl.isDownloaded(repoId: "test/revision-switch", revision: "main"))
    }

    /// A `.part` without a revision marker is compatible only with the legacy hard-coded `main`. A
    /// non-main request must delete it before building the Range request.
    func testNonMainRevisionDiscardsLegacyMainPartInsteadOfResuming() async throws {
        let dl = downloader()
        let revision = "release/v2"
        let root = dl.localURL(repoId: "test/revision-part")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let part = root.appending(component: "model.safetensors.part")
        try Data(repeating: 0xAA, count: 100).write(to: part)

        _ = try await dl.download(repoId: "test/revision-part", revision: revision) { _ in }

        XCTAssertTrue(HFMockProtocol.observedRangeHeaders.isEmpty,
                      "an unidentified legacy-main prefix must not be resumed at a non-main revision")
        let destination = root.appending(component: "model.safetensors")
        XCTAssertEqual(try Data(contentsOf: destination),
                       Data(repeating: 0xCC, count: HFMockProtocol.resumeSize))
    }

    /// Conversely, an interrupted non-main download carrying the same marker remains resumable.
    func testMatchingNonMainRevisionMarkerAllowsResume() async throws {
        let dl = downloader()
        let revision = "release/v2"
        let root = dl.localURL(repoId: "test/revision-part")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(revision).write(
            to: root.appending(component: ".mobilellm-download-revision.json"))
        try Data(repeating: 0xCC, count: 100).write(
            to: root.appending(component: "model.safetensors.part"))

        _ = try await dl.download(repoId: "test/revision-part", revision: revision) { _ in }

        XCTAssertEqual(HFMockProtocol.observedRangeHeaders, ["bytes=100-"])
        XCTAssertEqual(
            try Data(contentsOf: root.appending(component: "model.safetensors")),
            Data(repeating: 0xCC, count: HFMockProtocol.resumeSize))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appending(component: ".mobilellm-download-revision.json").path),
            "the in-progress identity marker is removed after the manifest commits")
    }

    /// File-scoped installs from one multi-GGUF repo form a union at the same revision. Downloading B
    /// must not erase A's attestation, so returning to A neither redownloads it nor mistakes an unrelated
    /// same-size orphan for an installed variant.
    func testSubsetManifestMergesAcrossAThenBThenAAndScopesProbes() async throws {
        let dl = downloader()
        let repo = "test/multi-gguf"

        let root = try await dl.download(repoId: repo, matching: ["a.gguf"]) { _ in }
        _ = try await dl.download(repoId: repo, matching: ["b.gguf"]) { _ in }

        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileName: "a.gguf"))
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileName: "b.gguf"))
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileNames: ["a.gguf", "b.gguf"]))

        let aResolve = "/test/multi-gguf/resolve/main/a.gguf"
        XCTAssertEqual(HFMockProtocol.observedURLs.filter { $0.contains(aResolve) }.count, 1)
        _ = try await dl.download(repoId: repo, matching: ["a.gguf"]) { _ in }
        XCTAssertEqual(HFMockProtocol.observedURLs.filter { $0.contains(aResolve) }.count, 1,
                       "A → B → A must reuse A because the merged manifest still attests it")

        let manifestData = try Data(
            contentsOf: root.appending(component: ".mobilellm-download-manifest.json"))
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let entries = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(Set(entries.compactMap { $0["path"] as? String }), ["a.gguf", "b.gguf"])

        try Data(repeating: 0xDD, count: 64).write(to: root.appending(component: "orphan.gguf"))
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileName: "orphan.gguf"),
                       "a physical file absent from the manifest is not an installed variant")
        XCTAssertFalse(dl.isDownloaded(
            repoId: repo, fileNames: ["a.gguf", "orphan.gguf"]))

        try Data(repeating: 0xAA, count: 65).write(to: root.appending(component: "a.gguf"))
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileName: "a.gguf"),
                       "the scoped probe validates its own manifest size")
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileName: "b.gguf"),
                      "a damaged A does not invalidate the independently attested B variant")
    }

    /// A newly verified scoped download must not inherit unrelated entries from an unaudited v1
    /// manifest. Otherwise one missing legacy file can poison the fresh variant and keep the whole
    /// manifest permanently untrusted.
    func testScopedDownloadReplacesLegacyEntriesWithFreshVersionTwoAttestation() async throws {
        let dl = downloader()
        let repo = "test/multi-gguf"
        let root = try await dl.download(repoId: repo, matching: ["a.gguf"]) { _ in }
        let manifestURL = root.appending(component: ".mobilellm-download-manifest.json")
        let legacy: [String: Any] = [
            "version": 1,
            "revision": "main",
            "files": [
                ["path": "a.gguf", "size": 64],
                ["path": "missing-legacy.gguf", "size": 64],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        _ = try await dl.download(repoId: repo, matching: ["b.gguf"]) { _ in }

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertEqual((manifest["version"] as? NSNumber)?.intValue, 2)
        let entries = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["path"] as? String }, ["b.gguf"])
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileName: "b.gguf"))
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileName: "a.gguf"),
                       "the unaudited legacy entry is intentionally not carried forward")
    }

    /// A forbidden (403) response status on the download surfaces as `.incompleteDownload` (the status guard
    /// only allows 200/206).
    func testForbiddenStatusThrowsIncompleteDownload() async {
        do {
            _ = try await downloader().download(repoId: "test/forbidden") { _ in }
            XCTFail("a 403 download must throw")
        } catch let ModelDownloadError.incompleteDownload(repo) {
            XCTAssertEqual(repo, "test/forbidden")
        } catch {
            XCTFail("expected .incompleteDownload, got \(error)")
        }
    }

    // MARK: - Resume: 206 append vs server-ignores-Range 200 restart

    /// Resume path: a pre-existing `.part` makes the client send `Range: bytes=N-`; a 206 response must
    /// APPEND its body onto the existing partial (so the first N bytes are preserved and the final size is
    /// N + body).
    func testResume206AppendsOntoExistingPart() async throws {
        let dl = downloader()
        let root = dl.localURL(repoId: "test/resume206")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Seed a 100-byte partial of a recognizable filler so we can prove it survived (append, not restart).
        let part = root.appending(component: "model.safetensors.part")
        try Data(repeating: 0xAA, count: 100).write(to: part)

        _ = try await dl.download(repoId: "test/resume206") { _ in }

        // The client sent a Range request for the missing tail.
        XCTAssertTrue(HFMockProtocol.observedRangeHeaders.contains("bytes=100-"),
                      "resume must send Range: bytes=100-, saw \(HFMockProtocol.observedRangeHeaders)")
        let dest = root.appending(component: "model.safetensors")
        let data = try Data(contentsOf: dest)
        XCTAssertEqual(data.count, 250, "final file is the pre-seed (100) + the 206 tail (150)")
        XCTAssertEqual(Array(data.prefix(100)), Array(repeating: 0xAA, count: 100),
                       "the pre-seeded prefix survived — the tail was appended, not restarted")
    }

    /// Corruption guard: the same pre-seeded `.part`, but the server IGNORES `Range` and replies 200 with the
    /// WHOLE body. The partial must be DISCARDED and the download restarted from zero — never appended (which
    /// would produce a 350-byte corrupt file).
    func testResume200RestartsWhenServerIgnoresRange() async throws {
        let dl = downloader()
        let root = dl.localURL(repoId: "test/resume200")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let part = root.appending(component: "model.safetensors.part")
        try Data(repeating: 0xAA, count: 100).write(to: part)

        _ = try await dl.download(repoId: "test/resume200") { _ in }

        let dest = root.appending(component: "model.safetensors")
        let data = try Data(contentsOf: dest)
        XCTAssertEqual(data.count, 250, "final file is exactly the full body — not 350 (append corruption)")
        XCTAssertEqual(data.first, 0xBB, "the stale 0xAA partial was discarded; the file starts with the fresh body")
        XCTAssertFalse(data.prefix(100).contains(0xAA), "no byte of the stale partial leaked into the restart")
    }
}

// MARK: - Fixtures + URLProtocol stub

/// A canned Hugging Face stub, keyed purely by the repoId embedded in the URL path (so scenarios stay
/// independent). Handles the tree-listing endpoint and the per-file resolve endpoint, honoring/ignoring the
/// `Range` header per scenario. The observed `Range` headers are recorded so a resume test can assert one
/// was sent.
private final class HFMockProtocol: URLProtocol {
    // Byte fillers: 0xBB is the "server body", so a resume test can tell it apart from a 0xAA pre-seed.
    private static let bodyByte: UInt8 = 0xBB
    static let resumeSize = 250
    static let weightSize = 128

    private static let recordLock = NSLock()
    nonisolated(unsafe) private static var _observedRangeHeaders: [String] = []
    nonisolated(unsafe) private static var _observedURLs: [String] = []
    static var observedRangeHeaders: [String] {
        recordLock.lock(); defer { recordLock.unlock() }; return _observedRangeHeaders
    }
    static var observedURLs: [String] {
        recordLock.lock(); defer { recordLock.unlock() }; return _observedURLs
    }
    static func reset() {
        recordLock.lock()
        _observedRangeHeaders = []
        _observedURLs = []
        recordLock.unlock()
    }
    private static func record(range: String) { recordLock.lock(); _observedRangeHeaders.append(range); recordLock.unlock() }
    private static func record(url: URL?) {
        recordLock.lock()
        _observedURLs.append(url?.absoluteString ?? "")
        recordLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.record(url: request.url)
        if let range = request.value(forHTTPHeaderField: "Range") { Self.record(range: range) }
        let (status, headers, body) = Self.response(for: request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: Routing

    /// Repo of a tree URL `/api/models/{repo}/tree/main` or a resolve URL `/{repo}/resolve/main/{file}`.
    private static func repo(ofTree path: String) -> String? {
        guard path.hasPrefix("/api/models/"), let r = path.range(of: "/tree/main") else { return nil }
        return String(path[path.index(path.startIndex, offsetBy: "/api/models/".count)..<r.lowerBound])
    }
    private static func repoAndFile(ofResolve path: String) -> (String, String)? {
        // Path shape: `/{repo}/resolve/main/{file}`, where `{repo}` itself contains a slash (org/name).
        guard let r = path.range(of: "/resolve/main/") else { return nil }
        let repo = String(path[path.startIndex..<r.lowerBound]).dropFirst()   // drop the leading "/"
        let file = String(path[r.upperBound...])
        return (String(repo), file)
    }

    private static func response(for request: URLRequest) -> (Int, [String: String], Data) {
        let path = request.url?.path ?? ""
        let encodedPath = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .percentEncodedPath ?? ""
        let jsonHeaders = ["Content-Type": "application/json"]

        if encodedPath == "/api/models/test/revision/tree/refs%2Fpr%207" {
            return treeResponse(repo: "test/revision", jsonHeaders: jsonHeaders)
        }
        if encodedPath == "/test/revision/resolve/refs%2Fpr%207/model.safetensors" {
            return resolveResponse(repo: "test/revision", file: "model.safetensors", range: nil)
        }
        if encodedPath == "/api/models/test/revision-switch/tree/release%2Fv2" {
            return treeResponse(repo: "test/revision-switch-new", jsonHeaders: jsonHeaders)
        }
        if encodedPath.hasPrefix("/test/revision-switch/resolve/release%2Fv2/") {
            let file = String(encodedPath.split(separator: "/").last ?? "")
            return resolveResponse(repo: "test/revision-switch-new", file: file,
                                   range: request.value(forHTTPHeaderField: "Range"))
        }
        if encodedPath == "/api/models/test/revision-part/tree/release%2Fv2" {
            return treeResponse(repo: "test/revision-part-new", jsonHeaders: jsonHeaders)
        }
        if encodedPath == "/test/revision-part/resolve/release%2Fv2/model.safetensors" {
            return resolveResponse(repo: "test/revision-part-new", file: "model.safetensors",
                                   range: request.value(forHTTPHeaderField: "Range"))
        }
        if let repo = repo(ofTree: path) {
            return treeResponse(repo: repo, jsonHeaders: jsonHeaders)
        }
        if let (repo, file) = repoAndFile(ofResolve: path) {
            return resolveResponse(repo: repo, file: file, range: request.value(forHTTPHeaderField: "Range"))
        }
        return (404, jsonHeaders, Data())
    }

    // MARK: Tree listing

    private static func treeResponse(repo: String, jsonHeaders: [String: String]) -> (Int, [String: String], Data) {
        func listing(_ files: [[String: Any]]) -> Data {
            (try? JSONSerialization.data(withJSONObject: files)) ?? Data()
        }
        func file(_ path: String, _ size: Int) -> [String: Any] { ["type": "file", "path": path, "size": size] }
        func lfsFile(_ path: String, _ body: Data, oid: String? = nil) -> [String: Any] {
            ["type": "file", "path": path, "size": body.count,
             "lfs": ["size": body.count, "oid": oid ?? sha256(body)]]
        }

        switch repo {
        case "test/happy":
            return (200, jsonHeaders, listing([file("config.json", 20), file("model.safetensors", weightSize)]))
        case "test/tree500":
            return (500, jsonHeaders, Data(#"{"error":"boom"}"#.utf8))
        case "test/nomodel":
            return (200, jsonHeaders, listing([file("README.md", 42)]))   // no .safetensors/.gguf/.json/.jinja
        case "test/unsafe":
            return (200, jsonHeaders, listing([file("../evil.safetensors", 8)]))
        case "test/short":
            return (200, jsonHeaders, listing([file("model.safetensors", 200)]))   // declared 200, body will be 50
        case "test/lfs-valid":
            let body = Data(repeating: 0xCC, count: weightSize)
            return (200, jsonHeaders, listing([lfsFile("model.safetensors", body)]))
        case "test/lfs-badhash":
            let body = Data(repeating: bodyByte, count: weightSize)
            let wrong = sha256(Data(repeating: 0xEE, count: weightSize))
            return (200, jsonHeaders, listing([lfsFile("model.safetensors", body, oid: wrong)]))
        case "test/lfs-invalid-metadata":
            return (200, jsonHeaders, listing([
                ["type": "file", "path": "model.safetensors", "size": weightSize,
                 "lfs": ["size": weightSize, "oid": "not-a-sha256"]]
            ]))
        case "test/revision":
            return (200, jsonHeaders, listing([file("model.safetensors", weightSize)]))
        case "test/revision-switch":
            let weights = Data(repeating: bodyByte, count: weightSize)
            return (200, jsonHeaders, listing([
                file("config.json", 20), lfsFile("model.safetensors", weights)
            ]))
        case "test/revision-switch-new":
            let weights = Data(repeating: 0xCC, count: weightSize)
            return (200, jsonHeaders, listing([
                file("config.json", 20), lfsFile("model.safetensors", weights)
            ]))
        case "test/revision-part-new":
            let weights = Data(repeating: 0xCC, count: resumeSize)
            return (200, jsonHeaders, listing([lfsFile("model.safetensors", weights)]))
        case "test/multi-gguf":
            return (200, jsonHeaders, listing([file("a.gguf", 64), file("b.gguf", 96)]))
        case "test/forbidden":
            return (200, jsonHeaders, listing([file("model.safetensors", 100)]))
        case "test/resume206":
            let body = Data(repeating: 0xAA, count: 100)
                + Data(repeating: bodyByte, count: resumeSize - 100)
            return (200, jsonHeaders, listing([lfsFile("model.safetensors", body)]))
        case "test/resume200":
            let body = Data(repeating: bodyByte, count: resumeSize)
            return (200, jsonHeaders, listing([lfsFile("model.safetensors", body)]))
        default:
            return (404, jsonHeaders, Data())
        }
    }

    // MARK: Per-file resolve

    private static func resolveResponse(repo: String, file: String, range: String?)
        -> (Int, [String: String], Data) {
        let htmlHeaders = ["Content-Type": "application/octet-stream"]
        func fullBody(_ n: Int) -> Data { Data(repeating: bodyByte, count: n) }

        switch repo {
        case "test/happy":
            return (200, htmlHeaders, fullBody(file == "config.json" ? 20 : weightSize))
        case "test/short":
            return (200, htmlHeaders, fullBody(50))   // shorter than the declared 200 → size-verify fails
        case "test/lfs-valid":
            return (200, htmlHeaders, Data(repeating: 0xCC, count: weightSize))
        case "test/lfs-badhash", "test/revision":
            return (200, htmlHeaders, fullBody(weightSize))
        case "test/revision-switch":
            return (200, htmlHeaders, fullBody(file == "config.json" ? 20 : weightSize))
        case "test/revision-switch-new":
            return (200, htmlHeaders, Data(repeating: 0xCC,
                                           count: file == "config.json" ? 20 : weightSize))
        case "test/revision-part-new":
            if let range, let start = Self.rangeStart(range) {
                var headers = htmlHeaders
                headers["Content-Range"] = "bytes \(start)-\(resumeSize - 1)/\(resumeSize)"
                return (206, headers, Data(repeating: 0xCC, count: resumeSize - start))
            }
            return (200, htmlHeaders, Data(repeating: 0xCC, count: resumeSize))
        case "test/multi-gguf":
            return (200, htmlHeaders, Data(
                repeating: file == "a.gguf" ? 0xA1 : 0xB2,
                count: file == "a.gguf" ? 64 : 96))
        case "test/forbidden":
            return (403, htmlHeaders, Data())
        case "test/resume206":
            // Honor Range: reply 206 with just the missing tail.
            if let range, let start = Self.rangeStart(range) {
                let tail = fullBody(resumeSize - start)
                var headers = htmlHeaders
                headers["Content-Range"] = "bytes \(start)-\(resumeSize - 1)/\(resumeSize)"
                return (206, headers, tail)
            }
            return (200, htmlHeaders, fullBody(resumeSize))
        case "test/resume200":
            // Ignore Range entirely — always the full body at 200 (the corruption-guard scenario).
            return (200, htmlHeaders, fullBody(resumeSize))
        default:
            return (404, htmlHeaders, Data())
        }
    }

    /// Parse `N` from a `bytes=N-` Range header.
    private static func rangeStart(_ header: String) -> Int? {
        guard let eq = header.range(of: "bytes=") else { return nil }
        let rest = header[eq.upperBound...].prefix { $0 != "-" }
        return Int(rest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
