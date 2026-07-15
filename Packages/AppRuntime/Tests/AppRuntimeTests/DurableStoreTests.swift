// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

private struct Rec: Codable, Equatable, Sendable {
    var id: Int
    var text: String
}

final class DurableStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(component: "DurableStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Round-trips records and leaves no stray temp file behind (atomic temp → rename).
    func testAtomicSaveAndLoad() async throws {
        let url = dir.appending(component: "store.json")
        let store = DurableStore<Rec>(fileURL: url)
        let records = [Rec(id: 1, text: "alpha"), Rec(id: 2, text: "beta")]
        try await store.save(records)

        let reloaded = await DurableStore<Rec>(fileURL: url).load()
        XCTAssertEqual(reloaded, records)

        // No `.tmp` sibling should remain after an atomic write.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    /// Missing file → empty (a genuinely empty store, first launch).
    func testMissingFileIsEmpty() async {
        let url = dir.appending(component: "absent.json")
        let loaded = await DurableStore<Rec>(fileURL: url).load()
        XCTAssertEqual(loaded, [])
    }

    /// A corrupt (present-but-unreadable) manifest is recovered from, NOT wiped: load returns empty,
    /// and the bad file is moved aside to `<name>.corrupt` so the bytes survive.
    func testCorruptManifestRecoversNotWipes() async throws {
        let url = dir.appending(component: "store.json")
        try Data("{ this is not valid json ".utf8).write(to: url)

        let store = DurableStore<Rec>(fileURL: url)
        let loaded = await store.load()
        XCTAssertEqual(loaded, [], "corrupt manifest should recover to empty, not crash")

        let backup = url.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "corrupt manifest must be backed up, not deleted")
        // The data survives in the backup (back-up-not-wipe).
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertFalse(backupBytes.isEmpty)

        // A subsequent save rebuilds a clean, readable manifest.
        try await store.save([Rec(id: 9, text: "recovered")])
        let after = await DurableStore<Rec>(fileURL: url).load()
        XCTAssertEqual(after, [Rec(id: 9, text: "recovered")])
    }

    /// Within a readable manifest, a single bad record element is skipped — the good ones still load.
    func testBadRecordIsSkipped() async throws {
        let url = dir.appending(component: "store.json")
        // Valid envelope; second record's `id` is the wrong type so only that element fails to decode.
        let json = """
        {
          "version": 1,
          "records": [
            { "id": 1, "text": "ok" },
            { "id": "not-an-int", "text": "bad" },
            { "id": 3, "text": "also ok" }
          ]
        }
        """
        try Data(json.utf8).write(to: url)

        let loaded = await DurableStore<Rec>(fileURL: url).load()
        XCTAssertEqual(loaded, [Rec(id: 1, text: "ok"), Rec(id: 3, text: "also ok")])
        // A valid-but-lossy manifest is not "corrupt" — no backup should be made.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }
}
