// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// One OpenAI-compatible service configuration, injected by the app at assembly time. The API key
/// lives in the device Keychain; the app reads it once and hands it here.
public struct ResponsesAPIConfiguration: Sendable, Equatable {
    /// Stable service identity distinguishing multiple online services in approval destinations.
    /// Kept in lockstep with the app's `OnlineService.id`; "responses-api-key" is the migrated default.
    public let serviceID: String
    public let baseURL: String
    public let apiKey: String
    /// Per-conversation reasoning effort (nil = service default; only sent when reasoning is enabled).
    public let reasoningEffort: ReasoningEffort?
    /// The selected model's REAL maximum output tokens when known. Nil means "unknown" — the runtime
    /// falls back to the conversation's context window as the accounting ceiling and the wire limit
    /// is omitted in auto mode so the service uses its own model default.
    public let maximumOutputTokens: UInt64?

    public static let defaultServiceID = "responses-api-key"

    public init(
        serviceID: String = ResponsesAPIConfiguration.defaultServiceID,
        baseURL: String,
        apiKey: String,
        reasoningEffort: ReasoningEffort? = nil,
        maximumOutputTokens: UInt64? = nil
    ) {
        self.serviceID = serviceID
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.reasoningEffort = reasoningEffort
        self.maximumOutputTokens = maximumOutputTokens
    }
}

/// Reasoning effort for reasoning-capable models (spec §15.3): low/medium/high, medium default.
public enum ReasoningEffort: String, CaseIterable, Hashable, Codable, Sendable {
    case low
    case medium
    case high
}

/// Per-run attempt timeout derived from the prepared plan (the run budget), keyed by request id so the
/// URLSession deadline is never a second hardcoded guess. An actor keeps this async-safe.
private actor ResponsesAPITimeoutStore {
    private var values: [AgentRequestID: TimeInterval] = [:]

    func store(_ timeout: TimeInterval, for requestID: AgentRequestID) {
        values[requestID] = timeout
    }

    func take(for requestID: AgentRequestID) -> TimeInterval? {
        values.removeValue(forKey: requestID)
    }
}

/// An `AgentModelProvider` that calls an OpenAI-compatible `/responses` endpoint, or the documented
/// Chat Completions endpoint for the official DeepSeek service. The whole request is one prepared,
/// authorized external operation (data egress, spec §15.1): every generation runs inside the model
/// boundary with exact destination, data category, and response accounting.
public final class ResponsesAPIModelProvider: AgentModelProvider, @unchecked Sendable {
    public static let providerID = "openai.responses"
    /// Advertising ceiling for OpenAI-compatible services without per-model metadata (matches the
    /// context window the app already advertises for online runs).
    public static let maximumContextTokens: UInt64 = 200_000

    public let descriptor: AgentModelProviderDescriptor
    /// Resolved on every generation so settings/Keychain changes apply without an app restart. The
    /// provider never retains the key in memory beyond one request; returning nil fails closed.
    private let configurationProvider: @Sendable (AgentModelSelection) -> ResponsesAPIConfiguration?
    private let session: URLSession
    /// Per-run attempt timeout derived from the prepared plan (the run budget), so the URLSession
    /// deadline is never a second hardcoded guess. Keyed by request id; cleared after each generate.
    private let timeouts = ResponsesAPITimeoutStore()

    enum WireDialect: Sendable, Equatable {
        case responses
        case deepSeekChatCompletions
    }

    public convenience init(
        configuration: ResponsesAPIConfiguration,
        session: URLSession = .shared,
        capabilityVersion: SemanticVersion = SemanticVersion("1.0.0")!
    ) throws {
        try self.init(
            selectionConfigurationProvider: { _ in configuration },
            session: session,
            capabilityVersion: capabilityVersion
        )
    }

    /// Backward-compatible dynamic configuration seam for one-service clients.
    public convenience init(
        configurationProvider: @escaping @Sendable () -> ResponsesAPIConfiguration?,
        session: URLSession = .shared,
        capabilityVersion: SemanticVersion = SemanticVersion("1.0.0")!
    ) throws {
        try self.init(
            selectionConfigurationProvider: { _ in configurationProvider() },
            session: session,
            capabilityVersion: capabilityVersion
        )
    }

    /// Selection-scoped configuration keeps concurrent/recovered runs bound to the endpoint and
    /// credential account represented by their immutable model selection.
    public init(
        selectionConfigurationProvider: @escaping @Sendable (AgentModelSelection) -> ResponsesAPIConfiguration?,
        session: URLSession = .shared,
        capabilityVersion: SemanticVersion = SemanticVersion("1.0.0")!
    ) throws {
        configurationProvider = selectionConfigurationProvider
        self.session = session
        descriptor = AgentModelProviderDescriptor(
            id: try AgentModelProviderID(Self.providerID),
            adapterVersion: capabilityVersion,
            capabilityVersion: capabilityVersion,
            location: .remote
        )
    }

