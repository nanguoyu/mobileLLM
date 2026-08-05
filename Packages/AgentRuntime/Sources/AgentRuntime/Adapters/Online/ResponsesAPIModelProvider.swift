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

    public static let defaultServiceID = "responses-api-key"

    public init(
        serviceID: String = ResponsesAPIConfiguration.defaultServiceID,
        baseURL: String,
        apiKey: String
    ) {
        self.serviceID = serviceID
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// An `AgentModelProvider` that calls an OpenAI-compatible `/responses` endpoint. The whole request is
/// one prepared, authorized external operation (data egress, spec §15.1): every generation runs inside
/// the model boundary with exact destination, data category, and response accounting.
public final class ResponsesAPIModelProvider: AgentModelProvider, @unchecked Sendable {
    public static let providerID = "openai.responses"

    public let descriptor: AgentModelProviderDescriptor
    /// Resolved on every generation so settings/Keychain changes apply without an app restart. The
    /// provider never retains the key in memory beyond one request; returning nil fails closed.
    private let configurationProvider: @Sendable () -> ResponsesAPIConfiguration?
    private let session: URLSession

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
        try AgentModelCapabilities(
            maximumContextTokens: 200_000,
            maximumOutputTokens: 16_384,
            features: AgentModelCapabilitySet([.nativeToolCalling, .multipleToolCalls]),
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
        let body = try Self.requestBody(
            request: request,
            baseURL: configuration.baseURL
        )
        var urlRequest = URLRequest(url: baseURL.appending(path: "responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw AgentModelProviderFailure(try Self.httpFailure(status: http?.statusCode ?? -1))
        }
        let parsed = try Self.parseResponse(data)
        let usage = try AgentModelUsage(
            inputTokens: parsed.usage.inputTokens,
            outputTokens: parsed.usage.outputTokens,
            activeMilliseconds: 0,
            peakMemoryBytes: 0
        )
        try await emitter.emit(.usage(usage), responseBytes: 0)

        if !parsed.text.isEmpty {
            try await emitter.emit(.answerDelta(parsed.text), responseBytes: 0)
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

    // MARK: - Pure request/response mapping (unit-tested)

    static func requestBody(request: AgentModelRequest, baseURL: String) throws -> Data {
        let parameters = request.generationParameters
        let (instructions, input) = try messagesPayload(request.messages)
        var fields: [String: JSONValue] = [
            "model": .string(request.selection.modelID.rawValue),
            "input": .array(input),
            "temperature": .number(parameters.temperature),
            "top_p": .number(parameters.topP),
            "max_output_tokens": .unsignedInteger(parameters.maximumOutputTokens),
        ]
        // The Responses API carries the system prompt as a top-level `instructions` string, not as an
        // input item; some gateways reject `messages` outright on /responses.
        if !instructions.isEmpty {
            fields["instructions"] = .string(instructions)
        }
        // Some gateways (e.g. reasoning-first small models) default to a long reasoning phase that can
        // consume the whole output budget before any answer token. When the user asked for no thinking,
        // ask the service to disable reasoning explicitly; `.automatic`/`.enabled` keep the gateway
        // default and stay compatible with services that reject unknown reasoning fields.
        if parameters.thinkingMode == .disabled {
            fields["reasoning"] = .object(["enabled": .bool(false)])
        }
        let tools = try toolsPayload(request.advertisedTools)
        // Some compatible gateways reject an empty array; omitting it is equivalent for every client
        // that supports the Responses API shape.
        if !tools.isEmpty {
            fields["tools"] = .array(tools)
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
        let calls: [ParsedCall]
        let usage: ParsedUsage
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
        var calls: [ParsedCall] = []
        if case .object(let root) = value,
           case .array(let output)? = root["output"]
        {
            for item in output {
                guard case .object(let object) = item,
                      case .string(let type)? = object["type"]
                else { continue }
                if type == "message" {
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
        let usage = ParsedUsage(
            inputTokens: number(["usage", "input_tokens"]) ?? 0,
            outputTokens: number(["usage", "output_tokens"]) ?? 0
        )
        return ParsedResponse(text: text, calls: calls, usage: usage)
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
            safeMessage: "The online model returned no output.",
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
