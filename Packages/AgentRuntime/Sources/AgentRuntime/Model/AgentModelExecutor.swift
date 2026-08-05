// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Runtime-visible events that are safe to render before a model attempt commits an action.
public enum AgentModelRuntimeEvent: Hashable, Sendable {
    case visibleReasoningDelta(String)
    case provisionalAnswerDelta(String)
    case usage(AgentModelUsage)
    case provisionalAnswerResolved(AgentModelProvisionalAnswerDisposition)
}

public protocol AgentModelRuntimeEventSink: Sendable {
    func receive(_ event: AgentModelRuntimeEvent) async
}

/// What happened to answer prose streamed before the normalized terminal action was known.
public enum AgentModelProvisionalAnswerDisposition: Hashable, Sendable {
    case none
    case committed(String)
    case discarded(String)
}

/// Why an unfinished model attempt returned to its preceding stable boundary.
public enum AgentModelInterruptionReason: String, CaseIterable, Hashable, Codable, Sendable {
    case cancelled
    case lifecycleQuiescence
    case resourcePressure
    case providerRequested
}

/// Typed interruption evidence. It is intentionally attempt-scoped and does not cancel a run.
public struct AgentModelInterruption: Hashable, Sendable {
    public let reason: AgentModelInterruptionReason
    public let lastUsage: AgentModelUsage?
    public let failure: AgentFailure
}

/// Complete eager result of one authorized model attempt.
public struct AgentModelExecutionResult: Hashable, Sendable {
    public let outcome: AgentModelAttemptOutcome
    public let interruption: AgentModelInterruption?
    public let provisionalAnswer: AgentModelProvisionalAnswerDisposition
    public let responseBytes: UInt64?
    public let responseDigest: StableDigest?

    fileprivate init(
        outcome: AgentModelAttemptOutcome,
        interruption: AgentModelInterruption?,
        provisionalAnswer: AgentModelProvisionalAnswerDisposition,
        responseBytes: UInt64?,
        responseDigest: StableDigest?
    ) {
        self.outcome = outcome
        self.interruption = interruption
        self.provisionalAnswer = provisionalAnswer
        self.responseBytes = responseBytes
        self.responseDigest = responseDigest
    }
}

/// A provider may throw this wrapper when it has a typed, side-effect-free failure but could not
/// emit a terminal event. The runtime converts it into one durable failed-attempt outcome.
public struct AgentModelProviderFailure: Error, Hashable, Sendable {
    public let failure: AgentFailure

    public init(_ failure: AgentFailure) { self.failure = failure }
}

/// A provider may cooperatively stop at an attempt boundary without claiming a terminal answer.
public struct AgentModelProviderInterruption: Error, Hashable, Sendable {
    public let reason: AgentModelInterruptionReason

    public init(reason: AgentModelInterruptionReason) { self.reason = reason }
}

/// Consumes model generation entirely inside the authorization boundary and commits at most one
/// normalized terminal action. Raw provider streams/tasks never escape this type.
public struct AgentModelExecutor: Sendable {
    public init() {}

