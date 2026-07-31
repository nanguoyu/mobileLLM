// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// A reasoning-only EOS or token limit gets one answer-only completion pass. This suite pins the boundary
/// conditions: exactly one retry, no thinking/tools on that pass, original reasoning/time retained, and no
/// recovery at all for cancellation or errors.
@MainActor
final class ChatStoreAnswerRecoveryTests: XCTestCase {

    private final class RecoveryEngine: LLMEngine, @unchecked Sendable {
        enum FirstEnd: Equatable { case eos, maxTokens, error }
        enum SecondPass { case answer(String), empty }
        struct Invocation: Sendable {
            let messages: [ChatTurn]
            let params: Sampling
        }
        struct Boom: Error {}

        private let firstEnd: FirstEnd
        private let secondPass: SecondPass
        private let firstDelayNanos: UInt64
        private let secondDelayNanos: UInt64
        private let lock = NSLock()
        private var call = 0
        private var recorded: [Invocation] = []

        init(firstEnd: FirstEnd = .eos, secondPass: SecondPass,
             firstDelayNanos: UInt64 = 70_000_000,
             secondDelayNanos: UInt64 = 0) {
            self.firstEnd = firstEnd
            self.secondPass = secondPass
            self.firstDelayNanos = firstDelayNanos
            self.secondDelayNanos = secondDelayNanos
        }

        func invocations() -> [Invocation] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {}
        func unload() async {}

