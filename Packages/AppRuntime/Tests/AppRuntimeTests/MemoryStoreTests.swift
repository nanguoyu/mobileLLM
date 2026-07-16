// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// The durable `MemoryStore`: save→list round-trip, persistence across re-instantiation (the tool's whole
/// point — facts survive an app relaunch), delete, and whitespace trimming. Backed by a temp file so the
/// suite stays hermetic.
final class MemoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(component: "MemoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSaveAndListPreservesOrder() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        await store.save("alpha")
        await store.save("beta")
        let facts = await store.list()
        XCTAssertEqual(facts.map(\.text), ["alpha", "beta"])
    }

    func testPersistsAcrossReinstantiation() async {
        let url = dir.appending(component: "m.json")
        let saved = await MemoryStore(fileURL: url).save("remember me")
        // A brand-new store at the same URL must read the saved fact back from disk.
        let facts = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(facts.map(\.text), ["remember me"])
        XCTAssertEqual(facts.first?.id, saved.id, "the stable id survives persistence")
    }

    func testDeleteRemovesFact() async {
        let url = dir.appending(component: "m.json")
        let store = MemoryStore(fileURL: url)
        let keep = await store.save("keep")
        let drop = await store.save("drop")
        await store.delete(id: drop.id)
        let reloaded = await MemoryStore(fileURL: url).list()
        XCTAssertEqual(reloaded.map(\.text), ["keep"])
        XCTAssertEqual(reloaded.first?.id, keep.id)
    }

    func testSaveTrimsWhitespace() async {
        let store = MemoryStore(fileURL: dir.appending(component: "m.json"))
        let fact = await store.save("   spaced out   ")
        XCTAssertEqual(fact.text, "spaced out")
    }
}
