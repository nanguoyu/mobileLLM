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

    /// A tool result that is a failure or denial, not a successful payload. Tool V2 adapters turn
    /// these into `.failed` outcomes so a run that recovered from them can never look like a clean
    /// "Completed".
    static func isFailureText(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("error:")
            || normalized.hasPrefix("couldn't")
            || normalized.hasPrefix("search failed")
            || normalized.hasPrefix("web search failed")
            || normalized.hasPrefix("no web results")
            || normalized.hasPrefix("no wikipedia article")
            || normalized.hasPrefix("calendar access is off")
            || normalized.hasPrefix("reminders access is off")
            || normalized.hasPrefix("location access is off")
            || normalized.hasPrefix("location is unavailable")
            || normalized.hasPrefix("that url isn't a readable web page")
            || normalized.hasPrefix("the page loaded but had no readable text")
    }

    /// Host-only normalization of an engine or document URL so a plan names the bounded endpoint, not
    /// the query-specific path.
    static func hostOnlyDestination(_ url: URL) throws -> ExternalDestination {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        if let port = url.port { components.port = port }
        guard let normalized = components.string else {
            throw AgentContractError.invalidExternalOperationPlan("invalid network destination")
        }
        return try ExternalDestination(kind: .networkEndpoint, normalizedIdentity: normalized)
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
        AsyncThrowingStream<ToolExecutionEvent, Error>(bufferingPolicy: .unbounded) { continuation in
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
                    // Never hop outside the plan: the ceiling may authorize a subset of the shared
                    // adapter's engines (settings changes after executor build), and every hop must
                    // stay inside the plan the user approved.
                    let plan = prepared.prepared.externalOperation.plan
                    let allowedDestinations = Set(
                        [plan.destination].compactMap { $0 } + plan.allowedFallbacks
                    )
                    for engine in engines {
                        if await context.cancellation.isCancelled() { throw CancellationError() }
                        guard let engineDestination = try? Self.destination(engine: engine),
                              allowedDestinations.contains(engineDestination)
                        else { continue }
                        do {
                            let boundary = try await context.performBoundary(
                                observation: ExternalOperationObservation(
                                    destination: engineDestination,
                                    dataCategories: [try AgentDataCategory(rawValue: "web.search")],
                                    effects: [.networkRead],
                                    requestBytes: UInt64(
                                        prepared.prepared.request.sanitizedArguments.string.utf8.count
                                    ),
                                    responseBytesLimit: maximumResponseBytes,
                                    // The authorization is bound to the canonical arguments digest, not
                                    // the raw query hash; a mismatch is rejected by the execution gate
                                    // before any network hop ("observed operation widened").
                                    payloadDigest: prepared.prepared.request
                                        .sanitizedArguments.fingerprint,
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
                        } catch let contract as AgentContractError {
                            // A gate/contract rejection is a wiring or authorization bug, not an engine
                            // outage; surface it instead of swallowing it into "no results".
                            throw contract
                        } catch {
                            // This engine failed or returned nothing; fall through to the next one.
                            let reason: String
                            if let net = error as? WebSearchTool.ToolNetError {
                                reason = net == .badResponse ? "bad-response-or-empty" : "bad-url"
                            } else if error is AgentContractError {
                                reason = String(describing: error)
                            } else {
                                reason = String(describing: type(of: error))
                            }
                            await context.logger.record(
                                code: "tool.web-search.engine-failed",
                                metadata: ["engine": engine.rawValue, "reason": reason]
                            )
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

// MARK: - Wikipedia (networkRead, bounded to the language-specific wikipedia host)

/// Adapts the legacy `WikipediaTool` to Tool V2. The destination is `{lang}.wikipedia.org` chosen from
/// the query, so the run ceiling can enumerate both language hosts exactly; both network steps of the
/// lookup run inside one authorized boundary hop.
public final class AppWikipediaToolAdapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: WikipediaTool
    private let frozenSchema: LLMCore.ToolSchema
    private let maximumResponseBytes: UInt64
    private let timeoutMilliseconds: UInt64

    public init(
        tool: WikipediaTool,
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
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public static func destination(lang: String) throws -> ExternalDestination {
        guard let url = URL(string: "https://\(lang).wikipedia.org/") else {
            throw WikipediaTool.ToolNetError.badURL
        }
        return try AppToolV2Support.hostOnlyDestination(url)
    }

    public func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor,
              request.proposedCall.toolID == descriptor.id.logicalID,
              tool.schema == frozenSchema
        else { throw ToolV2ContractError.descriptorMismatch }
        guard let query = Self.query(from: request.sanitizedArguments.string),
              !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw ToolV2ContractError.invalidArguments }
        let lang = WikipediaTool.lang(for: query)
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: try Self.destination(lang: lang),
            dataCategories: [try AgentDataCategory(rawValue: "web.wikipedia")],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Look up \"\(query)\" on Wikipedia",
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
                    guard let query = Self.query(from: arguments) else {
                        throw ToolV2ContractError.invalidArguments
                    }
                    let lang = WikipediaTool.lang(for: query)
                    let boundary = try await context.performBoundary(
                        observation: ExternalOperationObservation(
                            destination: try Self.destination(lang: lang),
                            dataCategories: [try AgentDataCategory(rawValue: "web.wikipedia")],
                            effects: [.networkRead],
                            requestBytes: UInt64(arguments.utf8.count),
                            responseBytesLimit: maximumResponseBytes,
                            payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                            descriptorID: descriptor.id.description,
                            schemaDigest: descriptor.id.schemaDigest,
                            trustRevision: descriptor.id.trustRevision
                        ),
                        operation: { control in
                            if await context.cancellation.isCancelled() { throw CancellationError() }
                            let search = try await self.tool.fetchSearch(query: query, lang: lang)
                            try await control.consumeResponseBytes(UInt64(search.count))
                            guard let title = WikipediaTool.parseTopTitle(search) else {
                                throw WikipediaTool.ToolNetError.badResponse
                            }
                            let summaryData = try await self.tool.fetchSummary(title: title, lang: lang)
                            try await control.consumeResponseBytes(UInt64(summaryData.count))
                            let summary = WikipediaTool.parseSummary(summaryData)
                            let text = summary.isEmpty
                                ? "No Wikipedia article found for \"\(query)\"."
                                : "\(title): \(summary)"
                            return try AppToolV2Support.canonicalText(text)
                        }
                    )
                    let text = try AppToolV2Support.textValue(boundary.value) ?? ""
                    try Task.checkCancellation()
                    if AppToolV2Support.isFailureText(text) {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.wikipedia.failed",
                            message: text
                        )))
                    } else {
                        continuation.yield(.completed(try ToolResultCollection([
                            .text(try ToolTextResult(text)),
                        ])))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.cancelledFailure()))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch let contract as AgentContractError {
                    continuation.finish(throwing: contract)
                } catch {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.wikipedia.failed",
                            message: "Wikipedia lookup failed or returned no article."
                        )))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
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
}

