// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
import AppRuntime
import LLMCore

/// D2 registry wiring: the cache signature that makes a tool toggle take effect on the next send (not the
/// next launch), and that a settings-derived `BuiltInToolConfig` assembles the right tools given the injected
/// seams. Pure — no network, no EventKit/CoreLocation, no permission prompts.
final class ToolRegistryWiringTests: XCTestCase {

    private func names(_ registry: ToolRegistry) -> Set<String> { Set(registry.tools.map(\.schema.name)) }

    // MARK: - Cache signature (tool-toggle invalidation)

    func testSignatureChangesWhenABuiltInToolIsToggled() {
        var config = BuiltInToolConfig()
        let before = ChatStore.registrySignature(config: config, servers: [])
        config.enabled.remove(.webSearch)
        let after = ChatStore.registrySignature(config: config, servers: [])
        XCTAssertNotEqual(before, after, "disabling a built-in tool must invalidate the cached registry")
    }

    func testSignatureChangesWhenSearchEnginePriorityChanges() {
        let a = ChatStore.registrySignature(config: BuiltInToolConfig(searchEngines: [.duckduckgo, .bing]), servers: [])
        let b = ChatStore.registrySignature(config: BuiltInToolConfig(searchEngines: [.bing, .duckduckgo]), servers: [])
        XCTAssertNotEqual(a, b, "engine priority order is part of the signature")
    }

    func testSignatureStableForEqualInputs() {
        let config = BuiltInToolConfig()
        let servers = [MCPServer(name: "A", url: "https://a/mcp", token: "t", disabledTools: ["x"])]
        XCTAssertEqual(ChatStore.registrySignature(config: config, servers: servers),
                       ChatStore.registrySignature(config: config, servers: servers),
                       "equal inputs hit the cache (no needless re-handshake)")
    }

    func testSignatureChangesWhenAnMCPToolIsMuted() {
        let config = BuiltInToolConfig()
        let plain = ChatStore.registrySignature(config: config, servers: [MCPServer(name: "A", url: "https://a/mcp")])
        let muted = ChatStore.registrySignature(config: config,
                                                servers: [MCPServer(name: "A", url: "https://a/mcp", disabledTools: ["x"])])
        XCTAssertNotEqual(plain, muted, "muting an MCP tool must invalidate the cache")
    }

    // MARK: - Assemble from a settings-derived config (mock seams)

    /// The wiring D2 relies on: a config with web_search disabled + calendar enabled, assembled with the
    /// injected seams, yields the calendar + memory tools but NOT web_search.
    func testAssembleRespectsDisabledSetAndInjectedSeams() {
        var config = BuiltInToolConfig()
        config.enabled.remove(.webSearch)
        config.enabled.formUnion([.createCalendarEvent, .listCalendarEvents])
        let registry = ToolRegistry.assemble(config: config,
                                             memoryStore: FakeMemoryStoreUI(),
                                             eventStore: FakeEventStoreUI(),
                                             locationProvider: FakeLocationProviderUI())
        let n = names(registry)
        XCTAssertFalse(n.contains("web_search"), "a disabled tool is dropped")
        XCTAssertTrue(n.isSuperset(of: ["create_calendar_event", "list_calendar_events"]),
                      "enabled + injected store → present")
        XCTAssertTrue(n.isSuperset(of: ["remember", "recall"]), "memory store injected + enabled by default")
    }

    /// Without injected seams (the ChatStore path in tests/previews), privacy tools stay absent even when
    /// enabled — so the calendar/location tools never surface there.
    func testAssembleWithoutSeamsOmitsInjectedTools() {
        var config = BuiltInToolConfig()
        config.enabled.formUnion([.createCalendarEvent, .currentLocation])
        let n = names(ToolRegistry.assemble(config: config))
        XCTAssertFalse(n.contains("create_calendar_event"))
        XCTAssertFalse(n.contains("current_location"))
        XCTAssertFalse(n.contains("remember"))
        XCTAssertTrue(n.contains("calculator"), "privacy-free tools need nothing injected")
    }
}

// MARK: - In-memory seams (no disk / EventKit / CoreLocation)

private actor FakeMemoryStoreUI: MemoryStoring {
    @discardableResult func save(_ text: String) -> MemoryFact { MemoryFact(text: text) }
    func list() -> [MemoryFact] { [] }
    func delete(id: String) {}
}

private actor FakeEventStoreUI: EventStoring {
    func createEvent(_ draft: CalendarEventDraft) throws -> String { draft.title }
    func events(daysAhead: Int) throws -> [CalendarEventInfo] { [] }
    func createReminder(_ draft: ReminderDraft) throws -> String { draft.title }
}

private struct FakeLocationProviderUI: LocationProviding {
    func currentLocation() async throws -> LocationFix { throw LocationError.denied }
}
