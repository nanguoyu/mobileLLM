// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The config-driven `ToolRegistry.assemble`: the default privacy-free set, the gate that a tool needs both
/// enabling AND its injected dependency, per-tool disabling, and the invariant that every `ToolID` rawValue
/// maps to exactly one advertised tool name.
final class ToolRegistryAssembleTests: XCTestCase {

    private func names(_ registry: ToolRegistry) -> Set<String> {
        Set(registry.tools.map(\.schema.name))
    }

    func testDefaultAssemblesPrivacyFreeToolsOnly() {
        let n = names(ToolRegistry.assemble())
        XCTAssertTrue(n.isSuperset(of: ["calculator", "current_datetime", "wikipedia",
                                        "web_search", "fetch_webpage"]))
        // No store injected → memory tools absent even though enabled by default.
        XCTAssertFalse(n.contains("remember"))
        XCTAssertFalse(n.contains("recall"))
        // Privacy-sensitive tools are off by default.
        XCTAssertFalse(n.contains("create_calendar_event"))
        XCTAssertFalse(n.contains("current_location"))
    }

    func testMemoryToolsAppearOnlyWithStore() {
        XCTAssertFalse(names(ToolRegistry.assemble()).contains("remember"))
        let n = names(ToolRegistry.assemble(memoryStore: FakeMemoryStore()))
        XCTAssertTrue(n.contains("remember"))
        XCTAssertTrue(n.contains("recall"))
    }

    func testCalendarToolsNeedEnableAndStore() {
        // A store alone isn't enough — calendar ids are off by default.
        XCTAssertFalse(names(ToolRegistry.assemble(eventStore: FakeEventStore())).contains("create_calendar_event"))
        let cfg = BuiltInToolConfig(enabled: BuiltInToolConfig.defaultEnabled
            .union([.createCalendarEvent, .listCalendarEvents, .createReminder]))
        let n = names(ToolRegistry.assemble(config: cfg, eventStore: FakeEventStore()))
        XCTAssertTrue(n.isSuperset(of: ["create_calendar_event", "list_calendar_events", "create_reminder"]))
    }

    func testLocationToolNeedsEnableAndProvider() {
        let cfg = BuiltInToolConfig(enabled: BuiltInToolConfig.defaultEnabled.union([.currentLocation]))
        // Enabled but no provider → absent.
        XCTAssertFalse(names(ToolRegistry.assemble(config: cfg)).contains("current_location"))
        // Enabled + provider → present.
        let n = names(ToolRegistry.assemble(config: cfg,
                                            locationProvider: FakeLocationProvider(result: .failure(.denied))))
        XCTAssertTrue(n.contains("current_location"))
    }

    func testDisablingToolRemovesIt() {
        var cfg = BuiltInToolConfig()
        cfg.enabled.remove(.webSearch)
        let n = names(ToolRegistry.assemble(config: cfg))
        XCTAssertFalse(n.contains("web_search"))
        XCTAssertTrue(n.contains("calculator"))
    }

    func testEveryToolIDMapsToATool() {
        let cfg = BuiltInToolConfig(enabled: Set(ToolID.allCases))
        let registry = ToolRegistry.assemble(
            config: cfg,
            memoryStore: FakeMemoryStore(),
            eventStore: FakeEventStore(),
            locationProvider: FakeLocationProvider(result: .failure(.denied)))
        XCTAssertEqual(names(registry), Set(ToolID.allCases.map(\.rawValue)),
                       "assembling every ToolID must yield exactly those tool names")
    }
}