// MARK: - Webpage reader (networkRead, user-supplied https destination)

/// Adapts the legacy `WebScraperTool` to Tool V2. The destination is the host of the user-supplied
/// URL; the run ceiling covers it with the https-only wildcard, and the tool's SSRF/redirect guards
/// still run inside the authorized boundary before any byte reaches the network.
public final class AppWebScraperToolAdapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: WebScraperTool
    private let frozenSchema: LLMCore.ToolSchema
    private let maximumResponseBytes: UInt64
    private let timeoutMilliseconds: UInt64

    public init(
        tool: WebScraperTool,
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
        self.maximumResponseBytes = maximumResponseBytes
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public static func destination(url: URL) throws -> ExternalDestination {
        try AppToolV2Support.hostOnlyDestination(url)
    }

    public func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor,
              request.proposedCall.toolID == descriptor.id.logicalID,
              tool.schema == frozenSchema
        else { throw ToolV2ContractError.descriptorMismatch }
        let url = try Self.url(from: request.sanitizedArguments.string)
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            destination: try Self.destination(url: url),
            dataCategories: [try AgentDataCategory(rawValue: "web.page")],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Read \(url.host ?? url.absoluteString)",
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
                    let url = try Self.url(from: arguments)
                    let boundary = try await context.performBoundary(
                        observation: ExternalOperationObservation(
                            destination: try Self.destination(url: url),
                            dataCategories: [try AgentDataCategory(rawValue: "web.page")],
                            effects: [.networkRead],
                            requestBytes: UInt64(arguments.utf8.count),
                            responseBytesLimit: maximumResponseBytes,
                            payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                            descriptorID: descriptor.id.description,
                            schemaDigest: descriptor.id.schemaDigest,
                            trustRevision: descriptor.id.trustRevision
                        ),
                        operation: { control in
                            if await context.cancellation.isCancelled() { throw CancellationError() }
                            let page = try await self.tool.fetchPage(url: url)
                            try await control.consumeResponseBytes(UInt64(page.body.count))
                            return try AppToolV2Support.canonicalText(self.tool.renderReadable(page: page))
                        }
                    )
                    let text = try AppToolV2Support.textValue(boundary.value) ?? ""
                    try Task.checkCancellation()
                    if AppToolV2Support.isFailureText(text) {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.webpage.failed",
                            message: text
                        )))
                    } else {
                        continuation.yield(.completed(try ToolResultCollection([
                            .text(try ToolTextResult(text)),
                        ])))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.cancelledFailure()))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch let contract as AgentContractError {
                    continuation.finish(throwing: contract)
                } catch {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.webpage.failed",
                            message: "Couldn't read that web page."
                        )))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// https-only on the agent path: the https wildcard destination is the security boundary, and
    /// plaintext http is not authorized by it.
    private static func url(from argumentsJSON: String) throws -> URL {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["url"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              !WebScraperTool.isBlockedHost(host)
        else { throw ToolV2ContractError.invalidArguments }
        return url
    }
}

