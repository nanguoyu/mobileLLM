// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation
import LLMCore

/// Converts the deliberately small V1 tool surface into Tool V2 without pretending that a legacy
/// implementation can enforce network, private-data, or write boundaries it cannot observe.
///
/// Only `localPure` tools are accepted here. Web, MCP, Memory, calendar, reminder, location, and file
/// tools require dedicated V2 adapters that place each real boundary hop inside
/// `ToolExecutionContext.performBoundary`.
public struct LegacyLocalToolAdapter: ToolV2, Sendable {
    public let descriptor: AgentToolDescriptor
    private let tool: any LLMCore.Tool
    private let frozenSchema: LLMCore.ToolSchema
    private let maximumResponseBytes: UInt64

    public init(
        tool: any LLMCore.Tool,
        providerID: String = "builtin",
        version: SemanticVersion = SemanticVersion("1.0.0")!,
        trustRevision: String,
        timeoutMilliseconds: UInt64 = 5_000,
        maximumResponseBytes: UInt64 = 64 * 1_024
    ) throws {
        let schema = tool.schema
        let inputSchema = try Self.inputSchema(for: schema)
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
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: timeoutMilliseconds),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: false,
            supportsCancellation: true
        )
        guard maximumResponseBytes > 0 else {
            throw LegacyLocalToolAdapterError.invalidResponseLimit
        }
        self.tool = tool
        frozenSchema = schema
        self.maximumResponseBytes = maximumResponseBytes
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
            kind: .localPure,
            subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments,
            payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects,
            requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes,
            maximumResponseBytes: maximumResponseBytes,
            timeoutMilliseconds: descriptor.timeoutPolicy.maximumMilliseconds,
            retryPolicy: descriptor.retryPolicy,
            idempotency: descriptor.idempotency,
            userPreview: "",
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

                    // `localPure` is the one Tool V2 class that intentionally crosses no
                    // authorization gate. The executor rejects a boundary for this class, so the
                    // adapter enforces its frozen response bound locally and closes directly.
                    let text = await tool.execute(
                        argumentsJSON: prepared.prepared.request.sanitizedArguments.string
                    )
                    try Task.checkCancellation()
                    if await context.cancellation.isCancelled() { throw CancellationError() }
                    guard UInt64(text.utf8.count) <= maximumResponseBytes else {
                        throw LegacyLocalToolAdapterError.invalidBoundaryResult
                    }
                    let results = try ToolResultCollection([
                        .text(try ToolTextResult(text)),
                    ])
                    continuation.yield(.completed(results))
                    continuation.finish()
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

    private static func inputSchema(for schema: LLMCore.ToolSchema) throws -> JSONSchemaDocument {
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

    private static func cancelledFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "tool.cancelled",
            classification: .cancelled,
            safeMessage: "The local tool stopped before producing a result.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
    }
}

public enum LegacyLocalToolAdapterError: Error, Hashable, Sendable {
    case invalidResponseLimit
    case invalidBoundaryResult
}
