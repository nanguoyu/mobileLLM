// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts
import AgentRuntime
import LLMCore

public typealias DeepSeekAPIKeyResolver = @Sendable (String) async throws -> String?

/// One implementation of the existing search/page capabilities, pinned by service identity in the
/// descriptor. Recovery resolves that same account and never substitutes another search provider.
final class AppDeepSeekWebToolAdapter: ToolV2, Sendable {
    let descriptor: AgentToolDescriptor
    private let operation: DeepSeekWebOperation
    private let serviceID: String
    private let client: DeepSeekWebClient
    private let resolveKey: DeepSeekAPIKeyResolver
    private static let revisionPrefix = "deepseek.web.v1:"
    private static let contentRevisionPrefix = "deepseek.web.v2:"
    private let enrichedSearch: Bool

    init(operation: DeepSeekWebOperation, serviceID: String, session: URLSession = .shared,
         enrichedSearch: Bool = true,
         resolveKey: @escaping DeepSeekAPIKeyResolver) throws {
        self.operation = operation
        self.serviceID = serviceID
        self.client = DeepSeekWebClient(session: session)
        self.resolveKey = resolveKey
        self.enrichedSearch = operation == .search && enrichedSearch
        descriptor = try Self.makeDescriptor(operation: operation, serviceID: serviceID, enrichedSearch: enrichedSearch)
    }

