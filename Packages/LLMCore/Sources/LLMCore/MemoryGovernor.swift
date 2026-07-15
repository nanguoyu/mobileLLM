// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AppRuntime

/// The fit verdict for a (model, variant) on a device at a given context (DESIGN §2.5).
public enum LLMFit: Sendable, Equatable {
    /// Green — comfortable headroom (peak ≤ 0.70 · ceiling at the requested context).
    case comfortable
    /// Amber — it runs, but you're deep into the budget; `maxContext` is the largest context that
    /// stays under the hard ceiling.
    case tight(maxContext: Int)
    /// Gray — the weights + runtime don't fit at all (no context helps; it's the weights).
    case unsupported

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

/// Resident-only memory planner (DESIGN §1.2 / §2.5). There is NO streaming rung for an LLM: decode
/// is bandwidth-bound at batch-1, so weights must be resident — a model either fits in RAM or it can't
/// run. The only lever is the KV cache.
///
/// `peak = baseResidentBytes + KV(context)`, where `baseResidentBytes = onDiskBytes + runtimeOverhead`.
public enum LLMMemoryGovernor {

    /// Fraction of the ceiling below which a plan is "comfortable" (green).
    private static let greenFraction = 0.70

    /// The usable resident ceiling for a device (DESIGN §1.2):
    ///   • phone ≤ 8.5 GB (the 8 GB 16 Pro) → a hard 5.3 GB (jetsam ~5.5 GB);
    ///   • larger phone (12 GB) → 0.72 · RAM (≈ 8.6 GB);
    ///   • Mac → min(RAM − 4 GB, 0.80 · RAM) — the conservative floor (critique A4).
    public static func residentCeilingBytes(for tier: DeviceTier) -> Int64 {
        if tier.isPhone {
            let gb = Double(tier.physicalMemoryBytes) / 1_000_000_000
            if gb <= 8.5 { return 5_300_000_000 }
            return Int64(Double(tier.physicalMemoryBytes) * 0.72)
        } else {
            return min(tier.physicalMemoryBytes - 4_000_000_000,
                       Int64(Double(tier.physicalMemoryBytes) * 0.80))
        }
    }

    /// Plan a (model, variant) on a device for a target `context`.
    public static func plan(model: LLMModel, variant: LLMVariant,
                            device: DeviceTier, context: Int) -> LLMFit {
        let ceiling = residentCeilingBytes(for: device)
        let base = variant.onDiskBytes + variant.backend.runtimeOverheadBytes

        // Weights + runtime don't fit even at ~0 context → unsupported (it's the weights, not the KV).
        guard base <= ceiling else { return .unsupported }

        let peak = base + model.architecture.attention.kvBytes(tokens: context)
        let green = Int64(greenFraction * Double(ceiling))
        if peak <= green { return .comfortable }

        // Fits, but tightly — report the largest context that stays under the hard ceiling.
        let maxContext = maxContext(base: base, ceiling: ceiling, attention: model.architecture.attention)
        return maxContext > 0 ? .tight(maxContext: maxContext) : .unsupported
    }

    /// The largest context whose peak stays ≤ ceiling, given the per-token KV cost. `base ≤ ceiling`
    /// is guaranteed by the caller, so this is ≥ 0.
    private static func maxContext(base: Int64, ceiling: Int64, attention: AttentionShape) -> Int {
        let perToken = attention.kvBytes(tokens: 1)
        guard perToken > 0 else { return Int.max }
        let headroom = ceiling - base
        return Int(max(0, headroom) / perToken)
    }
}
