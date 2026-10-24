// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI
@testable import LLMCore

// TEST-ID: AHT-WORKFLOW-001
@MainActor
final class ChatStoreWorkflowTests: XCTestCase {
    func testWorkflowMarkerIsPositionIndependentAndTokenBounded() {
        XCTAssertEqual(
            ChatStore.workflowGoal(in: "/workflow deploy Kimi K3 on iPhone"),
            "deploy Kimi K3 on iPhone"
        )
        XCTAssertEqual(
            ChatStore.workflowGoal(in: "deploy Kimi K3 /workflow on iPhone"),
            "deploy Kimi K3 on iPhone"
        )
        XCTAssertEqual(
            ChatStore.workflowGoal(in: "deploy Kimi K3 on iPhone /WORKFLOW"),
            "deploy Kimi K3 on iPhone"
        )
        XCTAssertEqual(ChatStore.workflowGoal(in: "Please run (/workflow) now"), "Please run () now")
        XCTAssertEqual(ChatStore.workflowGoal(in: "/workflow"), "")

        XCTAssertNil(ChatStore.workflowGoal(in: "https://example.com/workflow"))
        XCTAssertNil(ChatStore.workflowGoal(in: "use /workflow-v2 instead"))
        XCTAssertNil(ChatStore.workflowGoal(in: "use /workflowHelper instead"))
        XCTAssertNil(ChatStore.workflowGoal(in: "folder/workflow result"))
    }

    func testWorkflowCommandStartsMessageAnchoredWorkflow() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let workflowDirectory = dir.appendingPathComponent("workflows", isDirectory: true)
        let workflowStore = WorkflowStore(directory: workflowDirectory)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "workflow-\(UUID().uuidString)")!)
        XCTAssertFalse(settings.toolsEnabled, "a workflow without external work must not require tools")
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
        XCTAssertEqual(conversation.title, "research the topic")
        let activityTime = conversation.updatedAt
        let completed = WorkflowSummary(id: try XCTUnwrap(launched?.workflowID), title: "research the topic",
                                        conversationID: conversation.id, status: .completed)
        chat.attachWorkflowRecord(WorkflowMessageRecord(summary: completed), to: message.id)
        XCTAssertEqual(chat.activeConversation?.updatedAt, activityTime, "Reading a projection must not reorder chat history")

        var legacy = conversation
        legacy.title = "New Chat"
        XCTAssertEqual(legacy.displayTitle, "research the topic")
        legacy.title = "My chosen title"
        XCTAssertEqual(legacy.displayTitle, "My chosen title")
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

    func testWorkflowCommandAtEndStartsWorkflowWithMarkerRemoved() async throws {
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
        var launchedGoal: String?
        chat.workflowLaunch = { goal, _, _, _ in launchedGoal = goal }

        chat.draft = "How to deploy Kimi K3 on iPhone 16 Pro /workflow"
        chat.send()

        try await waitUntil { launchedGoal != nil }
        XCTAssertEqual(launchedGoal, "How to deploy Kimi K3 on iPhone 16 Pro")
        XCTAssertEqual(chat.activeConversation?.messages.first?.answer, launchedGoal)
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
        XCTAssertEqual(assistantMessages[0].workflowResultID, workflowID)
        XCTAssertEqual(assistantMessages[0].createdAt, completed.endTime)

        // TEST-ID: AHT-DYNAMIC-UI-002
        // Two cold projections emulate consecutive relaunches. The persisted workflow provenance,
        // not process memory, must suppress both duplicate insertions.
        try await waitForPersistedWorkflowResult(store: store, workflowID: workflowID)
        for relaunch in 1 ... 2 {
            let reloadedWorkflowStore = WorkflowStore(
                directory: dir.appendingPathComponent("wf", isDirectory: true)
            )
            let reloaded = ChatStore(
                engine: MockLLMEngine(script: .init(answer: "unused")),
                store: store,
                settings: AppSettings(defaults: UserDefaults(
                    suiteName: "workflow-relaunch-\(relaunch)-\(UUID().uuidString)"
                )!),
                activeModel: LoadedModel(
                    model: LLMCatalog.bonsai8b,
                    variant: LLMCatalog.bonsai8b.defaultVariantValue
                ),
                workflowStore: reloadedWorkflowStore
            )
            await reloaded.load()
            reloadedWorkflowStore.load()
            let activityTime = try XCTUnwrap(reloaded.conversations.first?.updatedAt)
            var refreshed = completed
            refreshed.aggregated.outputTokens += Int64(relaunch)
            try await reloadedWorkflowStore.save(refreshed)
            XCTAssertEqual(reloaded.conversations.first?.updatedAt, activityTime,
                           "A real metadata refresh must not make an old answer look newly delivered")

            let projected = reloaded.conversations.flatMap(\.messages).filter {
                $0.workflowResultID == workflowID
            }
            XCTAssertEqual(
                projected.count,
                1,
                "relaunch \(relaunch) duplicated the persisted workflow result"
            )
            try await waitForPersistedWorkflowResult(store: store, workflowID: workflowID)
        }
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

    private func waitForPersistedWorkflowResult(
        store: ConversationStore,
        workflowID: UUID
    ) async throws {
        for _ in 0 ..< 200 {
            let count = await store.loadAllLive().flatMap(\.messages).filter {
                $0.workflowResultID == workflowID
            }.count
            if count == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("workflow result provenance was not durably persisted exactly once")
    }
}
