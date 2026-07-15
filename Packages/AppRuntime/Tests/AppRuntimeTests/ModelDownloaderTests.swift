// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// Filesystem-level tests for the download install probes (no network). Covers the single-file
/// (GGUF) install check added for the llama.cpp engine, alongside the flat MLX-repo check.
final class ModelDownloaderTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-dl-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// A single-file GGUF variant reads as downloaded once its named file is present.
    func testSingleFileDownloadedWhenGGUFPresent() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "prism-ml/Bonsai-8B-gguf"
        let file = "Bonsai-8B-Q1_0.gguf"
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileName: file), "absent file → not downloaded")

        try write(dl.localURL(repoId: repo).appending(component: file), bytes: 1024)
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileName: file), "present file → downloaded")
    }

    /// An in-progress `.part` sibling means the single file is NOT yet complete.
    func testSingleFileIncompleteWithPartMarker() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "prism-ml/Bonsai-8B-gguf"
        let file = "Bonsai-8B-Q1_0.gguf"
        let root = dl.localURL(repoId: repo)
        try write(root.appending(component: file), bytes: 1024)
        try write(root.appending(component: file + ".part"), bytes: 128)
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileName: file), "a .part sibling → incomplete")
    }

    /// The flat-repo probe accepts a `.gguf` as valid weights (no-manifest fallback), not only
    /// `.safetensors`.
    func testFlatRepoAcceptsGGUFAsWeights() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "some/gguf-repo"
        try write(dl.localURL(repoId: repo).appending(component: "model-Q1_0.gguf"), bytes: 2048)
        XCTAssertTrue(dl.isDownloaded(repoId: repo), "a flat repo whose only weight is a .gguf is complete")
    }
}
