// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import AppRuntime

/// Regression coverage for the one-time migration from legacy manifests, which recorded Hugging Face
/// LFS digests but did not establish that the bytes matched them. Routine launch probes must never hash
/// model weights; the explicit async audit owns that work and promotes only a verified snapshot.
final class ModelDownloaderLegacyManifestAuditTests: XCTestCase {

    private let manifestName = ".mobilellm-download-manifest.json"
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appending(component: "mobilellm-legacy-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func fixture(
        repo: String,
        bytes: Data,
        expectedDigest: String? = nil
    ) throws -> (downloader: ModelDownloader, root: URL, weights: URL, manifest: URL) {
        let downloader = ModelDownloader(downloadBase: base)
        let root = downloader.localURL(repoId: repo)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let weights = root.appending(component: "model.gguf")
        try bytes.write(to: weights)
        let digest = expectedDigest ?? sha256(bytes)
        let manifest = root.appending(component: manifestName)
        let json: [String: Any] = [
            "version": 1,
            "files": [[
                "path": "model.gguf",
                "size": bytes.count,
                "sha256": digest,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
        return (downloader, root, weights, manifest)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifestJSON(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    func testRoutineProbeRejectsVersionOneWithoutPromotingIt() throws {
        let item = try fixture(repo: "legacy/routine", bytes: Data(repeating: 0x11, count: 4_096))

        XCTAssertFalse(item.downloader.isDownloaded(repoId: "legacy/routine"),
                       "a synchronous launch probe must not trust or hash an unaudited v1 manifest")
        XCTAssertEqual((try manifestJSON(at: item.manifest)["version"] as? NSNumber)?.intValue, 1,
                       "a routine presence check must remain side-effect free")
    }

    func testCorrectVersionOneSHAIsAuditedAndUpgradedToVersionTwo() async throws {
        let item = try fixture(repo: "legacy/valid", bytes: Data(repeating: 0xA5, count: 8_192))

        let result = await item.downloader.auditAndUpgradeLegacyManifest(repoId: "legacy/valid")

        XCTAssertEqual(result, .upgraded)
        let manifest = try manifestJSON(at: item.manifest)
        XCTAssertEqual((manifest["version"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(manifest["revision"] as? String, "main")
        XCTAssertTrue(item.downloader.isDownloaded(repoId: "legacy/valid"))
        XCTAssertTrue(item.downloader.verifyDownloadedIntegrity(repoId: "legacy/valid"))
    }

    func testSameSizeWrongContentIsInvalidAndDoesNotUpgrade() async throws {
        let correctBytes = Data(repeating: 0x33, count: 8_192)
        let expected = sha256(correctBytes)
        let item = try fixture(
            repo: "legacy/wrong",
            bytes: Data(repeating: 0x44, count: 8_192),
            expectedDigest: expected
        )

        let result = await item.downloader.auditAndUpgradeLegacyManifest(repoId: "legacy/wrong")

        XCTAssertEqual(result, .invalid)
        XCTAssertEqual((try manifestJSON(at: item.manifest)["version"] as? NSNumber)?.intValue, 1,
                       "failed integrity must never acquire v2's trusted-download meaning")
        XCTAssertFalse(item.downloader.isDownloaded(repoId: "legacy/wrong"))

        let failureMark = item.root.appending(component: ".mobilellm-legacy-audit-failure.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureMark.path))
        // Repairing only the bytes leaves the exact rejected manifest fingerprint in place. A later
        // launch must use the durable failure mark instead of hashing the same multi-GB snapshot again;
        // a normal redownload replaces the manifest and clears the mark.
        try correctBytes.write(to: item.weights)
        let repeatedAudit = await item.downloader
            .auditAndUpgradeLegacyManifest(repoId: "legacy/wrong")
        XCTAssertEqual(repeatedAudit, .invalid)
        XCTAssertEqual((try manifestJSON(at: item.manifest)["version"] as? NSNumber)?.intValue, 1)
    }

    func testSecondAuditIsNotRequiredAndDoesNotRehashVersionTwo() async throws {
        let item = try fixture(repo: "legacy/once", bytes: Data(repeating: 0x5A, count: 8_192))
        let firstAudit = await item.downloader.auditAndUpgradeLegacyManifest(repoId: "legacy/once")
        XCTAssertEqual(firstAudit, .upgraded)

        // Preserve the size while breaking the digest. A second legacy audit must stop at the v2 metadata
        // and report `notRequired`; the opt-in deep audit below proves the bytes no longer match.
        try Data(repeating: 0xC3, count: 8_192).write(to: item.weights)

        let secondAudit = await item.downloader.auditAndUpgradeLegacyManifest(repoId: "legacy/once")
        XCTAssertEqual(secondAudit, .notRequired)
        XCTAssertEqual((try manifestJSON(at: item.manifest)["version"] as? NSNumber)?.intValue, 2)
        XCTAssertTrue(item.downloader.isDownloaded(repoId: "legacy/once"),
                      "routine v2 probes use the established attestation plus file size")
        XCTAssertFalse(item.downloader.verifyDownloadedIntegrity(repoId: "legacy/once"),
                       "the explicit deep audit still detects post-download same-size mutation")
    }
}
