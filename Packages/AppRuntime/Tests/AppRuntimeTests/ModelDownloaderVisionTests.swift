// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// The multi-file install probe `isDownloaded(repoId:fileNames:)` (C1.3): a vision variant needs BOTH its
/// GGUF weights and its mmproj projector, so "installed" is true only when every listed file is present
/// with no in-progress `.part`. Filesystem-level, no network.
final class ModelDownloaderVisionTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-dl-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private let weights = "model.gguf"
    private let mmproj  = "mmproj-F16.gguf"

    /// Both files present → installed.
    func testBothFilesPresentIsDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/vision"
        let root = dl.localURL(repoId: repo)
        try write(root.appending(component: weights), bytes: 4096)
        try write(root.appending(component: mmproj), bytes: 2048)
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileNames: [weights, mmproj]))
    }

    /// Only the weights present (projector still to fetch) → NOT installed.
    func testMissingProjectorIsNotDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/vision"
        try write(dl.localURL(repoId: repo).appending(component: weights), bytes: 4096)
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileNames: [weights, mmproj]),
                       "weights alone is not a complete vision install")
    }

    /// An in-progress `.part` for one of the required files → NOT installed (mid-download).
    func testInProgressPartForOneFileIsNotDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/vision"
        let root = dl.localURL(repoId: repo)
        try write(root.appending(component: weights), bytes: 4096)
        try write(root.appending(component: mmproj), bytes: 2048)
        try write(root.appending(component: mmproj + ".part"), bytes: 512)
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileNames: [weights, mmproj]),
                       "a .part sibling means the projector is still downloading")
    }

    /// An empty file list delegates to the whole-repo probe (a flat MLX variant fetches everything).
    func testEmptyListDelegatesToWholeRepo() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/flat"
        XCTAssertFalse(dl.isDownloaded(repoId: repo, fileNames: []), "empty dir → whole-repo probe says no")
        try write(dl.localURL(repoId: repo).appending(component: "model.safetensors"), bytes: 4096)
        XCTAssertTrue(dl.isDownloaded(repoId: repo, fileNames: []), "weights present → whole-repo probe says yes")
    }
}