    public func capabilities(for selection: AgentModelSelection) async throws -> AgentModelCapabilities {
        // Per-service metadata wins when the user configured the model's real max output; otherwise
        // the provider stays permissive (up to the same ceiling it advertises for context) so auto
        // mode can never be rejected because our fallback was too small.
        let outputCeiling = configurationProvider(selection)?.maximumOutputTokens
            ?? Self.maximumContextTokens
        return try AgentModelCapabilities(
            maximumContextTokens: Self.maximumContextTokens,
            maximumOutputTokens: outputCeiling,
            features: AgentModelCapabilitySet([
                .nativeToolCalling, .multipleToolCalls, .reasoning,
            ]),
            toolCallingMode: .nativeStructured,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 16,
                requiresResidentModel: false,
                requiresDrainBeforeSwitch: false
            ),
            reportsTokenUsage: true,
            reportsCost: true
        )
    }

    public func prepare(
        _ request: AgentModelRequest,
        context: ModelPreparationContext
    ) async throws -> PreparedModelRequest {
        guard let configuration = configurationProvider(request.selection) else {
            throw AgentModelProviderFailure(try Self.configurationMissingFailure())
        }
        let modelName = request.selection.modelID.rawValue
        let plan = try ExternalOperationPlan(
            kind: .modelProvider,
            subjectID: descriptor.id.rawValue,
            destination: try ExternalDestination(
                kind: .modelProvider,
                normalizedIdentity: "\(Self.providerID):\(configuration.serviceID):\(modelName)"
            ),
            dataCategories: [try AgentDataCategory(rawValue: "model.inference")],
            payloadDigest: context.authorizationPayload.fingerprint,
            effects: [.externalCommunication],
            requiredCapabilities: AgentCapabilitySet([.externalCommunication]),
            maximumRequestBytes: context.maximumRequestBytes,
            maximumResponseBytes: context.maximumResponseBytes,
            timeoutMilliseconds: context.timeoutMilliseconds,
            retryPolicy: .never,
            idempotency: .nonIdempotent,
            userPreview: "Send this conversation to \(modelName)"
        )
        // The plan timeout is the run-budget-derived ceiling for THIS attempt; the URLSession must
        // honor the same number instead of a fixed constant.
        await timeouts.store(
            TimeInterval(context.timeoutMilliseconds) / 1_000,
            for: request.requestID
        )
        let external = try PreparedExternalOperationRequest(
            requestID: request.requestID,
            runID: request.runID,
            conversationID: context.conversationID,
            stepID: request.stepID,
            plan: plan,
            payload: context.authorizationPayload,
            capabilityGrant: context.capabilityGrant
        )
        return try PreparedModelRequest(request: request, externalOperation: external)
    }

    public func generate(
        _ request: AgentModelRequest,
        emitter: AgentModelBoundaryEmitter
    ) async throws -> AgentModelBoundaryCompletion {
        try Task.checkCancellation()
        let parameters = request.generationParameters
        guard let configuration = configurationProvider(request.selection) else {
            throw AgentModelProviderFailure(try Self.configurationMissingFailure())
        }
        guard let baseURL = URL(string: configuration.baseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https",
              baseURL.host?.isEmpty == false
        else {
            throw AgentModelProviderFailure(try Self.invalidBaseURLFailure())
        }
        let dialect = Self.wireDialect(
            baseURL: configuration.baseURL,
            modelID: request.selection.modelID.rawValue
        )
        let timeout = await timeouts.take(for: request.requestID) ?? 60
        func makeRequest() -> URLRequest {
            let endpoint = switch dialect {
            case .responses: baseURL.appending(path: "responses")
            case .deepSeekChatCompletions: baseURL.appending(path: "chat/completions")
            }
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            return urlRequest
        }
        func body(
            reasoningDisabled: Bool? = nil,
            maxOutputTokensOverride: UInt64? = nil,
            omitReasoning: Bool = false
        ) throws -> Data {
            switch dialect {
            case .responses:
                try Self.requestBody(
                    request: request,
                    baseURL: configuration.baseURL,
                    reasoningDisabled: reasoningDisabled,
                    maxOutputTokensOverride: maxOutputTokensOverride,
                    reasoningEffort: configuration.reasoningEffort,
                    omitReasoning: omitReasoning,
                    stream: true
                )
            case .deepSeekChatCompletions:
                try Self.chatCompletionsRequestBody(
                    request: request,
                    reasoningDisabled: reasoningDisabled,
                    maxOutputTokensOverride: maxOutputTokensOverride,
                    reasoningEffort: configuration.reasoningEffort,
                    omitReasoning: omitReasoning,
                    stream: true
                )
            }
        }
        let accounting = ResponsesAPIAccounting(emitter: emitter)
        let emitReasoning = request.generationParameters.thinkingMode != .disabled
        // A structured answer is normalized before it becomes the terminal action (for example,
        // outer whitespace/fences are removed). Streaming the raw bytes first would make the
        // executor correctly reject the provider because the provisional answer no longer equals
        // the normalized terminal answer. Keep structured output attempt-local until validation;
        // normal prose still streams token by token.
        let emitStreamDeltas = !Self.isStructured(request)
        func attempt(
            _ payload: Data,
            allowEffortFallback: Bool,
            allowAutoFallback: Bool,
            streamEmission: Bool = true
        ) async throws -> (parsed: ParsedResponse, streamed: Bool, data: Data) {
            var urlRequest = makeRequest()
            var boundedPayload = payload
            let spent = await accounting.usage
            if spent.outputTokens > 0 || spent.inputTokens > 0 {
                guard spent.outputTokens < parameters.maximumOutputTokens,
                      spent.inputTokens <= parameters.maximumContextTokens / 2 else {
                    throw AgentContractError.invalidEventSequence("online retry budget exhausted")
                }
                let remaining = parameters.maximumOutputTokens - spent.outputTokens
                guard var fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw AgentContractError.invalidEventSequence("invalid online request object")
                }
                let field = dialect == .responses ? "max_output_tokens" : "max_tokens"
                let requested = (fields[field] as? NSNumber)?.uint64Value ?? remaining
                fields[field] = min(requested, remaining)
                boundedPayload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            }
            urlRequest.httpBody = boundedPayload
            let (rawBytes, response) = try await session.bytes(for: urlRequest, delegate: ResponsesAPIRedirectBlocker.shared)
            let bytes = AccountedResponseBytes(bytes: rawBytes, accounting: accounting)
            try Task.checkCancellation()
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                // Some gateways reject the reasoning-effort field entirely (HTTP 400 mentioning
                // "reasoning"); retry once with the field omitted rather than failing the turn.
                if http?.statusCode == 400,
                   let errorText = String(data: data, encoding: .utf8)
                {
                    if allowEffortFallback,
                       ["reasoning", "thinking"].contains(where: {
                           errorText.localizedCaseInsensitiveContains($0)
                       })
                    {
                        let fallbackBody = try body(omitReasoning: true)
                        if fallbackBody != payload {
                            return try await attempt(
                                fallbackBody,
                                allowEffortFallback: false,
                                allowAutoFallback: false,
                                streamEmission: streamEmission
                            )
                        }
                    }
                    // Auto mode omits max_output_tokens; a gateway that REQUIRES the field rejects
                    // with a token-limit message. Retry once with the runtime ceiling as the explicit
                    // budget so the turn still works on strict services.
                    if allowAutoFallback,
                       ["max_output_tokens", "max_tokens", "output_tokens", "output limit"]
                           .contains(where: { errorText.localizedCaseInsensitiveContains($0) })
                    {
                        let fallbackBody = try body(
                            maxOutputTokensOverride: parameters.maximumOutputTokens
                        )
                        if fallbackBody != payload {
                            return try await attempt(
                                fallbackBody,
                                allowEffortFallback: false,
                                allowAutoFallback: false,
                                streamEmission: streamEmission
                            )
                        }
                    }
                }
                throw AgentModelProviderFailure(
                    try Self.httpFailure(
                        status: http?.statusCode ?? -1,
                        body: String(data: data, encoding: .utf8)
                    )
                )
            }
            let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            if contentType.contains("text/event-stream") {
                let parsed = switch dialect {
                case .responses:
                    try await Self.consumeEventStream(
                        bytes,
                        emitter: emitter,
                        emitReasoning: emitReasoning,
                        emit: streamEmission
                    )
                case .deepSeekChatCompletions:
                    try await Self.consumeChatCompletionsEventStream(
                        bytes,
                        emitter: emitter,
                        emitReasoning: emitReasoning,
                        emit: streamEmission
                    )
                }
                try await accounting.record(parsed.usage)
                return (parsed, true, Data())
            }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let parsed = switch dialect {
            case .responses: try Self.parseResponse(data)
            case .deepSeekChatCompletions: try Self.parseChatCompletion(data)
            }
            try await accounting.record(parsed.usage)
            return (parsed, false, data)
        }

        let started = ContinuousClock.now
        let firstBody = try body()
        var (parsed, streamed, _) = try await attempt(
            firstBody,
            allowEffortFallback: true,
            allowAutoFallback: parameters.outputBudgetMode == .auto,
            streamEmission: emitStreamDeltas
        )

        // Output-budget truncation: retry ONCE with a higher explicit budget. Streamed first
        // attempts keep what the UI already showed and emit only the continuation when the retry
        // preserves the shown prefix — never duplicating or splicing text.
        let outputCeiling = configuration.maximumOutputTokens ?? Self.maximumContextTokens
        let retryCeiling = min(outputCeiling, parameters.maximumOutputTokens)
        if parsed.isTruncated,
           parameters.outputBudgetMode == .auto
                || parameters.maximumOutputTokens < retryCeiling
        {
            let bumped = min(
                max(parameters.maximumOutputTokens, 16_384),
                retryCeiling
            )
            let retryBody = try body(maxOutputTokensOverride: bumped)
            let (retried, retriedStreamed, _) = try await attempt(
                retryBody,
                allowEffortFallback: false,
                allowAutoFallback: false,
                streamEmission: emitStreamDeltas && !streamed
            )
            if streamed {
                let textContinues = parsed.text.isEmpty || retried.text.hasPrefix(parsed.text)
                if textContinues,
                   !retried.isTruncated || retried.text.utf8.count > parsed.text.utf8.count
                {
                    let reasoningContinues = parsed.reasoning.isEmpty
                        || retried.reasoning.hasPrefix(parsed.reasoning)
                    if emitReasoning, reasoningContinues,
                       retried.reasoning.count > parsed.reasoning.count
                    {
                        try await emitter.emit(
                            .reasoningDelta(String(retried.reasoning.dropFirst(parsed.reasoning.count))),
                            responseBytes: 0
                        )
                    }
                    if retried.text.count > parsed.text.count {
                        try await emitter.emit(
                            .answerDelta(String(retried.text.dropFirst(parsed.text.count))),
                            responseBytes: 0
                        )
                    }
                    parsed = retried
                }
            } else if !retried.isTruncated || retried.text.utf8.count > parsed.text.utf8.count {
                parsed = retried
                streamed = retriedStreamed
            }
        }

        if !streamed {
            // Non-streaming fallback keeps the reasoning-only retry (streamed reasoning-only is
            // handled below; both stay inside the same authorization boundary).
            if parsed.text.isEmpty, parsed.calls.isEmpty, parsed.hasReasoning {
                let retryBody = try body(reasoningDisabled: true)
                let (retried, retriedStreamed, _) = try await attempt(
                    retryBody,
                    allowEffortFallback: false,
                    allowAutoFallback: false,
                    streamEmission: emitStreamDeltas
                )
                parsed = retried
                streamed = retriedStreamed
            }
        } else if parsed.text.isEmpty, parsed.calls.isEmpty, parsed.hasReasoning {
            // Streamed reasoning-only: reasoning was already shown live; retry once without reasoning
            // so the ANSWER streams too (no duplication of answer text).
            let retryBody = try body(reasoningDisabled: true)
            let (retried, retriedStreamed, _) = try await attempt(
                retryBody,
                allowEffortFallback: false,
                allowAutoFallback: false,
                streamEmission: emitStreamDeltas
            )
            parsed = retried
            streamed = retriedStreamed
        }
        try Task.checkCancellation()
        let elapsedMilliseconds = UInt64(
            (started.duration(to: .now) / .milliseconds(1))
        )
        let totalUsage = await accounting.usage
        let usage = try AgentModelUsage(
            inputTokens: totalUsage.inputTokens,
            outputTokens: totalUsage.outputTokens,
            activeMilliseconds: elapsedMilliseconds,
            peakMemoryBytes: 0
        )
        try await emitter.emit(.usage(usage), responseBytes: 0)

        if !streamed {
            // Non-streaming path emits the whole reasoning/answer after the request completes;
            // the streaming path already emitted them delta by delta.
            if !parsed.reasoning.isEmpty, emitReasoning {
                try await emitter.emit(.reasoningDelta(parsed.reasoning), responseBytes: 0)
            }
            if !parsed.text.isEmpty, emitStreamDeltas {
                try await emitter.emit(.answerDelta(parsed.text), responseBytes: 0)
            }
        }

        // Some compatible gateways repeat the SAME function_call item (identical name + arguments)
        // when the model decides to call a tool; the runtime would count every duplicate against the
        // per-run tool budget and fail the batch. Identical duplicates are no-ops — keep one.
        let calls = Self.deduplicatedCalls(parsed.calls)
        let action: AgentAction
        if calls.isEmpty {
            let structured = Self.isStructured(request)
            let finalText = structured ? Self.structuredJSONText(parsed.text) : parsed.text
            guard !finalText.isEmpty else {
                throw AgentModelProviderFailure(try Self.emptyFailure())
            }
            if structured {
                let value: JSONValue
                do {
                    value = try AgentWireDecoder.decode(
                        JSONValue.self,
                        from: Data(finalText.utf8),
                        limits: .inlineValue
                    )
                } catch {
                    throw AgentModelProviderFailure(try Self.structuredOutputFailure())
                }
                action = .finalAnswer(try AgentAnswer(structuredOutput: value))
            } else {
                action = .finalAnswer(try AgentAnswer(text: finalText))
            }
        } else {
            // Continuation state is persisted per call. Bound the derived representation before
            // duplicating opaque provider data into an action or a later context snapshot.
            let reasoningBytes = try JSONValue.array(parsed.reasoningItems).canonicalData().count
                + (parsed.reasoningItems.isEmpty ? parsed.reasoning.utf8.count : 0)
            guard reasoningBytes <= 1_048_576 / max(1, calls.count) else {
                throw AgentModelProviderFailure(try Self.toolFailure("Native tool continuation exceeds its size limit."))
            }
            let normalized = try calls.enumerated().map { index, call in
                try Self.normalize(
                    name: call.name,
                    argumentsJSON: call.argumentsJSON,
                    index: index,
                    request: request,
                    callID: call.callID,
                    reasoningItems: parsed.reasoningItems,
                    reasoningText: parsed.reasoningItems.isEmpty && !parsed.reasoning.isEmpty ? parsed.reasoning : nil
                )
            }
            action = .callTools(normalized)
        }
        try await emitter.emit(
            .completed(try AgentModelCompletion(action: action, usage: usage)),
            responseBytes: 0
        )
        return AgentModelBoundaryCompletion(
            outcome: .completed(try AgentModelCompletion(action: action, usage: usage)),
            responseDigest: try await accounting.digest
        )
    }

    // MARK: - Event-stream consumption

    private static func consumeEventStream(
        _ bytes: AccountedResponseBytes,
        emitter: AgentModelBoundaryEmitter,
        emitReasoning: Bool,
        emit: Bool = true
    ) async throws -> ParsedResponse {
        var reasoning = ""
        var text = ""
        var calls: [ParsedCall] = []
        var partialCalls: [Int: (name: String, arguments: String, callID: String?)] = [:]
        var reasoningItems: [JSONValue] = []
        var hasReasoningOutput = false
        var isTruncated = false
        var usage = ParsedUsage(inputTokens: 0, outputTokens: 0)

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let value = try? AgentWireDecoder.decode(
                      JSONValue.self,
                      from: Data(payload.utf8),
                      limits: .inlineValue
                  ),
                  case .object(let event) = value,
                  case .string(let type)? = event["type"]
            else { continue }

            let index = Int(min(Self.unsignedNumber(event["output_index"]) ?? 0, UInt64(Int.max)))
            switch type {
            case "response.output_item.added":
                if case .object(let item)? = event["item"] {
                    if item["type"] == .string("function_call"),
                       case .string(let name)? = item["name"]
                    {
                        partialCalls[index] = (name, "", stringValue(item["call_id"]))
                    } else if item["type"] == .string("reasoning") {
                        hasReasoningOutput = true
                    }
                }
            case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
                if case .string(let delta)? = event["delta"], !delta.isEmpty {
                    reasoning += delta
                    if emit, emitReasoning {
                        try await emitter.emit(.reasoningDelta(delta), responseBytes: 0)
                    }
                }
            case "response.output_text.delta":
                if case .string(let delta)? = event["delta"], !delta.isEmpty {
                    text += delta
                    if emit {
                        try await emitter.emit(.answerDelta(delta), responseBytes: 0)
                    }
                }
            case "response.function_call_arguments.delta":
                if case .string(let delta)? = event["delta"] {
                    var call = partialCalls[index] ?? ("", "", nil)
                    call.arguments += delta
                    partialCalls[index] = call
                }
            case "response.output_item.done":
                if case .object(let item)? = event["item"] {
                    if item["type"] == .string("reasoning") { reasoningItems.append(.object(item)) }
                    if item["type"] == .string("function_call") {
                        let pending = partialCalls.removeValue(forKey: index)
                        let name = stringValue(item["name"]) ?? pending?.name ?? ""
                        let arguments = stringValue(item["arguments"]) ?? pending?.arguments ?? ""
                        if !name.isEmpty {
                            calls.append(ParsedCall(name: name, argumentsJSON: arguments,
                                                    callID: stringValue(item["call_id"]) ?? pending?.callID))
                        }
                    }
                }
            case "response.completed", "response.incomplete":
                if case .object(let response)? = event["response"] {
                    let finished = try parseResponse(JSONValue.object(response).canonicalData())
                    if !finished.calls.isEmpty { calls = finished.calls }
                    if !finished.reasoningItems.isEmpty { reasoningItems = finished.reasoningItems }
                    usage = finished.usage
                    isTruncated = finished.isTruncated
                }
                if type == "response.incomplete" { isTruncated = true }
                let usageObject: [String: JSONValue]?
                if case .object(let eventUsage)? = event["usage"] {
                    usageObject = eventUsage
                } else if case .object(let response)? = event["response"],
                          case .object(let nested)? = response["usage"]
                {
                    usageObject = nested
                } else {
                    usageObject = nil
                }
                if let usageObject {
                    usage = ParsedUsage(
                        inputTokens: Self.usageNumber(
                            usageObject,
                            keys: ["input_tokens", "prompt_tokens", "inputTokens"]
                        ),
                        outputTokens: Self.usageNumber(
                            usageObject,
                            keys: ["output_tokens", "completion_tokens", "outputTokens"]
                        )
                    )
                }
                if case .string(let status)? = event["status"], status != "completed" {
                    isTruncated = true
                }
                if case .object(let incomplete)? = event["incomplete_details"],
                   case .string(let reason)? = incomplete["reason"]
                {
                    isTruncated = reason == "max_output_tokens"
                        || reason == "length"
                        || reason == "incomplete"
                }
            case "response.failed":
                let message: String
                if case .object(let error)? = event["error"],
                   case .string(let errorMessage)? = error["message"]
                {
                    message = errorMessage
                } else {
                    message = "The online model stream failed."
                }
                throw AgentModelProviderFailure(try Self.streamFailure(message))
            default:
                break
            }
        }
        return ParsedResponse(
            text: text,
            reasoning: reasoning,
            calls: calls,
            usage: usage,
            hasReasoning: hasReasoningOutput,
            isTruncated: isTruncated,
            reasoningItems: reasoningItems
        )
    }

    private static func consumeChatCompletionsEventStream(
        _ bytes: AccountedResponseBytes,
        emitter: AgentModelBoundaryEmitter,
        emitReasoning: Bool,
        emit: Bool = true
    ) async throws -> ParsedResponse {
        var reasoning = ""
        var text = ""
        var partialCalls: [Int: (name: String, arguments: String, callID: String?)] = [:]
        var hasReasoningOutput = false
        var isTruncated = false
        var usage = ParsedUsage(inputTokens: 0, outputTokens: 0)

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let value = try? AgentWireDecoder.decode(
                      JSONValue.self,
                      from: Data(payload.utf8),
                      limits: .inlineValue
                  ), case .object(let root) = value
            else { continue }

            if case .object(let error)? = root["error"] {
                let message: String
                if case .string(let value)? = error["message"] { message = value }
                else { message = "The online model stream failed." }
                throw AgentModelProviderFailure(try streamFailure(message))
            }
            if case .object(let usageObject)? = root["usage"] {
                usage = ParsedUsage(
                    inputTokens: usageNumber(
                        usageObject,
                        keys: ["prompt_tokens", "input_tokens", "inputTokens"]
                    ),
                    outputTokens: usageNumber(
                        usageObject,
                        keys: ["completion_tokens", "output_tokens", "outputTokens"]
                    )
                )
            }
            guard case .array(let choices)? = root["choices"] else { continue }
            for choice in choices {
                guard case .object(let choiceObject) = choice else { continue }
                if case .string(let finish)? = choiceObject["finish_reason"],
                   finish == "length" || finish == "insufficient_system_resource"
                {
                    isTruncated = true
                }
                guard case .object(let delta)? = choiceObject["delta"] else { continue }
                if case .string(let value)? = delta["reasoning_content"], !value.isEmpty {
                    hasReasoningOutput = true
                    reasoning += value
                    if emit, emitReasoning {
                        try await emitter.emit(.reasoningDelta(value), responseBytes: 0)
                    }
                }
                if case .string(let value)? = delta["content"], !value.isEmpty {
                    text += value
                    if emit {
                        try await emitter.emit(.answerDelta(value), responseBytes: 0)
                    }
                }
                if case .array(let toolCalls)? = delta["tool_calls"] {
                    for toolCall in toolCalls {
                        guard case .object(let callObject) = toolCall,
                              let rawIndex = unsignedNumber(callObject["index"]),
                              rawIndex <= UInt64(Int.max)
                        else { continue }
                        let index = Int(rawIndex)
                        var call = partialCalls[index] ?? (name: "", arguments: "", callID: nil)
                        if let id = stringValue(callObject["id"]) { call.callID = id }
                        if case .object(let function)? = callObject["function"] {
                            if case .string(let name)? = function["name"], !name.isEmpty {
                                call.name = name
                            }
                            if case .string(let arguments)? = function["arguments"] {
                                call.arguments += arguments
                            }
                        }
                        partialCalls[index] = call
                    }
                }
            }
        }
        let calls = partialCalls.keys.sorted().compactMap { index -> ParsedCall? in
            guard let call = partialCalls[index], !call.name.isEmpty else { return nil }
            return ParsedCall(name: call.name, argumentsJSON: call.arguments, callID: call.callID)
        }
        return ParsedResponse(
            text: text,
            reasoning: reasoning,
            calls: calls,
            usage: usage,
            hasReasoning: hasReasoningOutput,
            isTruncated: isTruncated
        )
    }

    private static func unsignedNumber(_ value: JSONValue?) -> UInt64? {
        switch value {
        case .unsignedInteger(let v): v
        case .integer(let v): v >= 0 ? UInt64(v) : nil
        case .number(let v): v >= 0 ? UInt64(v) : nil
        default: nil
        }
    }

    /// Compatible gateways report usage under OpenAI-chat keys (`prompt_tokens`/`completion_tokens`)
    /// or camelCase; accept any of them so run/UI token statistics are truthful.
    private static func usageNumber(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> UInt64 {
        for key in keys {
            if let value = unsignedNumber(object[key]) {
                return value
            }
        }
        return 0
    }

    private static func isStructured(_ request: AgentModelRequest) -> Bool {
        if case .structured = request.outputRequirement { return true }
        return false
    }

    /// Weak planner models often wrap JSON in ```json fences; the runtime's structured-output
    /// validator requires the raw JSON, so strip a single outer fence before building the action.
    private static func structuredJSONText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.contains("```") == true { lines.removeFirst() }
        if lines.last?.contains("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deduplicatedCalls(_ calls: [ParsedCall]) -> [ParsedCall] {
        var seen = Set<String>()
        return calls.filter { call in
            seen.insert(call.callID.map { "id:" + $0 } ?? "\(call.name)\u{0}\(call.argumentsJSON)").inserted
        }
    }

    private static func streamFailure(_ message: String) throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.stream",
            classification: .transient,
            safeMessage: message,
            retryAdvice: AgentRetryAdvice(
                automaticallyRetryable: true,
                maximumAdditionalAttempts: 1
            ),
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    // MARK: - Pure request/response mapping (unit-tested)

    static func wireDialect(baseURL: String, modelID: String) -> WireDialect {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        // DeepSeek's public OpenAI-format contract is Chat Completions. Its undocumented
        // `/responses` compatibility route currently ignores the thinking toggle, which can spend
        // the whole output budget without an answer. Only select this transport for the official
        // service host; third-party gateways keep their explicitly configured Responses contract.
        if host == "api.deepseek.com" || host.hasSuffix(".deepseek.com") {
            return .deepSeekChatCompletions
        }
        return .responses
    }

    private static func usesDeepSeekThinkingDialect(
        baseURL: String,
        modelID: String
    ) -> Bool {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        return modelID.lowercased().hasPrefix("deepseek-")
            || host == "api.deepseek.com"
            || host.hasSuffix(".deepseek.com")
    }

    static func chatCompletionsRequestBody(
        request: AgentModelRequest,
        reasoningDisabled: Bool? = nil,
        maxOutputTokensOverride: UInt64? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        omitReasoning: Bool = false,
        stream: Bool = false
    ) throws -> Data {
        let parameters = request.generationParameters
        var fields: [String: JSONValue] = [
            "model": .string(request.selection.modelID.rawValue),
            "messages": .array(chatMessagesPayload(request.messages, selection: request.selection)),
            "temperature": .number(parameters.temperature),
            "top_p": .number(parameters.topP),
        ]
        if let maxOutputTokensOverride {
            fields["max_tokens"] = .unsignedInteger(maxOutputTokensOverride)
        } else if parameters.outputBudgetMode != .auto {
            fields["max_tokens"] = .unsignedInteger(parameters.maximumOutputTokens)
        }
        let disabled = reasoningDisabled ?? (parameters.thinkingMode == .disabled)
        if omitReasoning {
            // One compatibility retry may omit the service-specific directive.
        } else if disabled {
            fields["thinking"] = .object(["type": .string("disabled")])
        } else if parameters.thinkingMode == .enabled, reasoningEffort != nil {
            fields["reasoning_effort"] = .string("high")
        }
        let tools = chatCompletionsToolsPayload(request.advertisedTools)
        if !tools.isEmpty { fields["tools"] = .array(tools) }
        if isStructured(request) {
            // DeepSeek's documented Chat Completions contract supports JSON mode, but not the
            // Responses API's `text.format` schema shape. The runtime still validates the exact
            // frozen JSON Schema after generation; this wire hint prevents prose/fence wrappers
            // from consuming the sole bounded repair pass before that authoritative validation.
            fields["response_format"] = .object(["type": .string("json_object")])
        }
        if stream {
            fields["stream"] = .bool(true)
            fields["stream_options"] = .object(["include_usage": .bool(true)])
        }
        return try JSONValue.object(fields).canonicalData()
    }

    private static func chatMessagesPayload(
        _ messages: [AgentModelMessage], selection: AgentModelSelection
    ) -> [JSONValue] {
        var result: [JSONValue] = []
        for message in messages {
            if let native = message.nativeToolCall, native.matches(selection) {
                var assistant: [String: JSONValue] = [
                    "role": .string("assistant"), "content": .null,
                    "tool_calls": .array([.object([
                        "id": .string(native.callID), "type": .string("function"),
                        "function": .object(["name": .string(native.name), "arguments": .string(native.arguments.string)]),
                    ])]),
                ]
                if let reasoning = native.reasoningText { assistant["reasoning_content"] = .string(reasoning) }
                result.append(.object(assistant))
                result.append(.object(["role": .string("tool"), "tool_call_id": .string(native.callID), "content": .string(message.content)]))
            } else {
                result.append(.object([
                    "role": .string(message.role == .tool ? "user" : message.role.rawValue),
                    "content": .string(message.role == .tool ? "Tool result: " + message.content : message.content),
                ]))
            }
        }
        return result
    }

    private static func chatCompletionsToolsPayload(
        _ descriptors: [AgentToolDescriptor]
    ) -> [JSONValue] {
        ModelToolNames.bindings(for: descriptors).map { binding in
            let descriptor = binding.descriptor
            return .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(binding.wireName),
                    "description": .string(descriptor.summary),
                    "parameters": descriptor.inputSchema.root,
                ]),
            ])
        }
    }

    static func requestBody(
        request: AgentModelRequest,
        baseURL: String,
        reasoningDisabled: Bool? = nil,
        maxOutputTokensOverride: UInt64? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        omitReasoning: Bool = false,
        stream: Bool = false
    ) throws -> Data {
        let parameters = request.generationParameters
        let (instructions, input) = try messagesPayload(request.messages, selection: request.selection)
        var fields: [String: JSONValue] = [
            "model": .string(request.selection.modelID.rawValue),
            "input": .array(input),
            "temperature": .number(parameters.temperature),
            "top_p": .number(parameters.topP),
        ]
        if URL(string: baseURL)?.host?.lowercased() == "api.openai.com" {
            fields["store"] = .bool(false)
            fields["include"] = .array([.string("reasoning.encrypted_content")])
        }
        if let maxOutputTokensOverride {
            // Explicit retry/fallback budgets always go on the wire.
            fields["max_output_tokens"] = .unsignedInteger(maxOutputTokensOverride)
        } else if parameters.outputBudgetMode != .auto {
            // Auto mode omits the limit so the service uses its own model default/maximum.
            fields["max_output_tokens"] = .unsignedInteger(parameters.maximumOutputTokens)
        }
        // The Responses API carries the system prompt as a top-level `instructions` string, not as an
        // input item; some gateways reject `messages` outright on /responses.
        if !instructions.isEmpty {
            fields["instructions"] = .string(instructions)
        }
        // Reasoning-first services default to a long reasoning phase that can consume the whole
        // output budget before any answer token. OpenAI Responses-compatible gateways use the
        // `reasoning` object, while DeepSeek V4's OpenAI-format contract uses
        // `thinking: { type: enabled|disabled }` plus a top-level `reasoning_effort`. Select the
        // dialect from both service host and model id so DeepSeek behind a compatible proxy still
        // receives its documented switch. `.automatic` stays neutral.
        let disableReasoning = reasoningDisabled ?? (parameters.thinkingMode == .disabled)
        let usesDeepSeekThinkingDialect = usesDeepSeekThinkingDialect(
            baseURL: baseURL,
            modelID: request.selection.modelID.rawValue
        )
        if omitReasoning {
            // Gateway rejected its reasoning/thinking field: leave the directive absent entirely.
        } else if disableReasoning {
            if usesDeepSeekThinkingDialect {
                fields["thinking"] = .object(["type": .string("disabled")])
            } else {
                fields["reasoning"] = .object(["enabled": .bool(false)])
            }
        } else if let reasoningEffort {
            if usesDeepSeekThinkingDialect {
                // DeepSeek currently accepts high/max. Its compatibility contract maps lower
                // effort names to high, so emit the canonical value rather than relying on a
                // gateway-specific coercion.
                fields["reasoning_effort"] = .string("high")
            } else {
                fields["reasoning"] = .object(["effort": .string(reasoningEffort.rawValue)])
            }
        }
        let tools = try toolsPayload(request.advertisedTools)
        // Some compatible gateways reject an empty array; omitting it is equivalent for every client
        // that supports the Responses API shape.
        if !tools.isEmpty {
            fields["tools"] = .array(tools)
        }
        if stream {
            fields["stream"] = .bool(true)
        }
        let body: JSONValue = .object(fields)
        return try body.canonicalData()
    }

    /// Replays native tool identities and provider reasoning state from the durable context.
    /// Pre-migration records have no call id and retain their explicit untrusted-text fallback.
    static func messagesPayload(
        _ messages: [AgentModelMessage], selection: AgentModelSelection? = nil
    ) throws -> (instructions: String, input: [JSONValue]) {
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        var input: [JSONValue] = []
        var seenReasoning = Set<StableDigest>()
        for message in messages where message.role != .system {
            if let native = message.nativeToolCall, selection.map(native.matches) ?? true {
                for item in native.reasoningItems {
                    let digest = try CanonicalJSON(item).fingerprint
                    if seenReasoning.insert(digest).inserted { input.append(item) }
                }
                input.append(native.functionCallItem)
                input.append(.object(["type": .string("function_call_output"),
                                      "call_id": .string(native.callID), "output": .string(message.content)]))
            } else {
                let role = message.role == .tool ? "user" : message.role.rawValue
                let content = message.role == .tool ? "Tool result: " + message.content : message.content
                input.append(.object([
                    "role": .string(role),
                    "content": .array([.object([
                        "type": .string(role == "assistant" ? "output_text" : "input_text"), "text": .string(content),
                    ])]),
                ]))
            }
        }
        return (instructions, input)
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        return text
    }

    static func toolsPayload(_ descriptors: [AgentToolDescriptor]) throws -> [JSONValue] {
        ModelToolNames.bindings(for: descriptors).map { binding in
            let descriptor = binding.descriptor
            let schema = descriptor.inputSchema.root
            return .object([
                "type": .string("function"),
                // Responses API tool items are FLAT: name/description/parameters sit next to type.
                // The Chat Completions nesting ({type, function:{...}}) is rejected by strict
                // Responses-compatible gateways with "tools[0]: missing field name".
                "name": .string(binding.wireName),
                "description": .string(descriptor.summary),
                "parameters": schema,
            ])
        }
    }

    struct ParsedUsage: Sendable, Equatable {
        let inputTokens: UInt64
        let outputTokens: UInt64
    }

    struct ParsedCall: Sendable, Equatable {
        let name: String
        let argumentsJSON: String
        var callID: String? = nil
    }

    struct ParsedResponse: Sendable, Equatable {
        let text: String
        let reasoning: String
        let calls: [ParsedCall]
        let usage: ParsedUsage
        /// True when the service emitted a reasoning item but no answer (budget consumed by thinking).
        let hasReasoning: Bool
        /// True when the service reported an incomplete/truncated completion (max_output_tokens hit).
        let isTruncated: Bool
        var reasoningItems: [JSONValue] = []
    }

    static func parseResponse(_ data: Data) throws -> ParsedResponse {
        let value = try AgentWireDecoder.decode(JSONValue.self, from: data, limits: .inlineValue)
        func number(_ path: [String]) -> UInt64? {
            var current = value
            for key in path {
                guard case .object(let object) = current, let next = object[key] else { return nil }
                current = next
            }
            switch current {
            case .unsignedInteger(let v): return v
            case .integer(let v): return v >= 0 ? UInt64(v) : nil
            case .number(let v): return v >= 0 ? UInt64(v) : nil
            default: return nil
            }
        }
        var text = ""
        var reasoning = ""
        var calls: [ParsedCall] = []
        var reasoningItems: [JSONValue] = []
        var hasReasoning = false
        var isTruncated = false
        if case .object(let root) = value,
           case .array(let output)? = root["output"]
        {
            for item in output {
                guard case .object(let object) = item,
                      case .string(let type)? = object["type"]
                else { continue }
                if type == "reasoning" {
                    reasoningItems.append(item)
                    hasReasoning = true
                    if case .array(let content)? = object["content"] {
                        for part in content {
                            guard case .object(let partObject) = part,
                                  partObject["type"] == .string("reasoning_text"),
                                  case .string(let partText)? = partObject["text"]
                            else { continue }
                            reasoning += partText
                        }
                    }
                } else if type == "message" {
                    if case .array(let content)? = object["content"] {
                        for part in content {
                            guard case .object(let partObject) = part,
                                  case .string(let partType)? = partObject["type"],
                                  partType == "output_text",
                                  case .string(let partText)? = partObject["text"]
                            else { continue }
                            text += partText
                        }
                    }
                } else if type == "function_call" {
                    guard case .string(let name)? = object["name"],
                          case .string(let arguments)? = object["arguments"]
                    else { continue }
                    calls.append(ParsedCall(name: name, argumentsJSON: arguments, callID: stringValue(object["call_id"])))
                }
            }
        }
        if case .object(let root) = value {
            if case .string(let status)? = root["status"], status != "completed" {
                isTruncated = true
            }
            if case .object(let incomplete)? = root["incomplete_details"],
               case .string(let reason)? = incomplete["reason"]
            {
                isTruncated = reason == "max_output_tokens"
                    || reason == "length"
                    || reason == "incomplete"
            }
        }
        let usage: ParsedUsage
        if case .object(let root) = value,
           case .object(let usageObject)? = root["usage"]
        {
            usage = ParsedUsage(
                inputTokens: Self.usageNumber(
                    usageObject,
                    keys: ["input_tokens", "prompt_tokens", "inputTokens"]
                ),
                outputTokens: Self.usageNumber(
                    usageObject,
                    keys: ["output_tokens", "completion_tokens", "outputTokens"]
                )
            )
        } else {
            usage = ParsedUsage(inputTokens: 0, outputTokens: 0)
        }
        return ParsedResponse(
            text: text,
            reasoning: reasoning,
            calls: calls,
            usage: usage,
            hasReasoning: hasReasoning,
            isTruncated: isTruncated,
            reasoningItems: reasoningItems
        )
    }

    static func parseChatCompletion(_ data: Data) throws -> ParsedResponse {
        let value = try AgentWireDecoder.decode(JSONValue.self, from: data, limits: .inlineValue)
        guard case .object(let root) = value else {
            return ParsedResponse(
                text: "",
                reasoning: "",
                calls: [],
                usage: ParsedUsage(inputTokens: 0, outputTokens: 0),
                hasReasoning: false,
                isTruncated: false
            )
        }
        var text = ""
        var reasoning = ""
        var calls: [ParsedCall] = []
        var isTruncated = false
        if case .array(let choices)? = root["choices"] {
            for choice in choices {
                guard case .object(let choiceObject) = choice else { continue }
                if case .string(let finish)? = choiceObject["finish_reason"],
                   finish == "length" || finish == "insufficient_system_resource"
                {
                    isTruncated = true
                }
                guard case .object(let message)? = choiceObject["message"] else { continue }
                if case .string(let content)? = message["content"] { text += content }
                if case .string(let content)? = message["reasoning_content"] {
                    reasoning += content
                }
                if case .array(let toolCalls)? = message["tool_calls"] {
                    for toolCall in toolCalls {
                        guard case .object(let callObject) = toolCall,
                              case .object(let function)? = callObject["function"],
                              case .string(let name)? = function["name"],
                              case .string(let arguments)? = function["arguments"]
                        else { continue }
                        calls.append(ParsedCall(name: name, argumentsJSON: arguments, callID: stringValue(callObject["id"])))
                    }
                }
            }
        }
        let usage: ParsedUsage
        if case .object(let usageObject)? = root["usage"] {
            usage = ParsedUsage(
                inputTokens: usageNumber(
                    usageObject,
                    keys: ["prompt_tokens", "input_tokens", "inputTokens"]
                ),
                outputTokens: usageNumber(
                    usageObject,
                    keys: ["completion_tokens", "output_tokens", "outputTokens"]
                )
            )
        } else {
            usage = ParsedUsage(inputTokens: 0, outputTokens: 0)
        }
        return ParsedResponse(
            text: text,
            reasoning: reasoning,
            calls: calls,
            usage: usage,
            hasReasoning: !reasoning.isEmpty,
            isTruncated: isTruncated
        )
    }

    private static func normalize(
        name: String,
        argumentsJSON: String,
        index: Int,
        request: AgentModelRequest,
        callID: String?,
        reasoningItems: [JSONValue],
        reasoningText: String?
    ) throws -> ProposedToolCall {
        guard let descriptor = ModelToolNames.bindings(for: request.advertisedTools).first(where: {
            $0.wireName == name
        })?.descriptor, let data = argumentsJSON.data(using: .utf8) else {
            throw AgentModelProviderFailure(try Self.toolFailure("The online model called unknown tool \(name)."))
        }
        let value = try AgentWireDecoder.decode(JSONValue.self, from: data, limits: .inlineValue)
        guard try descriptor.inputSchema.validates(instance: value) else {
            throw AgentModelProviderFailure(
                try Self.toolFailure("The online model called \(name) with invalid arguments.")
            )
        }
        let arguments = try CanonicalJSON(value)
        let digest = StableDigest.fingerprint(
            domain: "responses-tool-invocation.v1",
            components: [
                Data(request.requestID.description.utf8),
                Data(request.stepID.description.utf8),
                Data(String(index).utf8),
                Data(descriptor.id.description.utf8),
                arguments.data,
            ]
        ).rawValue
        let part1 = String(digest.prefix(8))
        let part2 = String(digest.dropFirst(8).prefix(4))
        let part3 = String(digest.dropFirst(12).prefix(4))
        let part4 = String(digest.dropFirst(16).prefix(4))
        let part5 = String(digest.dropFirst(20).prefix(12))
        let uuid = UUID(uuidString: "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)")!
        return ProposedToolCall(
            invocationID: ToolInvocationID(rawValue: uuid),
            toolID: descriptor.id.logicalID,
            arguments: arguments,
            nativeContext: try NativeToolCallContext(
                selectionDigest: NativeToolCallContext.digest(for: request.selection),
                callID: callID ?? "call_" + uuid.uuidString.lowercased(), name: name,
                arguments: arguments, reasoningItems: reasoningItems, reasoningText: reasoningText
            )
        )
    }

    static func httpFailure(status: Int, body: String? = nil) throws -> AgentFailure {
        var message: String
        if status == 401 || status == 403 {
            message = "The online model service rejected the API key (HTTP \(status)). "
                + "Check the API key AND the service's base URL in Settings → Online models, "
                + "then re-save."
        } else {
            message = "The online model service returned HTTP \(status)."
        }
        // Gateway error bodies are the fastest path to "why": include a bounded, cleaned excerpt so
        // the user (and the E2E diagnostics) can see the service's own reason.
        if let body {
            let cleaned = body
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let excerpt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
            if !excerpt.isEmpty {
                message += " \(excerpt)"
            }
        }
        return try AgentFailure(
            code: "model.online.http",
            classification: .permanent,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    private static func configurationMissingFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.configuration-missing",
            classification: .permanent,
            safeMessage: "The online model service is not configured. Add an API key and model in Settings.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    private static func invalidBaseURLFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.invalid-base-url",
            classification: .permanent,
            safeMessage: "The online model service base URL is invalid.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    private static func emptyFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.empty",
            classification: .permanent,
            safeMessage: "The online model returned no answer text. It may have spent its output "
                + "budget on service-side reasoning; turn thinking off or raise Max tokens and retry.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    private static func structuredOutputFailure() throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.structured-output-invalid",
            classification: .permanent,
            safeMessage: "The online model returned invalid structured output.",
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }

    private static func toolFailure(_ message: String) throws -> AgentFailure {
        try AgentFailure(
            code: "model.online.tool",
            classification: .permanent,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
    }
}
