// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import AppRuntime
import LLMCore
import MobileLLMUI

// MARK: - Tool catalog

/// The app's Tool V2 catalog: every built-in the UI can enable has a Tool V2 adapter, so the agent
/// runtime advertises exactly what it can execute. Network tools (web search, Wikipedia, webpage
/// reading) cross approved network boundaries; memory/calendar/reminders/location cross private-data
/// boundaries gated on their app seams; MCP tools come from explicit discovery.
final class AppToolCatalog: ExecutableToolCatalog, @unchecked Sendable {
    static let adaptedToolNames = AppLocalToolIDs.names

    let snapshot: ToolCatalogSnapshot
    let adapters: [AgentToolDescriptorID: any ToolV2]
    private let mcpCache: MCPDiscoveryCache
    private let session: URLSession
    private let deepSeekAPIKey: DeepSeekAPIKeyResolver

    static func catalog(
        enabledToolNames: [String],
        memoryAvailable: Bool,
        eventSeamAvailable: Bool,
        locationSeamAvailable: Bool,
        mcpDescriptors: [AgentToolDescriptor] = [],
        trustRevision: String = "builtin.v1",
        deepSeekWebServiceID: String? = nil
    ) throws -> ToolCatalogSnapshot {
        let builtIns = ToolRegistry.standard.tools
        var descriptors: [AgentToolDescriptor] = []
        var unavailable: [UnavailableTool] = []
        for tool in builtIns {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: tool.schema.name)
            let enabled = enabledToolNames.contains(tool.schema.name)
            let seamMissing = (tool.schema.name == "remember" || tool.schema.name == "recall")
                && !memoryAvailable
            if Self.adaptedToolNames.contains(tool.schema.name), enabled, !seamMissing
            {
                if let serviceID = deepSeekWebServiceID,
                   let operation = [DeepSeekWebOperation.search, .fetch].first(where: { $0.toolName == tool.schema.name }) {
                    descriptors.append(try AppDeepSeekWebToolAdapter.makeDescriptor(operation: operation, serviceID: serviceID))
                    continue
                }
                let inputSchema = try AppToolV2Support.inputSchema(for: tool.schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: tool.schema.name,
                    summary: tool.schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: tool.schema.name),
                    requiredCapabilities: Self.requiredCapabilities(for: tool.schema.name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: tool.schema.name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: tool.schema.name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        // Memory tools are opt-in seams and therefore absent from `ToolRegistry.standard`; the frozen
        // catalog must advertise them explicitly or the selector reports `descriptorMissing` for a
        // perfectly valid `remember`/`recall` call (the executor adapters exist, the descriptors did not).
        for (name, schema) in [("remember", RememberTool.schema), ("recall", RecallTool.schema)] {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: name)
            if enabledToolNames.contains(name), memoryAvailable {
                let inputSchema = try AppToolV2Support.inputSchema(for: schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: schema.name,
                    summary: schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: name),
                    requiredCapabilities: Self.requiredCapabilities(for: name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        // Calendar, reminders and location are also opt-in system seams (EventKit / CoreLocation),
        // absent from `ToolRegistry.standard`; advertise them exactly when their seam is available.
        let systemDataTools: [(name: String, schema: ToolSchema, seam: Bool)] = [
            ("create_calendar_event", CreateCalendarEventTool.schema, eventSeamAvailable),
            ("list_calendar_events", ListCalendarEventsTool.schema, eventSeamAvailable),
            ("create_reminder", CreateReminderTool.schema, eventSeamAvailable),
            ("current_location", CurrentLocationTool.schema, locationSeamAvailable),
        ]
        for entry in systemDataTools {
            let logicalID = try AgentToolLogicalID(providerID: "builtin", name: entry.name)
            if enabledToolNames.contains(entry.name), entry.seam {
                let inputSchema = try AppToolV2Support.inputSchema(for: entry.schema)
                descriptors.append(try AgentToolDescriptor(
                    id: AgentToolDescriptorID(
                        logicalID: logicalID,
                        version: SemanticVersion("1.0.0")!,
                        schemaDigest: inputSchema.digest,
                        trustRevision: trustRevision
                    ),
                    title: entry.schema.name,
                    summary: entry.schema.description,
                    inputSchema: inputSchema,
                    outputSchema: nil,
                    effects: Self.effects(for: entry.name),
                    requiredCapabilities: Self.requiredCapabilities(for: entry.name),
                    timeoutPolicy: ToolTimeoutPolicy(
                        maximumMilliseconds: Self.timeoutMilliseconds(for: entry.name)
                    ),
                    retryPolicy: .never,
                    idempotency: Self.idempotency(for: entry.name),
                    supportsProgress: false,
                    supportsCancellation: true
                ))
            } else {
                unavailable.append(
                    UnavailableTool(
                        logicalID: logicalID,
                        reason: .providerUnavailable
                    )
                )
            }
        }
        descriptors.append(contentsOf: mcpDescriptors.sorted { $0.id.description < $1.id.description })
        return try ToolCatalogSnapshot(
            revision: 1,
            descriptors: descriptors,
            unavailable: unavailable
        )
    }

    init(
        enabledToolNames: [String],
        memoryStore: (any MemoryStoring)?,
        eventStore: (any EventStoring)?,
        locationProvider: (any LocationProviding)?,
        mcpCache: MCPDiscoveryCache,
        session: URLSession = .shared,
        deepSeekAPIKey: @escaping DeepSeekAPIKeyResolver = { _ in nil }
    ) throws {
        self.session = session
        self.deepSeekAPIKey = deepSeekAPIKey
        let enabled = Set(enabledToolNames)
        var adapters: [AgentToolDescriptorID: any ToolV2] = [:]
        func register(_ adapter: any ToolV2) {
            adapters[adapter.descriptor.id] = adapter
        }
        if enabled.contains("calculator") {
            try register(LegacyLocalToolAdapter(
                tool: CalculatorTool(),
                providerID: "builtin",
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("current_datetime") {
            try register(LegacyLocalToolAdapter(
                tool: DateTimeTool(),
                providerID: "builtin",
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("web_search") {
            try register(AppWebSearchToolAdapter(
                tool: WebSearchTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("wikipedia") {
            try register(AppWikipediaToolAdapter(
                tool: WikipediaTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("fetch_webpage") {
            try register(AppWebScraperToolAdapter(
                tool: WebScraperTool(session: session),
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("create_calendar_event"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: CreateCalendarEventTool(store: eventStore),
                effects: [.localWrite],
                destinationIdentity: "mobilellm.calendar",
                dataCategory: "user.calendar",
                userPreview: "Add an event to the user's calendar",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("list_calendar_events"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: ListCalendarEventsTool(store: eventStore),
                effects: [.localRead],
                destinationIdentity: "mobilellm.calendar",
                dataCategory: "user.calendar",
                userPreview: "List the user's upcoming calendar events",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("create_reminder"), let eventStore {
            try register(AppSystemDataToolAdapter(
                tool: CreateReminderTool(store: eventStore),
                effects: [.localWrite],
                destinationIdentity: "mobilellm.reminders",
                dataCategory: "user.reminders",
                userPreview: "Create a reminder for the user",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 5_000
            ))
        }
        if enabled.contains("current_location"), let locationProvider {
            try register(AppSystemDataToolAdapter(
                tool: CurrentLocationTool(provider: locationProvider),
                effects: [.localRead],
                destinationIdentity: "mobilellm.location",
                dataCategory: "user.location",
                userPreview: "Get the user's approximate current location",
                trustRevision: "builtin.v1",
                timeoutMilliseconds: 15_000
            ))
        }
        if enabled.contains("remember"), let memoryStore {
            try register(AppMemoryToolAdapter(
                tool: RememberTool(store: memoryStore),
                effects: [.localWrite],
                trustRevision: "builtin.v1"
            ))
        }
        if enabled.contains("recall"), let memoryStore {
            try register(AppMemoryToolAdapter(
                tool: RecallTool(store: memoryStore),
                effects: [.localRead],
                trustRevision: "builtin.v1"
            ))
        }
        self.snapshot = try Self.catalog(
            enabledToolNames: enabledToolNames,
            memoryAvailable: memoryStore != nil,
            eventSeamAvailable: eventStore != nil,
            locationSeamAvailable: locationProvider != nil
        )
        self.adapters = adapters
        self.mcpCache = mcpCache
    }

    private static func effects(for name: String) -> [AgentEffect] {
        switch name {
        case "web_search": [.networkRead]
        case "wikipedia", "fetch_webpage": [.networkRead]
        case "remember": [.localWrite]
        case "recall": [.localRead]
        case "create_calendar_event", "create_reminder": [.localWrite]
        case "list_calendar_events", "current_location": [.localRead]
        default: [.localPure]
        }
    }

    private static func requiredCapabilities(for name: String) -> AgentCapabilitySet {
        AgentCapabilitySet(effects(for: name).compactMap(\.minimumCapability))
    }

    private static func idempotency(for name: String) -> ExternalIdempotency {
        // A write tool cannot declare pure-read idempotency (descriptor semantics validation).
        name == "remember" || name == "create_calendar_event" || name == "create_reminder"
            ? .nonIdempotent : .pureRead
    }

    private static func timeoutMilliseconds(for name: String) -> UInt64 {
        switch name {
        case "web_search", "wikipedia", "fetch_webpage": 30_000
        case "current_location": 15_000
        default: 5_000
        }
    }

    func localSnapshot() async throws -> ToolCatalogSnapshot { snapshot }

    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        if let adapter = adapters[descriptorID] { return adapter }
        if let serviceID = AppDeepSeekWebToolAdapter.serviceID(from: descriptorID),
           let operation = [DeepSeekWebOperation.search, .fetch].first(where: { $0.toolName == descriptorID.logicalID.name }) {
            let adapter = try AppDeepSeekWebToolAdapter(operation: operation, serviceID: serviceID,
                                                      session: session, resolveKey: deepSeekAPIKey)
            return adapter.descriptor.id == descriptorID ? adapter : nil
        }
        // MCP adapters are built lazily from the explicit discovery cache; a descriptor can only
        // appear in a frozen run if the user's setup/refresh flow discovered that server.
        let providerPrefix = "mcp."
        let providerID = descriptorID.logicalID.providerID
        guard providerID.hasPrefix(providerPrefix),
              let stableID = UUID(uuidString: String(providerID.dropFirst(providerPrefix.count))),
              let server = mcpCache.server(serverStableID: stableID)
        else { return nil }
        guard let spec = mcpCache.specs(serverStableID: stableID).first(where: {
            $0.name == descriptorID.logicalID.name
        }) else { return nil }
        return try MCPToolV2Adapter(
            client: MCPClient(server: server),
            spec: spec,
            serverStableID: stableID,
            trustRevision: "mcp.v1"
        )
    }
}

