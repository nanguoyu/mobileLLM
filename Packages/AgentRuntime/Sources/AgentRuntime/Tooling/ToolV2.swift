// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

public enum ToolArgumentValidation: String, CaseIterable, Hashable, Codable, Sendable {
    case fullyValidated
    case partiallyValidatedConservative
}

/// One proposed call after descriptor resolution, size checks, and local schema validation.
public struct ToolExecutionRequest: Hashable, Codable, Sendable {
    public let proposedCall: ProposedToolCall
    public let descriptor: AgentToolDescriptor
    public let sanitizedArguments: SanitizedCanonicalJSON
    public let argumentValidation: ToolArgumentValidation
    public let maximumArgumentBytes: UInt64

    public init(
        proposedCall: ProposedToolCall,
        descriptor: AgentToolDescriptor,
        sanitizedArguments: SanitizedCanonicalJSON,
        maximumArgumentBytes: UInt64 = 256 * 1_024
    ) throws {
        guard proposedCall.toolID == descriptor.id.logicalID else {
            throw ToolV2ContractError.descriptorMismatch
        }
        guard proposedCall.arguments == sanitizedArguments.value,
              maximumArgumentBytes > 0,
              maximumArgumentBytes <= UInt64(CanonicalJSON.maximumBytes),
              proposedCall.arguments.data.count <= maximumArgumentBytes
        else { throw ToolV2ContractError.invalidArguments }
        let instance = try AgentWireDecoder.decode(
            JSONValue.self,
            from: proposedCall.arguments.data,
            limits: .inlineValue
        )
        switch descriptor.inputSchema.enforcement {
        case .fullyEnforced:
            guard try descriptor.inputSchema.validates(instance: instance) else {
                throw ToolV2ContractError.schemaValidationFailed
            }
            argumentValidation = .fullyValidated
        case .partiallyEnforced:
            argumentValidation = .partiallyValidatedConservative
        }
        self.proposedCall = proposedCall
        self.descriptor = descriptor
        self.sanitizedArguments = sanitizedArguments
        self.maximumArgumentBytes = maximumArgumentBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedValidation = try container.decode(
            ToolArgumentValidation.self,
            forKey: .argumentValidation
        )
        do {
            try self.init(
                proposedCall: container.decode(ProposedToolCall.self, forKey: .proposedCall),
                descriptor: container.decode(AgentToolDescriptor.self, forKey: .descriptor),
                sanitizedArguments: container.decode(
                    SanitizedCanonicalJSON.self,
                    forKey: .sanitizedArguments
                ),
                maximumArgumentBytes: container.decode(
                    UInt64.self,
                    forKey: .maximumArgumentBytes
                )
            )
            guard argumentValidation == encodedValidation else {
                throw ToolV2ContractError.invalidArguments
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case proposedCall, descriptor, sanitizedArguments, argumentValidation, maximumArgumentBytes
    }
}

/// Trusted runtime inputs available to side-effect-free tool preparation.
public struct ToolPreparationContext: Hashable, Codable, Sendable {
    public let requestID: AgentRequestID
    public let runID: AgentRunID
    public let conversationID: ConversationID
    public let stepID: AgentStepID
    public let capabilityGrant: StepCapabilityGrant

    public init(
        requestID: AgentRequestID,
        runID: AgentRunID,
        conversationID: ConversationID,
        stepID: AgentStepID,
        capabilityGrant: StepCapabilityGrant
    ) {
        self.requestID = requestID
        self.runID = runID
        self.conversationID = conversationID
        self.stepID = stepID
        self.capabilityGrant = capabilityGrant
    }
}

/// Durable, closure-free preparation result. It is safe to journal and reconstruct after restart.
public struct PreparedToolInvocation: Hashable, Codable, Sendable {
    public let request: ToolExecutionRequest
    public let externalOperation: PreparedExternalOperationRequest
    public let fingerprint: StableDigest

    public init(
        request: ToolExecutionRequest,
        context: ToolPreparationContext,
        plan: ExternalOperationPlan
    ) throws {
        let descriptor = request.descriptor
        guard plan.descriptorID == descriptor.id.description,
              plan.schemaDigest == descriptor.id.schemaDigest,
              plan.trustRevision == descriptor.id.trustRevision,
              plan.canonicalArguments == request.sanitizedArguments,
              plan.payloadDigest == request.sanitizedArguments.fingerprint,
              plan.effects == descriptor.effects,
              descriptor.requiredCapabilities.isSubset(of: plan.requiredCapabilities),
              plan.timeoutMilliseconds <= descriptor.timeoutPolicy.maximumMilliseconds,
              plan.idempotency == descriptor.idempotency,
              Self.retry(plan.retryPolicy, doesNotWiden: descriptor.retryPolicy)
        else { throw ToolV2ContractError.preparedPlanMismatch }
        let prepared = try PreparedExternalOperationRequest(
            requestID: context.requestID,
            runID: context.runID,
            conversationID: context.conversationID,
            stepID: context.stepID,
            invocationID: request.proposedCall.invocationID,
            plan: plan,
            payload: request.sanitizedArguments,
            capabilityGrant: context.capabilityGrant
        )
        self.request = request
        externalOperation = prepared
        fingerprint = StableDigest.fingerprint(
            domain: "prepared-tool-invocation.v1",
            components: [
                Data(request.descriptor.id.description.utf8),
                Data(request.proposedCall.invocationID.description.utf8),
                Data(request.proposedCall.arguments.fingerprint.rawValue.utf8),
                Data(prepared.fingerprint.rawValue.utf8),
            ]
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decode(ToolExecutionRequest.self, forKey: .request)
        externalOperation = try container.decode(
            PreparedExternalOperationRequest.self,
            forKey: .externalOperation
        )
        let encodedFingerprint = try container.decode(StableDigest.self, forKey: .fingerprint)
        let descriptor = request.descriptor
        guard externalOperation.invocationID == request.proposedCall.invocationID,
              externalOperation.plan.descriptorID == descriptor.id.description,
              externalOperation.plan.schemaDigest == descriptor.id.schemaDigest,
              externalOperation.plan.trustRevision == descriptor.id.trustRevision,
              externalOperation.plan.canonicalArguments == request.sanitizedArguments,
              externalOperation.payload == request.sanitizedArguments,
              externalOperation.plan.effects == descriptor.effects,
              descriptor.requiredCapabilities.isSubset(
                of: externalOperation.plan.requiredCapabilities
              ),
              externalOperation.plan.timeoutMilliseconds
                <= descriptor.timeoutPolicy.maximumMilliseconds,
              externalOperation.plan.idempotency == descriptor.idempotency,
              Self.retry(
                externalOperation.plan.retryPolicy,
                doesNotWiden: descriptor.retryPolicy
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid prepared tool plan")
            )
        }
        fingerprint = StableDigest.fingerprint(
            domain: "prepared-tool-invocation.v1",
            components: [
                Data(request.descriptor.id.description.utf8),
                Data(request.proposedCall.invocationID.description.utf8),
                Data(request.proposedCall.arguments.fingerprint.rawValue.utf8),
                Data(externalOperation.fingerprint.rawValue.utf8),
            ]
        )
        guard fingerprint == encodedFingerprint else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Forged tool fingerprint")
            )
        }
    }

