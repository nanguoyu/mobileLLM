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
                ResponsesAPIConfiguration(baseURL: config.baseURL, apiKey: config.apiKey)
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
        let result = try await AgentModelExecutor().execute(
            provider: provider,
            authorized: authorized
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
}
