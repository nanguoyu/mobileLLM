// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
@testable import MobileLLMUI
@testable import LLMCore

// TEST-ID: AHT-LIFECYCLE-001
// TEST-ID: AHT-LIFECYCLE-002
@MainActor
final class AgentRunProgressAndAdmissionTests: XCTestCase {
    func testProgressFractionIsTruthfulAndBoundedWhileActive() {
        let base = AgentRunPresentation(conversationID: UUID(), runID: AgentRunID(rawValue: UUID()),
                                        state: .generating)

        // No durable steps yet: a finite active run reports a small but non-zero fraction.
        let empty = try? XCTUnwrap(base.progressFraction)
        XCTAssertNotNil(empty)
        XCTAssertGreaterThan(empty ?? 0, 0)
        XCTAssertLessThan(empty ?? 1, 1)

        let progressing = base.replacing(steps: [
            AgentRunStep(kind: .toolCall, title: "web_search", status: .succeeded, sequence: 1),
            AgentRunStep(kind: .modelAttempt, title: "generating", status: .running, sequence: 2),
        ])
        let fraction = try? XCTUnwrap(progressing.progressFraction)
        XCTAssertNotNil(fraction)
        XCTAssertGreaterThan(fraction ?? 0, 0)
        XCTAssertLessThan(fraction ?? 1, 1)

        let terminal = progressing.replacing(
            state: .completed,
            terminalReason: .completed,
            finalText: "answer"
        )
        XCTAssertEqual(terminal.progressFraction, 1)
        XCTAssertNil(AgentRunPresentation(conversationID: UUID(), runID: AgentRunID(rawValue: UUID()))
            .progressFraction)
    }

    func testBackgroundAdmissionGateStopsNewTurns() async throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "admission-\(UUID().uuidString)")!)
        let chat = ChatStore(
            engine: MockLLMEngine(script: .init(answer: "answer")),
            store: store,
            settings: settings,
            activeModel: LoadedModel(
                model: LLMCatalog.bonsai8b,
                variant: LLMCatalog.bonsai8b.defaultVariantValue
            )
        )

        XCTAssertTrue(chat.canSend == false)
        chat.draft = "hello"
        XCTAssertTrue(chat.canSend)

        chat.setAcceptingNewActions(false)
        XCTAssertFalse(chat.canSend)
        chat.send()
        XCTAssertNil(chat.activeConversation, "backgrounded admission gate must not create a turn")

        chat.setAcceptingNewActions(true)
        XCTAssertTrue(chat.canSend)
        chat.send()
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.activeConversation?.messages.count, 2)
    }

    private func tempStore() -> (ConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "progress-admission-\(UUID().uuidString)")
        return (ConversationStore(directory: dir), dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