// MARK: - System data (calendar / reminders / location: localRead / localWrite + TCC seam)

/// Adapts privacy-gated system-data tools (calendar, reminders, location) to Tool V2. The TCC
/// permission is requested lazily by the underlying provider; the runtime boundary names the private
/// store and the data category, and a denial string becomes a failed tool outcome (never a clean
/// success).
public final class AppSystemDataToolAdapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: any LLMCore.Tool
    private let frozenSchema: LLMCore.ToolSchema
    private let effects: [AgentEffect]
    private let destinationIdentity: String
    private let dataCategory: String
    private let userPreview: String
    private let maximumResponseBytes: UInt64
    private let timeoutMilliseconds: UInt64

    public init(
        tool: any LLMCore.Tool,
        effects: [AgentEffect],
        destinationIdentity: String,
        dataCategory: String,
        userPreview: String,
        providerID: String = "builtin",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 15_000,
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
        self.destinationIdentity = destinationIdentity
        self.dataCategory = dataCategory
        self.userPreview = userPreview
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
                normalizedIdentity: destinationIdentity
            ),
            dataCategories: [try AgentDataCategory(rawValue: dataCategory)],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: .never,
            idempotency: descriptor.idempotency,
            userPreview: userPreview,
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
                                normalizedIdentity: destinationIdentity
                            ),
                            dataCategories: [try AgentDataCategory(rawValue: dataCategory)],
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
                    let text = try AppToolV2Support.textValue(boundary.value) ?? ""
                    try Task.checkCancellation()
                    if AppToolV2Support.isFailureText(text) {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.system-data.failed",
                            message: text
                        )))
                    } else {
                        continuation.yield(.completed(try ToolResultCollection([
                            .text(try ToolTextResult(text)),
                        ])))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try AppToolV2Support.cancelledFailure()))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch let contract as AgentContractError {
                    continuation.finish(throwing: contract)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
                    if AppToolV2Support.isFailureText(text) {
                        continuation.yield(.failed(try AppToolV2Support.toolFailure(
                            code: "tool.memory.failed",
                            message: text
                        )))
                    } else {
                        continuation.yield(.completed(try ToolResultCollection([
                            .text(try ToolTextResult(text)),
                        ])))
                    }
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