    public func execute(
        provider: any AgentModelProvider,
        authorized: AuthorizedAgentModelAttempt,
        attemptNumber: UInt16 = 1,
        eventSink: (any AgentModelRuntimeEventSink)? = nil
    ) async throws -> AgentModelExecutionResult {
        let frozen = authorized.preparedAttempt
        guard provider.descriptor == frozen.providerDescriptor,
              provider.descriptor.id == authorized.request.request.selection.providerID,
              provider.descriptor.location == .onDevice
                || (provider.descriptor.location == .remote
                    && frozen.preparedRequest.externalOperation.plan.kind == .modelProvider)
        else { throw AgentModelRuntimeError.executingWrongProvider }

        let prepared = frozen.preparedRequest.externalOperation
        let attempt = try ExternalOperationAttempt(
            prepared: prepared,
            attemptNumber: attemptNumber
        )
        let hop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        let observation = try Self.observation(for: prepared)
        let accumulator = ModelEventAccumulator(
            request: frozen.preparedRequest.request,
            capabilities: frozen.capabilities,
            providerLocation: frozen.providerDescriptor.location,
            downstream: eventSink
        )
        let invocation = ModelInvocationProbe()

        do {
            let boundary = try await authorized.request.performGenerationBoundary(
                observation: observation,
                attempt: attempt,
                hop: hop,
                sink: accumulator
            ) { request, emitter in
                await invocation.markStarted()
                return try await provider.generate(request, emitter: emitter)
            }
            let snapshot = await accumulator.snapshot()
            let outcomeMatches = switch boundary.outcome {
            case .interrupted: snapshot.outcome == nil
            case .completed, .failed: snapshot.outcome == boundary.outcome
            }
            guard outcomeMatches else {
                throw AgentModelRuntimeError.providerContractViolation(
                    .invalidEventSequence("model accumulator outcome mismatch")
                )
            }
            return try await Self.finish(
                outcome: boundary.outcome,
                snapshot: snapshot,
                capabilities: frozen.capabilities,
                responseBytes: boundary.responseBytes,
                responseDigest: boundary.responseDigest,
                downstream: eventSink
            )
        } catch let error as AgentModelProviderFailure {
            try Self.validateLocalFailure(error.failure)
            return try await Self.finishThrown(
                outcome: .failed(error.failure),
                accumulator: accumulator,
                downstream: eventSink
            )
        } catch let error as AgentModelProviderInterruption {
            return try await Self.finishInterrupted(
                reason: error.reason,
                accumulator: accumulator,
                downstream: eventSink
            )
        } catch is CancellationError {
            return try await Self.finishInterrupted(
                reason: .cancelled,
                accumulator: accumulator,
                downstream: eventSink
            )
        } catch let error as AgentContractError {
            if await invocation.started {
                throw AgentModelRuntimeError.providerContractViolation(error)
            }
            throw AgentModelRuntimeError.authorizationRejected(error)
        } catch let error as AgentModelRuntimeError {
            throw error
        } catch {
            if Task.isCancelled {
                return try await Self.finishInterrupted(
                    reason: .cancelled,
                    accumulator: accumulator,
                    downstream: eventSink
                )
            }
            let failure = try Self.providerRuntimeFailure()
            return try await Self.finishThrown(
                outcome: .failed(failure),
                accumulator: accumulator,
                downstream: eventSink
            )
        }
    }

    private static func observation(
        for prepared: PreparedExternalOperationRequest
    ) throws -> ExternalOperationObservation {
        let plan = prepared.plan
        return try ExternalOperationObservation(
            destination: plan.destination,
            dataCategories: plan.dataCategories,
            effects: plan.effects,
            requestBytes: UInt64(prepared.payload.data.count),
            responseBytesLimit: plan.maximumResponseBytes,
            payloadDigest: plan.payloadDigest,
            executionConstraintDigest: plan.executionConstraintDigest,
            artifactIDs: plan.artifactIDs,
            workspaceID: plan.workspaceID,
            descriptorID: plan.descriptorID,
            schemaDigest: plan.schemaDigest,
            trustRevision: plan.trustRevision,
            idempotencyKey: plan.idempotencyKey,
            credentialReference: plan.credentialReference,
            resolvedSecretReferenceIDs: prepared.payload.referencedSecretIDs
        )
    }

    private static func finish(
        outcome: AgentModelAttemptOutcome,
        snapshot: ModelEventSnapshot,
        capabilities: AgentModelCapabilities,
        responseBytes: UInt64,
        responseDigest: StableDigest?,
        downstream: (any AgentModelRuntimeEventSink)?
    ) async throws -> AgentModelExecutionResult {
        if case .completed(let completion) = outcome,
           case .callTools(let calls) = completion.action,
           calls.count > 1,
           !capabilities.features.contains(.multipleToolCalls)
        {
            throw AgentModelRuntimeError.providerContractViolation(
                .invalidEventSequence("provider lacks multiple-tool-call capability")
            )
        }
        let disposition = try Self.provisionalDisposition(
            text: snapshot.provisionalAnswer,
            outcome: outcome
        )
        await downstream?.receive(.provisionalAnswerResolved(disposition))
        let interruption: AgentModelInterruption?
        if case .interrupted(let usage) = outcome {
            let reason: AgentModelInterruptionReason = Task.isCancelled
                ? .cancelled
                : .providerRequested
            interruption = try Self.interruption(reason: reason, usage: usage)
        } else {
            interruption = nil
        }
        return AgentModelExecutionResult(
            outcome: outcome,
            interruption: interruption,
            provisionalAnswer: disposition,
            responseBytes: responseBytes,
            responseDigest: responseDigest
        )
    }

