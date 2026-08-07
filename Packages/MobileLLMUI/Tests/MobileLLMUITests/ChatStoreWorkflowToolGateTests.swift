// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI
@testable import LLMCore

/// The app-side workflow tool gate flow (spec §33 gap 1): a launcher refusal for missing research
/// tools pauses the send; confirming enables the tools and relaunches with the same stable ids;
/// cancelling rolls the initiating message back and changes nothing.
@MainActor
final class ChatStoreWorkflowToolGateTests: XCTestCase {

    func testGateAppearsAndConfirmRelaunchesWithStableIds() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "gate-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "unused")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            )
        )
        var attempts = 0
        var relaunched: (goal: String, conversationID: UUID, userMessageID: UUID, workflowID: UUID)?
        chat.workflowLaunch = { goal, conversationID, userMessageID, workflowID in
            attempts += 1
            if attempts == 1 {
                throw WorkflowToolPolicyGateError.toolsRequired([.webSearch, .fetchWebpage])
            }
            relaunched = (goal, conversationID, userMessageID, workflowID)
        }

        chat.draft = "/workflow research the topic"
        chat.send()

        try await waitUntil { chat.workflowToolGate != nil }
        let gate = try XCTUnwrap(chat.workflowToolGate)
        XCTAssertEqual(gate.goal, "research the topic")
        XCTAssertEqual(gate.missingTools, [.webSearch, .fetchWebpage])
        let messageBefore = try XCTUnwrap(chat.activeConversation?.messages.first)
        XCTAssertEqual(messageBefore.id, gate.userMessageID)

        chat.confirmWorkflowToolGate()

        try await waitUntil { relaunched != nil }
        XCTAssertEqual(relaunched?.goal, gate.goal)
        XCTAssertEqual(relaunched?.conversationID, gate.conversationID)
        XCTAssertEqual(relaunched?.userMessageID, gate.userMessageID)
        XCTAssertEqual(relaunched?.workflowID, gate.workflowID)
        XCTAssertTrue(settings.toolsEnabled)
        XCTAssertFalse(settings.disabledBuiltInTools.contains(ToolID.webSearch.rawValue))
        XCTAssertFalse(settings.disabledBuiltInTools.contains(ToolID.fetchWebpage.rawValue))
        let policy = try XCTUnwrap(chat.activeConversation?.toolPolicy)
        XCTAssertTrue(policy.masterEnabled)
        let allowed = Set(policy.allowedToolIDs)
        XCTAssertTrue(allowed.contains(WorkflowToolPolicyGate.logicalID(for: .webSearch)))
        XCTAssertTrue(allowed.contains(WorkflowToolPolicyGate.logicalID(for: .fetchWebpage)))
        XCTAssertNil(chat.workflowToolGate)
    }

    func testCancelRollsBackInitiatingMessageAndChangesNothing() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "gate-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "unused")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            )
        )
        var attempts = 0
        chat.workflowLaunch = { _, _, _, _ in
            attempts += 1
            throw WorkflowToolPolicyGateError.toolsRequired([.webSearch])
        }

        chat.draft = "/workflow deploy kimi k3"
        chat.send()
        try await waitUntil { chat.workflowToolGate != nil }
        let gate = try XCTUnwrap(chat.workflowToolGate)
        XCTAssertEqual(chat.activeConversation?.messages.count, 1)

        let toolsBefore = settings.toolsEnabled
        let disabledBefore = settings.disabledBuiltInTools
        chat.cancelWorkflowToolGate()

        XCTAssertNil(chat.workflowToolGate)
        XCTAssertEqual(chat.activeConversation?.messages.count, 0,
                       "cancelling the gate must roll back the initiating message")
        XCTAssertEqual(attempts, 1, "no relaunch may happen after cancel")
        XCTAssertEqual(settings.toolsEnabled, toolsBefore)
        XCTAssertEqual(settings.disabledBuiltInTools, disabledBefore)
    }

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-gate-\(UUID().uuidString)", isDirectory: true)
        return (ConversationStore(directory: dir), dir)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition timed out")
    }
}
