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

/// An `AgentModelProvider` that calls an OpenAI-compatible `/responses` endpoint. The whole request is
/// one prepared, authorized external operation (data egress, spec §15.1): every generation runs inside
/// the model boundary with exact destination, data category, and response accounting.
public final class ResponsesAPIModelProvider: AgentModelProvider, @unchecked Sendable {
    public static let providerID = "openai.responses"
    /// Advertising ceiling for OpenAI-compatible services without per-model metadata (matches the
    /// context window the app already advertises for online runs).
    public static let maximumContextTokens: UInt64 = 200_000

    public let descriptor: AgentModelProviderDescriptor
    /// Resolved on every generation so settings/Keychain changes apply without an app restart. The
    /// provider never retains the key in memory beyond one request; returning nil fails closed.
    private let configurationProvider: @Sendable () -> ResponsesAPIConfiguration?
    private let session: URLSession
    /// Per-run attempt timeout derived from the prepared plan (the run budget), so the URLSession
    /// deadline is never a second hardcoded guess. Keyed by request id; cleared after each generate.
    private let timeouts = ResponsesAPITimeoutStore()

    public convenience init(
        configuration: ResponsesAPIConfiguration,
        session: URLSession = .shared,
        capabilityVersion: SemanticVersion = SemanticVersion("1.0.0")!
    ) throws {
        try self.init(
            configurationProvider: { configuration },
            session: session,
            capabilityVersion: capabilityVersion
        )
    }