    private static func retry(
        _ plan: ExternalRetryPolicy,
        doesNotWiden descriptor: ExternalRetryPolicy
    ) -> Bool {
        if plan == descriptor { return true }
        return plan.kind == .never && descriptor.kind == .boundedExponential
    }

    private enum CodingKeys: String, CodingKey { case request, externalOperation, fingerprint }
}

/// Non-serializable execution token that can only be issued after policy authorization.
public struct AuthorizedToolInvocation: Sendable {
    public let prepared: PreparedToolInvocation
    public let authorization: AuthorizedExternalOperationRequest

    @_spi(AgentRuntime)
    public init(
        prepared: PreparedToolInvocation,
        authorization: AuthorizedExternalOperationRequest
    ) throws {
        guard authorization.prepared == prepared.externalOperation else {
            throw ToolV2ContractError.authorizationMismatch
        }
        self.prepared = prepared
        self.authorization = authorization
    }
}

public protocol ToolCancellationChecking: Sendable {
    func isCancelled() async -> Bool
}

public protocol ToolArtifactWriting: Sendable {
    func commit(
        data: Data,
        mimeType: String,
        semanticType: String?,
        retention: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference
}

public protocol ToolRedactedLogging: Sendable {
    func record(code: String, metadata: [String: String]) async
}

public protocol ToolExecutionEventSink: Sendable {
    func receive(_ event: ToolExecutionEvent) async
}

/// Explicit execution dependencies. It exposes no unrestricted filesystem, network, or secret API.
public struct ToolExecutionContext: Sendable {
    public let runID: AgentRunID
    public let stepID: AgentStepID
    public let invocationID: ToolInvocationID
    public let deadline: AgentTimestamp
    public let budgetReservationID: BudgetReservationID
    public let cancellation: any ToolCancellationChecking
    public let artifactWriter: any ToolArtifactWriting
    public let logger: any ToolRedactedLogging

