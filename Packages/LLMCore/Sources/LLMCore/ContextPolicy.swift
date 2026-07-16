// SPDX-License-Identifier: MIT

import Foundation
import AppRuntime

/// What the context-length setting actually means, and what it may legally be.
///
/// Two different ceilings bound it, and conflating them is what makes the setting feel arbitrary:
///
///  1. **The model's native context** (`architecture.nativeContext`) — a hard capability ceiling. Qwen3.5
///     was trained to 256K; a 4K model is a 4K model. Asking for more than this doesn't extend the model,
///     it just degrades it, so we clamp rather than pass it through.
///  2. **This device's RAM** — the ceiling that actually binds. Context is the KV cache, and the KV cache
///     is resident bytes: on an 8 GB phone a 9B model may be trained to 256K and still only fit ~16K.
///
/// So the setting is a real lever — it buys memory and prefill speed, not capability — but it's only
/// meaningful *relative to a model*. Hence: ladder capped by the model, fit computed per rung.
public enum ContextPolicy {

    /// The rungs we offer, in tokens. Powers of two the whole way up; the top rungs only ever appear for
    /// models that were trained that long and devices that can hold it.
    public static let ladder = [2048, 4096, 8192, 16_384, 32_768, 65_536, 131_072, 262_144]

    /// The rungs valid for a model: everything up to its native context, plus the native value itself when
    /// it isn't a power of two (a 40K model should still be able to ask for all 40K).
    public static func options(for model: LLMModel) -> [Int] {
        let native = model.architecture.nativeContext
        var out = ladder.filter { $0 <= native }
        if out.last != native, native > 0 { out.append(native) }
        return out
    }

    /// What the engine is actually given. A setting is a *request*: this is the honest answer after the
    /// model's own ceiling applies. (Explore models are the live case — a community checkpoint can be
    /// 4K-native while the global setting says 32K.)
    public static func effective(requested: Int, model: LLMModel) -> Int {
        max(ladder[0], min(requested, model.architecture.nativeContext))
    }

    /// Whether **this specific context** actually fits.
    ///
    /// Note `LLMFit.isSupported` does NOT answer this: the governor returns `.tight(maxContext:)` for any
    /// plan past the green line, including ones whose peak is far over the hard ceiling — `.tight` means
    /// "the weights fit, and here's the most context you can have", so a rung is only real if it's within
    /// that `maxContext`. Asking `isSupported` instead reports a 256K rung as fine on an 8 GB phone.
    public static func fits(model: LLMModel, variant: LLMVariant, device: DeviceTier, context: Int) -> Bool {
        switch LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: context) {
        case .comfortable: return true
        case .tight(let maxContext): return context <= maxContext
        case .unsupported: return false
        }
    }

    /// The largest rung that reads green for this variant on this device; failing that, the largest that
    /// fits at all; failing that, the floor (nothing smaller is offerable). This is "the device holds ~N".
    public static func largestFitting(model: LLMModel, variant: LLMVariant, device: DeviceTier) -> Int {
        let rungs = options(for: model)
        if let green = rungs.last(where: { LLMMemoryGovernor.plan(model: model, variant: variant,
                                                                  device: device, context: $0) == .comfortable }) {
            return green
        }
        if let ok = rungs.last(where: { fits(model: model, variant: variant, device: device, context: $0) }) {
            return ok
        }
        return rungs.first ?? ladder[0]
    }
}
