// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineLlama

/// The context-overflow turn selector (`LlamaEngine.fitMessages`). It must drop WHOLE oldest non-system
/// turns — never chop tokens off the front — always keeping every system turn and the final user turn, and
/// fail cleanly when even that minimum overflows. Measured with a synthetic per-turn cost so the selection
/// is exercised as a pure function, with no model loaded.
final class ContextFitTests: XCTestCase {

    /// Synthetic token count: one "token" per content character, summed over the kept turns.
    private let cost: ([ChatTurn]) -> Int = { $0.reduce(0) { $0 + $1.content.count } }

    private func sys(_ s: String) -> ChatTurn { ChatTurn(role: .system, content: s) }
    private func usr(_ s: String) -> ChatTurn { ChatTurn(role: .user, content: s) }
    private func asst(_ s: String) -> ChatTurn { ChatTurn(role: .assistant, content: s) }

    // [S=1, AAAA=4 (user), BBBB=4 (assistant), CC=2 (user, final)] → total 11
    private var convo: [ChatTurn] {
        [sys("S"), usr("AAAA"), asst("BBBB"), usr("CC")]
    }

    func testKeepsEverythingWhenItFits() {
        XCTAssertEqual(LlamaEngine.fitMessages(convo, budget: 11, tokenCount: cost), convo)
        XCTAssertEqual(LlamaEngine.fitMessages(convo, budget: 100, tokenCount: cost), convo)
    }

    func testDropsOldestNonSystemTurnFirst() {
        // budget 10 < 11: drop the OLDEST droppable turn (the user "AAAA"), which brings it to 7 ≤ 10.
        // System prefix and the final user turn survive; the newer history is preferred.
        let kept = LlamaEngine.fitMessages(convo, budget: 10, tokenCount: cost)
        XCTAssertEqual(kept, [sys("S"), asst("BBBB"), usr("CC")])
    }

    func testDropsDownToSystemPlusFinalWhenTight() {
        // budget 6: dropping "AAAA" → 7 (still over), then "BBBB" → {S, CC} = 3 ≤ 6.
        let kept = LlamaEngine.fitMessages(convo, budget: 6, tokenCount: cost)
        XCTAssertEqual(kept, [sys("S"), usr("CC")])
    }

    func testExactMinimalBudgetFits() {
        // {S=1, CC=2} = 3: the minimal set fits exactly.
        XCTAssertEqual(LlamaEngine.fitMessages(convo, budget: 3, tokenCount: cost), [sys("S"), usr("CC")])
    }

    func testReturnsNilWhenSystemPlusFinalOverflow() {
        // Even {S, CC} = 3 can't fit in 2 → nil (caller raises .contextWindowExceeded instead of truncating).
        XCTAssertNil(LlamaEngine.fitMessages(convo, budget: 2, tokenCount: cost))
    }

    func testEverySystemTurnIsPreserved() {
        // Two system turns, one mid-history: both must survive a drop.
        let msgs = [sys("S1"), usr("AAAA"), sys("S2"), asst("BBBB"), usr("Q")]   // 2+4+2+4+1 = 13
        let kept = LlamaEngine.fitMessages(msgs, budget: 10, tokenCount: cost)    // drop "AAAA" → 9
        XCTAssertEqual(kept, [sys("S1"), sys("S2"), asst("BBBB"), usr("Q")])
    }

    func testFinalUserTurnIsNeverDropped() {
        // The final turn is the big one; it stays and the older short turn is dropped instead.
        let msgs = [sys("S"), usr("XX"), usr("BIGBIGBIG")]   // 1+2+9 = 12, final = "BIGBIGBIG"
        XCTAssertEqual(LlamaEngine.fitMessages(msgs, budget: 10, tokenCount: cost), [sys("S"), usr("BIGBIGBIG")])
        // If the final turn alone (with system) can't fit, fail rather than drop it.
        XCTAssertNil(LlamaEngine.fitMessages(msgs, budget: 9, tokenCount: cost))
    }

    func testNoDroppableTurnsOverflowsToNil() {
        // Only a system turn and the final user turn exist — nothing is droppable.
        let msgs = [sys("S"), usr("TENCHARSXX")]   // 1 + 10 = 11
        XCTAssertNil(LlamaEngine.fitMessages(msgs, budget: 10, tokenCount: cost))
        XCTAssertEqual(LlamaEngine.fitMessages(msgs, budget: 11, tokenCount: cost), msgs)
    }
}