    public init(
        configurationProvider: @escaping @Sendable () -> ResponsesAPIConfiguration?,
        session: URLSession = .shared,
        capabilityVersion: SemanticVersion = SemanticVersion("1.0.0")!
    ) throws {
        self.configurationProvider = configurationProvider
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
        let outputCeiling = configurationProvider()?.maximumOutputTokens ?? Self.maximumContextTokens
        return try AgentModelCapabilities(
            maximumContextTokens: Self.maximumContextTokens,
            maximumOutputTokens: outputCeiling,
            features: AgentModelCapabilitySet([
                .nativeToolCalling, .multipleToolCalls, .reasoning,
            ]),
            toolCallingMode: .nativeStructured,
            cancellationGranularity: .token,
            resourceConstraints: ModelResourceConstraints(
                maximumConcurrentAttempts: 1,
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
        guard let configuration = configurationProvider() else {
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
        guard let configuration = configurationProvider() else {
            throw AgentModelProviderFailure(try Self.configurationMissingFailure())
        }
        guard let baseURL = URL(string: configuration.baseURL),
              let scheme = baseURL.scheme?.lowercased(),
              scheme == "https",
              baseURL.host?.isEmpty == false
        else {
            throw AgentModelProviderFailure(try Self.invalidBaseURLFailure())
        }
        let timeout = await timeouts.take(for: request.requestID) ?? 60
        func makeRequest() -> URLRequest {
            var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            return urlRequest
        }
        let emitReasoning = request.generationParameters.thinkingMode != .disabled
        func attempt(
            _ body: Data,
            allowEffortFallback: Bool,
            allowAutoFallback: Bool,
            streamEmission: Bool = true
        ) async throws -> (parsed: ParsedResponse, streamed: Bool, data: Data) {
            var urlRequest = makeRequest()
            urlRequest.httpBody = body
            let (bytes, response) = try await session.bytes(for: urlRequest)
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
                       errorText.localizedCaseInsensitiveContains("reasoning")
                    {
                        let fallbackBody = try Self.requestBody(
                            request: request,
                            baseURL: configuration.baseURL,
                            reasoningEffort: configuration.reasoningEffort,
                            omitReasoning: true,
                            stream: true
                        )
                        if fallbackBody != body {
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
                        let fallbackBody = try Self.requestBody(
                            request: request,
                            baseURL: configuration.baseURL,
                            maxOutputTokensOverride: parameters.maximumOutputTokens,
                            reasoningEffort: configuration.reasoningEffort,
                            stream: true
                        )
                        if fallbackBody != body {
                            return try await attempt(
                                fallbackBody,
                                allowEffortFallback: false,
                                allowAutoFallback: false,
                                streamEmission: streamEmission
                            )
                        }
                    }
                }
                throw AgentModelProviderFailure(try Self.httpFailure(status: http?.statusCode ?? -1))
            }
            let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "")
                .lowercased()
            if contentType.contains("text/event-stream") {
                let parsed = try await Self.consumeEventStream(
                    bytes,
                    emitter: emitter,
                    emitReasoning: emitReasoning,
                    emit: streamEmission
                )
                return (parsed, true, Data())
            }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return (try Self.parseResponse(data), false, data)
        }

        let started = ContinuousClock.now
        let firstBody = try Self.requestBody(
            request: request,
            baseURL: configuration.baseURL,
            reasoningEffort: configuration.reasoningEffort,
            stream: true
        )
        var (parsed, streamed, data) = try await attempt(
            firstBody,
            allowEffortFallback: true,
            allowAutoFallback: parameters.outputBudgetMode == .auto
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
            let retryBody = try Self.requestBody(
                request: request,
                baseURL: configuration.baseURL,
                maxOutputTokensOverride: bumped,
                reasoningEffort: configuration.reasoningEffort,
                stream: true
            )
            let (retried, retriedStreamed, retriedData) = try await attempt(
                retryBody,
                allowEffortFallback: false,
                allowAutoFallback: false,
                streamEmission: !streamed
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
                    data = retriedData
                }
            } else if !retried.isTruncated || retried.text.utf8.count > parsed.text.utf8.count {
                parsed = retried
                streamed = retriedStreamed
                data = retriedData
            }
        }

        if !streamed {
            // Non-streaming fallback keeps the reasoning-only retry (streamed reasoning-only is
            // handled below; both stay inside the same authorization boundary).
            if parsed.text.isEmpty, parsed.calls.isEmpty, parsed.hasReasoning, emitReasoning {
                let retryBody = try Self.requestBody(
                    request: request,
                    baseURL: configuration.baseURL,
                    reasoningDisabled: true,
                    stream: true
                )
                let (retried, retriedStreamed, retriedData) = try await attempt(
                    retryBody,
                    allowEffortFallback: false,
                    allowAutoFallback: false
                )
                parsed = retried
                streamed = retriedStreamed
                data = retriedData
            }
        } else if parsed.text.isEmpty, parsed.calls.isEmpty, parsed.hasReasoning, emitReasoning {
            // Streamed reasoning-only: reasoning was already shown live; retry once without reasoning
            // so the ANSWER streams too (no duplication of answer text).
            let retryBody = try Self.requestBody(
                request: request,
                baseURL: configuration.baseURL,
                reasoningDisabled: true,
                stream: true
            )
            let (retried, retriedStreamed, retriedData) = try await attempt(
                retryBody,
                allowEffortFallback: false,
                allowAutoFallback: false
            )
            parsed = retried
            streamed = retriedStreamed
            data = retriedData
        }
        try Task.checkCancellation()
        let elapsedMilliseconds = UInt64(
            (started.duration(to: .now) / .milliseconds(1))
        )
        let usage = try AgentModelUsage(
            inputTokens: parsed.usage.inputTokens,
            outputTokens: parsed.usage.outputTokens,
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
            if !parsed.text.isEmpty {
                try await emitter.emit(.answerDelta(parsed.text), responseBytes: 0)
            }
        }

        let action: AgentAction
        if parsed.calls.isEmpty {
            guard !parsed.text.isEmpty else {
                throw AgentModelProviderFailure(try Self.emptyFailure())
            }
            action = .finalAnswer(try AgentAnswer(text: parsed.text))
        } else {
            let calls = try parsed.calls.enumerated().map { index, call in
                try Self.normalize(
                    name: call.name,
                    argumentsJSON: call.argumentsJSON,
                    index: index,
                    request: request
                )
            }
            action = .callTools(calls)
        }
        try await emitter.emit(
            .completed(try AgentModelCompletion(action: action, usage: usage)),
            responseBytes: UInt64(data.count)
        )
        return AgentModelBoundaryCompletion(
            outcome: .completed(try AgentModelCompletion(action: action, usage: usage)),
            responseDigest: StableDigest.sha256(data)
        )
    }

    // MARK: - Event-stream consumption

