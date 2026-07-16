// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineApple

/// `Sampling` → `GenerationOptions`. The framework's sampling mode is an EITHER/OR (top-k XOR nucleus)
/// while ours carries both, so exactly one survives — these pin WHICH, and pin that the knobs with no
/// equivalent are dropped rather than faked onto something that isn't them.
final class SamplingPlanTests: XCTestCase {

    /// The shipped defaults (temperature 0.7, top-p 0.95, top-k 20): nucleus wins, temperature passes
    /// through, and the token cap is forwarded.
    func testDefaultsPreferNucleus() {
        let plan = AppleChatMapping.plan(for: Sampling())
        XCTAssertEqual(plan.sampling, .nucleus(0.95, seed: nil))
        XCTAssertEqual(plan.temperature, 0.7)
        XCTAssertEqual(plan.maximumResponseTokens, 1024)
    }

    /// Temperature 0 means "don't sample" — say that with `.greedy`, and don't also hand over a 0
    /// temperature alongside a random sampler.
    func testZeroTemperatureIsGreedy() {
        var params = Sampling()
        params.temperature = 0
        let plan = AppleChatMapping.plan(for: params)
        XCTAssertEqual(plan.sampling, .greedy)
        XCTAssertNil(plan.temperature, "a greedy plan must not also carry a temperature")
    }

    /// A top-p that constrains nothing (1.0) falls back to top-k, which does.
    func testTopPOfOneFallsBackToTopK() {
        var params = Sampling()
        params.topP = 1
        params.topK = 40
        XCTAssertEqual(AppleChatMapping.plan(for: params).sampling, .topK(40, seed: nil))
    }

    /// Neither knob constrains anything → leave sampling to the framework rather than inventing a mode.
    func testUnconstrainedSamplingIsAutomatic() {
        var params = Sampling()
        params.topP = 1
        params.topK = 0
        XCTAssertEqual(AppleChatMapping.plan(for: params).sampling, .automatic)
    }

    /// The seed rides along on whichever random mode is chosen (the framework takes it per-mode).
    func testSeedIsForwardedOnBothRandomModes() {
        var params = Sampling()
        params.seed = 42
        XCTAssertEqual(AppleChatMapping.plan(for: params).sampling, .nucleus(0.95, seed: 42))

        params.topP = 1
        params.topK = 10
        XCTAssertEqual(AppleChatMapping.plan(for: params).sampling, .topK(10, seed: 42))
    }

    /// `maxTokens <= 0` is our "no cap"; the framework spells that `nil`, not 0 (which would mean
    /// "generate nothing").
    func testNoTokenCapBecomesNil() {
        var params = Sampling()
        params.maxTokens = 0
        XCTAssertNil(AppleChatMapping.plan(for: params).maximumResponseTokens)

        params.maxTokens = 512
        XCTAssertEqual(AppleChatMapping.plan(for: params).maximumResponseTokens, 512)
    }

    /// The knobs the framework has NO equivalent for must not leak into the plan by being quietly mapped
    /// onto something else. The plan carries exactly three fields; changing only these knobs must not
    /// change it at all.
    func testKnobsWithoutAnEquivalentAreDropped() {
        let baseline = AppleChatMapping.plan(for: Sampling())
        var params = Sampling()
        params.repetitionPenalty = 1.5   // no equivalent: the OS owns decoding
        params.thinking = false          // no equivalent: the system model has no <think> convention
        params.contextTokenCap = 128     // no equivalent: the session owns its context window
        params.kvBits = 8                // no equivalent: the KV cache is the OS's, not ours
        params.quantizedKVStart = 999    // ditto
        XCTAssertEqual(AppleChatMapping.plan(for: params), baseline,
                       "a knob with no equivalent must be dropped, never faked onto another field")
    }
}
