// SPDX-License-Identifier: MIT

import XCTest
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
              case .object(let function)? = tool["function"],
              function["name"] == .string("calculator")
        else { return XCTFail("expected one calculator tool") }
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

    func testGenerateRetriesReasoningOnlyResponseWithoutReasoning() async throws {
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
                XCTAssertFalse(
                    body.contains("reasoning"),
                    "the first attempt keeps service-side reasoning: \(body)"
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
            XCTAssertEqual(decoded?["max_output_tokens"] as? Int, 4_096)
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
            maximumOutputTokens: 1_024,
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
}
