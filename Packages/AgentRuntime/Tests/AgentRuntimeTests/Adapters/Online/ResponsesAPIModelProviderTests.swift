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
        let payload = try ResponsesAPIModelProvider.messagesPayload(messages)
        XCTAssertEqual(payload.count, 4)
        guard case .object(let system) = payload[0] else { return XCTFail("system") }
        XCTAssertEqual(system["role"], .string("system"))
        guard case .object(let tool) = payload[3] else { return XCTFail("tool") }
        XCTAssertEqual(tool["role"], .string("user"))
        XCTAssertEqual(tool["content"], .string("Tool result: 42"))
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
        guard case .array(let messages)? = object["messages"] else { return XCTFail("messages") }
        XCTAssertEqual(messages.count, 1)
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
            remoteDestination: "openai.responses:fixture-model"
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

    func testGenerateFailsClosedWhenConfigurationMissing() async throws {
        let session = URLSession(configuration: .ephemeral)
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: { nil },
            session: session
        )
        let fixture = try ModelFixture(
            location: .remote,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:fixture-model"
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
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(6)),
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

        guard case .failed(let failure) = result.outcome else {
            return XCTFail("expected typed failure, got \(result.outcome)")
        }
        XCTAssertEqual(failure.code, "model.online.configuration-missing")
        XCTAssertEqual(failure.externalEffect, .confirmedNone)
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
            remoteDestination: "openai.responses:fixture-model"
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
}