    static func makeDescriptor(operation: DeepSeekWebOperation, serviceID: String, enrichedSearch: Bool = true) throws -> AgentToolDescriptor {
        guard !serviceID.isEmpty, serviceID.utf8.count <= 128,
              serviceID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw DeepSeekWebError.invalidArgument }
        let enriched = operation == .search && enrichedSearch
        var properties: [String: JSONValue] = [operation.argumentName: .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(operation == .search ? 128 : 8192),
                "description": .string(operation == .search
                    ? "Focused web search query, at most 128 Unicode characters. Supports site:, quoted phrases, and date filters."
                    : "Public HTTPS page URL to read; no embedded username or password.")
            ])]
        if enriched {
            properties["include_content"] = .object(["type": .string("boolean"),
                "description": .string("Include bounded page excerpts returned by Search. Defaults to true. Set false for lighter summary-only discovery; this is not a live Fetch.")])
        }
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"), "additionalProperties": .bool(false), "properties": .object(properties),
            "required": .array([.string(operation.argumentName)])
        ]))
        return try AgentToolDescriptor(
            id: AgentToolDescriptorID(logicalID: AgentToolLogicalID(providerID: "builtin", name: operation.toolName),
                version: SemanticVersion(enriched ? "1.1.0" : "1.0.0")!, schemaDigest: schema.digest,
                trustRevision: (enriched ? contentRevisionPrefix : revisionPrefix) + Data(serviceID.utf8).base64EncodedString()),
            title: operation.toolName,
            summary: operation == .search
                ? (enriched ? "Search through DeepSeek and return source links, summaries and bounded page excerpts when available. Search-returned content is not a live Fetch."
                    : "Search the live web through DeepSeek and return source links and summaries.")
                : "Read a public webpage through DeepSeek and return its source URL and Markdown content.",
            inputSchema: schema, outputSchema: nil, effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 30_000), retryPolicy: .never,
            idempotency: .pureRead, supportsProgress: false, supportsCancellation: true
        )
    }

    static func serviceID(from descriptor: AgentToolDescriptorID) -> String? {
        let prefix = descriptor.trustRevision.hasPrefix(contentRevisionPrefix) ? contentRevisionPrefix : revisionPrefix
        guard descriptor.logicalID.providerID == "builtin",
              ["web_search", "fetch_webpage"].contains(descriptor.logicalID.name),
              descriptor.trustRevision.hasPrefix(prefix),
              let data = Data(base64Encoded: String(descriptor.trustRevision.dropFirst(prefix.count)))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func usesSearchContent(_ descriptor: AgentToolDescriptorID) -> Bool {
        descriptor.logicalID.name == "web_search" && descriptor.trustRevision.hasPrefix(contentRevisionPrefix)
    }

    static func destination() throws -> ExternalDestination {
        try ExternalDestination(kind: .networkEndpoint, normalizedIdentity: "https://api.deepseek.com")
    }

    private var category: AgentDataCategory { try! AgentDataCategory(rawValue: operation == .search ? "web.search" : "web.page") }

    private func argument(_ request: ToolExecutionRequest) throws -> String {
        guard case .object(let object) = try AgentWireDecoder.decode(JSONValue.self, from: request.sanitizedArguments.data, limits: .inlineValue),
              case .string(let value)? = object[operation.argumentName] else { throw DeepSeekWebError.invalidArgument }
        return value
    }

    private func includeContent(_ request: ToolExecutionRequest) throws -> Bool {
        guard enrichedSearch else { return false }
        guard case .object(let object) = try AgentWireDecoder.decode(JSONValue.self, from: request.sanitizedArguments.data, limits: .inlineValue) else { throw DeepSeekWebError.invalidArgument }
        guard let value = object["include_content"] else { return true }
        guard case .bool(let include) = value else { throw DeepSeekWebError.invalidArgument }
        return include
    }

    func prepare(request: ToolExecutionRequest, context: ToolPreparationContext) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor, request.proposedCall.toolID == descriptor.id.logicalID else {
            throw ToolV2ContractError.descriptorMismatch
        }
        let value = try argument(request)
        let plan = try ExternalOperationPlan(
            kind: .tool, subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments, destination: Self.destination(),
            dataCategories: [category], payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects, requiredCapabilities: descriptor.requiredCapabilities,
            // Reserve the bounded JSON envelope without making argument validation a fatal
            // preparation error. Execute reports invalid URLs/queries as ordinary tool failures.
            maximumRequestBytes: request.maximumArgumentBytes + 64,
            maximumResponseBytes: UInt64(DeepSeekWebClient.maximumResponseBytes),
            timeoutMilliseconds: 30_000, retryPolicy: .never, idempotency: .pureRead,
            userPreview: operation == .search ? "Search with DeepSeek: \(value)" : "Read with DeepSeek: \(value)",
            descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision
        )
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    func execute(prepared: AuthorizedToolInvocation, context: ToolExecutionContext) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = prepared.prepared.request
                    guard request.descriptor == descriptor else { throw ToolV2ContractError.executingWrongDescriptor }
                    let value = try argument(request)
                    let include = try includeContent(request)
                    let body = try DeepSeekWebClient.requestBody(operation: operation, argument: value, includeSearchContent: include)
                    if await context.cancellation.isCancelled() { throw CancellationError() }
                    let boundary = try await context.performBoundary(observation: ExternalOperationObservation(
                        destination: Self.destination(), dataCategories: [category], effects: [.networkRead],
                        requestBytes: UInt64(body.count), responseBytesLimit: UInt64(DeepSeekWebClient.maximumResponseBytes),
                        payloadDigest: request.sanitizedArguments.fingerprint,
                        descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest,
                        trustRevision: descriptor.id.trustRevision
                    ), operation: { control in
                        guard let key = try await self.resolveKey(self.serviceID) else { throw DeepSeekWebError.missingAPIKey }
                        let response = try await self.client.perform(operation: self.operation, argument: value, apiKey: key, includeSearchContent: include,
                            consumeResponseBytes: { try await control.consumeResponseBytes($0) })
                        if self.enrichedSearch {
                            guard let results = response.searchResults else { throw DeepSeekWebError.invalidResponse }
                            let result = try WorkflowSearchEvidence.result(query: value, sources: results.map {
                                .init(url: $0.url, title: $0.title, summary: $0.summary, pageExcerpt: $0.pageExcerpt,
                                      truncated: $0.pageExcerptTruncated, publicationDate: $0.publicationDate)
                            }).value
                            return ExternalOperationBoundaryCompletion(value: .canonicalJSON(result))
                        }
                        return try AppToolV2Support.canonicalText(response.text)
                    })
                    await context.logger.record(code: "tool.deepseek.completed", metadata: ["operation": operation.rawValue, "serviceID": serviceID])
                    let result: ToolResultContent
                    if enrichedSearch {
                        guard case .canonicalJSON(let value) = boundary.value else { throw DeepSeekWebError.invalidResponse }
                        result = .structured(try ToolStructuredResult(value))
                    }
                    else {
                        guard let text = try AppToolV2Support.textValue(boundary.value) else { throw DeepSeekWebError.invalidResponse }
                        result = .text(try ToolTextResult(text))
                    }
                    continuation.yield(.completed(try ToolResultCollection([result])))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(try! AppToolV2Support.cancelledFailure()))
                    continuation.finish()
                } catch let error as AgentContractError {
                    continuation.finish(throwing: error)
                } catch {
                    let message = (error as? DeepSeekWebError)?.localizedDescription ?? "DeepSeek web service could not complete the request."
                    continuation.yield(.failed(try! Self.failure(for: error, operation: operation, message: message)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func failure(for error: Error, operation: DeepSeekWebOperation, message: String) throws -> AgentFailure {
        if operation == .fetch, (error as? DeepSeekWebError) == .httpStatus(404) {
            return try AgentFailure(code: "tool.web.safe-read-miss", classification: .availabilityRelated,
                safeMessage: message, retryAdvice: .never, externalEffect: .confirmedNone,
                requiredUserAction: .none, redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1))
        }
        return try AppToolV2Support.toolFailure(code: "tool.deepseek.failed", message: message)
    }
}
