// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import LLMCore

// MARK: - Shared schema / failure helpers

enum AppToolV2Support {
    enum ToolAdapterError: Error {
        case invalidBoundaryResult
    }

    /// Converts a legacy LLMCore schema into the Tool V2 Draft 2020-12 JSON Schema document.
    static func inputSchema(for schema: LLMCore.ToolSchema) throws -> JSONSchemaDocument {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for parameter in schema.parameters {
            let type: String = switch parameter.kind {
            case .string: "string"
            case .number: "number"
            case .boolean: "boolean"
            }
            properties[parameter.name] = .object([
                "type": .string(type),
                "description": .string(parameter.description),
            ])
            if parameter.required { required.append(.string(parameter.name)) }
        }
        return try JSONSchemaDocument(
            root: .object([
                "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required),
                "additionalProperties": .bool(false),
            ])
        )
    }

    static func cancelledFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "tool.cancelled",
            classification: .cancelled,
            safeMessage: "The tool stopped before producing a result.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    static func toolFailure(code: String, message: String) throws -> AgentFailure {
        try AgentFailure(
            code: code,
            classification: .permanent,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    /// Extracts a bounded text payload carried out of a boundary as canonical JSON.
    static func textValue(_ value: ExternalOperationBoundaryValue) throws -> String? {
        guard case .canonicalJSON(let json) = value else { return nil }
        let decoded = try AgentWireDecoder.decode(JSONValue.self, from: json.data, limits: .inlineValue)
        guard case .string(let text) = decoded else { return nil }
        return text
    }

    static func canonicalText(_ text: String) throws -> ExternalOperationBoundaryCompletion {
        try ExternalOperationBoundaryCompletion(
            value: .canonicalJSON(CanonicalJSON(.string(text)))
        )
    }
}

// MARK: - Web Search (networkRead, requires approval)

/// Adapts the legacy `WebSearchTool` to Tool V2. Every engine fetch crosses the authorization gate as
/// its own bounded network hop; the primary engine is the plan destination and the rest are fallbacks.
public final class AppWebSearchToolAdapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: WebSearchTool
    private let frozenSchema: LLMCore.ToolSchema
    private let engines: [SearchEngine]
    private let maximumResponseBytes: UInt64
    private let timeoutMilliseconds: UInt64

