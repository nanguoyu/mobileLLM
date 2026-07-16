// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// The streaming state machine (`ChatStore.apply` / `stop`): no existing test observes `chat.streaming?.phase`
/// during a LIVE turn. Here we watch the phase progress warming → thinking → answering, verify the thinking
/// clock starts on the first reasoning token and freezes on the first answer token, confirm Stop moves the
/// phase to `.stopping`, and confirm an error AFTER partial text still commits that partial (never discards)
/// with an error banner. These ordering details regress the disclosure UI without failing any commit-only test.
@MainActor
final class ChatStoreStreamingStateTests: XCTestCase {

    private var mockModel: LoadedModel {
        LoadedModel(model: LLMCatalog.bonsai8b, variant: LLMCatalog.bonsai8b.defaultVariantValue)
    }

    private func makeStore(engine: LLMEngine) -> (ChatStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(component: "chat-stream-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "stream-\(UUID().uuidString)")!)
        let chat = ChatStore(engine: engine, store: store, settings: settings, activeModel: mockModel)
        return (chat, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Phase progression + thinking-clock freeze

    func testPhaseProgressesWarmingThinkingAnsweringAndFreezesThinkingClock() async throws {
        // A slow think→answer stream so each phase lasts long enough to sample deterministically.
        let (chat, dir) = makeStore(engine: MockLLMEngine(script: .init(
            reasoning: String(repeating: "reason ", count: 12),
            answer: String(repeating: "reply ", count: 12),
            chunkSize: 1, chunkDelayNanos: 3_000_000)))
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "go"
        chat.send()
        // Right after send() (before the generation Task runs) the turn is warming.
        XCTAssertEqual(chat.streaming?.phase, .warming, "a turn starts warming, before the first token")

        var phases: [StreamingState.Phase] = [.warming]
        var sawThinkingClockRunning = false
        var sawFrozenDurationWhileAnswering = false
        let deadline = Date().addingTimeInterval(5)
        while chat.isStreaming && Date() < deadline {
            if let s = chat.streaming {
                if phases.last != s.phase { phases.append(s.phase) }
                if s.phase == .thinking, s.thinkingStartedAt != nil { sawThinkingClockRunning = true }
                if s.phase == .answering, s.thinkingDuration != nil { sawFrozenDurationWhileAnswering = true }
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await waitUntilIdle(chat)

        // Order: warming first, then thinking must precede answering.
        XCTAssertEqual(phases.first, .warming)
        let thinkIdx = try XCTUnwrap(phases.firstIndex(of: .thinking), "the reasoning stream enters the thinking phase")
        let answerIdx = try XCTUnwrap(phases.firstIndex(of: .answering), "the answer stream enters the answering phase")
        XCTAssertLessThan(thinkIdx, answerIdx, "thinking precedes answering")

        XCTAssertTrue(sawThinkingClockRunning, "thinkingStartedAt is set while reasoning streams")
        XCTAssertTrue(sawFrozenDurationWhileAnswering, "the thinking duration freezes once the answer starts")

        // Committed message records the honest thinking wall-clock.
        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertNotNil(assistant.thinkingSeconds, "the committed turn persists a thinking duration")
        XCTAssertFalse(assistant.answer.isEmpty)
    }

    // MARK: - Stop moves to the stopping phase

    func testStopMidAnswerEntersStoppingPhaseThenCommitsPartial() async throws {
        let (chat, dir) = makeStore(engine: MockLLMEngine(script: .init(
            reasoning: "r", answer: String(repeating: "word ", count: 300),
            chunkSize: 1, chunkDelayNanos: 2_000_000)))
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "go"
        chat.send()

        // Wait until answer text is actually streaming (we're in the answering phase), then stop.
        let deadline = Date().addingTimeInterval(5)
        while (chat.streaming?.answer.isEmpty ?? true) && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(chat.streaming?.answer.isEmpty ?? true, "some answer streamed before Stop")

        chat.stop()
        // stop() sets the phase synchronously, before the cancelled task commits.
        XCTAssertEqual(chat.streaming?.phase, .stopping, "Stop moves the live turn to the stopping phase")

        try await waitUntilIdle(chat)
        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.stats?.stopReason, .cancelled, "Stop commits with a cancelled stop reason")
        XCTAssertFalse(assistant.answer.isEmpty, "the partial answer is committed, never discarded")
        XCTAssertNil(chat.streaming)
    }

    // MARK: - Error AFTER partial text commits the partial + an error banner

    /// An engine that yields some answer, THEN throws — the partial must still commit (not be discarded as
    /// an empty failure) and an error banner must surface.
    private final class PartialThenThrowEngine: LLMEngine, @unchecked Sendable {
        struct Boom: Error {}
        private let partial: String
        init(partial: String) { self.partial = partial }
        func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {}
        func unload() async {}
        func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
            let partial = self.partial
            return AsyncThrowingStream { cont in
                cont.yield(.answer(partial))
                cont.finish(throwing: Boom())
            }
        }
    }

    func testErrorAfterPartialAnswerCommitsPartialAndBanner() async throws {
        let (chat, dir) = makeStore(engine: PartialThenThrowEngine(partial: "here is a partial reply"))
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "go"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.answer, "here is a partial reply", "the partial that streamed before the error is committed")
        XCTAssertNil(assistant.emptyOutcome, "a non-empty partial is NOT an empty failed/stopped outcome")
        XCTAssertEqual(assistant.stats?.stopReason, .cancelled, "an interrupted turn synthesizes cancelled stats")
        XCTAssertEqual(chat.banner?.kind, .error, "the mid-stream error surfaces an error banner")
        XCTAssertNil(chat.streaming)
    }
}