    public init(
        authorized: AuthorizedToolInvocation,
        deadline: AgentTimestamp,
        budgetReservationID: BudgetReservationID,
        cancellation: any ToolCancellationChecking,
        artifactWriter: any ToolArtifactWriting,
        logger: any ToolRedactedLogging
    ) throws {
        guard deadline.rawValue > 0 else { throw ToolV2ContractError.invalidExecutionContext }
        let operation = authorized.prepared.externalOperation
        runID = operation.runID
        stepID = operation.stepID
        invocationID = authorized.prepared.request.proposedCall.invocationID
        self.deadline = deadline
        self.budgetReservationID = budgetReservationID
        self.cancellation = cancellation
        self.artifactWriter = artifactWriter
        self.logger = logger
    }
}

public protocol ToolV2: Sendable {
    var descriptor: AgentToolDescriptor { get }

    func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation

    func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error>
}

public protocol ExecutableToolCatalog: ToolCatalog {
    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)?
}

public enum ToolV2ContractError: Error, Hashable, Sendable {
    case descriptorMismatch
    case invalidArguments
    case schemaValidationFailed
    case preparedPlanMismatch
    case authorizationMismatch
    case invalidExecutionContext
    case executingWrongDescriptor
    case progressNotSupported
    case missingTerminal
    case eventAfterTerminal
    case invalidOutputSchema
    case providerThrewBeforeTerminal
}

/// Consumes the provider stream internally so raw asynchronous execution never escapes the
/// authorized runtime boundary.
public struct ToolExecutor: Sendable {
    public init() {}

    public func execute(
        tool: any ToolV2,
        authorized: AuthorizedToolInvocation,
        context: ToolExecutionContext,
        eventSink: (any ToolExecutionEventSink)? = nil
    ) async throws -> AgentToolInvocationOutcome {
        guard tool.descriptor.id == authorized.prepared.request.descriptor.id,
              context.runID == authorized.prepared.externalOperation.runID,
              context.stepID == authorized.prepared.externalOperation.stepID,
              context.invocationID == authorized.prepared.request.proposedCall.invocationID
        else { throw ToolV2ContractError.executingWrongDescriptor }
        var terminal: AgentToolInvocationOutcome?
        var terminalEvent: ToolExecutionEvent?
        do {
            for try await event in tool.execute(prepared: authorized, context: context) {
                guard terminal == nil else { throw ToolV2ContractError.eventAfterTerminal }
                switch event {
                case .progress:
                    guard tool.descriptor.supportsProgress else {
                        throw ToolV2ContractError.progressNotSupported
                    }
                case .completed(let results):
                    try validate(results: results, against: tool.descriptor.outputSchema)
                    terminal = .completed(results)
                case .failed(let failure):
                    let candidate: AgentToolInvocationOutcome = failure.externalEffect == .uncertain
                        || failure.classification == .potentiallySideEffecting
                        ? .uncertain(failure)
                        : .failed(failure)
                    try candidate.validate()
                    terminal = candidate
                }
                if terminal == nil {
                    await eventSink?.receive(event)
                } else {
                    // Do not expose a terminal result until the provider stream itself closes
                    // cleanly. A provider that yields `completed` and then throws did not satisfy
                    // the exactly-one-terminal contract and must not create a durable success.
                    terminalEvent = event
                }
            }
        } catch let error as ToolV2ContractError {
            throw error
        } catch {
            if terminal != nil { throw ToolV2ContractError.eventAfterTerminal }
            throw ToolV2ContractError.providerThrewBeforeTerminal
        }
        guard let terminal else { throw ToolV2ContractError.missingTerminal }
        if let terminalEvent { await eventSink?.receive(terminalEvent) }
        return terminal
    }

    private func validate(
        results: ToolResultCollection,
        against outputSchema: JSONSchemaDocument?
    ) throws {
        guard let outputSchema, outputSchema.enforcement == .fullyEnforced else { return }
        for result in results {
            guard case .structured(let structured) = result else { continue }
            let value = try AgentWireDecoder.decode(
                JSONValue.self,
                from: structured.value.data,
                limits: .inlineValue
            )
            guard try outputSchema.validates(instance: value) else {
                throw ToolV2ContractError.invalidOutputSchema
            }
        }
    }
}