    private static func finishThrown(
        outcome: AgentModelAttemptOutcome,
        accumulator: ModelEventAccumulator,
        downstream: (any AgentModelRuntimeEventSink)?
    ) async throws -> AgentModelExecutionResult {
        let snapshot = await accumulator.snapshot()
        guard snapshot.outcome == nil else {
            throw AgentModelRuntimeError.providerContractViolation(
                .invalidEventSequence("provider threw after terminal model event")
            )
        }
        let disposition = try provisionalDisposition(
            text: snapshot.provisionalAnswer,
            outcome: outcome
        )
        await downstream?.receive(.provisionalAnswerResolved(disposition))
        return AgentModelExecutionResult(
            outcome: outcome,
            interruption: nil,
            provisionalAnswer: disposition,
            responseBytes: nil,
            responseDigest: nil
        )
    }

    private static func finishInterrupted(
        reason: AgentModelInterruptionReason,
        accumulator: ModelEventAccumulator,
        downstream: (any AgentModelRuntimeEventSink)?
    ) async throws -> AgentModelExecutionResult {
        let snapshot = await accumulator.snapshot()
        guard snapshot.outcome == nil else {
            throw AgentModelRuntimeError.providerContractViolation(
                .invalidEventSequence("provider interrupted after terminal model event")
            )
        }
        let outcome = AgentModelAttemptOutcome.interrupted(snapshot.lastUsage)
        let disposition = try provisionalDisposition(
            text: snapshot.provisionalAnswer,
            outcome: outcome
        )
        await downstream?.receive(.provisionalAnswerResolved(disposition))
        return AgentModelExecutionResult(
            outcome: outcome,
            interruption: try interruption(reason: reason, usage: snapshot.lastUsage),
            provisionalAnswer: disposition,
            responseBytes: nil,
            responseDigest: nil
        )
    }

    private static func provisionalDisposition(
        text: String,
        outcome: AgentModelAttemptOutcome
    ) throws -> AgentModelProvisionalAnswerDisposition {
        guard !text.isEmpty else { return .none }
        if case .completed(let completion) = outcome,
           case .finalAnswer(let answer) = completion.action
        {
            guard answer.text == text else {
                throw AgentModelRuntimeError.providerContractViolation(
                    .invalidEventSequence("streamed answer differs from terminal answer")
                )
            }
            return .committed(text)
        }
        return .discarded(text)
    }

    private static func validateLocalFailure(_ failure: AgentFailure) throws {
        guard failure.classification != .potentiallySideEffecting,
              failure.externalEffect == .notApplicable || failure.externalEffect == .confirmedNone
        else {
            throw AgentModelRuntimeError.providerContractViolation(
                .invalidEventSequence("local model reported an external side effect")
            )
        }
    }

    private static func providerRuntimeFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "model.provider-runtime",
            classification: .transient,
            safeMessage: "The local model provider stopped before completing this attempt.",
            retryAdvice: AgentRetryAdvice(
                automaticallyRetryable: true,
                maximumAdditionalAttempts: 1
            ),
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
    }

    private static func interruption(
        reason: AgentModelInterruptionReason,
        usage: AgentModelUsage?
    ) throws -> AgentModelInterruption {
        let classification: AgentFailureClassification
        let code: String
        let message: String
        switch reason {
        case .cancelled:
            classification = .cancelled
            code = "model.cancelled"
            message = "The model attempt was cancelled at a safe boundary."
        case .lifecycleQuiescence:
            classification = .transient
            code = "model.lifecycle-interrupted"
            message = "The model attempt paused when the app left its execution window."
        case .resourcePressure:
            classification = .budgetRelated
            code = "model.resource-interrupted"
            message = "The model attempt paused because the device needed resources."
        case .providerRequested:
            classification = .transient
            code = "model.provider-interrupted"
            message = "The local model provider stopped at an attempt boundary."
        }
        let failure = try AgentFailure(
            code: code,
            classification: classification,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(
                classification: .internalMetadata,
                policyVersion: 1
            )
        )
        return AgentModelInterruption(reason: reason, lastUsage: usage, failure: failure)
    }
}

private struct ModelEventSnapshot: Sendable {
    let outcome: AgentModelAttemptOutcome?
    let provisionalAnswer: String
    let lastUsage: AgentModelUsage?
}