        func generate(messages: [ChatTurn], params: Sampling)
            -> AsyncThrowingStream<EngineDelta, Error> {
            lock.lock()
            let index = call
            call += 1
            recorded.append(Invocation(messages: messages, params: params))
            lock.unlock()
            let firstEnd = self.firstEnd
            let secondPass = self.secondPass
            let firstDelay = firstDelayNanos
            let secondDelay = secondDelayNanos

            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        if index == 0 {
                            continuation.yield(.reasoning("ORIGINAL_PRIVATE_REASONING"))
                            try await Task.sleep(nanoseconds: firstDelay)
                            switch firstEnd {
                            case .eos:
                                continuation.yield(.done(Self.stats(tokens: 3, stopReason: .eos)))
                            case .maxTokens:
                                continuation.yield(.done(Self.stats(tokens: 3, stopReason: .maxTokens)))
                            case .error:
                                throw Boom()
                            }
                        } else {
                            if secondDelay > 0 { try await Task.sleep(nanoseconds: secondDelay) }
                            if case .answer(let answer) = secondPass {
                                continuation.yield(.answer(answer))
                            }
                            continuation.yield(.done(Self.stats(tokens: 2)))
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private static func stats(tokens: Int, stopReason: StopReason = .eos) -> Stats {
            Stats(promptTokens: 1, genTokens: tokens, promptTPS: 1,
                  tokensPerSecond: 1, peakMemoryBytes: 0, stopReason: stopReason)
        }
    }

    private func makeStore(engine: LLMEngine) -> (ChatStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "answer-recovery-\(UUID().uuidString)")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "answer-recovery-\(UUID().uuidString)")!)
        settings.toolsEnabled = false
        let model = LLMCatalog.bonsai8b
        let chat = ChatStore(engine: engine, store: ConversationStore(directory: dir), settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue))
        chat.thinkingEnabled = true
        return (chat, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { XCTFail("generation did not finish"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testReasoningOnlyEOSRunsExactlyOneAnswerOnlyPassAndKeepsReasoning() async throws {
        let engine = RecoveryEngine(secondPass: .answer("FINAL_VISIBLE_ANSWER"),
                                    secondDelayNanos: 80_000_000)
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "give me the result"
        chat.send()

        let finishingDeadline = Date().addingTimeInterval(3)
        var finishingDuration: TimeInterval?
        while Date() < finishingDeadline {
            if chat.streaming?.warmingNote == "Finishing answer…" {
                finishingDuration = chat.streaming?.thinkingDuration
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let frozenDuration = try XCTUnwrap(finishingDuration,
                                           "the same row should surface its answer-only finishing pass")
        XCTAssertGreaterThan(frozenDuration, 0.04)
        XCTAssertEqual(chat.streaming?.reasoning, "ORIGINAL_PRIVATE_REASONING")

        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.answer, "FINAL_VISIBLE_ANSWER")
        XCTAssertEqual(assistant.reasoning, "ORIGINAL_PRIVATE_REASONING")
        XCTAssertEqual(assistant.thinkingSeconds ?? -1, frozenDuration, accuracy: 0.03,
                       "the recovery pass must not restart or replace the first reasoning clock")
        XCTAssertNil(assistant.emptyOutcome)

        let calls = engine.invocations()
        XCTAssertEqual(calls.count, 2, "one initial pass plus exactly one recovery pass")
        XCTAssertTrue(calls[0].params.thinking)
        XCTAssertFalse(calls[1].params.thinking, "the recovery pass is explicitly answer-only")
        XCTAssertEqual(calls[1].params.maxTokens, 384,
                       "the one recovery pass is bounded even if the model ignores thinking=false")
        XCTAssertTrue(calls[1].messages.first(where: { $0.role == .system })?.content
            .contains("Output only the final answer") == true)
    }

    func testSecondReasoningOnlyEOSDoesNotLoopAndCommitsNoReply() async throws {
        let engine = RecoveryEngine(secondPass: .empty)
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "answer this"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(engine.invocations().count, 2, "an empty recovery result is terminal, never recursive")
        XCTAssertEqual(assistant.emptyOutcome, .noReply)
        XCTAssertTrue(assistant.answer.isEmpty)
        XCTAssertEqual(assistant.reasoning, "ORIGINAL_PRIVATE_REASONING")
        XCTAssertNotNil(assistant.thinkingSeconds)
        XCTAssertNil(assistant.stats)
    }

    func testReasoningOnlyMaxTokensRunsExactlyOneAnswerOnlyPass() async throws {
        let engine = RecoveryEngine(firstEnd: .maxTokens,
                                    secondPass: .answer("RECOVERED_AFTER_TOKEN_LIMIT"))
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "finish the answer"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.answer, "RECOVERED_AFTER_TOKEN_LIMIT")
        XCTAssertEqual(assistant.reasoning, "ORIGINAL_PRIVATE_REASONING")
        XCTAssertNil(assistant.emptyOutcome)

        let calls = engine.invocations()
        XCTAssertEqual(calls.count, 2, "a token-limited reasoning pass gets exactly one recovery")
        XCTAssertTrue(calls[0].params.thinking)
        XCTAssertFalse(calls[1].params.thinking)
        XCTAssertEqual(calls[1].params.maxTokens, 384)
        XCTAssertTrue(calls[1].messages.first(where: { $0.role == .system })?.content
            .contains("Output only the final answer") == true)
    }

    func testReasoningOnlyMaxTokensWithEmptyRecoveryDoesNotLoopAndCommitsNoReply() async throws {
        let engine = RecoveryEngine(firstEnd: .maxTokens, secondPass: .empty)
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "finish this"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(engine.invocations().count, 2,
                       "an empty token-limit recovery is terminal, never recursive")
        XCTAssertEqual(assistant.emptyOutcome, .noReply)
        XCTAssertTrue(assistant.answer.isEmpty)
        XCTAssertEqual(assistant.reasoning, "ORIGINAL_PRIVATE_REASONING")
        XCTAssertNotNil(assistant.thinkingSeconds)
        XCTAssertNil(assistant.stats)
    }

    func testCancellationDuringFirstReasoningNeverStartsRecovery() async throws {
        let engine = RecoveryEngine(secondPass: .answer("must not run"), firstDelayNanos: 1_000_000_000)
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "stop this"
        chat.send()
        let deadline = Date().addingTimeInterval(2)
        while chat.streaming?.reasoning.isEmpty != false && Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        chat.stop()
        try await waitUntilIdle(chat)

        XCTAssertEqual(engine.invocations().count, 1)
        XCTAssertEqual(chat.activeConversation?.messages.last?.emptyOutcome, .stopped)
    }

    func testErrorAfterFirstReasoningNeverStartsRecovery() async throws {
        let engine = RecoveryEngine(firstEnd: .error, secondPass: .answer("must not run"))
        let (chat, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "fail this"
        chat.send()
        try await waitUntilIdle(chat)

        XCTAssertEqual(engine.invocations().count, 1)
        XCTAssertEqual(chat.activeConversation?.messages.last?.emptyOutcome, .failed)
        XCTAssertEqual(chat.activeConversation?.messages.last?.reasoning, "ORIGINAL_PRIVATE_REASONING")
        XCTAssertEqual(chat.banner?.kind, .error)
    }
}
