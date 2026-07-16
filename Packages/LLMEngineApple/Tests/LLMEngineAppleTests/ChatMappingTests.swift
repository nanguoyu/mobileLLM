// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineApple

/// `[ChatTurn]` → the session's inputs. The same contract `MLXLLMEngine.prepareChat` holds (and its
/// ChatMappingTests pin): every turn survives, in order, with its role — dropping history here is how a
/// multi-turn chat silently becomes a one-shot.
final class ChatMappingTests: XCTestCase {

    private func user(_ s: String) -> ChatTurn { ChatTurn(role: .user, content: s) }
    private func assistant(_ s: String) -> ChatTurn { ChatTurn(role: .assistant, content: s) }
    private func system(_ s: String) -> ChatTurn { ChatTurn(role: .system, content: s) }

    // MARK: - Instructions

    func testSystemTurnBecomesInstructions() throws {
        let chat = try AppleChatMapping.prepareChat([system("You are terse."), user("Hi")])
        XCTAssertEqual(chat.instructions, "You are terse.")
        XCTAssertEqual(chat.prompt, "Hi")
        XCTAssertTrue(chat.history.isEmpty)
    }

    /// The app can emit more than one system turn (the system prompt plus an auto-compaction breadcrumb).
    /// A session takes ONE instructions entry, so they coalesce in order — none may be dropped.
    func testMultipleSystemTurnsCoalesceInOrder() throws {
        let chat = try AppleChatMapping.prepareChat([
            system("You are terse."), user("Hi"), assistant("Hey"),
            system("Earlier context was summarised."), user("Again?"),
        ])
        XCTAssertEqual(chat.instructions, "You are terse.\n\nEarlier context was summarised.")
    }

    func testNoSystemTurnMeansNoInstructions() throws {
        let chat = try AppleChatMapping.prepareChat([user("Hi")])
        XCTAssertNil(chat.instructions)
    }

    /// An empty system turn contributes nothing rather than a stray blank line.
    func testEmptySystemTurnsAreIgnored() throws {
        let chat = try AppleChatMapping.prepareChat([system(""), user("Hi")])
        XCTAssertNil(chat.instructions)
    }

    // MARK: - History

    /// The FULL prior conversation is kept, in order, with roles preserved — and the system turns are not
    /// smuggled back into it (they're already in `instructions`).
    func testFullHistoryIsPreservedWithRoles() throws {
        let chat = try AppleChatMapping.prepareChat([
            system("Be brief."),
            user("one"), assistant("two"), user("three"), assistant("four"),
            user("five"),
        ])
        XCTAssertEqual(chat.prompt, "five")
        XCTAssertEqual(chat.history, [user("one"), assistant("two"), user("three"), assistant("four")])
        XCTAssertFalse(chat.history.contains { $0.role == .system })
    }

    /// The ToolLoop appends tool results as ordinary turns; consecutive same-role turns must survive as-is.
    func testConsecutiveSameRoleTurnsSurvive() throws {
        let chat = try AppleChatMapping.prepareChat([
            user("q"), assistant("calling a tool"), assistant("tool said 42"), user("so?"),
        ])
        XCTAssertEqual(chat.history, [user("q"), assistant("calling a tool"), assistant("tool said 42")])
        XCTAssertEqual(chat.prompt, "so?")
    }

    // MARK: - The final turn

    func testLastTurnIsThePrompt() throws {
        let chat = try AppleChatMapping.prepareChat([user("first"), assistant("reply"), user("last")])
        XCTAssertEqual(chat.prompt, "last")
        XCTAssertEqual(chat.history.count, 2)
    }

    /// Nothing to answer: no user turn at all.
    func testEmptyTurnsThrows() {
        XCTAssertThrowsError(try AppleChatMapping.prepareChat([])) { error in
            XCTAssertEqual(error as? AppleEngineError, .noUserMessage)
        }
    }

    /// System turns alone are not a question.
    func testSystemOnlyThrows() {
        XCTAssertThrowsError(try AppleChatMapping.prepareChat([system("You are terse.")])) { error in
            XCTAssertEqual(error as? AppleEngineError, .noUserMessage)
        }
    }

    /// A history ending on the assistant has nothing to answer — that's a caller bug, not an empty prompt.
    func testTrailingAssistantTurnThrows() {
        XCTAssertThrowsError(try AppleChatMapping.prepareChat([user("hi"), assistant("hello")])) { error in
            XCTAssertEqual(error as? AppleEngineError, .noUserMessage)
        }
    }

    /// Images are dropped, not an error: this API surface takes no image input, and the composer only
    /// offers images for a vision variant (llama.cpp + mmproj), so none reaches this engine. The TEXT of
    /// such a turn must still come through.
    func testImageAttachmentsAreIgnoredButTextSurvives() throws {
        let withImage = ChatTurn(role: .user, content: "what is this?", images: [Data([0xFF, 0xD8])])
        let chat = try AppleChatMapping.prepareChat([withImage])
        XCTAssertEqual(chat.prompt, "what is this?")
    }
}
