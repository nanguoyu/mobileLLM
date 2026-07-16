// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `SkillStore`: first-load seeding of the built-ins, seed-once (a relaunch never duplicates them), CRUD
/// persistence across reload, built-in immutability, and duplicate-to-edit (Skills v1, S6). Backed by temp
/// files so the suite stays hermetic.
@MainActor
final class SkillStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(component: "SkillStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appending(component: "skills.json") }

    /// Reload from a FRESH store at the same URL, polling until `predicate` holds (mutations persist through
    /// a fire-and-forget task, like `ChatStore.persist`).
    private func pollReload(until predicate: @escaping ([Skill]) -> Bool,
                            timeout: TimeInterval = 2) async throws -> [Skill] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let store = SkillStore(fileURL: url)
            await store.load()
            if predicate(store.skills) { return store.skills }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let store = SkillStore(fileURL: url)
        await store.load()
        return store.skills   // last read — the assertion will surface the diff
    }

    // MARK: - Seeding

    func testFirstLoadSeedsBuiltIns() async {
        let store = SkillStore(fileURL: url)
        await store.load()
        XCTAssertEqual(store.skills, Skill.builtIns, "an empty store seeds exactly the five built-ins")
        XCTAssertEqual(store.customSkills.count, 0)
    }

    func testSecondLoadDoesNotDuplicateBuiltIns() async {
        await SkillStore(fileURL: url).load()   // first instance seeds + writes to disk
        let relaunched = SkillStore(fileURL: url)
        await relaunched.load()                 // fresh instance at the same file
        XCTAssertEqual(relaunched.builtInSkills.count, 5, "a relaunch reads the five back, never re-seeds")
        XCTAssertEqual(relaunched.skills, Skill.builtIns)
    }

    func testRepeatedLoadOnSameInstanceIsIdempotent() async {
        let store = SkillStore(fileURL: url)
        await store.load()
        await store.load()   // second call is a no-op (hasLoaded guard)
        XCTAssertEqual(store.skills.count, 5)
    }

    // MARK: - CRUD persistence

    func testCreateUpdateDeletePersistAcrossReload() async throws {
        let store = SkillStore(fileURL: url)
        await store.load()

        let created = store.create(name: "Pirate", emoji: "🏴", summary: "arr",
                                   instructions: "Answer as a pirate.")
        XCTAssertFalse(created.isBuiltIn, "created skills are custom")
        var reloaded = try await pollReload { $0.contains { $0.id == created.id } }
        XCTAssertEqual(reloaded.count, 6, "five built-ins + one custom, persisted")

        store.update(Skill(id: created.id, name: "Fancy Pirate", emoji: "🏴", summary: "arr",
                           instructions: "Answer as a fancy pirate.", isBuiltIn: false))
        reloaded = try await pollReload { $0.first { $0.id == created.id }?.name == "Fancy Pirate" }
        XCTAssertEqual(reloaded.first { $0.id == created.id }?.instructions, "Answer as a fancy pirate.")

        store.delete(id: created.id)
        reloaded = try await pollReload { !$0.contains { $0.id == created.id } }
        XCTAssertEqual(reloaded.count, 5, "deleting the custom skill leaves just the built-ins")
    }

    // MARK: - Built-in immutability

    func testBuiltInsCannotBeUpdatedOrDeleted() async {
        let store = SkillStore(fileURL: url)
        await store.load()
        let builtIn = store.builtInSkills[0]

        store.update(Skill(id: builtIn.id, name: "HACKED", emoji: "💀", summary: "x",
                           instructions: "y", isBuiltIn: false))
        XCTAssertEqual(store.skill(id: builtIn.id)?.name, builtIn.name, "update is a no-op on a built-in")

        store.delete(id: builtIn.id)
        XCTAssertNotNil(store.skill(id: builtIn.id), "delete is a no-op on a built-in")
        XCTAssertEqual(store.builtInSkills.count, 5)
    }

    // MARK: - Duplicate

    func testDuplicateMakesEditableCustomCopy() async {
        let store = SkillStore(fileURL: url)
        await store.load()
        let original = store.builtInSkills[0]

        let copy = store.duplicate(original)
        XCTAssertFalse(copy.isBuiltIn, "the copy is a custom skill")
        XCTAssertNotEqual(copy.id, original.id, "the copy has its own id")
        XCTAssertEqual(copy.instructions, original.instructions, "the behavior is carried over")
        XCTAssertTrue(copy.name.contains(original.name), "the copy is clearly derived from the original")
        XCTAssertEqual(store.customSkills.count, 1)
        // The copy is now editable (unlike its built-in source).
        store.update(Skill(id: copy.id, name: "Mine", emoji: copy.emoji, summary: copy.summary,
                           instructions: "changed", isBuiltIn: false))
        XCTAssertEqual(store.skill(id: copy.id)?.instructions, "changed")
    }

    func testCreateTrimsAndClampsEmojiToOne() async {
        let store = SkillStore(fileURL: url)
        await store.load()
        let skill = store.create(name: "  Spaced  ", emoji: "🔥🔥🔥", summary: "  s  ",
                                 instructions: "  do it  ")
        XCTAssertEqual(skill.name, "Spaced", "name is whitespace-trimmed")
        XCTAssertEqual(skill.summary, "s")
        XCTAssertEqual(skill.instructions, "do it")
        XCTAssertEqual(skill.emoji.count, 1, "the glyph is clamped to a single emoji")
    }
}
