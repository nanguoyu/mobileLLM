// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime

/// URLProtocol stub so the online provider's real `generate` path (URLSession → parse → emitter) is
/// covered without network access.
final class MockResponsesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            Self.capturedRequest = request
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands protocol handlers the body as a stream; read it back for assertions.
    static func requestBodyString(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class ResponsesAPIModelProviderTests: XCTestCase {

    func testWireAliasesCannotCollideWithARealToolNameAndExcludeDots() throws {
        func descriptor(_ name: String) throws -> AgentToolDescriptor {
            try MCPToolV2Adapter.descriptor(spec: MCPToolSpec(name: name, description: "Lookup", inputSchemaJSON: "{\"type\":\"object\"}"),
                                           serverStableID: UUID(), trustRevision: "test")
        }
        let dotted = try descriptor("lookup.v2")
        let reserved = try XCTUnwrap(ModelToolNames.bindings(for: [dotted]).first?.wireName)
        let spoof = try descriptor(reserved)
        let names = ModelToolNames.bindings(for: [dotted, spoof]).map(\.wireName)
        XCTAssertEqual(Set(names).count, 2)
        XCTAssertFalse(names.contains { $0.contains(".") })
        XCTAssertEqual(names[1], reserved)
    }


    func testNativeToolResultsReplayCallIdentityAndReasoningAfterSerialization() throws {
        let fixture = try ModelFixture(location: .remote, providerID: ResponsesAPIModelProvider.providerID)
        let reasoning: JSONValue = .object(["type": .string("reasoning"), "id": .string("rs_1"),
                                            "summary": .array([]), "encrypted_content": .string("opaque")])
        let native = try NativeToolCallContext(
            selectionDigest: NativeToolCallContext.digest(for: fixture.request.selection),
            callID: "call_123", name: "lookup", arguments: CanonicalJSON(.object([:])),
            reasoningItems: [reasoning], reasoningText: "provider reasoning"
        )
        let message = try AgentModelMessage(role: .tool, content: "verified result", isUntrustedData: true,
                                            nativeToolCall: native)
        let restored = try JSONDecoder().decode(AgentModelMessage.self, from: JSONEncoder().encode(message))
        let wire = try ResponsesAPIModelProvider.messagesPayload([restored], selection: fixture.request.selection).input
        XCTAssertEqual(wire, [reasoning, native.functionCallItem, .object([
            "type": .string("function_call_output"), "call_id": .string("call_123"),
            "output": .string("verified result"),
        ])])
        XCTAssertThrowsError(try AgentModelMessage(role: .user, content: "x", isUntrustedData: false, nativeToolCall: native))
        XCTAssertThrowsError(try NativeToolCallContext(selectionDigest: native.selectionDigest, callID: "c", name: "lookup",
                                                       arguments: native.arguments, reasoningItems: [.object(["type": .string("message")])]))
    }

    func testNativeIdentitySeparatesRepeatedCallsWithEqualArguments() {
        let calls = [
            ResponsesAPIModelProvider.ParsedCall(name: "lookup", argumentsJSON: "{}", callID: "a"),
            ResponsesAPIModelProvider.ParsedCall(name: "lookup", argumentsJSON: "{}", callID: "b"),
            ResponsesAPIModelProvider.ParsedCall(name: "lookup", argumentsJSON: "{}", callID: "a"),
        ]
        XCTAssertEqual(ResponsesAPIModelProvider.deduplicatedCalls(calls).map(\.callID), ["a", "b"])
    }

    func testOnlineWirePreservesUniqueNamesForTwoMCPServers() throws {
        let spec = MCPToolSpec(name: "lookup", description: "Look up current information", inputSchemaJSON: "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}")
        let descriptors = try [UUID(), UUID()].map { try MCPToolV2Adapter.descriptor(spec: spec, serverStableID: $0, trustRevision: "audit.v1") }
        XCTAssertNotEqual(descriptors[0].id.logicalID, descriptors[1].id.logicalID)
        let payload = try ResponsesAPIModelProvider.toolsPayload(descriptors)
        let names = payload.compactMap { value -> String? in
            guard case .object(let object) = value, case .string(let name)? = object["name"] else { return nil }; return name
        }
        XCTAssertEqual(Set(names).count, descriptors.count, "Distinct registered MCP tools collapse to wire names: \(names)")
    }

    func testMessagesPayloadMapsRolesAndToolFallback() throws {
        let messages = try [
            AgentModelMessage(role: .system, content: "sys", isUntrustedData: false),
            AgentModelMessage(role: .user, content: "hi", isUntrustedData: false),
            AgentModelMessage(role: .assistant, content: "ok", isUntrustedData: false),
            AgentModelMessage(role: .tool, content: "42", isUntrustedData: true),
        ]
        let (instructions, input) = try ResponsesAPIModelProvider.messagesPayload(messages)
        XCTAssertEqual(instructions, "sys")
        XCTAssertEqual(input.count, 3)
        guard case .object(let user) = input[0] else { return XCTFail("user") }
        XCTAssertEqual(user["role"], .string("user"))
        guard case .array(let userContent)? = user["content"],
              case .object(let userPart) = userContent[0],
              userPart["type"] == .string("input_text"),
              userPart["text"] == .string("hi")
        else { return XCTFail("user content item") }
        guard case .object(let assistant) = input[1] else { return XCTFail("assistant") }
        XCTAssertEqual(assistant["role"], .string("assistant"))
        guard case .array(let assistantContent)? = assistant["content"],
              case .object(let assistantPart) = assistantContent[0],
              assistantPart["type"] == .string("output_text")
        else { return XCTFail("assistant content item") }
        guard case .object(let tool) = input[2] else { return XCTFail("tool") }
        XCTAssertEqual(tool["role"], .string("user"))
        guard case .array(let toolContent)? = tool["content"],
              case .object(let toolPart) = toolContent[0],
              toolPart["text"] == .string("Tool result: 42")
        else { return XCTFail("tool result item") }
    }

    func testRequestBodyCarriesModelAndMessages() throws {
        let fixture = try ModelFixture()
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertEqual(object["model"], .string("fixture-model"))
        XCTAssertNil(object["messages"], "the Responses API wire format must not use messages")
        guard case .array(let input)? = object["input"] else { return XCTFail("input") }
        XCTAssertEqual(input.count, 1)
    }

    func testRequestBodyOmitsMaxOutputTokensInAutoMode() throws {
        let fixture = try ModelFixture(outputBudgetMode: .auto)
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertNil(
            object["max_output_tokens"],
            "auto mode omits the wire limit so the service uses its own model default"
        )

        let explicit = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1",
            maxOutputTokensOverride: 8_192
        )
        let explicitValue = try AgentWireDecoder.decode(
            JSONValue.self,
            from: explicit,
            limits: .inlineValue
        )
        guard case .object(let explicitObject) = explicitValue else { return XCTFail("body object") }
        XCTAssertEqual(explicitObject["max_output_tokens"], .integer(8_192))
    }

    func testDeduplicatesIdenticalParsedCalls() throws {
        let duplicate = ResponsesAPIModelProvider.ParsedCall(
            name: "lookup",
            argumentsJSON: #"{"q":"a"}"#
        )
        let different = ResponsesAPIModelProvider.ParsedCall(
            name: "lookup",
            argumentsJSON: #"{"q":"b"}"#
        )
        XCTAssertEqual(
            ResponsesAPIModelProvider.deduplicatedCalls([
                duplicate, duplicate, different,
            ]).count,
            2,
            "identical gateway-duplicated tool calls must collapse to one"
        )
    }

    func testCapabilitiesHonorPerServiceOutputCeiling() async throws {
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: "https://gateway.example/v1",
                    apiKey: "sk-test",
                    maximumOutputTokens: 8_192
                )
            },
            session: URLSession(configuration: .ephemeral)
        )
        let fixture = try ModelFixture(
            location: .remote,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let capabilities = try await provider.capabilities(for: fixture.request.selection)
        XCTAssertEqual(capabilities.maximumOutputTokens, 8_192)
        XCTAssertEqual(capabilities.maximumContextTokens, ResponsesAPIModelProvider.maximumContextTokens)
    }

    func testRequestBodyOmitsToolsWhenNoneAreAdvertised() throws {
        let fixture = try ModelFixture(advertisedTools: [])
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertNil(object["tools"], "empty tool arrays are omitted for gateway compatibility")
    }

    func testRequestBodyDisablesReasoningWhenThinkingIsOff() throws {
        let fixture = try ModelFixture(thinkingMode: .disabled)
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value,
              case .object(let reasoning)? = object["reasoning"],
              reasoning["enabled"] == .bool(false)
        else { return XCTFail("expected reasoning.enabled=false") }
    }

    func testRequestBodyUsesDocumentedDeepSeekThinkingDialect() throws {
        let fixture = try ModelFixture(
            thinkingMode: .disabled,
            modelID: "deepseek-v4-flash"
        )
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://proxy.example/v1",
            reasoningEffort: .medium
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value,
              case .object(let thinking)? = object["thinking"]
        else { return XCTFail("expected DeepSeek thinking object") }
        XCTAssertEqual(thinking["type"], .string("disabled"))
        XCTAssertNil(object["reasoning"])
        XCTAssertNil(object["reasoning_effort"], "effort is irrelevant when thinking is disabled")

        let enabled = try ModelFixture(
            thinkingMode: .enabled,
            modelID: "deepseek-v4-pro"
        )
        let enabledData = try ResponsesAPIModelProvider.requestBody(
            request: enabled.request,
            baseURL: "https://api.deepseek.com/v1",
            reasoningEffort: .medium
        )
        let enabledValue = try AgentWireDecoder.decode(
            JSONValue.self,
            from: enabledData,
            limits: .inlineValue
        )
        guard case .object(let enabledObject) = enabledValue else {
            return XCTFail("expected body object")
        }
        XCTAssertNil(enabledObject["reasoning"])
        XCTAssertNil(enabledObject["thinking"], "enabled mode keeps DeepSeek's default")
        XCTAssertEqual(enabledObject["reasoning_effort"], .string("high"))
    }

    func testOfficialDeepSeekSelectsChatCompletionsWithoutChangingProxyContract() {
        XCTAssertEqual(
            ResponsesAPIModelProvider.wireDialect(
                baseURL: "https://api.deepseek.com/v1",
                modelID: "deepseek-v4-flash"
            ),
            .deepSeekChatCompletions
        )
        XCTAssertEqual(
            ResponsesAPIModelProvider.wireDialect(
                baseURL: "https://gateway.example/v1",
                modelID: "deepseek-v4-flash"
            ),
            .responses,
            "a third-party gateway keeps the explicitly configured Responses transport"
        )
    }

    func testChatCompletionsBodyAndParserUseDocumentedDeepSeekShape() throws {
        let descriptor = try ModelFixture.tool(name: "web_search")
        let fixture = try ModelFixture(
            thinkingMode: .disabled,
            advertisedTools: [descriptor],
            modelID: "deepseek-v4-flash"
        )
        let structuredRequest = try AgentModelRequest(
            requestID: fixture.request.requestID,
            runID: fixture.request.runID,
            stepID: fixture.request.stepID,
            selection: fixture.request.selection,
            compiledManifestDigest: fixture.request.compiledManifestDigest,
            messages: fixture.request.messages,
            advertisedTools: fixture.request.advertisedTools,
            toolSelectionSnapshot: fixture.request.toolSelectionSnapshot,
            generationParameters: fixture.request.generationParameters,
            outputRequirement: .structured(descriptor.inputSchema)
        )
        let data = try ResponsesAPIModelProvider.chatCompletionsRequestBody(
            request: structuredRequest,
            reasoningEffort: .medium,
            stream: true
        )
        let value = try AgentWireDecoder.decode(JSONValue.self, from: data, limits: .inlineValue)
        guard case .object(let object) = value,
              case .array(let messages)? = object["messages"],
              case .array(let tools)? = object["tools"],
              case .object(let firstTool) = tools.first,
              case .object(let function)? = firstTool["function"],
              case .object(let thinking)? = object["thinking"],
              case .object(let responseFormat)? = object["response_format"],
              case .object(let streamOptions)? = object["stream_options"]
        else { return XCTFail("expected documented Chat Completions request: \(value)") }
        XCTAssertEqual(messages.count, fixture.request.messages.count + 1)
        guard case .object(let outputInstruction) = messages.first,
              case .string(let instruction)? = outputInstruction["content"]
        else { return XCTFail("structured calls must send their output contract") }
        XCTAssertEqual(outputInstruction["role"], .string("system"))
        XCTAssertTrue(instruction.contains("JSON"), "DeepSeek JSON mode requires a JSON instruction")
        XCTAssertTrue(instruction.contains(try CanonicalJSON(descriptor.inputSchema.root).string))
        let responsesData = try ResponsesAPIModelProvider.requestBody(
            request: structuredRequest, baseURL: "https://gateway.example/v1"
        )
        let responsesValue = try AgentWireDecoder.decode(JSONValue.self, from: responsesData, limits: .inlineValue)
        guard case .object(let responsesObject) = responsesValue,
              case .string(let responsesInstructions)? = responsesObject["instructions"]
        else { return XCTFail("Responses requests also need the complete output contract") }
        XCTAssertTrue(responsesInstructions.contains(instruction))
        XCTAssertNil(object["input"])
        XCTAssertNil(object["instructions"])
        XCTAssertEqual(object["max_tokens"], .integer(1_024))
        XCTAssertEqual(thinking["type"], .string("disabled"))
        XCTAssertEqual(responseFormat["type"], .string("json_object"))
        XCTAssertEqual(object["stream"], .bool(true))
        XCTAssertEqual(streamOptions["include_usage"], .bool(true))
        XCTAssertEqual(firstTool["type"], .string("function"))
        XCTAssertEqual(function["name"], .string("web_search"))
        XCTAssertNotNil(function["parameters"])

        let response = #"{"choices":[{"finish_reason":"length","message":{"content":"Answer","reasoning_content":"Plan","tool_calls":[{"function":{"name":"web_search","arguments":"{\"q\":\"Kimi K3\"}"}}]}}],"usage":{"prompt_tokens":21,"completion_tokens":8}}"#
        let parsed = try ResponsesAPIModelProvider.parseChatCompletion(Data(response.utf8))
        XCTAssertEqual(parsed.text, "Answer")
        XCTAssertEqual(parsed.reasoning, "Plan")
        XCTAssertEqual(parsed.calls, [
            .init(name: "web_search", argumentsJSON: #"{"q":"Kimi K3"}"#),
        ])
        XCTAssertEqual(parsed.usage, .init(inputTokens: 21, outputTokens: 8))
        XCTAssertTrue(parsed.hasReasoning)
        XCTAssertTrue(parsed.isTruncated)
    }

    func testGenerateUsesOfficialDeepSeekChatEndpointAndStreamsAnswer() async throws {
        for answerText in [
            "Kimi K3 cannot run locally on an iPhone 16 Pro.",
            "The literal marker `<｜｜DSML｜｜tool_calls>` identifies a tool envelope.",
            "<｜｜DSML｜｜tool_calls>\n<｜｜DSML｜｜invoke name=\"fetch_webpage\">\n</｜｜DSML｜｜invoke>\n</｜｜DSML｜｜tool_calls>"
        ] {
            let encodedText = String(decoding: try JSONEncoder().encode(answerText), as: UTF8.self)
            let streamBody = """
            data: {"choices":[{"delta":{"reasoning_content":"private plan"}}]}

            data: {"choices":[{"delta":{"content":\(encodedText)}}]}

            data: {"choices":[{"finish_reason":"stop","delta":{}}],"usage":{"prompt_tokens":31,"completion_tokens":11}}

            data: [DONE]

            """
            MockResponsesURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/chat/completions")
                let body = MockResponsesURLProtocol.requestBodyString(request)
                XCTAssertTrue(body.contains("\"messages\""), body)
                XCTAssertTrue(body.contains("\"thinking\":{\"type\":\"disabled\"}"), body)
                XCTAssertFalse(body.contains("\"input\""), body)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!,
                    Data(streamBody.utf8)
                )
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockResponsesURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer {
                MockResponsesURLProtocol.handler = nil
                MockResponsesURLProtocol.capturedRequest = nil
            }

            let fixture = try ModelFixture(
                location: .remote,
                thinkingMode: .disabled,
                providerID: ResponsesAPIModelProvider.providerID,
                remoteDestination: "openai.responses:responses-api-key:deepseek-v4-flash",
                modelID: "deepseek-v4-flash"
            )
            let provider = try ResponsesAPIModelProvider(
                configurationProvider: {
                    ResponsesAPIConfiguration(
                        baseURL: "https://api.deepseek.com/v1",
                        apiKey: "sk-test"
                    )
                },
                session: session
            )
            let cloudPolicy = try AgentModelPolicy(
                localOnly: false,
                allowedSelections: [fixture.request.selection],
                strategy: .pinned,
                requiredCapabilities: AgentModelCapabilitySet([])
            )
            let cloudContext = try ModelPreparationContext(
                conversationID: fixture.context.conversationID,
                modelPolicy: cloudPolicy,
                capabilityGrant: fixture.context.capabilityGrant,
                authorizationPayload: fixture.context.authorizationPayload,
                maximumRequestBytes: fixture.context.maximumRequestBytes,
                maximumResponseBytes: fixture.context.maximumResponseBytes,
                timeoutMilliseconds: fixture.context.timeoutMilliseconds
            )
            let prepared = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: cloudContext
            )
            let policy = TestApprovalPolicyEngine()
            let authorization = try await policy.bindLocalPolicy(
                prepared: prepared.preparedRequest.externalOperation,
                approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
                trustedRunAuthority: fixture.authority,
                at: AgentTimestamp(rawValue: 1_000)
            )
            let authorized = AuthorizedAgentModelAttempt(
                preparedAttempt: prepared,
                request: try AuthorizedModelRequest(
                    request: fixture.request,
                    authorization: authorization,
                    clock: FixedAuthorizationClock(),
                    policyValidator: policy,
                    attemptLedger: TestAttemptLedger()
                )
            )

            let result = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: authorized
            )
            if answerText.hasPrefix("<｜｜DSML｜｜tool_calls>") {
                guard case .failed(let failure) = result.outcome else {
                    XCTFail("Raw tool markup must not be committed as an answer or executed as a tool")
                    continue
                }
                XCTAssertEqual(failure.code, "model.online.malformed-action")
                XCTAssertEqual(failure.externalEffect, .confirmedNone)
                XCTAssertEqual(failure.retryAdvice, .never)
                continue
            }
            guard case .completed(let completion) = result.outcome,
                  case .finalAnswer(let answer) = completion.action
            else { return XCTFail("expected final answer, got \(result.outcome)") }
            XCTAssertEqual(answer.text, answerText)
            XCTAssertEqual(completion.usage.inputTokens, 31)
            XCTAssertEqual(completion.usage.outputTokens, 11)
        }
    }

    func testStructuredDeepSeekStreamNormalizesBeforePublishingProvisionalAnswer() async throws {
        let schema = try ModelFixture.tool(name: "structured_result").inputSchema
        let streamBody = """
        data: {"choices":[{"delta":{"content":"\\n  {\\\"q\\\":\\\"value\\\"}\\n"}}]}

        data: {"choices":[{"finish_reason":"stop","delta":{}}],"usage":{"prompt_tokens":19,"completion_tokens":7}}

        data: [DONE]

        """
        let emptyStreamBody = """
        data: {"choices":[{"finish_reason":"stop","delta":{"content":""}}],"usage":{"prompt_tokens":19,"completion_tokens":0}}

        data: [DONE]

        """
        for streamBody in [streamBody, emptyStreamBody] {
            MockResponsesURLProtocol.handler = { request in
                let body = MockResponsesURLProtocol.requestBodyString(request)
                XCTAssertTrue(body.contains("\"response_format\":{\"type\":\"json_object\"}"), body)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/event-stream"]
                    )!,
                    Data(streamBody.utf8)
                )
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockResponsesURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer {
                MockResponsesURLProtocol.handler = nil
                MockResponsesURLProtocol.capturedRequest = nil
            }

            let fixture = try ModelFixture(
                location: .remote,
                thinkingMode: .disabled,
                providerID: ResponsesAPIModelProvider.providerID,
                remoteDestination: "openai.responses:responses-api-key:deepseek-v4-flash",
                modelID: "deepseek-v4-flash",
                outputRequirement: .structured(schema)
            )
            let provider = try ResponsesAPIModelProvider(
                configurationProvider: {
                    ResponsesAPIConfiguration(
                        baseURL: "https://api.deepseek.com/v1",
                        apiKey: "sk-test"
                    )
                },
                session: session
            )
            let cloudPolicy = try AgentModelPolicy(
                localOnly: false,
                allowedSelections: [fixture.request.selection],
                strategy: .pinned,
                requiredCapabilities: AgentModelCapabilitySet([])
            )
            let cloudContext = try ModelPreparationContext(
                conversationID: fixture.context.conversationID,
                modelPolicy: cloudPolicy,
                capabilityGrant: fixture.context.capabilityGrant,
                authorizationPayload: fixture.context.authorizationPayload,
                maximumRequestBytes: fixture.context.maximumRequestBytes,
                maximumResponseBytes: fixture.context.maximumResponseBytes,
                timeoutMilliseconds: fixture.context.timeoutMilliseconds
            )
            let prepared = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: cloudContext
            )
            let policy = TestApprovalPolicyEngine()
            let authorization = try await policy.bindLocalPolicy(
                prepared: prepared.preparedRequest.externalOperation,
                approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
                trustedRunAuthority: fixture.authority,
                at: AgentTimestamp(rawValue: 1_000)
            )
            let authorized = AuthorizedAgentModelAttempt(
                preparedAttempt: prepared,
                request: try AuthorizedModelRequest(
                    request: fixture.request,
                    authorization: authorization,
                    clock: FixedAuthorizationClock(),
                    policyValidator: policy,
                    attemptLedger: TestAttemptLedger()
                )
            )
            let sink = RecordingModelEventSink()

            let result = try await AgentModelExecutor().execute(
                provider: provider,
                authorized: authorized,
                eventSink: sink
            )
            if streamBody == emptyStreamBody {
                guard case .failed(let failure) = result.outcome else {
                    XCTFail("Empty structured output must fail instead of becoming an answer")
                    continue
                }
                XCTAssertEqual(failure.code, "model.online.structured-output-invalid")
                XCTAssertEqual(failure.externalEffect, .confirmedNone)
                XCTAssertEqual(failure.retryAdvice, .never, "The existing controller repair owns the retry")
                continue
            }
            guard case .completed(let completion) = result.outcome,
                  case .finalAnswer(let answer) = completion.action
            else { return XCTFail("expected structured final answer, got \(result.outcome)") }
            XCTAssertNil(answer.text)
            XCTAssertEqual(answer.structuredOutput, .object(["q": .string("value")]))
            let answerDeltas = (await sink.events()).compactMap { event -> String? in
                guard case .provisionalAnswerDelta(let delta) = event else { return nil }
                return delta
            }
            XCTAssertTrue(
                answerDeltas.isEmpty,
                "structured bytes must not escape before normalization and schema validation"
            )
        }
    }

    func testRequestBodyLeavesReasoningDefaultWhenThinkingIsOn() throws {
        let fixture = try ModelFixture(thinkingMode: .enabled)
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertNil(object["reasoning"], "thinking enabled must keep the gateway default")
    }

    func testRequestBodyStaysNeutralForAutomaticThinking() throws {
        // `.automatic` is not produced by the app for online runs anymore (the per-service reasoning
        // toggle maps to `.enabled`/`.disabled`); if it ever appears, the provider must not invent a
        // reasoning directive.
        let fixture = try ModelFixture(thinkingMode: .automatic)
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertNil(object["reasoning"], "automatic thinking must stay neutral")
    }

    func testRequestBodyIncludesToolsWhenAdvertised() throws {
        let descriptor = try ModelFixture.tool(name: "calculator")
        let fixture = try ModelFixture(advertisedTools: [descriptor])
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1"
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value,
              case .array(let tools)? = object["tools"],
              tools.count == 1,
              case .object(let tool) = tools[0],
              tool["name"] == .string("calculator"),
              tool["description"] == .string("Look up a local value"),
              tool["parameters"] != nil,
              tool["function"] == nil
        else {
            return XCTFail("expected one flat Responses-API calculator tool: \(value)")
        }
    }

    func testParseResponseExtractsTextCallsAndUsage() throws {
        let json = """
        {"usage":{"input_tokens":12,"output_tokens":7},
         "output":[
           {"type":"message","role":"assistant","content":[
             {"type":"output_text","text":"Hello "},
             {"type":"output_text","text":"world"}
           ]},
           {"type":"function_call","call_id":"c1","name":"calculator",
            "arguments":"{\\"expression\\":\\"1+1\\"}"}
         ]}
        """
        let parsed = try ResponsesAPIModelProvider.parseResponse(Data(json.utf8))
        XCTAssertEqual(parsed.text, "Hello world")
        XCTAssertEqual(parsed.calls.count, 1)
        XCTAssertEqual(parsed.calls[0].name, "calculator")
        XCTAssertEqual(parsed.calls[0].callID, "c1")
        XCTAssertEqual(parsed.usage.inputTokens, 12)
        XCTAssertEqual(parsed.usage.outputTokens, 7)
        XCTAssertFalse(parsed.hasReasoning)
    }

    func testParseResponseDetectsReasoningOnlyOutput() throws {
        let json = """
        {"usage":{"input_tokens":1,"output_tokens":12},
         "output":[{"type":"reasoning","content":[
           {"type":"reasoning_text","text":"thinking hard"}
         ]}]}
        """
        let parsed = try ResponsesAPIModelProvider.parseResponse(Data(json.utf8))
        XCTAssertTrue(parsed.text.isEmpty)
        XCTAssertTrue(parsed.calls.isEmpty)
        XCTAssertTrue(parsed.hasReasoning)
        XCTAssertFalse(parsed.isTruncated)
    }

    func testParseResponseDetectsTruncatedCompletion() throws {
        let json = """
        {"status":"incomplete",
         "incomplete_details":{"reason":"max_output_tokens"},
         "usage":{"input_tokens":1,"output_tokens":5},
         "output":[{"type":"message","role":"assistant","content":[
           {"type":"output_text","text":"Sleep doesn"}
         ]}]}
        """
        let parsed = try ResponsesAPIModelProvider.parseResponse(Data(json.utf8))
        XCTAssertEqual(parsed.text, "Sleep doesn")
        XCTAssertTrue(parsed.isTruncated)
    }

    func testParseResponseExtractsReasoningText() throws {
        let json = """
        {"usage":{"input_tokens":1,"output_tokens":7},
         "output":[
           {"type":"reasoning","content":[
             {"type":"reasoning_text","text":"think "},
             {"type":"reasoning_text","text":"hard"}
           ]},
           {"type":"message","role":"assistant","content":[
             {"type":"output_text","text":"Answer"}
           ]}
         ]}
        """
        let parsed = try ResponsesAPIModelProvider.parseResponse(Data(json.utf8))
        XCTAssertEqual(parsed.reasoning, "think hard")
        XCTAssertEqual(parsed.text, "Answer")
    }

    func testRequestBodySendsEffortWhenReasoningEnabledAndOmitsOnFallback() throws {
        let fixture = try ModelFixture(thinkingMode: .enabled)
        let data = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1",
            reasoningEffort: .medium
        )
        let value = try AgentWireDecoder.decode(
            JSONValue.self,
            from: data,
            limits: .inlineValue
        )
        guard case .object(let object) = value else { return XCTFail("body object") }
        XCTAssertEqual(object["reasoning"], .object(["effort": .string("medium")]))

        let fallbackData = try ResponsesAPIModelProvider.requestBody(
            request: fixture.request,
            baseURL: "https://gateway.example/v1",
            reasoningEffort: .medium,
            omitReasoning: true
        )
        let fallbackValue = try AgentWireDecoder.decode(
            JSONValue.self,
            from: fallbackData,
            limits: .inlineValue
        )
        guard case .object(let fallbackObject) = fallbackValue else { return XCTFail("body object") }
        XCTAssertNil(fallbackObject["reasoning"], "fallback must omit the reasoning field entirely")
    }

    func testGeneratePostsResponsesAndEmitsTextUsageCompletion() async throws {
        let responseJSON = """
        {"usage":{"input_tokens":12,"output_tokens":7},
         "output":[{"type":"message","role":"assistant","content":[
           {"type":"output_text","text":"Hello "},
           {"type":"output_text","text":"world"}
         ]}]}
        """
        MockResponsesURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseJSON.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { MockResponsesURLProtocol.handler = nil }
        defer { MockResponsesURLProtocol.capturedRequest = nil }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: "https://gateway.example/v1",
                    apiKey: "sk-test-secret"
                )
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorizedRequest = try AuthorizedModelRequest(
            request: fixture.request,
            authorization: authorization,
            clock: FixedAuthorizationClock(),
            policyValidator: policy,
            attemptLedger: TestAttemptLedger()
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: authorizedRequest
        )
        let sink = RecordingModelEventSink()

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "Hello world")
        XCTAssertEqual(completion.usage.inputTokens, 12)
        XCTAssertEqual(completion.usage.outputTokens, 7)
        let request = try XCTUnwrap(MockResponsesURLProtocol.capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let events = await sink.events()
        XCTAssertEqual(
            events,
            [
                .usage(completion.usage),
                .provisionalAnswerDelta("Hello world"),
                .provisionalAnswerResolved(.committed("Hello world")),
            ]
        )
    }

    func testPrepareFailsClosedWhenConfigurationMissing() async throws {
        let session = URLSession(configuration: .ephemeral)
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: { nil },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        do {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: cloudContext
            )
            XCTFail("prepare must fail closed without a configured service")
        } catch let failure as AgentModelProviderFailure {
            XCTAssertEqual(failure.failure.code, "model.online.configuration-missing")
            XCTAssertEqual(failure.failure.externalEffect, .confirmedNone)
        }
    }

    func testGenerateRejectsNonHTTPSBaseURL() async throws {
        let session = URLSession(configuration: .ephemeral)
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(baseURL: "http://insecure.example/v1", apiKey: "sk-test")
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(7)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorizedRequest = try AuthorizedModelRequest(
            request: fixture.request,
            authorization: authorization,
            clock: FixedAuthorizationClock(),
            policyValidator: policy,
            attemptLedger: TestAttemptLedger()
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: authorizedRequest
        )

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
        )

        guard case .failed(let failure) = result.outcome else {
            return XCTFail("expected typed failure, got \(result.outcome)")
        }
        XCTAssertEqual(failure.code, "model.online.invalid-base-url")
    }

    func testUnauthorizedHTTPFailureNamesTheAPIKeyFix() throws {
        let unauthorized = try ResponsesAPIModelProvider.httpFailure(status: 401)
        XCTAssertEqual(unauthorized.code, "model.online.http")
        XCTAssertTrue(
            unauthorized.safeMessage.contains("API key"),
            "401 must point the user at the key: \(unauthorized.safeMessage)"
        )
        XCTAssertTrue(
            unauthorized.safeMessage.contains("Settings"),
            "401 must be actionable: \(unauthorized.safeMessage)"
        )

        let serverError = try ResponsesAPIModelProvider.httpFailure(status: 500)
        XCTAssertTrue(serverError.safeMessage.contains("HTTP 500"))
        XCTAssertFalse(serverError.safeMessage.contains("API key"))
    }

    func testGenerateRetriesReasoningOnlyResponseEvenWhenReasoningWasAlreadyDisabled() async throws {
        MockResponsesURLProtocol.requestCount = 0
        MockResponsesURLProtocol.handler = { request in
            MockResponsesURLProtocol.requestCount += 1
            let body = MockResponsesURLProtocol.requestBodyString(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if MockResponsesURLProtocol.requestCount == 1 {
                XCTAssertTrue(
                    body.contains("reasoning") && body.contains("enabled"),
                    "the first attempt must request reasoning-disabled mode: \(body)"
                )
                return (response, Data("""
                {"usage":{"input_tokens":1,"output_tokens":12},
                 "output":[{"type":"reasoning","content":[
                   {"type":"reasoning_text","text":"thinking hard"}
                 ]}]}
                """.utf8))
            }
            XCTAssertTrue(
                body.contains("reasoning") && body.contains("enabled"),
                "the retry must disable reasoning: \(body)"
            )
            return (response, Data("""
            {"usage":{"input_tokens":2,"output_tokens":2},
             "output":[{"type":"message","role":"assistant","content":[
               {"type":"output_text","text":"OK"}
             ]}]}
            """.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
            MockResponsesURLProtocol.requestCount = 0
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(baseURL: "https://gateway.example/v1", apiKey: "sk-test")
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .disabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "OK")
        XCTAssertEqual(MockResponsesURLProtocol.requestCount, 2)
    }

    func testGenerateRetriesTruncatedResponseWithHigherBudgetSameReasoning() async throws {
        MockResponsesURLProtocol.requestCount = 0
        MockResponsesURLProtocol.handler = { request in
            MockResponsesURLProtocol.requestCount += 1
            let body = MockResponsesURLProtocol.requestBodyString(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if MockResponsesURLProtocol.requestCount == 1 {
                return (response, Data("""
                {"status":"incomplete",
                 "incomplete_details":{"reason":"max_output_tokens"},
                 "usage":{"input_tokens":1,"output_tokens":5},
                 "output":[{"type":"message","role":"assistant","content":[
                   {"type":"output_text","text":"Sleep doesn"}
                 ]}]}
                """.utf8))
            }
            let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            XCTAssertEqual(decoded?["max_output_tokens"] as? Int, 4_091)
            XCTAssertNil(decoded?["reasoning"], "the truncation retry keeps the same reasoning mode")
            return (response, Data("""
            {"status":"completed",
             "usage":{"input_tokens":2,"output_tokens":6},
             "output":[{"type":"message","role":"assistant","content":[
               {"type":"output_text","text":"Sleep doesn’t have to be perfect."}
             ]}]}
            """.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
            MockResponsesURLProtocol.requestCount = 0
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(baseURL: "https://gateway.example/v1", apiKey: "sk-test")
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            maximumOutputTokens: 4_096,
            outputBudgetMode: .auto,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "Sleep doesn’t have to be perfect.")
        XCTAssertEqual(completion.usage.inputTokens, 3)
        XCTAssertEqual(completion.usage.outputTokens, 11)
        XCTAssertEqual(MockResponsesURLProtocol.requestCount, 2)
    }

    func testGenerateFallsBackWhenGatewayRejectsEffortField() async throws {
        MockResponsesURLProtocol.requestCount = 0
        MockResponsesURLProtocol.handler = { request in
            MockResponsesURLProtocol.requestCount += 1
            let body = MockResponsesURLProtocol.requestBodyString(request)
            if MockResponsesURLProtocol.requestCount == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(
                    #"{"error":{"message":"unknown parameter: reasoning"}}"#.utf8
                ))
            }
            XCTAssertFalse(
                body.contains("reasoning"),
                "the fallback must omit the reasoning field: \(body)"
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("""
            {"status":"completed",
             "usage":{"input_tokens":2,"output_tokens":2},
             "output":[{"type":"message","role":"assistant","content":[
               {"type":"output_text","text":"OK"}
             ]}]}
            """.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
            MockResponsesURLProtocol.requestCount = 0
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: "https://gateway.example/v1",
                    apiKey: "sk-test",
                    reasoningEffort: .medium
                )
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "OK")
        XCTAssertEqual(MockResponsesURLProtocol.requestCount, 2)
    }

    func testGenerateStreamsReasoningAndAnswerDeltas() async throws {
        let streamBody = """
        data: {"type":"response.reasoning_text.delta","delta":"think "}

        data: {"type":"response.reasoning_text.delta","delta":"ing"}

        data: {"type":"response.output_text.delta","delta":"Hel"}

        data: {"type":"response.output_text.delta","delta":"lo"}

        data: {"type":"response.completed","status":"completed","usage":{"input_tokens":2,"output_tokens":2}}

        """
        MockResponsesURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(streamBody.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
            MockResponsesURLProtocol.requestCount = 0
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: "https://gateway.example/v1",
                    apiKey: "sk-test",
                    reasoningEffort: .medium
                )
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )
        let sink = RecordingModelEventSink()

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "Hello")
        XCTAssertEqual(completion.usage.inputTokens, 2)
        XCTAssertEqual(completion.usage.outputTokens, 2)

        let events = await sink.events()
        XCTAssertEqual(
            events.filter {
                if case .visibleReasoningDelta = $0 { return true }
                return false
            },
            [.visibleReasoningDelta("think "), .visibleReasoningDelta("ing")]
        )
        XCTAssertEqual(
            events.filter {
                if case .provisionalAnswerDelta = $0 { return true }
                return false
            },
            [.provisionalAnswerDelta("Hel"), .provisionalAnswerDelta("lo")]
        )
    }

    /// DeepSeek nests usage inside `response.completed.response.usage`; the parser must read the
    /// nested object so workflow/run token statistics are truthful.
    func testGenerateStreamsDeepSeekNestedUsage() async throws {
        let streamBody = """
        data: {"type":"response.output_text.delta","delta":"Hello"}

        data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":7}}}

        """
        MockResponsesURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(streamBody.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: "https://gateway.example/v1",
                    apiKey: "sk-test",
                    reasoningEffort: .medium
                )
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
        )
        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "Hello")
        XCTAssertEqual(completion.usage.inputTokens, 12)
        XCTAssertEqual(completion.usage.outputTokens, 7)
    }

    func testGenerateStreamedTruncationRetriesWithHigherBudgetAndEmitsOnlyContinuation() async throws {
        MockResponsesURLProtocol.requestCount = 0
        MockResponsesURLProtocol.handler = { request in
            MockResponsesURLProtocol.requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            if MockResponsesURLProtocol.requestCount == 1 {
                return (response, Data("""
                data: {"type":"response.output_text.delta","delta":"Sleep doesn"}

                data: {"type":"response.completed","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":1,"output_tokens":5}}

                """.utf8))
            }
            let body = MockResponsesURLProtocol.requestBodyString(request)
            let decoded = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            XCTAssertEqual(decoded?["max_output_tokens"] as? Int, 4_091)
            return (response, Data("""
            data: {"type":"response.output_text.delta","delta":"Sleep doesn"}

            data: {"type":"response.output_text.delta","delta":"’t have to be perfect."}

            data: {"type":"response.completed","status":"completed","usage":{"input_tokens":2,"output_tokens":7}}

            """.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockResponsesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockResponsesURLProtocol.handler = nil
            MockResponsesURLProtocol.capturedRequest = nil
            MockResponsesURLProtocol.requestCount = 0
        }

        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(baseURL: "https://gateway.example/v1", apiKey: "sk-test")
            },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            maximumOutputTokens: 4_096,
            outputBudgetMode: .auto,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model"
        )
        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: cloudContext
        )
        let policy = TestApprovalPolicyEngine()
        let authorization = try await policy.bindLocalPolicy(
            prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(5)),
            trustedRunAuthority: fixture.authority,
            at: AgentTimestamp(rawValue: 1_000)
        )
        let authorized = AuthorizedAgentModelAttempt(
            preparedAttempt: prepared,
            request: try AuthorizedModelRequest(
                request: fixture.request,
                authorization: authorization,
                clock: FixedAuthorizationClock(),
                policyValidator: policy,
                attemptLedger: TestAttemptLedger()
            )
        )
        let sink = RecordingModelEventSink()

        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else { return XCTFail("expected final answer, got \(result.outcome)") }
        XCTAssertEqual(answer.text, "Sleep doesn’t have to be perfect.")
        XCTAssertEqual(completion.usage.inputTokens, 3)
        XCTAssertEqual(completion.usage.outputTokens, 12)
        XCTAssertEqual(MockResponsesURLProtocol.requestCount, 2)

        let answerDeltas = (await sink.events()).compactMap { event -> String? in
            guard case .provisionalAnswerDelta(let delta) = event else { return nil }
            return delta
        }
        XCTAssertEqual(
            answerDeltas,
            ["Sleep doesn", "’t have to be perfect."],
            "the first attempt streams live and the retry emits ONLY the continuation"
        )
        XCTAssertEqual(answerDeltas.joined(), answer.text)
    }
    func testTransportAccountsSSEBytesAndDigestAndRejectsOversizedBodies() async throws {
        let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\ndata: {\"type\":\"response.completed\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":2}}\n\n"
        let data = Data(stream.utf8)
        let result = try await executeTransportFixture(data: data, type: "text/event-stream", limit: 1_024)
        XCTAssertEqual(result.responseBytes, UInt64(data.count))
        XCTAssertEqual(result.responseDigest, StableDigest.sha256(data))
        for type in ["text/event-stream", "application/json"] {
            do {
                _ = try await executeTransportFixture(data: data, type: type, limit: 1)
                XCTFail("transport must reject bytes beyond the prepared limit")
            } catch let error as AgentModelRuntimeError {
                guard case .providerContractViolation = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        do {
            _ = try await executeTransportFixture(data: Data(repeating: 65, count: 16_384), type: "text/plain", limit: 1, status: 500)
            XCTFail("error responses must also be bounded")
        } catch let error as AgentModelRuntimeError {
            guard case .providerContractViolation = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func executeTransportFixture(data: Data, type: String, limit: UInt64, status: Int = 200) async throws -> AgentModelExecutionResult {
        MockResponsesURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, data)
        }
        defer { MockResponsesURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockResponsesURLProtocol.self]
        let provider = try ResponsesAPIModelProvider(
            configuration: ResponsesAPIConfiguration(baseURL: "https://fixture.test/v1", apiKey: "fixture-key"),
            session: URLSession(configuration: config)
        )
        let fixture = try ModelFixture(location: .remote, providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:responses-api-key:fixture-model")
        let context = try ModelPreparationContext(conversationID: fixture.context.conversationID,
            modelPolicy: AgentModelPolicy(localOnly: false, allowedSelections: [fixture.request.selection], strategy: .pinned, requiredCapabilities: AgentModelCapabilitySet([])),
            capabilityGrant: fixture.context.capabilityGrant, authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes, maximumResponseBytes: limit, timeoutMilliseconds: 60_000)
        let prepared = try await AgentModelRequestPreparer().prepare(provider: provider, request: fixture.request, context: context)
        let policy = TestApprovalPolicyEngine()
        let auth = try await policy.bindLocalPolicy(prepared: prepared.preparedRequest.externalOperation,
            approvalID: ApprovalID(), trustedRunAuthority: fixture.authority, at: AgentTimestamp(rawValue: 1_000))
        let authorized = AuthorizedAgentModelAttempt(preparedAttempt: prepared, request: try AuthorizedModelRequest(
            request: fixture.request, authorization: auth, clock: FixedAuthorizationClock(), policyValidator: policy, attemptLedger: TestAttemptLedger()))
        return try await AgentModelExecutor().execute(provider: provider, authorized: authorized)
    }

}