    private static func consumeEventStream(
        _ bytes: URLSession.AsyncBytes,
        emitter: AgentModelBoundaryEmitter,
        emitReasoning: Bool,
        emit: Bool = true
    ) async throws -> ParsedResponse {
        var reasoning = ""
        var text = ""
        var calls: [ParsedCall] = []
        var callName: String?
        var callArguments = ""
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

            switch type {
            case "response.output_item.added":
                if case .object(let item)? = event["item"] {
                    if item["type"] == .string("function_call"),
                       case .string(let name)? = item["name"]
                    {
                        callName = name
                        callArguments = ""
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
                    callArguments += delta
                }
            case "response.output_item.done":
                if case .object(let item)? = event["item"],
                   item["type"] == .string("function_call")
                {
                    let name: String
                    if case .string(let eventName)? = item["name"] {
                        name = eventName
                    } else {
                        name = callName ?? ""
                    }
                    if !name.isEmpty {
                        calls.append(ParsedCall(name: name, argumentsJSON: callArguments))
                    }
                    callName = nil
                    callArguments = ""
                }
            case "response.completed":
                if case .object(let usageObject)? = event["usage"] {
                    usage = ParsedUsage(
                        inputTokens: Self.unsignedNumber(usageObject["input_tokens"]) ?? 0,
                        outputTokens: Self.unsignedNumber(usageObject["output_tokens"]) ?? 0
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
        let (instructions, input) = try messagesPayload(request.messages)
        var fields: [String: JSONValue] = [
            "model": .string(request.selection.modelID.rawValue),
            "input": .array(input),
            "temperature": .number(parameters.temperature),
            "top_p": .number(parameters.topP),
        ]
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
        // Reasoning-first services (e.g. DeepSeek v4) default to a long reasoning phase that can
        // consume the whole output budget before any answer token. The app maps its per-service
        // "Allow reasoning" toggle to `.enabled`/`.disabled`: disabled asks the service to skip
        // reasoning (fast, deterministic), enabled omits the field so the service keeps its default.
        // `.automatic` (not produced by the app today) stays neutral.
        let disableReasoning = reasoningDisabled ?? (parameters.thinkingMode == .disabled)
        if omitReasoning {
            // Gateway rejected the reasoning field: leave it absent entirely.
        } else if disableReasoning {
            fields["reasoning"] = .object(["enabled": .bool(false)])
        } else if let reasoningEffort {
            fields["reasoning"] = .object(["effort": .string(reasoningEffort.rawValue)])
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

    /// Splits the compiled conversation into the Responses API wire shape: a top-level `instructions`
    /// string for system content and `input` items for everything else. Tool results are relayed as
    /// user-role text because the compiled message does not carry the native `call_id`.
    static func messagesPayload(_ messages: [AgentModelMessage]) throws -> (instructions: String, input: [JSONValue]) {
        let instructions = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n")
        let input = messages
            .filter { $0.role != .system }
            .map { message -> JSONValue in
                let role: String = switch message.role {
                case .system: "system"   // unreachable: filtered above, kept exhaustive
                case .user: "user"
                case .assistant: "assistant"
                case .tool: "user"       // native tool_call_id is not carried by the compiled message;
                                         // relay as a user-role result so the loop still sees it.
                }
                let content = message.role == .tool
                    ? "Tool result: \(message.content)"
                    : message.content
                let partType = role == "assistant" ? "output_text" : "input_text"
                return .object([
                    "role": .string(role),
                    "content": .array([
                        .object([
                            "type": .string(partType),
                            "text": .string(content),
                        ]),
                    ]),
                ])
            }
        return (instructions, input)
    }

    static func toolsPayload(_ descriptors: [AgentToolDescriptor]) throws -> [JSONValue] {
        descriptors.map { descriptor in
            let schema = descriptor.inputSchema.root
            return .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(descriptor.id.logicalID.name),
                    "description": .string(descriptor.summary),
                    "parameters": schema,
                ]),
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
                    calls.append(ParsedCall(name: name, argumentsJSON: arguments))
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
        let usage = ParsedUsage(
            inputTokens: number(["usage", "input_tokens"]) ?? 0,
            outputTokens: number(["usage", "output_tokens"]) ?? 0
        )
        return ParsedResponse(
            text: text,
            reasoning: reasoning,
            calls: calls,
            usage: usage,
            hasReasoning: hasReasoning,
            isTruncated: isTruncated
        )
    }

    private static func normalize(
        name: String,
        argumentsJSON: String,
        index: Int,
        request: AgentModelRequest
    ) throws -> ProposedToolCall {
        guard let descriptor = request.advertisedTools.first(where: {
            $0.id.logicalID.name == name
        }), let data = argumentsJSON.data(using: .utf8) else {
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
            arguments: arguments
        )
    }

    static func httpFailure(status: Int) throws -> AgentFailure {
        let message: String
        if status == 401 || status == 403 {
            message = "The online model service rejected the API key (HTTP \(status)). "
                + "Check the API key AND the service's base URL in Settings → Online models, "
                + "then re-save."
        } else {
            message = "The online model service returned HTTP \(status)."
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
