// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
import MLXLMCommon
@testable import LLMEngineMLX

/// Pure mapping tests for `MLXLLMEngine.prepareChat` — the ChatTurn→ChatSession translation. These
/// never load weights or touch Metal; they guard the CRITICAL regression where multi-turn history
/// (and ToolLoop tool results) were dropped down to a single user line.
final class ChatMappingTests: XCTestCase {

    private func assertMessage(_ m: Chat.Message, _ role: Chat.Message.Role, _ content: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.role, role, file: file, line: line)
        XCTAssertEqual(m.content, content, file: file, line: line)
    }

    /// The whole conversation must survive, in order. The trailing two user turns model the ToolLoop
    /// case: a tool result is appended as a fresh user turn after the original question — exactly the
    /// scenario that used to lose everything but the last line.
    func testFullConversationArrivesCompleteAndOrdered() throws {
        let turns = [
            ChatTurn(role: .system, content: "SYS"),
            ChatTurn(role: .user, content: "u1"),
            ChatTurn(role: .assistant, content: "a1"),
            ChatTurn(role: .user, content: "u2"),
            ChatTurn(role: .user, content: "u3"),
        ]
        let chat = try MLXLLMEngine.prepareChat(turns)

        XCTAssertEqual(chat.instructions, "SYS")
        XCTAssertEqual(chat.history.count, 3)
        assertMessage(chat.history[0], .user, "u1")
        assertMessage(chat.history[1], .assistant, "a1")
        assertMessage(chat.history[2], .user, "u2")
        XCTAssertEqual(chat.prompt, "u3")
    }

    /// The app can prepend a second system turn (the auto-compaction breadcrumb). Chat templates model
    /// one system message, so both must fold into `instructions`, in order, without leaking into history.
    func testCoalescesMultipleSystemTurns() throws {
        let turns = [
            ChatTurn(role: .system, content: "You are helpful."),
            ChatTurn(role: .system, content: "Earlier we discussed cats."),
            ChatTurn(role: .user, content: "Continue."),
        ]
        let chat = try MLXLLMEngine.prepareChat(turns)

        XCTAssertEqual(chat.instructions, "You are helpful.\n\nEarlier we discussed cats.")
        XCTAssertTrue(chat.history.isEmpty)
        XCTAssertEqual(chat.prompt, "Continue.")
    }

    /// A single user turn (no prior context) is the common first message: empty history, no system.
    func testSingleTurnHasEmptyHistoryAndNoInstructions() throws {
        let chat = try MLXLLMEngine.prepareChat([ChatTurn(role: .user, content: "Hi")])
        XCTAssertNil(chat.instructions)
        XCTAssertTrue(chat.history.isEmpty)
        XCTAssertEqual(chat.prompt, "Hi")
    }

    /// No user turn to answer ⇒ a typed, surfaced error (not a fresh, empty ChatSession).
    func testThrowsWhenLastTurnIsNotUser() {
        let turns = [
            ChatTurn(role: .system, content: "SYS"),
            ChatTurn(role: .user, content: "u1"),
            ChatTurn(role: .assistant, content: "a1"),
        ]
        XCTAssertThrowsError(try MLXLLMEngine.prepareChat(turns)) {
            XCTAssertEqual($0 as? MLXLLMEngine.EngineError, .noUserMessage)
        }
    }

    func testThrowsWhenEmpty() {
        XCTAssertThrowsError(try MLXLLMEngine.prepareChat([])) {
            XCTAssertEqual($0 as? MLXLLMEngine.EngineError, .noUserMessage)
        }
    }

    /// LocalizedError must yield human text, not an enum dump.
    func testEngineErrorsAreLocalized() {
        XCTAssertFalse(MLXLLMEngine.EngineError.notLoaded.localizedDescription.isEmpty)
        XCTAssertFalse(MLXLLMEngine.EngineError.noUserMessage.localizedDescription.isEmpty)
        let loadMsg = MLXLLMEngine.EngineError.loadFailed(reason: "disk full").localizedDescription
        XCTAssertTrue(loadMsg.contains("disk full"))
    }
}
