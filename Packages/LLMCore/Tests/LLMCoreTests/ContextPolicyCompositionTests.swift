// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore
import AppRuntime

/// Composition properties of the context ladder against REAL catalog models + the memory governor — the
/// invariants that must hold across the whole catalog and a sweep of device RAM, not just the single
/// synthetic model the existing `ContextPolicyTests` pins.
final class ContextPolicyCompositionTests: XCTestCase {

    /// For every catalog model the ladder stops at (never exceeds) the checkpoint's native context — asking
    /// for more degrades the model rather than extending it, so no offered rung may sit above it.
    func testOptionsRespectNativeContextForEveryCatalogModel() {
        for model in LLMCatalog.all {
            let native = model.architecture.nativeContext
            let options = ContextPolicy.options(for: model)
            XCTAssertFalse(options.isEmpty, "\(model.id): must offer at least the floor rung")
            XCTAssertLessThanOrEqual(options.max() ?? 0, native,
                                     "\(model.id): no rung may exceed native context \(native)")
            XCTAssertEqual(options.last, native,
                           "\(model.id): the top rung is exactly the native ceiling")
            XCTAssertEqual(options, options.sorted(), "\(model.id): rungs are ascending")
        }
    }

    /// `largestFitting` is monotonic (non-decreasing) in device RAM *within a tier*: more RAM can only hold
    /// the same context or more. NOTE it is deliberately NOT monotonic ACROSS the phone→Mac boundary — a
    /// Mac reserves a fixed OS headroom, so an 8 GB Mac's resident ceiling is below an 8 GB phone's — hence
    /// the sweeps stay inside one tier each.
    func testLargestFittingIsMonotonicInDeviceRAMWithinATier() {
        let model = LLMCatalog.bonsai8b
        let variant = model.defaultVariantValue

        func assertMonotonic(gbFrom: Double, gbTo: Double, isPhone: Bool) {
            var last = -1
            var gb = gbFrom
            while gb <= gbTo + 0.001 {
                let tier = DeviceTier(physicalMemoryBytes: Int64(gb * 1_000_000_000), isPhone: isPhone)
                let fit = ContextPolicy.largestFitting(model: model, variant: variant, device: tier)
                XCTAssertGreaterThanOrEqual(fit, last,
                    "largestFitting must not shrink as RAM grows (isPhone=\(isPhone), \(gb) GB): \(fit) < \(last)")
                XCTAssertLessThanOrEqual(fit, model.architecture.nativeContext,
                    "largestFitting can never exceed the native ceiling")
                last = fit
                gb += 1.0
            }
        }

        assertMonotonic(gbFrom: 4, gbTo: 16, isPhone: true)     // phones
        assertMonotonic(gbFrom: 16, gbTo: 128, isPhone: false)  // Macs
    }

    /// The effective clamp composes with `Sampling` so the value the engine actually receives never exceeds
    /// the model ceiling. `effective` first clamps a requested context to `[floor, native]`; feeding that as
    /// the `Sampling.contextTokenCap` (further min-composed with any user cap) must stay within `native`.
    func testEffectiveComposedWithSamplingNeverExceedsModelCeiling() {
        for model in LLMCatalog.all {
            let native = model.architecture.nativeContext
            let floor = ContextPolicy.ladder[0]
            for requested in [0, 512, 2048, 8192, 100_000, 262_144, 10_000_000] {
                let eff = ContextPolicy.effective(requested: requested, model: model)
                XCTAssertLessThanOrEqual(eff, native, "\(model.id): effective(\(requested)) exceeds native")
                XCTAssertGreaterThanOrEqual(eff, floor, "\(model.id): effective(\(requested)) below floor")

                // The engine is handed `eff` as its context cap; compose with an arbitrary user-set cap.
                let sampling = Sampling(contextTokenCap: eff)
                for userCap in [1024, 8192, native, native * 8] {
                    let engineCap = min(sampling.contextTokenCap, userCap)
                    XCTAssertLessThanOrEqual(engineCap, native,
                        "\(model.id): composed engine cap (\(engineCap)) must stay within native \(native)")
                }
            }
        }
    }

    /// `effective` is idempotent — clamping an already-clamped value is a no-op — so re-applying the policy
    /// (e.g. a model switch re-running it) never drifts.
    func testEffectiveIsIdempotent() {
        for model in LLMCatalog.all {
            for requested in [512, 4096, 50_000, 262_144, 9_000_000] {
                let once = ContextPolicy.effective(requested: requested, model: model)
                let twice = ContextPolicy.effective(requested: once, model: model)
                XCTAssertEqual(once, twice, "\(model.id): effective must be idempotent at \(requested)")
            }
        }
    }
}
