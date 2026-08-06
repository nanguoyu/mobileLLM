// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI
@testable import LLMCore

// TEST-ID: AHT-WORKFLOW-001
@MainActor
final class ChatStoreWorkflowTests: XCTestCase {
    func testWorkflowCommandStartsMessageAnchoredWorkflow() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workflowDirectory = dir.appendingPathComponent("workflows", isDirectory: true)
        let workflowStore = WorkflowStore(directory: workflowDirectory)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "workflow-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "unused")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            ),
            workflowStore: workflowStore
        )
        var launched: (goal: String, conversationID: UUID, userMessageID: UUID, workflowID: UUID)?
        chat.workflowLaunch = { goal, conversationID, userMessageID, workflowID in
            launched = (goal, conversationID, userMessageID, workflowID)
            let summary = WorkflowSummary(
                id: workflowID,
                title: goal,
                conversationID: conversationID,
                status: .running
            )
            try await workflowStore.save(summary)
            chat.attachWorkflowRecord(
                WorkflowMessageRecord(summary: summary),
                to: userMessageID
            )
        }

        chat.draft = "/workflow research the topic"
        chat.send()

        try await waitUntil { launched != nil }
        let conversation = try XCTUnwrap(chat.activeConversation)
        let message = try XCTUnwrap(conversation.messages.first)
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.answer, "research the topic")
        XCTAssertEqual(message.workflowRecord?.workflowID, launched?.workflowID)
        XCTAssertEqual(message.workflowRecord?.status, .running)
        XCTAssertTrue(chat.hasRunningWorkflow)
    }

    func testWorkflowCommandWithoutGoalShowsWarningAndSendsNothing() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workflowStore = WorkflowStore(directory: dir.appendingPathComponent("wf", isDirectory: true))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "workflow-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "unused")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            ),
            workflowStore: workflowStore
        )
        var launched = false
        chat.workflowLaunch = { _, _, _, _ in launched = true }

        chat.draft = "/workflow   "
        chat.send()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(launched)
        XCTAssertNil(chat.activeConversation, "an empty /workflow goal must not create a turn")
        XCTAssertNotNil(chat.banner)
    }

    func testWorkflowCompletionProjectsFinalAnswerIntoChat() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workflowStore = WorkflowStore(directory: dir.appendingPathComponent("wf", isDirectory: true))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "workflow-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "unused")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            ),
            workflowStore: workflowStore
        )
        var workflowIDValue: UUID?
        chat.workflowLaunch = { goal, conversationID, userMessageID, workflowID in
            workflowIDValue = workflowID
            let summary = WorkflowSummary(
                id: workflowID,
                title: goal,
                conversationID: conversationID,
                status: .running
            )
            try await workflowStore.save(summary)
            chat.attachWorkflowRecord(
                WorkflowMessageRecord(summary: summary),
                to: userMessageID
            )
        }

        chat.draft = "/workflow research kim k3"
        chat.send()
        try await waitUntil { workflowIDValue != nil }
        let workflowID = try XCTUnwrap(workflowIDValue)

        var completed = try XCTUnwrap(workflowStore.summary(workflowID: workflowID))
        completed.status = .completed
        completed.endTime = Date()
        completed.completedPhaseCount = 1
        completed.totalPhaseCount = 1
        completed.finalAnswer = "Deploy Kimi K3 on iPhone 16 Pro with a 4-bit GGUF and llama.cpp."
        completed.refreshAggregates()
        try await workflowStore.save(completed)

        try await waitUntil {
            chat.activeConversation?.messages.contains {
                $0.role == .assistant
                    && $0.answer.contains("Deploy Kimi K3")
            } ?? false
        }
        let assistantMessages = chat.activeConversation?.messages.filter {
            $0.role == .assistant && !$0.answer.isEmpty
        } ?? []
        XCTAssertEqual(assistantMessages.count, 1, "the final answer must be projected exactly once")
        XCTAssertTrue(assistantMessages[0].answer.contains("llama.cpp"))
    }

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-chat-\(UUID().uuidString)", isDirectory: true)
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
