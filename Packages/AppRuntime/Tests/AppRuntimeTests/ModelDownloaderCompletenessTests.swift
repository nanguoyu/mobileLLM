// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// Flat-repo completeness + manifest verification for `isDownloaded(repoId:)` — the logic that decides
/// "reuse this download vs. re-fetch multiple GB". The existing `ModelDownloaderTests` cover the
/// single-file (GGUF) probe and the path sanitizer; these cover the multi-shard index check, manifest
/// size verification, the `.incomplete` marker, and the empty-directory guard — all filesystem-level, no
/// network.
///
/// NOTE: the resumable STREAMING download protocol (206 resume / 200-ignores-Range restart / interrupted
/// `.part`) is intentionally NOT exercised here — `ModelDownloader.download` builds its `URLSession`
/// through a private `makeSession()` with no injection seam, and `URLProtocol.registerClass` does not
/// intercept a `URLSessionConfiguration.default` session, so a `URLProtocol` stub cannot drive it without
/// a source change. See the workstream's reported risk.
final class ModelDownloaderCompletenessTests: XCTestCase {

    /// The on-disk manifest name is a stable filesystem contract (kept private in the source); the fixtures
    /// below write it by that literal name.
    private let manifestName = ".mobilellm-download-manifest.json"

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-dl-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// Write a minimal valid download manifest listing `(relativePath, expectedSize)` pairs.
    private func writeManifest(_ root: URL, files: [(String, Int64)]) throws {
        let entries = files.map { #"{"path":"\#($0.0)","size":\#($0.1)}"# }.joined(separator: ",")
        let json = #"{"version":1,"files":[\#(entries)]}"#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appending(component: manifestName))
    }

    // MARK: - Multi-shard index completeness

    /// A `model.safetensors.index.json` names every shard; the repo is complete only once ALL of them are
    /// physically present. A missing shard must read as not-downloaded (a partial multi-GB model is not
    /// safe to load).
    func testShardedRepoIncompleteUntilEveryReferencedShardPresent() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/sharded"
        let root = dl.localURL(repoId: repo)
        let shard1 = "model-00001-of-00002.safetensors"
        let shard2 = "model-00002-of-00002.safetensors"
        try write(root.appending(component: "model.safetensors.index.json"), bytes: 0)
        // Overwrite the index with a real weight_map referencing both shards.
        let index = #"{"weight_map":{"a.weight":"\#(shard1)","b.weight":"\#(shard2)"}}"#
        try Data(index.utf8).write(to: root.appending(component: "model.safetensors.index.json"))

        try write(root.appending(component: shard1), bytes: 2048)
        XCTAssertFalse(dl.isDownloaded(repoId: repo), "one shard still missing → incomplete")

        try write(root.appending(component: shard2), bytes: 2048)
        XCTAssertTrue(dl.isDownloaded(repoId: repo), "all referenced shards present → complete")
    }

    // MARK: - Manifest size verification

    /// A written manifest is the authoritative record: if a listed file's on-disk size no longer matches
    /// the recorded size (truncation/corruption), the repo must read as not-downloaded so it re-fetches.
    func testManifestSizeMismatchReadsAsNotDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/manifested"
        let root = dl.localURL(repoId: repo)
        try write(root.appending(component: "model.safetensors"), bytes: 100)

        try writeManifest(root, files: [("model.safetensors", 100)])
        XCTAssertTrue(dl.isDownloaded(repoId: repo), "manifest size matches on-disk → complete")

        try writeManifest(root, files: [("model.safetensors", 999)])
        XCTAssertFalse(dl.isDownloaded(repoId: repo), "manifest size no longer matches → re-download")
    }

    // MARK: - In-progress markers

    /// A stray `.incomplete` marker anywhere under the repo means an install is mid-flight → not downloaded,
    /// even when the weights + manifest otherwise verify. (The existing suite covers `.part` for the
    /// single-file probe; this covers `.incomplete` on the flat-repo path.)
    func testIncompleteMarkerReadsAsNotDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/marker"
        let root = dl.localURL(repoId: repo)
        try write(root.appending(component: "model.safetensors"), bytes: 100)
        try writeManifest(root, files: [("model.safetensors", 100)])
        XCTAssertTrue(dl.isDownloaded(repoId: repo), "baseline: verifies as complete")

        try write(root.appending(component: "model.safetensors.incomplete"), bytes: 10)
        XCTAssertFalse(dl.isDownloaded(repoId: repo), "an .incomplete marker → mid-flight, not complete")
    }

    // MARK: - Empty-directory guard

    /// An existing-but-empty repo directory (no manifest, no weights) must never read as complete — the
    /// no-manifest fallback requires the weights to be physically present.
    func testEmptyRepoDirectoryIsNotDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/empty"
        try FileManager.default.createDirectory(at: dl.localURL(repoId: repo), withIntermediateDirectories: true)
        XCTAssertFalse(dl.isDownloaded(repoId: repo), "an empty directory is not a complete download")
    }

    /// The no-manifest fallback still accepts a flat repo whose weights are physically present (an older
    /// install / HF-CLI cache with no manifest is not forced into a needless re-download).
    func testNoManifestButWeightsPresentIsDownloaded() throws {
        let dl = ModelDownloader(downloadBase: base)
        let repo = "org/nomanifest"
        try write(dl.localURL(repoId: repo).appending(component: "model.safetensors"), bytes: 4096)
        XCTAssertTrue(dl.isDownloaded(repoId: repo), "weights present, no manifest → still complete")
    }
}
