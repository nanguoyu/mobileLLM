// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI

/// Codex-style action presentation: readable tool names, one-line concrete previews ("Search: …",
/// "Compute: …"), and approval titles that never leak internal descriptor identities.
@MainActor
final class AgentRunStepPresentationTests: XCTestCase {

    func testReadableToolNamePrettifiesIdentifiers() {
        XCTAssertEqual(AgentRunStore.readableToolName("web_search"), "Web search")
        XCTAssertEqual(AgentRunStore.readableToolName("create_calendar_event"), "Create calendar event")
        XCTAssertEqual(AgentRunStore.readableToolName("calculator"), "Calculator")
    }

    func testActionPreviewForKnownTools() {
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "web_search", argumentsJSON: #"{"query":"current year"}"#),
            "Search: current year"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "calculator", argumentsJSON: #"{"expression":"17+25"}"#),
            "Compute: 17+25"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "remember", argumentsJSON: #"{"text":"The user likes tea."}"#),
            "Remember: The user likes tea."
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "fetch_webpage", argumentsJSON: #"{"url":"https://example.com"}"#),
            "Fetch: https://example.com"
        )
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "create_reminder", argumentsJSON: #"{"title":"Water plants"}"#),
            "Remind: Water plants"
        )
    }

    func testActionPreviewFallsBackToCompactJSONAndEmpty() {
        XCTAssertEqual(
            AgentRunStore.actionPreview(toolName: "unknown_tool", argumentsJSON: #"{"a":{"b":"c"}}"#),
            #"{"a":{"b":"c"}}"#
        )
        XCTAssertEqual(AgentRunStore.actionPreview(toolName: "web_search", argumentsJSON: nil), "")
        XCTAssertEqual(AgentRunStore.actionPreview(toolName: "current_datetime", argumentsJSON: "{}"), "")
    }

    func testApprovalTitleUsesReadableToolName() throws {
        let destination = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://html.duckduckgo.com"
        )
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "builtin:web_search",
            destination: destination,
            dataCategories: [try AgentDataCategory(rawValue: "web.search")],
            payloadDigest: StableDigest.sha256(Data("x".utf8)),
            effects: [.networkRead],
            requiredCapabilities: AgentCapabilitySet([.networkRead]),
            maximumRequestBytes: 64,
            maximumResponseBytes: 1024,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: "Search the web"
        )
        XCTAssertEqual(AgentRunStore.approvalToolDisplayName(plan), "Web search")
    }

    func testApprovalTitleUsesModelNameForOnlineInference() throws {
        let destination = try ExternalDestination(
            kind: .modelProvider,
            normalizedIdentity: "openai.responses:responses-api-key:deepseek-v4-flash"
        )
        let plan = try ExternalOperationPlan(
            kind: .modelProvider,
            subjectID: "openai.responses",
            destination: destination,
            dataCategories: [try AgentDataCategory(rawValue: "model.inference")],
            payloadDigest: StableDigest.sha256(Data("x".utf8)),
            effects: [.externalCommunication],
            requiredCapabilities: AgentCapabilitySet([.externalCommunication]),
            maximumRequestBytes: 64,
            maximumResponseBytes: 1024,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .nonIdempotent,
            userPreview: "Send this conversation to deepseek-v4-flash"
        )
        XCTAssertEqual(AgentRunStore.approvalToolDisplayName(plan), "deepseek-v4-flash")
    }
}
