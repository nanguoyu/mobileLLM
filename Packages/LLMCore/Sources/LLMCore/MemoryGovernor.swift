// SPDX-License-Identifier: MIT

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

    /// Fraction of a llama.cpp GGUF's mmap'd weight bytes that counts against the jetsam ceiling.
    /// mmap'd weights are file-backed *clean* pages the OS can reclaim under pressure, unlike MLX's
    /// anonymous/dirty resident weights — so only a portion is truly "hard" resident. An **estimate**
    /// (iOS 18+ residency sets can wire GPU buffers and erase this discount → the experimental hybrid
    /// is never allowed green regardless; see below).
    /// Public so the activation pre-flight computes the SAME engine-aware peak the fit badge shows —
    /// two copies of this constant already diverged once (a model shown amber refused to even try).
    public static let mmapResidentFraction = 0.60

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

    /// Plan a (model, variant) on a device for a target `context`. Engine-aware (DESIGN §1 / §6): the
    /// MLX path is resident-weights (numbers unchanged), the llama.cpp path discounts its mmap'd
    /// weights so the fit is honestly better on memory-tight phones — but never lets the experimental
    /// hybrid GGUF read green.
    public static func plan(model: LLMModel, variant: LLMVariant,
                            device: DeviceTier, context: Int) -> LLMFit {
        switch variant.engine {
        case .mlx:      return planMLX(model: model, variant: variant, device: device, context: context)
        case .llamaCpp: return planLlamaCpp(model: model, variant: variant, device: device, context: context)
        }
    }

    /// Resident-weights MLX planner — the original model, kept byte-for-byte (regression-guarded).
    private static func planMLX(model: LLMModel, variant: LLMVariant,
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

    /// llama.cpp GGUF planner: mmap'd weights are file-backed *clean* pages (not counted in
    /// `phys_footprint` the way MLX's anonymous/dirty buffers are), so only `mmapResidentFraction` of them
    /// counts against the jetsam ceiling — an honest discount that makes GGUF fit better than MLX. The fit
    /// is now purely size-driven: the qwen3_5 hybrid arch is CONFIRMED on mainline llama.cpp (Bonsai-27B
    /// decodes on Metal), so a small hybrid (Qwen3.5-4B) reads comfortably green while a big one (a 16 GB
    /// 27B GGUF) is honestly `.unsupported` on a phone by the weight math alone — no arch special-casing.
    private static func planLlamaCpp(model: LLMModel, variant: LLMVariant,
                                     device: DeviceTier, context: Int) -> LLMFit {
        let ceiling = residentCeilingBytes(for: device)
        let overhead = variant.backend.runtimeOverheadBytes
        let discountedBase = Int64(Double(variant.onDiskBytes) * mmapResidentFraction) + overhead
        let rawBase = variant.onDiskBytes + overhead
        let kv = model.architecture.attention.kvBytes(tokens: context)

        // Supported if the clean-page (discounted) footprint fits — the mmap discount is what lets a big
        // GGUF run on a memory-tight phone at all.
        guard discountedBase <= ceiling else { return .unsupported }

        // Green ONLY if it's comfortable WITHOUT banking on the discount (raw weights fit the green line),
        // so a model that fits only via the clean-page gamble reads honest `.tight`, never a falsely
        // confident green. This is purely size-driven — no arch special-casing.
        let green = Int64(greenFraction * Double(ceiling))
        if rawBase + kv <= green { return .comfortable }

        let maxContext = maxContext(base: discountedBase, ceiling: ceiling, attention: model.architecture.attention)
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
