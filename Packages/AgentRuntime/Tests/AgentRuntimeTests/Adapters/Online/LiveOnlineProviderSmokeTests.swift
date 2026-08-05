// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation

/// MAC-SIDE functional smoke for the online provider: reads the developer's ~/.mobilellm/openai.json
/// (never prints it), sends a REAL request through the actual provider + executor, and verifies the
/// response is non-empty and reasonably fast. This is the workflow that must catch online-model
/// regressions BEFORE any phone run: it exercises the exact request/parse/emit path against the
/// configured service.
///
/// The test skips when the config file is absent (CI / fresh checkout), and never writes secrets.
final class LiveOnlineProviderSmokeTests: XCTestCase {
    private struct LocalConfig: Codable {
        var apiKey: String
        var baseURL: String
        var model: String?
    }

    private func loadConfig() throws -> LocalConfig {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mobilellm/openai.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LocalConfig.self, from: data),
              !config.apiKey.isEmpty,
              let model = config.model, !model.isEmpty
        else {
            throw XCTSkip("~/.mobilellm/openai.json is missing; configure it to run live smoke tests")
        }
        return config
    }

    func testLiveResponsesWithReasoningDisabledReturnsAnswerFast() async throws {
        let config = try loadConfig()
        let model = config.model ?? ""
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    reasoningEffort: .medium
                )
            },
            session: .shared
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .disabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:\(ResponsesAPIConfiguration.defaultServiceID):\(model)",
            modelID: model,
            userMessage: "Explain how sleep affects memory. Reply in one short paragraph."
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

        let started = ContinuousClock.now
        let sink = RecordingModelEventSink()
        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )
        let elapsed = started.duration(to: .now)

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else {
            let detail = result.outcome
            let attachment = XCTAttachment(string: "elapsed=\(elapsed) outcome=\(detail)")
            attachment.name = "live-online-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            return XCTFail("live online request did not complete: \(detail)")
        }

        let answerText = answer.text ?? ""
        let summary = XCTAttachment(string: """
        elapsed_seconds=\(Double(elapsed.components.seconds))
        answer_length=\(answerText.utf8.count)
        reasoning_emitted=\(await sink.events().contains { if case .visibleReasoningDelta = $0 { true } else { false } })
        input_tokens=\(completion.usage.inputTokens)
        output_tokens=\(completion.usage.outputTokens)
        active_ms=\(completion.usage.activeMilliseconds)
        answer_prefix=\(String(answerText.prefix(120)))
        """)
        summary.name = "live-online-smoke"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertFalse(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThan(
            elapsed,
            .seconds(60),
            "reasoning-disabled online replies should be fast, took \(elapsed)"
        )
    }

    /// The user-facing promise is token-by-token UI streaming: deltas must arrive BEFORE the full
    /// answer is known and their concatenation must equal the committed answer. This test asks for a
    /// longer reply so the gateway has to emit multiple `output_text.delta` chunks; a service that
    /// buffers the whole response (or an SSE parser that waits for completion) fails here even though
    /// the final answer is correct.
    func testLiveResponsesStreamAnswerDeltasIncrementally() async throws {
        let config = try loadConfig()
        let model = config.model ?? ""
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    reasoningEffort: .medium
                )
            },
            session: .shared
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .disabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:\(ResponsesAPIConfiguration.defaultServiceID):\(model)",
            modelID: model,
            userMessage: "Explain how sleep affects memory. Write at least three sentences."
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

        let started = ContinuousClock.now
        let sink = RecordingModelEventSink()
        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )
        let elapsed = started.duration(to: .now)

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else {
            let detail = result.outcome
            let attachment = XCTAttachment(string: "elapsed=\(elapsed) outcome=\(detail)")
            attachment.name = "live-online-stream-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            return XCTFail("live online streaming request did not complete: \(detail)")
        }

        let events = await sink.events()
        let answerDeltas = events.compactMap { event -> String? in
            guard case .provisionalAnswerDelta(let delta) = event else { return nil }
            return delta
        }
        let streamed = answerDeltas.joined()
        let answerText = answer.text ?? ""
        let summary = XCTAttachment(string: """
        elapsed_seconds=\(Double(elapsed.components.seconds))
        answer_length=\(answerText.utf8.count)
        answer_delta_count=\(answerDeltas.count)
        streamed_matches_final=\(streamed == answerText)
        input_tokens=\(completion.usage.inputTokens)
        output_tokens=\(completion.usage.outputTokens)
        answer_prefix=\(String(answerText.prefix(120)))
        """)
        summary.name = "live-online-stream-deltas"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertFalse(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThanOrEqual(
            answerDeltas.count,
            2,
            "expected multiple answer deltas from the live SSE stream, got \(answerDeltas.count)"
        )
        XCTAssertEqual(
            streamed,
            answerText,
            "streamed delta concatenation must equal the committed answer"
        )
        XCTAssertLessThan(
            elapsed,
            .seconds(60),
            "online streaming replies should complete quickly, took \(elapsed)"
        )
    }

    /// Auto budget is the product default: the wire request OMITS max_output_tokens so the service
    /// uses the selected model's own output maximum. This live check proves the configured gateway
    /// accepts the omission (strict gateways fall back to an explicit ceiling inside the provider).
    func testLiveResponsesAutoBudgetOmitsLimitAndReturnsAnswer() async throws {
        let config = try loadConfig()
        let model = config.model ?? ""
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    reasoningEffort: .medium
                )
            },
            session: .shared
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .disabled,
            maximumOutputTokens: 4_096,
            outputBudgetMode: .auto,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:\(ResponsesAPIConfiguration.defaultServiceID):\(model)",
            modelID: model,
            userMessage: "Reply with the word OK and nothing else."
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
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(8)),
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
        else {
            let detail = result.outcome
            let attachment = XCTAttachment(string: "outcome=\(detail)")
            attachment.name = "live-online-auto-budget-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            return XCTFail("live auto-budget request did not complete: \(detail)")
        }
        XCTAssertFalse((answer.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Diagnostics for the tool-calling contract: with a calculator advertised, the configured
    /// gateway/model MUST return a native function_call for a prompt that cannot be answered from
    /// knowledge ("1234567 * 7654321" is deliberately not a memorized product). This is the exact
    /// wire path the simulator tool E2E drives.
    func testLiveResponsesCallsToolWhenRequired() async throws {
        let config = try loadConfig()
        let model = config.model ?? ""
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    reasoningEffort: .medium
                )
            },
            session: .shared
        )
        let tool = try ModelFixture.tool(name: "calculator")
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .disabled,
            advertisedTools: [tool],
            maximumOutputTokens: 4_096,
            outputBudgetMode: .auto,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:\(ResponsesAPIConfiguration.defaultServiceID):\(model)",
            modelID: model,
            userMessage: "What is 1234567 * 7654321? You do not know this product from memory. "
                + "You MUST call the calculator tool exactly once to compute it."
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
            approvalID: ApprovalID(rawValue: ModelFixture.uuid(9)),
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

        guard case .completed(let completion) = result.outcome else {
            let detail = result.outcome
            let attachment = XCTAttachment(string: "outcome=\(detail)")
            attachment.name = "live-online-tool-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            return XCTFail("live tool-call request did not complete: \(detail)")
        }
        let attachment = XCTAttachment(string: "action=\(completion.action)")
        attachment.name = "live-online-tool-action"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard case .callTools(let calls) = completion.action else {
            return XCTFail("gateway/model did not call the advertised calculator: \(completion.action)")
        }
        XCTAssertEqual(calls.map(\.toolID.name), ["calculator"])
    }

    /// The 2026-standard path: reasoning ENABLED with medium effort. Verifies the configured gateway
    /// accepts `reasoning.effort` and still returns a real answer (not just reasoning).
    func testLiveResponsesWithMediumEffortReturnsAnswer() async throws {
        let config = try loadConfig()
        let model = config.model ?? ""
        let provider = try ResponsesAPIModelProvider(
            configurationProvider: {
                ResponsesAPIConfiguration(
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    reasoningEffort: .medium
                )
            },
            session: .shared
        )
        let fixture = try ModelFixture(
            location: .remote,
            thinkingMode: .enabled,
            providerID: ResponsesAPIModelProvider.providerID,
            remoteDestination: "openai.responses:\(ResponsesAPIConfiguration.defaultServiceID):\(model)",
            modelID: model,
            userMessage: "Explain how sleep affects memory. Reply in one short paragraph."
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

        let started = ContinuousClock.now
        let sink = RecordingModelEventSink()
        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized,
            eventSink: sink
        )
        let elapsed = started.duration(to: .now)

        guard case .completed(let completion) = result.outcome,
              case .finalAnswer(let answer) = completion.action
        else {
            let detail = result.outcome
            let attachment = XCTAttachment(string: "elapsed=\(elapsed) outcome=\(detail)")
            attachment.name = "live-online-medium-effort-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            return XCTFail("live medium-effort request did not complete: \(detail)")
        }

        let answerText = answer.text ?? ""
        let events = await sink.events()
        let reasoningEmitted = events.contains {
            if case .visibleReasoningDelta = $0 { return true }
            return false
        }
        let summary = XCTAttachment(string: """
        elapsed_seconds=\(Double(elapsed.components.seconds))
        answer_length=\(answerText.utf8.count)
        reasoning_emitted=\(reasoningEmitted)
        input_tokens=\(completion.usage.inputTokens)
        output_tokens=\(completion.usage.outputTokens)
        answer_prefix=\(String(answerText.prefix(120)))
        """)
        summary.name = "live-online-medium-effort"
        summary.lifetime = .keepAlways
        add(summary)

        XCTAssertFalse(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertLessThan(
            elapsed,
            .seconds(60),
            "medium-effort online replies should complete quickly, took \(elapsed)"
        )
    }
}
