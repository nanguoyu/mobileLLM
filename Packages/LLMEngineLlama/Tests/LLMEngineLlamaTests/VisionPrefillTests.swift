// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineLlama

/// The pure vision-prefill helpers (C1.5): media-marker injection and the per-image context-fit budget.
/// The `mtmd` calls themselves need a loaded model + mmproj (the orchestrator's live gate) and are NOT
/// exercised here — these pin the model-free logic: markers land in the right turns, a no-image prompt is
/// byte-identical to before, and each attached image reserves its token budget in the overflow fitter.
final class VisionPrefillTests: XCTestCase {

    private let marker = "<__media__>"

    private func sys(_ s: String) -> ChatTurn { ChatTurn(role: .system, content: s) }
    private func usr(_ s: String, images: [Data] = []) -> ChatTurn {
        ChatTurn(role: .user, content: s, images: images)
    }
    private func img(_ n: Int) -> Data { Data(repeating: 0xAB, count: n) }

    // MARK: - Marker injection

    /// An image-bearing turn gets exactly one marker (each on its own line) prefixed per attached image,
    /// with the original content preserved after them; role + images pass through unchanged.
    func testInjectPrefixesOneMarkerPerImage() {
        let turn = usr("what is this?", images: [img(1), img(2)])
        let out = LlamaEngine.injectMediaMarkers([turn], marker: marker)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].content, "\(marker)\n\(marker)\nwhat is this?")
        XCTAssertEqual(out[0].role, .user)
        XCTAssertEqual(out[0].images.count, 2, "the images stay attached for the bitmap pass")
    }

    /// Turns without images are returned untouched — only image turns are rewritten.
    func testInjectLeavesTextTurnsUntouched() {
        let convo = [sys("S"), usr("older text"), usr("look", images: [img(4)])]
        let out = LlamaEngine.injectMediaMarkers(convo, marker: marker)
        XCTAssertEqual(out[0], convo[0])                       // system untouched
        XCTAssertEqual(out[1], convo[1])                       // text user turn untouched
        XCTAssertEqual(out[2].content, "\(marker)\nlook")      // image turn gets its marker
    }

    /// With no images anywhere, injection is the identity — so the rendered prompt is byte-for-byte what the
    /// text path builds today (the guarantee that a text conversation is unaffected).
    func testNoImagesIsIdentityAndPromptByteIdentical() {
        let convo = [sys("S"), usr("Hi"), ChatTurn(role: .assistant, content: "Hey"), usr("Bye")]
        XCTAssertEqual(LlamaEngine.injectMediaMarkers(convo, marker: marker), convo)

        let injectedPrompt = LlamaEngine.buildPrompt(
            messages: LlamaEngine.injectMediaMarkers(convo, marker: marker),
            template: .chatML, reasoning: .thinkTags, thinking: true)
        let plainPrompt = LlamaEngine.buildPrompt(messages: convo, template: .chatML,
                                                  reasoning: .thinkTags, thinking: true)
        XCTAssertEqual(injectedPrompt, plainPrompt)
    }

    /// The rendered prompt carries exactly one marker occurrence per attached image, across turns — the
    /// count `mtmd_tokenize` requires to match the bitmap count.
    func testRenderedPromptHasOneMarkerPerImage() {
        let convo = [sys("S"), usr("a", images: [img(1)]), usr("b", images: [img(1), img(1)])]  // 3 images
        let prompt = LlamaEngine.buildPrompt(messages: LlamaEngine.injectMediaMarkers(convo, marker: marker),
                                             template: .chatML, reasoning: .none, thinking: false)
        XCTAssertEqual(prompt.components(separatedBy: marker).count - 1, 3)
    }

    // MARK: - Per-image token budget

    func testImageTokenBudgetIsReserved() {
        XCTAssertEqual(LlamaEngine.imageTokenBudget, 600)
    }

    func testImageTokenCountSumsAcrossTurns() {
        let convo = [sys("S"), usr("a", images: [img(1)]), usr("b", images: [img(1), img(1)])]  // 3 images
        XCTAssertEqual(LlamaEngine.imageTokenCount(convo), 3 * 600)
        XCTAssertEqual(LlamaEngine.imageTokenCount([sys("S"), usr("text")]), 0)
    }

    /// The overflow fitter, fed the same image-aware cost the engine uses (text chars + 600/image), drops an
    /// older turn to make room for an attached image's tokens that a text-only fit would have kept whole.
    func testFitMessagesReservesPerImageTokens() {
        // text cost = 1 char per content char; plus 600 per attached image.
        let cost: ([ChatTurn]) -> Int = { $0.reduce(0) { $0 + $1.content.count } + LlamaEngine.imageTokenCount($0) }
        let convo = [sys("S"), usr("OLD"), ChatTurn(role: .assistant, content: "A"), usr("Q", images: [img(1)])]
        // Text-only cost of the whole convo = 1+3+1+1 = 6; with the image = 606.
        XCTAssertEqual(cost(convo), 606)
        // Budget 605: the image's 600 tokens force dropping the oldest droppable turn ("OLD").
        let kept = LlamaEngine.fitMessages(convo, budget: 605, tokenCount: cost)
        XCTAssertEqual(kept, [sys("S"), ChatTurn(role: .assistant, content: "A"), usr("Q", images: [img(1)])])
        // Without the image the same budget keeps everything (text cost 6 ≤ 605).
        let textConvo = [sys("S"), usr("OLD"), ChatTurn(role: .assistant, content: "A"), usr("Q")]
        XCTAssertEqual(LlamaEngine.fitMessages(textConvo, budget: 605, tokenCount: cost), textConvo)
    }

    /// An image whose reservation cannot fit even after dropping all droppable history overflows to nil (the
    /// caller raises `.contextWindowExceeded`) rather than silently dropping the image.
    func testUnfittableImageOverflowsToNil() {
        let cost: ([ChatTurn]) -> Int = { $0.reduce(0) { $0 + $1.content.count } + LlamaEngine.imageTokenCount($0) }
        let convo = [sys("S"), usr("Q", images: [img(1)])]     // 1 + 1 + 600 = 602, nothing droppable
        XCTAssertNil(LlamaEngine.fitMessages(convo, budget: 500, tokenCount: cost))
    }
}
