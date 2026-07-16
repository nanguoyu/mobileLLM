// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineLlama

/// The engine's public surface that doesn't need a loaded model: the training-context accessor's
/// unloaded contract, and that every `EngineError` carries an actionable, user-facing description. No
/// weights are loaded here (the training-context read short-circuits to nil while unloaded).
final class EngineSurfaceTests: XCTestCase {

    func testModelTrainingContextIsNilBeforeLoad() async {
        let engine = LlamaEngine()
        let trained = await engine.modelTrainingContext
        XCTAssertNil(trained, "with no model loaded there is no training context to report")
        let loaded = await engine.isLoaded
        XCTAssertFalse(loaded)
    }

    func testEveryErrorHasANonEmptyDescription() {
        let cases: [LlamaEngine.EngineError] = [
            .backendUnavailable, .weightsNotFound, .modelLoadFailed, .contextInitFailed,
            .notLoaded, .decodeFailed, .noUserMessage, .contextWindowExceeded,
        ]
        for e in cases {
            let d = e.errorDescription
            XCTAssertNotNil(d, "\(e) must expose an errorDescription")
            XCTAssertFalse(d?.isEmpty ?? true, "\(e) description must not be empty")
        }
    }

    func testLoadFailureDescriptionNamesTheLever() {
        // A3.6: a load failure should point the user at a smaller quantization / freeing memory.
        let d = LlamaEngine.EngineError.modelLoadFailed.errorDescription?.lowercased() ?? ""
        XCTAssertTrue(d.contains("quant"), "load failure should suggest a smaller quantization")
        XCTAssertTrue(d.contains("memory"), "load failure should suggest freeing memory")
    }

    func testContextOverflowDescriptionIsActionable() {
        let d = LlamaEngine.EngineError.contextWindowExceeded.errorDescription?.lowercased() ?? ""
        XCTAssertTrue(d.contains("context"), "overflow message should name the context window")
        XCTAssertTrue(d.contains("system prompt") || d.contains("shorten"), "should name a way out")
    }
}
