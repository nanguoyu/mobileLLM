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

    init(operation: DeepSeekWebOperation, serviceID: String, session: URLSession = .shared,
         resolveKey: @escaping DeepSeekAPIKeyResolver) throws {
        self.operation = operation
        self.serviceID = serviceID
        self.client = DeepSeekWebClient(session: session)
        self.resolveKey = resolveKey
        descriptor = try Self.makeDescriptor(operation: operation, serviceID: serviceID)
    }

    static func makeDescriptor(operation: DeepSeekWebOperation, serviceID: String) throws -> AgentToolDescriptor {
        guard !serviceID.isEmpty, serviceID.utf8.count <= 128,
              serviceID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw DeepSeekWebError.invalidArgument }
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([operation.argumentName: .object([
                "type": .string("string"), "minLength": .integer(1),
                "maxLength": .integer(operation == .search ? 128 : 8192),
                "description": .string(operation == .search
                    ? "Focused web search query, at most 128 Unicode characters. Supports site:, quoted phrases, and date filters."
                    : "Public HTTPS page URL to read; no embedded username or password.")
            ])]),
            "required": .array([.string(operation.argumentName)])
        ]))
        return try AgentToolDescriptor(
            id: AgentToolDescriptorID(logicalID: AgentToolLogicalID(providerID: "builtin", name: operation.toolName),
                version: SemanticVersion("1.0.0")!, schemaDigest: schema.digest,
                trustRevision: revisionPrefix + Data(serviceID.utf8).base64EncodedString()),
            title: operation.toolName,
            summary: operation == .search
                ? "Search the live web through DeepSeek and return source links and summaries."
                : "Read a public webpage through DeepSeek and return its source URL and Markdown content.",
            inputSchema: schema, outputSchema: nil, effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 30_000), retryPolicy: .never,
            idempotency: .pureRead, supportsProgress: false, supportsCancellation: true
        )
    }

    static func serviceID(from descriptor: AgentToolDescriptorID) -> String? {
        guard descriptor.logicalID.providerID == "builtin",
              ["web_search", "fetch_webpage"].contains(descriptor.logicalID.name),
              descriptor.trustRevision.hasPrefix(revisionPrefix),
              let data = Data(base64Encoded: String(descriptor.trustRevision.dropFirst(revisionPrefix.count)))
        else { return nil }
        return String(data: data, encoding: .utf8)
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

    func prepare(request: ToolExecutionRequest, context: ToolPreparationContext) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor, request.proposedCall.toolID == descriptor.id.logicalID else {
            throw ToolV2ContractError.descriptorMismatch
        }
        let value = try argument(request)
        let body = try DeepSeekWebClient.requestBody(operation: operation, argument: value)
        let plan = try ExternalOperationPlan(
            kind: .tool, subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments, destination: Self.destination(),
            dataCategories: [category], payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects, requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: UInt64(body.count), maximumResponseBytes: UInt64(DeepSeekWebClient.maximumResponseBytes),
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
                    let body = try DeepSeekWebClient.requestBody(operation: operation, argument: value)
                    if await context.cancellation.isCancelled() { throw CancellationError() }
                    let boundary = try await context.performBoundary(observation: ExternalOperationObservation(
                        destination: Self.destination(), dataCategories: [category], effects: [.networkRead],
                        requestBytes: UInt64(body.count), responseBytesLimit: UInt64(DeepSeekWebClient.maximumResponseBytes),
                        payloadDigest: request.sanitizedArguments.fingerprint,
                        descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest,
                        trustRevision: descriptor.id.trustRevision
                    ), operation: { control in
                        guard let key = try await self.resolveKey(self.serviceID) else { throw DeepSeekWebError.missingAPIKey }
                        let response = try await self.client.perform(operation: self.operation, argument: value, apiKey: key)
                        try await control.consumeResponseBytes(response.responseBytes)
                        return try AppToolV2Support.canonicalText(response.text)
                    })
                    guard let text = try AppToolV2Support.textValue(boundary.value) else { throw DeepSeekWebError.invalidResponse }
                    await context.logger.record(code: "tool.deepseek.completed", metadata: ["operation": operation.rawValue, "serviceID": serviceID])
                    continuation.yield(.completed(try ToolResultCollection([.text(ToolTextResult(text))])))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(try! AppToolV2Support.cancelledFailure()))
                    continuation.finish()
                } catch let error as AgentContractError {
                    continuation.finish(throwing: error)
                } catch {
                    let message = (error as? DeepSeekWebError)?.localizedDescription ?? "DeepSeek web service could not complete the request."
                    continuation.yield(.failed(try! AppToolV2Support.toolFailure(code: "tool.deepseek.failed", message: message)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
