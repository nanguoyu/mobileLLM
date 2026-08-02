// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Dispatch
import Foundation
import LLMCore

/// Bounded operational knobs for the local adapter. They do not alter model-selection policy.
public struct LocalModelAdapterConfiguration: Sendable {
    public let maximumImageBytes: UInt64
    public let maximumTotalImageBytes: UInt64
    public let maximumBufferedActionBytes: UInt64
    let nowMilliseconds: @Sendable () -> UInt64

    public init(
        maximumImageBytes: UInt64 = 32 * 1_024 * 1_024,
        maximumTotalImageBytes: UInt64 = 64 * 1_024 * 1_024,
        maximumBufferedActionBytes: UInt64 = 64 * 1_024,
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds / 1_000_000
        }
    ) throws {
        guard maximumImageBytes > 0,
              maximumTotalImageBytes >= maximumImageBytes,
              maximumBufferedActionBytes > 0
        else { throw LocalModelAdapterError.invalidRegistration("invalid adapter limits") }
        self.maximumImageBytes = maximumImageBytes
        self.maximumTotalImageBytes = maximumTotalImageBytes
        self.maximumBufferedActionBytes = maximumBufferedActionBytes
        self.nowMilliseconds = nowMilliseconds
    }
}

/// Production on-device adapter from Agent Harness requests to the existing `LLMCore.LLMEngine`.
///
/// Loading is deliberately separate: the resource arbiter calls `residencyDriver` first. Generation
/// never auto-loads, changes selection, consults a remote catalog, or performs a second model pass.
public struct LocalModelProvider: AgentModelProvider, Sendable {
    public let descriptor: AgentModelProviderDescriptor
    public let residencyDriver: LLMCoreModelResidencyDriver

    private let artifactResolver: any LocalModelArtifactBytesResolving
    private let configuration: LocalModelAdapterConfiguration

    public init(
        descriptor: AgentModelProviderDescriptor,
        residencyDriver: LLMCoreModelResidencyDriver,
        artifactResolver: any LocalModelArtifactBytesResolving =
            UnavailableLocalModelArtifactResolver(),
        configuration: LocalModelAdapterConfiguration = try! LocalModelAdapterConfiguration()
    ) throws {
        guard descriptor.location == .onDevice,
              !residencyDriver.registeredSelections.isEmpty,
              residencyDriver.registeredSelections.allSatisfy({
                  $0.providerID == descriptor.id
                    && $0.capabilityVersion == descriptor.capabilityVersion
              })
        else { throw LocalModelAdapterError.invalidRegistration("provider descriptor mismatch") }
        self.descriptor = descriptor
        self.residencyDriver = residencyDriver
        self.artifactResolver = artifactResolver
        self.configuration = configuration
    }

    public func capabilities(
        for selection: AgentModelSelection
    ) async throws -> AgentModelCapabilities {
        guard selection.providerID == descriptor.id,
              selection.capabilityVersion == descriptor.capabilityVersion
        else { throw LocalModelAdapterError.selectionNotRegistered(selection) }
        return try await residencyDriver.registration(for: selection).capabilities
    }

    public func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        _ = try await residencyDriver.registration(for: request.selection)
        return try LocalAgentModelPreparation.prepare(
            request: request,
            context: context,
            provider: descriptor
        )
    }

    public func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let registration = try await residencyDriver.registration(for: request.selection)
        let resolver = artifactResolver
        let configuration = configuration
        return try await residencyDriver.runGeneration(selection: request.selection) { engine in
            try await LocalModelGeneration.run(
                engine: engine,
                registration: registration,
                request: request,
                artifactResolver: resolver,
                configuration: configuration,
                emitter: emitter
            )
        }
    }
}