    public init(
        tool: WebSearchTool,
        providerID: String = "builtin",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 30_000,
        maximumResponseBytes: UInt64 = 2 * 1_024 * 1_024
    ) throws {
        let schema = tool.schema
        let inputSchema = try AppToolV2Support.inputSchema(for: schema)
        let logicalID = try AgentToolLogicalID(providerID: providerID, name: schema.name)
        descriptor = try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: logicalID,
                version: version,
                schemaDigest: inputSchema.digest,
                trustRevision: trustRevision
            ),
            title: schema.name,
            summary: schema.description,
            inputSchema: inputSchema,
            outputSchema: nil,
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: timeoutMilliseconds),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: false,
            supportsCancellation: true
        )
        self.tool = tool
        frozenSchema = schema
        engines = tool.engines
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor,
              request.proposedCall.toolID == descriptor.id.logicalID,
              tool.schema == frozenSchema
        else { throw ToolV2ContractError.descriptorMismatch }
        let query = Self.query(from: request.sanitizedArguments.string) ?? ""
        // The plan is the authority-bounded itinerary: only engines the run ceiling actually granted
        // may be called or offered as fallbacks. The shared adapter's engine list is a superset of the
        // per-run ceiling (settings may change after the executor is built), so intersect it here.
        let grantedDestinations = context.capabilityGrant.authority.destinations
        let destinations = try engines
            .map { try Self.destination(engine: $0) }
            .filter { grantedDestinations.contains($0) }
        guard let first = destinations.first else {
            throw AgentContractError.capabilityEscalation([])
        }
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: first,
            allowedFallbacks: Array(destinations.dropFirst()),
            dataCategories: [try AgentDataCategory(rawValue: "web.search")],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: query.isEmpty ? "Search the web" : "Search the web for: \(query)",
            descriptorID: descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    public func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard prepared.prepared.request.descriptor == descriptor,
                          prepared.prepared.request.proposedCall.toolID == descriptor.id.logicalID,
                          tool.schema == frozenSchema
                    else { throw ToolV2ContractError.executingWrongDescriptor }
                    let query = Self.query(from: prepared.prepared.request.sanitizedArguments.string)
                    guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                        continuation.yield(.failed(
                            try AppToolV2Support.toolFailure(
                                code: "tool.web-search.missing-query",
                                message: "Web search requires a non-empty query."
                            )
                        ))
                        continuation.finish()
                        return
                    }
                    for engine in engines {
                        if await context.cancellation.isCancelled() { throw CancellationError() }
                        // Never hop outside the plan: the ceiling may authorize a subset of the shared
                        // adapter's engines (settings changes after executor build), and every hop must
                        // stay inside the plan the user approved.
                        let allowedDestinations = Set(
                            [prepared.prepared.request.plan.destination].compactMap { $0 }
                                + prepared.prepared.request.plan.allowedFallbacks
                        )
                        guard let engineDestination = try? Self.destination(engine: engine),
                              allowedDestinations.contains(engineDestination)
                        else { continue }
                        do {
                            let boundary = try await context.performBoundary(
                                observation: ExternalOperationObservation(
                                    destination: engineDestination,
                                    dataCategories: [try AgentDataCategory(rawValue: "web.search")],
                                    effects: [.networkRead],
                                    requestBytes: UInt64(query.utf8.count),
                                    responseBytesLimit: maximumResponseBytes,
                                    payloadDigest: StableDigest.sha256(Data(query.utf8)),
                                    descriptorID: descriptor.id.description,
                                    schemaDigest: descriptor.id.schemaDigest,
                                    trustRevision: descriptor.id.trustRevision
                                ),
                                operation: { control in
                                    let html = try await self.tool.fetchHTML(query: query, engine: engine)
                                    try await control.consumeResponseBytes(UInt64(html.count))
                                    guard let decoded = String(data: html, encoding: .utf8)
                                        ?? String(data: html, encoding: .isoLatin1)
                                    else { throw WebSearchTool.ToolNetError.badResponse }
                                    let results = WebSearchTool.parse(engine: engine, html: decoded)
                                    guard !results.isEmpty else {
                                        throw WebSearchTool.ToolNetError.badResponse
                                    }
                                    return try AppToolV2Support.canonicalText(
                                        WebSearchTool.render(results, query: query)
                                    )
                                }
                            )
                            guard let text = try AppToolV2Support.textValue(boundary.value) else {
                                throw WebSearchTool.ToolNetError.badResponse
                            }
                            try Task.checkCancellation()
                            let results = try ToolResultCollection([
                                .text(try ToolTextResult(text)),
                            ])
                            continuation.yield(.completed(results))
                            continuation.finish()
                            return
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // This engine failed or returned nothing; fall through to the next one.
                        }
                    }
                    continuation.yield(.failed(
                        try AppToolV2Support.toolFailure(
                            code: "tool.web-search.unreachable",
                            message: "Web search failed: all search engines returned no results or were unreachable."
                        )
                    ))
                    continuation.finish()
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.cancelledFailure()))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func query(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String
        else { return nil }
        return query
    }

    /// Host-only destination for one engine. Public so the app's run ceiling can enumerate the exact
    /// bounded endpoint set from the user's configured engines.
    public static func destination(engine: SearchEngine) throws -> ExternalDestination {
        // The DESTINATION is the engine host, not the query-specific URL: a run ceiling can enumerate
        // the bounded endpoint set, and the query itself travels as the canonical argument.
        guard let url = WebSearchTool.endpoint(engine: engine, query: "probe"),
              let host = url.host
        else {
            throw WebSearchTool.ToolNetError.badURL
        }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        if let port = url.port { components.port = port }
        guard let normalized = components.string else { throw WebSearchTool.ToolNetError.badURL }
        return try ExternalDestination(kind: .networkEndpoint, normalizedIdentity: normalized)
    }
}

