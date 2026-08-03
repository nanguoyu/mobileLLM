// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation
import LLMCore

/// Adapts one discovered MCP tool to Tool V2 with the spec's conservative remote-tool posture:
/// `unknownExternal` (exact approval for every invocation), no automatic retry, non-idempotent plan,
/// stable server identity (never the mutable URL), and transport loss after intent surfaced as an
/// uncertain outcome that enters `waitingForReconciliation`.
///
/// Discovery (`initialize` + `tools/list`) never happens here and never happens during prompt
/// compilation: the app's explicit server setup/refresh flow caches the tool specs, and only cached
/// specs are advertised.
public final class MCPToolV2Adapter: ToolV2, @unchecked Sendable {
    public let descriptor: AgentToolDescriptor
    private let client: MCPClient
    private let spec: MCPToolSpec
    private let serverStableID: UUID
    private let timeoutMilliseconds: UInt64
    private let maximumResponseBytes: UInt64

    public init(
        client: MCPClient,
        spec: MCPToolSpec,
        serverStableID: UUID,
        providerIDPrefix: String = "mcp",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 30_000,
        maximumResponseBytes: UInt64 = 512 * 1_024
    ) throws {
        self.client = client
        self.spec = spec
        self.serverStableID = serverStableID
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumResponseBytes = maximumResponseBytes
        descriptor = try Self.descriptor(
            spec: spec,
            serverStableID: serverStableID,
            providerIDPrefix: providerIDPrefix,
            version: version,
            trustRevision: trustRevision,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    /// The exact descriptor identity both the frozen context catalog and the executor adapter share.
    /// Deterministic in the MCP tool spec + stable server id, so a later adapter build matches the
    /// frozen snapshot's descriptor id, schema digest, and trust revision.
    public static func descriptor(
        spec: MCPToolSpec,
        serverStableID: UUID,
        providerIDPrefix: String = "mcp",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 30_000
    ) throws -> AgentToolDescriptor {
        let logicalID = try AgentToolLogicalID(
            providerID: "\(providerIDPrefix).\(serverStableID.uuidString)",
            name: spec.name
        )
        let inputSchema = try Self.schema(from: spec.inputSchemaJSON)
        return try AgentToolDescriptor(
            id: AgentToolDescriptorID(
                logicalID: logicalID,
                version: version,
                schemaDigest: inputSchema.digest,
                trustRevision: trustRevision
            ),
            title: spec.name,
            summary: spec.description.isEmpty ? "MCP tool \(spec.name)." : spec.description,
            inputSchema: inputSchema,
            outputSchema: nil,
            effects: [.unknownExternal],
            requiredCapabilities: AgentCapabilitySet([.unknownExternal]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: timeoutMilliseconds),
            retryPolicy: .never,
            idempotency: .nonIdempotent,
            supportsProgress: false,
            supportsCancellation: true
        )
    }

    public func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor,
              request.proposedCall.toolID == descriptor.id.logicalID
        else { throw ToolV2ContractError.descriptorMismatch }
        let plan = try ExternalOperationPlan(
            kind: .mcp,
            subjectID: "mcp.\(serverStableID.uuidString).\(spec.name)",
            canonicalArguments: request.sanitizedArguments,
            destination: try ExternalDestination(
                kind: .mcpServer,
                normalizedIdentity: serverStableID.uuidString
            ),
            dataCategories: [try AgentDataCategory(rawValue: "mcp.call")],
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: timeoutMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: "Call MCP tool \(spec.name) on server \(serverStableID.uuidString.prefix(8))",
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
                          prepared.prepared.request.proposedCall.toolID == descriptor.id.logicalID
                    else { throw ToolV2ContractError.executingWrongDescriptor }
                    if await context.cancellation.isCancelled() { throw CancellationError() }
                    let arguments = prepared.prepared.request.sanitizedArguments.string
                    do {
                        let boundary = try await context.performBoundary(
                            observation: ExternalOperationObservation(
                                destination: try ExternalDestination(
                                    kind: .mcpServer,
                                    normalizedIdentity: serverStableID.uuidString
                                ),
                                dataCategories: [try AgentDataCategory(rawValue: "mcp.call")],
                                effects: [.unknownExternal],
                                requestBytes: UInt64(arguments.utf8.count),
                                responseBytesLimit: maximumResponseBytes,
                                payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                                descriptorID: descriptor.id.description,
                                schemaDigest: descriptor.id.schemaDigest,
                                trustRevision: descriptor.id.trustRevision
                            ),
                            operation: { control in
                                if await context.cancellation.isCancelled() { throw CancellationError() }
                                let text = try await self.client.call(
                                    name: self.spec.name,
                                    argumentsJSON: arguments
                                )
                                try await control.consumeResponseBytes(UInt64(text.utf8.count))
                                return try MCPToolV2Boundary.canonicalText(text)
                            }
                        )
                        guard let text = try MCPToolV2Boundary.textValue(boundary.value) else {
                            throw ToolV2ContractError.invalidOutputSchema
                        }
                        try Task.checkCancellation()
                        let results = try ToolResultCollection([
                            .text(try ToolTextResult(text)),
                        ])
                        continuation.yield(.completed(results))
                        continuation.finish()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MCPClient.MCPError {
                        // A request that could never have left the device is a confirmed failure;
                        // everything after intent is transport-ambiguous and must reconcile.
                        if error == .badURL {
                            continuation.yield(.failed(try Self.confirmedFailure()))
                            continuation.finish()
                        } else {
                            continuation.yield(.failed(try Self.uncertainFailure()))
                            continuation.finish()
                        }
                    } catch let error as URLError
                        where error.code == .badURL || error.code == .unsupportedURL
                    {
                        // URL(string:) is lenient enough that a configured garbage URL reaches
                        // URLSession and fails locally; the request never left the device.
                        continuation.yield(.failed(try Self.confirmedFailure()))
                        continuation.finish()
                    } catch {
                        continuation.yield(.failed(try Self.uncertainFailure()))
                        continuation.finish()
                    }
                } catch is CancellationError {
                    do {
                        continuation.yield(.failed(try Self.cancelledFailure()))
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

    private static func schema(from json: String) throws -> JSONSchemaDocument {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let value = try? AgentWireDecoder.decode(
                JSONValue.self,
                from: data,
                limits: .contractEnvelope
              )
        else {
            return try JSONSchemaDocument(root: .object(["type": .string("object")]))
        }
        if let document = try? JSONSchemaDocument(root: value) { return document }
        return try JSONSchemaDocument(root: .object(["type": .string("object")]))
    }

    private static func confirmedFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "tool.mcp.invalid-url",
            classification: .permanent,
            safeMessage: "The MCP server URL is invalid; nothing was sent.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func uncertainFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "tool.mcp.transport-uncertain",
            classification: .potentiallySideEffecting,
            safeMessage: "The MCP server did not confirm the tool call; the result is uncertain.",
            retryAdvice: .never,
            externalEffect: .uncertain,
            requiredUserAction: .reconcile,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func cancelledFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "tool.mcp.cancelled",
            classification: .cancelled,
            safeMessage: "The MCP tool stopped before producing a result.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }
}

/// Boundary payload helpers for the MCP adapter; kept internal to AgentRuntime.
enum MCPToolV2Boundary {
    static func canonicalText(_ text: String) throws -> ExternalOperationBoundaryCompletion {
        try ExternalOperationBoundaryCompletion(
            value: .canonicalJSON(CanonicalJSON(.string(text)))
        )
    }

    static func textValue(_ value: ExternalOperationBoundaryValue) throws -> String? {
        guard case .canonicalJSON(let json) = value else { return nil }
        let decoded = try AgentWireDecoder.decode(JSONValue.self, from: json.data, limits: .inlineValue)
        guard case .string(let text) = decoded else { return nil }
        return text
    }
}
