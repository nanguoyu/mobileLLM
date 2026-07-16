// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// The CJK-aware token estimator (A2.2): CJK/kana/hangul ≈1 token per character, Latin ≈chars/4, mixed
/// strings segmented correctly. A pure heuristic, so assertions bound ranges rather than exact tokenizer
/// output — except the CJK cases, where the ≈1-per-scalar rule is deterministic.
final class TokenEstimateTests: XCTestCase {

    func testEmptyAndWhitespace() {
        XCTAssertEqual(TokenEstimate.tokens(in: ""), 0)
        XCTAssertEqual(TokenEstimate.tokens(in: "   "), 1)   // non-empty → at least one token
    }

    /// Pure English tracks the classic ~chars/4, well below the character count.
    func testPureEnglish() {
        let s = "The quick brown fox jumps over the lazy dog."   // 44 chars
        let t = TokenEstimate.tokens(in: s)
        XCTAssertEqual(t, (s.count + 3) / 4)          // ceil(44/4) = 11
        XCTAssertLessThan(t, s.count / 2)
    }

    /// Pure Chinese is ≈1 token per character — NOT chars/4.
    func testPureChinese() {
        XCTAssertEqual(TokenEstimate.tokens(in: "你好世界"), 4)
        let long = "今天天气很好我们去公园散步吧"   // 14 CJK chars
        XCTAssertEqual(TokenEstimate.tokens(in: long), long.count)
    }

    /// The whole point: the CJK estimate is ~3–4× the naive count/4, which is what let the trim math overrun.
    func testChineseBeatsNaiveQuarter() {
        let s = "你好世界你好世界"   // 8 chars
        XCTAssertEqual(TokenEstimate.tokens(in: s), 8)
        XCTAssertGreaterThan(TokenEstimate.tokens(in: s), max(1, s.count / 4) * 3)
    }

    /// Japanese kana and Korean hangul are wide too.
    func testKanaAndHangul() {
        XCTAssertEqual(TokenEstimate.tokens(in: "こんにちは"), 5)   // 5 hiragana
        XCTAssertEqual(TokenEstimate.tokens(in: "안녕하세요"), 5)   // 5 hangul syllables
    }

    /// A mixed string is segmented: the Latin run is estimated at chars/4, each CJK char at 1.
    func testMixedSegmentsCorrectly() {
        // "Hello " → 6 narrow → ceil(6/4)=2 ; "你好" → 2 wide → total 4.
        XCTAssertEqual(TokenEstimate.tokens(in: "Hello 你好"), 4)
        // A longer mix stays between the pure-English estimate and one-token-per-character.
        let mix = "Please translate 我爱自然语言处理 into English."
        let t = TokenEstimate.tokens(in: mix)
        XCTAssertGreaterThan(t, TokenEstimate.tokens(in: "Please translate  into English."))
        XCTAssertLessThan(t, mix.count)
    }

    /// Emoji don't crash the estimator and count as a small positive number of tokens.
    func testEmoji() {
        XCTAssertEqual(TokenEstimate.tokens(in: "🎉🎊🥳"), 3)   // three single-scalar emoji
        XCTAssertGreaterThan(TokenEstimate.tokens(in: "great job 👍🚀"), 0)
    }
}