private actor ModelEventAccumulator: AgentModelEventSink {
    private let request: AgentModelRequest
    private let capabilities: AgentModelCapabilities
    private let providerLocation: AgentModelProviderLocation
    private let downstream: (any AgentModelRuntimeEventSink)?
    private var actionSignal: AgentAction?
    private var terminalOutcome: AgentModelAttemptOutcome?
    private var answer = ""
    private var usage: AgentModelUsage?

    init(
        request: AgentModelRequest,
        capabilities: AgentModelCapabilities,
        providerLocation: AgentModelProviderLocation,
        downstream: (any AgentModelRuntimeEventSink)?
    ) {
        self.request = request
        self.capabilities = capabilities
        self.providerLocation = providerLocation
        self.downstream = downstream
    }

    func receive(_ event: AgentModelEvent) async throws {
        guard terminalOutcome == nil else {
            throw AgentContractError.invalidEventSequence("model event follows terminal outcome")
        }
        switch event {
        case .reasoningDelta(let delta):
            guard request.generationParameters.thinkingMode != .disabled,
                  capabilities.features.contains(.reasoning)
            else { throw AgentContractError.invalidEventSequence("unadvertised model reasoning") }
            await downstream?.receive(.visibleReasoningDelta(delta))
        case .answerDelta(let delta):
            guard actionSignal == nil,
                  answer.utf8.count <= 8 * 1_024 * 1_024 - delta.utf8.count
            else { throw AgentContractError.invalidEventSequence("provisional answer is invalid") }
            answer += delta
            await downstream?.receive(.provisionalAnswerDelta(delta))
        case .toolCalls(let calls):
            guard capabilities.toolCallingMode != .unavailable,
                  calls.count <= 1 || capabilities.features.contains(.multipleToolCalls),
                  actionSignal == nil
            else { throw AgentContractError.invalidEventSequence("unsupported model tool action") }
            actionSignal = .callTools(calls)
        case .requestUserInput(let interaction):
            guard actionSignal == nil else {
                throw AgentContractError.invalidEventSequence("multiple model actions")
            }
            actionSignal = .requestUserInput(interaction)
        case .usage(let current):
            try validateUsage(current)
            usage = current
            await downstream?.receive(.usage(current))
        case .completed(let completion):
            guard actionSignal.map({ $0 == completion.action }) ?? true else {
                throw AgentContractError.invalidEventSequence("terminal action changed")
            }
            try validateUsage(completion.usage)
            try completion.validate(
                against: request,
                resolvedToolDescriptors: request.advertisedTools
            )
            if case .callTools(let calls) = completion.action {
                guard capabilities.toolCallingMode != .unavailable,
                      calls.count <= 1 || capabilities.features.contains(.multipleToolCalls)
                else { throw AgentContractError.invalidEventSequence("unsupported terminal tool action") }
            }
            terminalOutcome = .completed(completion)
            usage = completion.usage
        case .failed(let failure):
            guard actionSignal == nil,
                  failure.classification != .potentiallySideEffecting,
                  failure.externalEffect == .notApplicable
                    || failure.externalEffect == .confirmedNone,
                  providerLocation == .onDevice
            else { throw AgentContractError.invalidEventSequence("invalid local model failure") }
            terminalOutcome = .failed(failure)
        }
    }

    func snapshot() -> ModelEventSnapshot {
        ModelEventSnapshot(
            outcome: terminalOutcome,
            provisionalAnswer: answer,
            lastUsage: usage
        )
    }

    private func validateUsage(_ current: AgentModelUsage) throws {
        guard current.inputTokens <= request.generationParameters.maximumContextTokens,
              current.outputTokens <= request.generationParameters.maximumOutputTokens,
              capabilities.reportsCost || current.reportedCostMicros == nil,
              providerLocation != .onDevice || (current.reportedCostMicros ?? 0) == 0,
              usage.map({ Self.isMonotonic(current, after: $0) }) ?? true
        else { throw AgentContractError.invalidEventSequence("invalid model usage") }
    }

    private static func isMonotonic(
        _ current: AgentModelUsage,
        after previous: AgentModelUsage
    ) -> Bool {
        guard current.inputTokens >= previous.inputTokens,
              current.outputTokens >= previous.outputTokens,
              current.activeMilliseconds >= previous.activeMilliseconds,
              current.peakMemoryBytes >= previous.peakMemoryBytes,
              current.costCurrencyCode == previous.costCurrencyCode
        else { return false }
        return switch (current.reportedCostMicros, previous.reportedCostMicros) {
        case let (.some(current), .some(previous)): current >= previous
        case (.none, .none): true
        default: false
        }
    }
}

private actor ModelInvocationProbe {
    private(set) var started = false

    func markStarted() { started = true }
}
