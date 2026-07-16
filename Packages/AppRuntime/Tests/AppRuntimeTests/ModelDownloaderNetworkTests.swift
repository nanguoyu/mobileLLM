// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// End-to-end `ModelDownloader.download()` over a `URLProtocol` stub — the whole networked subsystem the
/// filesystem-probe tests can't reach: HF tree-listing JSON parsing + `isModelFile` selection, the
/// streaming download into `.part`, the size-verify → `moveItem` rename, `writeManifest`, cross-file
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

    /// A body shorter than its declared size fails the size-verify → the `.part` is removed and
    /// `.hashMismatch` is thrown (a truncated download must never be renamed into place).
    func testShortBodyFailsSizeVerifyAndRemovesPart() async throws {
        let dl = downloader()
        do {
            _ = try await dl.download(repoId: "test/short") { _ in }
            XCTFail("a truncated body must fail verification")
        } catch let ModelDownloadError.hashMismatch(file) {
            XCTAssertTrue(file.contains("model.safetensors"), "the failing file is reported: \(file)")
        } catch {
            XCTFail("expected .hashMismatch, got \(error)")
        }
        let part = dl.localURL(repoId: "test/short").appending(component: "model.safetensors.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "the wrong-size .part must be removed")
        let dest = dl.localURL(repoId: "test/short").appending(component: "model.safetensors")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "a truncated file must not be renamed into place")
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
    private static let resumeSize = 250
    private static let weightSize = 128

    private static let recordLock = NSLock()
    nonisolated(unsafe) private static var _observedRangeHeaders: [String] = []
    static var observedRangeHeaders: [String] {
        recordLock.lock(); defer { recordLock.unlock() }; return _observedRangeHeaders
    }
    static func reset() { recordLock.lock(); _observedRangeHeaders = []; recordLock.unlock() }
    private static func record(range: String) { recordLock.lock(); _observedRangeHeaders.append(range); recordLock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
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
        let jsonHeaders = ["Content-Type": "application/json"]

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
        case "test/forbidden":
            return (200, jsonHeaders, listing([file("model.safetensors", 100)]))
        case "test/resume206", "test/resume200":
            return (200, jsonHeaders, listing([file("model.safetensors", resumeSize)]))
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
}