private enum LocalModelGeneration {
    static func run(
        engine: any LLMEngine,
        registration: LocalModelRegistration,
        request: AgentModelRequest,
        artifactResolver: any LocalModelArtifactBytesResolving,
        configuration: LocalModelAdapterConfiguration,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let messages: [ChatTurn]
        do {
            messages = try await compileMessages(
                request: request,
                registration: registration,
                artifactResolver: artifactResolver,
                configuration: configuration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentContractError {
            throw error
        } catch {
            return try await fail(
                artifactFailure(error),
                responseBytes: 0,
                emitter: emitter
            )
        }

        let sampling = samplingParameters(
            request.generationParameters,
            registration: registration
        )
        let bindings = LocalModelPromptRenderer.bindings(for: request.advertisedTools)
        var processor = ToolCallProcessor(acceptsBareJSON: registration.toolDialect == .deepSeek)
        var parsedCalls: [ToolCall] = []
        var answer = ""
        var stats: Stats?
        var silentActionBytes: UInt64 = 0
        let startedAt = configuration.nowMilliseconds()

        do {
            for try await delta in engine.generate(messages: messages, params: sampling) {
                try Task.checkCancellation()
                if stats != nil {
                    return try await fail(
                        protocolFailure("engine emitted data after its done event"),
                        responseBytes: sourceBytes(delta),
                        emitter: emitter
                    )
                }
                switch delta {
                case .reasoning(let value):
                    guard request.generationParameters.thinkingMode != .disabled,
                          registration.capabilities.features.contains(.reasoning),
                          !value.isEmpty
                    else {
                        return try await fail(
                            protocolFailure("engine emitted unsupported reasoning"),
                            responseBytes: UInt64(value.utf8.count),
                            emitter: emitter
                        )
                    }
                    try await emitter.emit(
                        .reasoningDelta(value),
                        responseBytes: UInt64(value.utf8.count)
                    )
                case .answer(let value):
                    guard !value.isEmpty else {
                        return try await fail(
                            protocolFailure("engine emitted an empty answer delta"),
                            responseBytes: 0,
                            emitter: emitter
                        )
                    }
                    let byteCount = UInt64(value.utf8.count)
                    let events = processor.feed(value)
                    let emittedText = try await consume(
                        events,
                        rawResponseBytes: byteCount,
                        emitsAnswerDeltas: request.outputRequirement.streamsTextAnswer,
                        answer: &answer,
                        calls: &parsedCalls,
                        emitter: emitter
                    )
                    if emittedText || !events.isEmpty {
                        silentActionBytes = 0
                    } else {
                        let (sum, overflow) = silentActionBytes.addingReportingOverflow(byteCount)
                        silentActionBytes = overflow ? .max : sum
                        try await emitter.emit(
                            .usage(zeroUsage),
                            responseBytes: byteCount
                        )
                    }
                    if let malformed = malformedBody(in: events) {
                        return try await fail(
                            malformedFailure(malformed, dialect: registration.toolDialect),
                            responseBytes: 0,
                            emitter: emitter
                        )
                    }
                    if silentActionBytes > configuration.maximumBufferedActionBytes {
                        return try await fail(
                            malformedFailure("oversized tool-call candidate", dialect: registration.toolDialect),
                            responseBytes: 0,
                            emitter: emitter
                        )
                    }
                    if parsedCalls.count > 64 {
                        return try await fail(
                            malformedFailure("too many tool calls", dialect: registration.toolDialect),
                            responseBytes: 0,
                            emitter: emitter
                        )
                    }
                case .done(let value):
                    stats = value
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentContractError {
            throw error
        } catch {
            // Some AsyncSequence implementations finish with an implementation-specific
            // error (or simply close) when their producer task is cancelled. Cancellation
            // is an attempt interruption, never an engine failure eligible for retry.
            if Task.isCancelled { throw CancellationError() }
            return try await fail(engineFailure(), responseBytes: 0, emitter: emitter)
        }

        try Task.checkCancellation()
        let trailing = processor.finish()
        _ = try await consume(
            trailing,
            rawResponseBytes: 0,
            emitsAnswerDeltas: request.outputRequirement.streamsTextAnswer,
            answer: &answer,
            calls: &parsedCalls,
            emitter: emitter
        )
        if let malformed = malformedBody(in: trailing) {
            return try await fail(
                malformedFailure(malformed, dialect: registration.toolDialect),
                responseBytes: 0,
                emitter: emitter
            )
        }
        if parsedCalls.count > 64 {
            return try await fail(
                malformedFailure("too many tool calls", dialect: registration.toolDialect),
                responseBytes: 0,
                emitter: emitter
            )
        }
        guard let stats else {
            return try await fail(
                protocolFailure("engine stream ended without usage statistics"),
                responseBytes: 0,
                emitter: emitter
            )
        }

        let usage: AgentModelUsage
        do {
            usage = try modelUsage(
                stats,
                request: request,
                startedAt: startedAt,
                endedAt: configuration.nowMilliseconds()
            )
        } catch {
            return try await fail(
                protocolFailure("engine reported invalid usage"),
                responseBytes: 0,
                emitter: emitter
            )
        }
        try await emitter.emit(.usage(usage), responseBytes: 0)
        if stats.stopReason == .cancelled {
            return AgentModelBoundaryCompletion(outcome: .interrupted(usage))
        }

        if !parsedCalls.isEmpty {
            let action: AgentAction
            do {
                action = .callTools(try normalizeCalls(
                    parsedCalls,
                    bindings: bindings,
                    request: request
                ))
            } catch {
                return try await fail(
                    malformedFailure("invalid tool name, arguments, or schema", dialect: registration.toolDialect),
                    responseBytes: 0,
                    emitter: emitter
                )
            }
            if case .callTools(let calls) = action {
                try await emitter.emit(.toolCalls(calls), responseBytes: 0)
            }
            return try await complete(action, usage: usage, emitter: emitter)
        }

        let action: AgentAction
        switch request.outputRequirement {
        case .text, .textAndArtifacts:
            guard !answer.isEmpty else {
                return try await fail(
                    protocolFailure("model produced no final answer"),
                    responseBytes: 0,
                    emitter: emitter
                )
            }
            action = .finalAnswer(try AgentAnswer(text: answer))
        case .structured(let schema):
            guard let value = decodeStructuredAnswer(answer),
                  (try? schema.validates(instance: value)) == true
            else {
                return try await fail(
                    structuredOutputFailure(),
                    responseBytes: 0,
                    emitter: emitter
                )
            }
            action = .finalAnswer(try AgentAnswer(structuredOutput: value))
        case .artifacts:
            return try await fail(
                artifactOutputFailure(),
                responseBytes: 0,
                emitter: emitter
            )
        }
        return try await complete(action, usage: usage, emitter: emitter)
    }

    private static func compileMessages(
        request: AgentModelRequest,
        registration: LocalModelRegistration,
        artifactResolver: any LocalModelArtifactBytesResolving,
        configuration: LocalModelAdapterConfiguration
    ) async throws -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var totalImageBytes: UInt64 = 0
        for message in request.messages {
            var images: [Data] = []
            for reference in message.artifacts where reference.mimeType.hasPrefix("image/") {
                guard reference.integrityStatus == .verified,
                      reference.byteCount <= configuration.maximumImageBytes
                else { throw LocalModelAdapterError.artifactIntegrityMismatch(reference.id) }
                let (nextTotal, overflow) = totalImageBytes.addingReportingOverflow(reference.byteCount)
                guard !overflow, nextTotal <= configuration.maximumTotalImageBytes else {
                    throw LocalModelAdapterError.artifactLimitExceeded
                }
                let bytes = try await artifactResolver.preauthorizedBytes(for: reference)
                guard UInt64(bytes.count) == reference.byteCount,
                      StableDigest.sha256(bytes) == reference.contentDigest
                else { throw LocalModelAdapterError.artifactIntegrityMismatch(reference.id) }
                totalImageBytes = nextTotal
                images.append(bytes)
            }
            let content = message.isUntrustedData
                ? LocalModelPromptRenderer.frameUntrusted(
                    message.content,
                    dialect: registration.toolDialect
                )
                : message.content
            turns.append(ChatTurn(
                role: engineRole(message.role),
                content: content,
                images: images
            ))
        }

        var policyBlocks: [String] = []
        let bindings = LocalModelPromptRenderer.bindings(for: request.advertisedTools)
        let toolBlock = try LocalModelPromptRenderer.toolBlock(
            bindings: bindings,
            dialect: registration.toolDialect
        )
        if !toolBlock.isEmpty { policyBlocks.append(toolBlock) }
        if case .structured(let schema) = request.outputRequirement {
            policyBlocks.append(try LocalModelPromptRenderer.structuredOutputBlock(schema))
        }
        guard !policyBlocks.isEmpty else { return turns }
        let policy = policyBlocks.joined(separator: "\n\n")
        if let index = turns.firstIndex(where: { $0.role == .system }) {
            let existing = turns[index]
            turns[index] = ChatTurn(
                role: .system,
                content: existing.content + "\n\n" + policy,
                images: existing.images
            )
        } else {
            turns.insert(ChatTurn(role: .system, content: policy), at: 0)
        }
        return turns
    }

    private static func engineRole(_ role: AgentModelMessageRole) -> ChatTurn.Role {
        switch role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        case .tool: .user
        }
    }

    private static func samplingParameters(
        _ parameters: AgentModelGenerationParameters,
        registration: LocalModelRegistration
    ) -> Sampling {
        let thinking = switch parameters.thinkingMode {
        case .disabled: false
        case .enabled: true
        case .automatic: registration.capabilities.features.contains(.reasoning)
        }
        return Sampling(
            temperature: parameters.temperature,
            topP: parameters.topP,
            topK: parameters.topK.map(Int.init) ?? 0,
            repetitionPenalty: parameters.repetitionPenalty,
            maxTokens: Int(parameters.maximumOutputTokens),
            thinking: thinking,
            contextTokenCap: Int(parameters.maximumContextTokens),
            kvBits: 4,
            quantizedKVStart: 256,
            seed: parameters.seed
        )
    }

    @discardableResult
    private static func consume(
        _ events: [ToolCallProcessor.Event],
        rawResponseBytes: UInt64,
        emitsAnswerDeltas: Bool,
        answer: inout String,
        calls: inout [ToolCall],
        emitter: AgentModelBoundaryEmitter
    ) async throws -> Bool {
        var accounted = false
        var emittedText = false
        for event in events {
            switch event {
            case .text(let text):
                guard !text.isEmpty else { continue }
                answer += text
                if emitsAnswerDeltas {
                    try await emitter.emit(
                        .answerDelta(text),
                        responseBytes: accounted ? 0 : rawResponseBytes
                    )
                    accounted = true
                    emittedText = true
                }
            case .call(let call):
                calls.append(call)
            case .malformed:
                break
            }
        }
        if !accounted, rawResponseBytes > 0, !events.isEmpty {
            try await emitter.emit(.usage(zeroUsage), responseBytes: rawResponseBytes)
        }
        return emittedText
    }

    private static func malformedBody(
        in events: [ToolCallProcessor.Event]
    ) -> String? {
        for event in events {
            if case .malformed(let body) = event { return body }
        }
        return nil
    }

    private static func normalizeCalls(
        _ calls: [ToolCall],
        bindings: [LocalModelToolBinding],
        request: AgentModelRequest
    ) throws -> [ProposedToolCall] {
        try calls.enumerated().map { index, call in
            guard let binding = bindings.first(where: { $0.wireName == call.name }),
                  let data = call.argumentsJSON.data(using: .utf8)
            else { throw LocalModelAdapterError.invalidRegistration("unknown model tool call") }
            let value = try AgentWireDecoder.decode(
                JSONValue.self,
                from: data,
                limits: .inlineValue
            )
            guard try binding.descriptor.inputSchema.validates(instance: value) else {
                throw LocalModelAdapterError.invalidRegistration("invalid model tool arguments")
            }
            let arguments = try CanonicalJSON(value)
            return ProposedToolCall(
                invocationID: deterministicInvocationID(
                    request: request,
                    index: index,
                    binding: binding,
                    arguments: arguments
                ),
                toolID: binding.descriptor.id.logicalID,
                arguments: arguments
            )
        }
    }

    private static func deterministicInvocationID(
        request: AgentModelRequest,
        index: Int,
        binding: LocalModelToolBinding,
        arguments: CanonicalJSON
    ) -> ToolInvocationID {
        let digest = StableDigest.fingerprint(
            domain: "local-model-tool-invocation.v1",
            components: [
                Data(request.requestID.description.utf8),
                Data(request.stepID.description.utf8),
                Data(String(index).utf8),
                Data(binding.descriptor.id.description.utf8),
                arguments.data,
            ]
        ).rawValue
        let part1 = String(digest.prefix(8))
        let part2 = String(digest.dropFirst(8).prefix(4))
        let part3 = String(digest.dropFirst(12).prefix(4))
        let part4 = String(digest.dropFirst(16).prefix(4))
        let part5 = String(digest.dropFirst(20).prefix(12))
        let uuid = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
        return ToolInvocationID(rawValue: UUID(uuidString: uuid)!)
    }

    private static func decodeStructuredAnswer(_ answer: String) -> JSONValue? {
        var candidate = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            guard let firstLine = candidate.firstIndex(of: "\n"),
                  candidate.hasSuffix("```")
            else { return nil }
            candidate = String(candidate[candidate.index(after: firstLine)...].dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? AgentWireDecoder.decode(JSONValue.self, from: data, limits: .inlineValue)
    }

    private static func modelUsage(
        _ stats: Stats,
        request: AgentModelRequest,
        startedAt: UInt64,
        endedAt: UInt64
    ) throws -> AgentModelUsage {
        guard stats.promptTokens >= 0,
              stats.genTokens >= 0,
              stats.peakMemoryBytes >= 0,
              UInt64(stats.promptTokens) <= request.generationParameters.maximumContextTokens,
              UInt64(stats.genTokens) <= request.generationParameters.maximumOutputTokens
        else { throw LocalModelAdapterError.invalidRegistration("invalid engine usage") }
        return try AgentModelUsage(
            inputTokens: UInt64(stats.promptTokens),
            outputTokens: UInt64(stats.genTokens),
            activeMilliseconds: endedAt >= startedAt ? endedAt - startedAt : 0,
            peakMemoryBytes: UInt64(stats.peakMemoryBytes)
        )
    }

    private static func complete(
        _ action: AgentAction,
        usage: AgentModelUsage,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        let completion = try AgentModelCompletion(action: action, usage: usage)
        try await emitter.emit(.completed(completion), responseBytes: 0)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }

    private static func fail(
        _ failure: AgentFailure,
        responseBytes: UInt64,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        try await emitter.emit(.failed(failure), responseBytes: responseBytes)
        return AgentModelBoundaryCompletion(outcome: .failed(failure))
    }

    private static var zeroUsage: AgentModelUsage {
        try! AgentModelUsage(
            inputTokens: 0,
            outputTokens: 0,
            activeMilliseconds: 0,
            peakMemoryBytes: 0
        )
    }

    private static func malformedFailure(_ raw: String, dialect: ToolDialect) -> AgentFailure {
        let bytes = Data(raw.utf8)
        return try! AgentFailure(
            code: "model.local.malformed-action",
            classification: .incompatible,
            safeMessage: "The local model produced a tool action that could not be validated.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            details: [
                "dialect": dialect.rawValue,
                "responseBytes": String(bytes.count),
            ],
            redaction: RedactionMetadata(
                // The provider response itself is never retained.  Only the bounded
                // diagnostic fields above and this one-way correlation digest cross
                // the boundary, so the persisted envelope is internal metadata.
                classification: .internalMetadata,
                redactedFieldPaths: ["providerResponse.toolCall"],
                omittedByteCount: UInt64(max(1, bytes.count)),
                policyVersion: 1,
                omittedContentDigest: StableDigest.sha256(bytes)
            )
        )
    }

    private static func protocolFailure(_ detail: String) -> AgentFailure {
        try! AgentFailure(
            code: "model.local.protocol-violation",
            classification: .incompatible,
            safeMessage: "The local model engine returned an invalid generation stream.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .restoreDependency,
            details: ["reason": detail],
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func engineFailure() -> AgentFailure {
        try! AgentFailure(
            code: "model.local.engine-failure",
            classification: .transient,
            safeMessage: "The local model engine stopped before completing this attempt.",
            retryAdvice: try! AgentRetryAdvice(
                automaticallyRetryable: true,
                maximumAdditionalAttempts: 1
            ),
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func artifactFailure(_ error: Error) -> AgentFailure {
        try! AgentFailure(
            code: "model.local.artifact-unavailable",
            classification: .incompatible,
            safeMessage: "An authorized image could not be verified for local model input.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .restoreDependency,
            details: ["reason": String(describing: type(of: error))],
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func structuredOutputFailure() -> AgentFailure {
        try! AgentFailure(
            code: "model.local.structured-output-invalid",
            classification: .incompatible,
            safeMessage: "The local model response did not match the required structured output schema.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func artifactOutputFailure() -> AgentFailure {
        try! AgentFailure(
            code: "model.local.artifact-output-unsupported",
            classification: .incompatible,
            safeMessage: "This local model adapter cannot create durable artifact output directly.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .restoreDependency,
            redaction: RedactionMetadata(classification: .internalMetadata, policyVersion: 1)
        )
    }

    private static func sourceBytes(_ delta: EngineDelta) -> UInt64 {
        switch delta {
        case .reasoning(let value), .answer(let value): UInt64(value.utf8.count)
        case .done: 0
        }
    }
}

private extension AgentOutputRequirement {
    var streamsTextAnswer: Bool {
        switch self {
        case .text, .textAndArtifacts: true
        case .structured, .artifacts: false
        }
    }
}
