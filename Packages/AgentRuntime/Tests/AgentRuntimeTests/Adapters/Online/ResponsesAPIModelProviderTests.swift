// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime

/// URLProtocol stub so the online provider's real `generate` path (URLSession → parse → emitter) is
/// covered without network access.
final class MockResponsesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?

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
}
