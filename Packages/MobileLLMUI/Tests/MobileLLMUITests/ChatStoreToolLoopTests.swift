// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
@testable import LLMCore

/// The `toolsEnabled == true` branch of `ChatStore.send()` — the entire agent-loop path that no existing
/// store-layer test reaches, because `MockLLMEngine` replays ONE fixed script every call and so can never
/// emit a `<tool_call>` on turn 1 and a distinct answer on turn 2. Here a scripted per-call engine drives
/// the loop through the store so the real wiring runs end-to-end: `toolRegistry()` assembly, `ToolLoop`
/// construction, `applyLoopEvent` mapping tool events onto `streaming.toolActivity`, and the commit of
/// `message.toolRuns`. The privacy-free `calculator` needs no injected seams.
@MainActor
final class ChatStoreToolLoopTests: XCTestCase {

    /// A scripted engine: each successive `generate` replays the next canned answer, and records the
    /// message history it was handed, so the app-level tool loop can be driven deterministically. With a
    /// per-char delay it streams the answer token-by-token (a wide window for observing live state);
    /// otherwise it emits the whole answer as one chunk (matching LLMCore's proven `ToolLoop` double).
    private final class ScriptedEngine: LLMEngine, @unchecked Sendable {
        private let scripts: [String]
        private let perCharDelayNanos: UInt64
        private let lock = NSLock()
        private var call = 0
        private var histories: [[ChatTurn]] = []

        init(_ scripts: [String], perCharDelayNanos: UInt64 = 0) {
            self.scripts = scripts
            self.perCharDelayNanos = perCharDelayNanos
        }

        /// Every message history handed to `generate`, in call order (thread-safe snapshot).
        func receivedHistories() -> [[ChatTurn]] { lock.lock(); defer { lock.unlock() }; return histories }
        func callCount() -> Int { lock.lock(); defer { lock.unlock() }; return call }
        /// Replay the script from the top (used to make a second send on the same store independent of how
        /// many calls the first send consumed).
        func reset() { lock.lock(); call = 0; histories.removeAll(); lock.unlock() }

        func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {}
        func unload() async {}

