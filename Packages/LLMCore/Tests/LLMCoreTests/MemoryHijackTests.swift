// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore
import AppRuntime

/// A turn becomes remember-only when the user is read as asking for something to be saved: no other tool is
/// advertised, and a failed save used to replace the reply outright. These pin the two ways that went wrong
/// — an over-broad trigger, and an answer traded away for a bookkeeping notice.
final class MemoryHijackTests: XCTestCase {

    private actor Store: MemoryStoring {
        private var facts: [MemoryFact] = []
        func save(_ text: String, source: MemoryFact.Source) async throws -> MemoryFact {
            let f = MemoryFact(text: text, source: source); facts.append(f); return f
        }
        func saveIfAbsent(_ text: String, source: MemoryFact.Source) async throws -> MemorySaveResult {
            .saved(try await save(text, source: source))
        }
        func list() async -> [MemoryFact] { facts }
        func update(id: String, text: String) async throws {}
        func delete(id: String) async throws {}
        func deleteAll() async throws {}
    }

    private func answer(to prompt: String, script: [String]) async throws -> String {
        let engine = TurnScriptedEngine(script)
        let registry = ToolRegistry.assemble(config: .default, memoryStore: Store(),
                                             eventStore: nil, locationProvider: nil)
        let loop = ToolLoop(engine: engine, registry: registry,
                            now: Date(timeIntervalSince1970: 1_784_000_000))
        var text = ""
        for try await event in loop.run(messages: [ChatTurn(role: .user, content: prompt)],
                                        params: Sampling()) {
            switch event {
            case .answer(let s): text += s
            case .discardAnswer: text = ""
            default: break
            }
        }
        return text
    }

    // MARK: The trigger

    /// "别忘了…" is nearly always an instruction about the REPLY, not a request to store a fact. Treating it
    /// as a memory request made every such turn remember-only, so the question the user actually asked went
    /// unanswered — the whole answer replaced by a memory notice.
    func testDontForgetIsAnInstructionNotAMemoryRequest() async throws {
        let text = try await answer(to: "17+25 等于几？别忘了用中文回答",
                                    script: ["42。"])
        XCTAssertTrue(text.contains("42"), "the real question must still be answered, got: \(text)")
        XCTAssertFalse(text.contains("couldn't save"), "no memory machinery should engage here")
    }

    func testEnglishDontForgetIsAlsoJustAnInstruction() async throws {
        let text = try await answer(to: "What is 17+25? Don't forget the units.",
                                    script: ["42 units."])
        XCTAssertTrue(text.contains("42"), "got: \(text)")
    }

    /// An explicit request still engages memory — narrowing must not disable the feature.
    func testAnExplicitSaveRequestStillRequiresTheTool() async throws {
        let text = try await answer(
            to: "请记住我住在南京",
            script: [#"<tool_call>{"name":"remember","arguments":{"text":"The user lives in Nanjing"}}</tool_call>"#,
                     "好的，我记住了。"])
        XCTAssertTrue(text.contains("记住"), "an explicit request still saves and confirms, got: \(text)")
    }

    // MARK: The answer must survive a failed save

    /// A save-request turn can also carry a real question. When the save fails, the answer to that question
    /// is still worth having — trading it for a bookkeeping notice makes the user pay twice.
    func testAFailedSaveKeepsARealAnswerAndAppendsTheNotice() async throws {
        let text = try await answer(
            to: "请记住我住在南京，另外 17+25 等于几？",
            script: ["42。", "42。"])
        XCTAssertTrue(text.contains("42"),
                      "the answer to the user's actual question must survive, got: \(text)")
        XCTAssertTrue(text.contains("couldn't save") || text.contains("Nothing was saved"),
                      "and the failed save must still be stated, got: \(text)")
    }

    /// The opposite case, and why the rule isn't simply "always keep the prose": when the discarded text IS
    /// the false success claim, surfacing it would tell the user their fact was saved directly above a
    /// notice saying it wasn't. Nothing is better than a lie.
    func testAFalseSuccessClaimIsNotSurfaced() async throws {
        let text = try await answer(to: "请记住我住在南京",
                                    script: ["好的，我已经记住了。", "好的，我已经记住了。"])
        XCTAssertFalse(text.contains("已经记住"), "the false claim must not reach the user, got: \(text)")
        XCTAssertTrue(text.contains("couldn't save") || text.contains("Nothing was saved"))
    }
}