// MARK: - Memory (app-owned localRead / localWrite, auto-authorized by local policy)

/// Adapts the legacy `RememberTool` / `RecallTool` to Tool V2. The app-owned memory store is the
/// boundary; local policy auto-authorizes appLocalRead/appLocalWrite, and the store actor performs the
/// durable save/search inside the gate's byte-accounted scope.
public final class AppMemoryToolAdapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: any LLMCore.Tool
    private let frozenSchema: LLMCore.ToolSchema
    private let effects: [AgentEffect]
    private let maximumResponseBytes: UInt64
    private let timeoutMilliseconds: UInt64

    public init(
        tool: any LLMCore.Tool,
        effects: [AgentEffect],
        providerID: String = "builtin",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 5_000,
        maximumResponseBytes: UInt64 = 64 * 1_024
    ) throws {
        let schema = tool.schema
        let inputSchema = try AppToolV2Support.inputSchema(for: schema)
        let logicalID = try AgentToolLogicalID(providerID: providerID, name: schema.name)
        descriptor = try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: logicalID,
                version: version,
                schemaDigest: inputSchema.digest,
                trustRevision: trustRevision
            ),
            title: schema.name,
            summary: schema.description,
            inputSchema: inputSchema,
            outputSchema: nil,
            effects: effects,
            requiredCapabilities: AgentCapabilitySet(effects.compactMap(\.minimumCapability)),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: timeoutMilliseconds),
            retryPolicy: .never,
            idempotency: effects.contains(.localWrite) ? .nonIdempotent : .pureRead,
            supportsProgress: false,
            supportsCancellation: true
        )
        self.tool = tool
        frozenSchema = schema
        self.effects = effects
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor,
              request.proposedCall.toolID == descriptor.id.logicalID,
              tool.schema == frozenSchema
        else { throw ToolV2ContractError.descriptorMismatch }
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.memory"
            ),
            dataCategories: [try AgentDataCategory(rawValue: "user.memory")],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: descriptor.id.logicalID.name == "remember"
                ? "Save a lasting fact to the user's on-device memory"
                : "Search the user's on-device memory",
            descriptorID: descriptor.id.description,
            schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    public func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard prepared.prepared.request.descriptor == descriptor,
                          prepared.prepared.request.proposedCall.toolID == descriptor.id.logicalID,
                          tool.schema == frozenSchema
                    else { throw ToolV2ContractError.executingWrongDescriptor }
                    if await context.cancellation.isCancelled() { throw CancellationError() }
                    let arguments = prepared.prepared.request.sanitizedArguments.string
                    let boundary = try await context.performBoundary(
                        observation: ExternalOperationObservation(
                            destination: try ExternalDestination(
                                kind: .privateDataStore,
                                normalizedIdentity: "mobilellm.memory"
                            ),
                            dataCategories: [try AgentDataCategory(rawValue: "user.memory")],
                            effects: effects,
                            requestBytes: UInt64(arguments.utf8.count),
                            responseBytesLimit: maximumResponseBytes,
                            payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                            descriptorID: descriptor.id.description,
                            schemaDigest: descriptor.id.schemaDigest,
                            trustRevision: descriptor.id.trustRevision
                        ),
                        operation: { control in
                            if await context.cancellation.isCancelled() { throw CancellationError() }
                            let text = await self.tool.execute(argumentsJSON: arguments)
                            try await control.consumeResponseBytes(UInt64(text.utf8.count))
                            return try AppToolV2Support.canonicalText(text)
                        }
                    )
                    guard let text = try AppToolV2Support.textValue(boundary.value) else {
                        throw AppToolV2Support.ToolAdapterError.invalidBoundaryResult
                    }
                    try Task.checkCancellation()
                    let results = try ToolResultCollection([
                        .text(try ToolTextResult(text)),
                    ])
                    continuation.yield(.completed(results))
                    continuation.finish()
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.cancelledFailure()))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