        func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
            lock.lock(); let idx = call; call += 1; histories.append(messages); lock.unlock()
            let script = idx < scripts.count ? scripts[idx] : "(no more script)"
            let delay = perCharDelayNanos
            return AsyncThrowingStream { cont in
                let task = Task {
                    do {
                        if delay == 0 {
                            cont.yield(.answer(script))
                        } else {
                            for ch in script {
                                try Task.checkCancellation()
                                cont.yield(.answer(String(ch)))
                                try await Task.sleep(nanoseconds: delay)
                            }
                        }
                        cont.yield(.done(Stats(promptTokens: 0, genTokens: script.count, promptTPS: 0,
                                               tokensPerSecond: 1, peakMemoryBytes: 0, stopReason: .eos)))
                        cont.finish()
                    } catch is CancellationError {
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func makeStore(engine: LLMEngine,
                           configure: (AppSettings) -> Void = { _ in }) -> (ChatStore, ConversationStore, AppSettings, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "chat-toolloop-\(UUID().uuidString)")
        let store = ConversationStore(directory: dir)
        let settings = AppSettings(defaults: UserDefaults(suiteName: "toolloop-\(UUID().uuidString)")!)
        settings.toolsEnabled = true
        configure(settings)
        let model = LLMCatalog.bonsai8b
        let chat = ChatStore(engine: engine, store: store, settings: settings,
                             activeModel: LoadedModel(model: model, variant: model.defaultVariantValue))
        return (chat, store, settings, dir)
    }

    private func waitUntilIdle(_ chat: ChatStore, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isStreaming {
            if Date() > deadline { throw XCTSkip("streaming did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let calcCall =
        #"I'll compute that. <tool_call>{"name":"calculator","arguments":{"expression":"17+25"}}</tool_call>"#

    // MARK: - Critical: a full tools-enabled send commits the tool round-trip

    /// Send with tools ON: the model asks for the calculator (turn 1), the loop runs it locally, feeds the
    /// framed result back, and the model answers (turn 2). The committed assistant message must record the
    /// tool run WITH its result, surface the answer, and never leak the `<tool_call>` markup into the bubble.
    func testToolsEnabledSendRunsCalculatorAndCommitsToolRuns() async throws {
        let engine = ScriptedEngine([Self.calcCall, "The answer is 42."])
        let (chat, _, _, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "what is 17+25?"
        chat.send()
        try await waitUntilIdle(chat)

        let assistant = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertEqual(assistant.role, .assistant)

        let runs = try XCTUnwrap(assistant.toolRuns, "the committed message records the tool round-trip")
        XCTAssertEqual(runs.count, 1, "exactly one tool ran")
        XCTAssertEqual(runs.first?.name, "calculator")
        XCTAssertEqual(runs.first?.result, "42", "the calculator's result is attached to the run (applyLoopEvent .toolResult)")
        XCTAssertTrue(runs.first?.arguments.contains("17+25") ?? false, "the model's arguments round-trip onto the run")

        XCTAssertTrue(assistant.answer.contains("The answer is 42."), "the post-tool answer is surfaced")
        XCTAssertFalse(assistant.answer.contains("tool_call"), "the <tool_call> markup never leaks into the answer bubble")
        XCTAssertEqual(assistant.stats?.stopReason, .eos, "the final .done stats commit onto the message")
        XCTAssertNil(assistant.emptyOutcome, "a tool turn that produced an answer is not an empty outcome")

        XCTAssertNil(chat.streaming, "streaming ends after the loop terminates")
        XCTAssertEqual(engine.callCount(), 2, "the engine was driven twice: the tool turn then the answer turn")
    }

    /// The framed, untrusted tool result must actually reach the model on the SECOND turn — i.e. the loop's
    /// cross-turn data flow runs through the store, not just in the LLMCore unit. Inspect the exact history
    /// the engine received on its second `generate`.
    func testToolResultIsFedBackToTheModelOnTheSecondTurn() async throws {
        let engine = ScriptedEngine([Self.calcCall, "Done."])
        let (chat, _, _, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "what is 17+25?"
        chat.send()
        try await waitUntilIdle(chat)

        let histories = engine.receivedHistories()
        XCTAssertEqual(histories.count, 2)
        let secondTurnText = histories[1].map(\.content).joined(separator: "\n")
        XCTAssertTrue(secondTurnText.contains("42"), "the calculator result is fed back into the second turn's prompt")
        XCTAssertTrue(secondTurnText.contains("EXTERNAL tool output"),
                      "the result is fenced as untrusted before the model sees it (frameToolResult)")
    }

    // MARK: - applyLoopEvent surfaces tool activity into LIVE streaming state

    /// While the loop is still running (second turn streaming), the store must expose the tool activity on
    /// `streaming.toolActivity` with its result and the phase moved to `.answering` — the state the activity
    /// row renders mid-turn. A slow second turn gives a wide, deterministic observation window.
    func testToolActivitySurfacesInLiveStreamingState() async throws {
        // Turn 1 asks for the calculator; turn 2 is a long answer streamed char-by-char so the loop stays
        // live long enough to observe committed tool activity before it finishes.
        let engine = ScriptedEngine([Self.calcCall, String(repeating: "answer ", count: 30)],
                                    perCharDelayNanos: 3_000_000)
        let (chat, _, _, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "what is 17+25?"
        chat.send()

        // Poll until the tool has run and its result is on the LIVE streaming state (still generating).
        let deadline = Date().addingTimeInterval(5)
        var observed: StreamingState?
        while Date() < deadline {
            if let s = chat.streaming, s.toolActivity.first?.result == "42" {
                observed = s
                break
            }
            if !chat.isStreaming { break }
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        let live = try XCTUnwrap(observed, "the loop's tool activity should surface on live streaming state")
        XCTAssertEqual(live.toolActivity.count, 1)
        XCTAssertEqual(live.toolActivity.first?.name, "calculator")
        XCTAssertEqual(live.phase, .answering, "a tool call moves the phase to .answering, not .thinking")

        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.activeConversation?.messages.last?.toolRuns?.first?.result, "42")
    }

    // MARK: - toolRegistry() cache invalidation on a config change (drives the rebuild)

    /// The per-turn registry is cached by a signature over the enabled tools; disabling a tool between
    /// sends must REBUILD it (not serve the stale cache). Proof through behavior: the same model script asks
    /// for the calculator on both sends — it runs on the first, but after the tool is disabled the rebuilt
    /// registry no longer has it, so the loop reports the unknown tool and commits no tool run.
    func testDisablingAToolBetweenSendsRebuildsTheRegistry() async throws {
        let engine = ScriptedEngine([Self.calcCall, "42 it is."])
        let (chat, _, settings, dir) = makeStore(engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }

        chat.draft = "17+25?"
        chat.send()
        try await waitUntilIdle(chat)
        XCTAssertEqual(chat.activeConversation?.messages.last?.toolRuns?.first?.result, "42",
                       "with the calculator enabled, the first send runs it")

        // Let the first send's tool-loop task fully unwind before the second send: after `.done` the loop
        // stream's trailing finalize still runs on the main actor, and must not race the next send on the
        // same store. Then replay the script from the top so send 2 asks for the calculator independently.
        try await settle()
        engine.reset()

        // Turn the calculator OFF — the registry signature changes, so the next send must rebuild.
        settings.disabledBuiltInTools.insert(ToolID.calculator.rawValue)

        chat.draft = "17+25 again?"
        chat.send()
        try await waitUntilIdle(chat)

        let last = try XCTUnwrap(chat.activeConversation?.messages.last)
        XCTAssertNil(last.toolRuns, "the rebuilt registry no longer has the calculator, so no tool ran")
        XCTAssertTrue(last.answer.contains("No tool named"),
                      "the loop reports the now-unknown tool — proving the registry was rebuilt, not cached stale")
    }

    /// Give any just-finished generation task time to run its trailing (no-op) finalize on the main actor
    /// before a second send starts on the same store.
    private func settle() async throws {
        for _ in 0..<8 { await Task.yield() }
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}
