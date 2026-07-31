// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
import AppRuntime
@testable import LLMEngineLlama

private final class LlamaGovernanceProbe: GenerationControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints = 0
    var checkpointCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints
    }
    var isPaused: Bool { false }
    var isCancelled: Bool { false }
    func pause() {}
    func resume() {}
    func cancel() {}
    private func recordCheckpoint() {
        lock.lock()
        checkpoints += 1
        lock.unlock()
    }
    func checkpoint() async throws { recordCheckpoint() }
}

private struct LlamaNominalThermal: ThermalGoverning {
    func throttleIfNeeded(onCooling: (@Sendable () -> Void)?) async throws {}
}

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
            .visionUnavailable, .imageDecodeFailed,
        ]
        for e in cases {
            let d = e.errorDescription
            XCTAssertNotNil(d, "\(e) must expose an errorDescription")
            XCTAssertFalse(d?.isEmpty ?? true, "\(e) description must not be empty")
        }
    }

    /// The vision errors name the actual lever: re-download to get the projector / send text only, and a
    /// valid image format.
    func testVisionErrorsAreActionable() {
        let unavailable = LlamaEngine.EngineError.visionUnavailable.errorDescription?.lowercased() ?? ""
        XCTAssertTrue(unavailable.contains("image"), "visionUnavailable should mention images")
        XCTAssertTrue(unavailable.contains("re-download") || unavailable.contains("text"),
                      "visionUnavailable should name a way out")
        let decode = LlamaEngine.EngineError.imageDecodeFailed.errorDescription?.lowercased() ?? ""
        XCTAssertTrue(decode.contains("jpeg") || decode.contains("png") || decode.contains("image"),
                      "imageDecodeFailed should name the accepted formats")
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

    func testGenerateActuallyEntersInjectedGovernanceBeforeEngineState() async {
        let probe = LlamaGovernanceProbe()
        let engine = LlamaEngine(governanceFactory: {
            GenerationGovernance(control: probe, thermalGovernor: LlamaNominalThermal())
        })
        let stream = engine.generate(
            messages: [ChatTurn(role: .user, content: "hello")],
            params: Sampling())

        do {
            for try await _ in stream {}
            XCTFail("an unloaded engine must fail")
        } catch let error as LlamaEngine.EngineError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("expected notLoaded, got \(error)")
        }

        XCTAssertEqual(probe.checkpointCount, 1,
                       "the engine must enter the run's cooperative governance before touching state")
    }
}
