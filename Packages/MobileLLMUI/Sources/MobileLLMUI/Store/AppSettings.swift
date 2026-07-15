// SPDX-License-Identifier: MIT

import Foundation
import Observation
import AppRuntime
import LLMCore

/// User preferences (DESIGN §4 Settings): the default model, chat behavior, sampling, and appearance.
/// `@Observable` so SwiftUI bindings drive it directly; changes persist to `UserDefaults` as one small
/// Codable snapshot (chat data itself lives in files — DESIGN §2.4).
@MainActor
@Observable
public final class AppSettings {

    // MARK: Model
    public var defaultModelID: String { didSet { persist() } }
    /// Which inference engine to prefer (Auto = greenest fit; or pin MLX / llama.cpp).
    public var enginePreference: EnginePreference { didSet { persist() } }

    // MARK: Behavior
    public var systemPrompt: String { didSet { persist() } }
    public var thinkingDefault: Bool { didSet { persist() } }
    public var thinkingDisplay: ThinkingDisplayMode { didSet { persist() } }

    // MARK: Sampling
    public var temperature: Double { didSet { persist() } }
    public var topP: Double { didSet { persist() } }
    public var topK: Int { didSet { persist() } }
    public var repetitionPenalty: Double { didSet { persist() } }
    public var maxTokens: Int { didSet { persist() } }
    public var contextLength: Int { didSet { persist() } }
    /// KV-cache quantization width; 0 = unquantized (advanced).
    public var kvBits: Int { didSet { persist() } }

    // MARK: Appearance
    public var appearance: AppearanceMode { didSet { persist() } }

    private let defaults: UserDefaults
    private let key = "mobileLLM.settings.v1"
    /// Suppresses `persist()` during the initial load so `didSet` doesn't re-write while decoding.
    private var loading = true

    public init(defaults: UserDefaults = .standard,
                fallbackDefaultModelID: String = "bonsai-8b") {
        self.defaults = defaults
        let snap = Self.loadSnapshot(from: defaults, key: key)
        defaultModelID = snap?.defaultModelID ?? fallbackDefaultModelID
        enginePreference = snap?.enginePreference ?? .auto
        systemPrompt = snap?.systemPrompt ?? ""
        thinkingDefault = snap?.thinkingDefault ?? true
        thinkingDisplay = snap?.thinkingDisplay ?? .autoCollapse
        temperature = snap?.temperature ?? 0.7
        topP = snap?.topP ?? 0.95
        topK = snap?.topK ?? 20
        repetitionPenalty = snap?.repetitionPenalty ?? 1.05
        maxTokens = snap?.maxTokens ?? 1024
        contextLength = snap?.contextLength ?? 8192
        kvBits = snap?.kvBits ?? 4
        appearance = snap?.appearance ?? .system
        loading = false
    }

    /// Build the engine `Sampling` from the current settings + a per-turn thinking override.
    public func sampling(thinking: Bool) -> Sampling {
        Sampling(temperature: temperature, topP: topP, topK: topK,
                 repetitionPenalty: repetitionPenalty, maxTokens: maxTokens, thinking: thinking,
                 contextTokenCap: contextLength, kvBits: kvBits)
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var defaultModelID: String
        /// Optional so an older persisted snapshot (pre-engine-picker) still decodes; defaults to `.auto`.
        var enginePreference: EnginePreference?
        var systemPrompt: String
        var thinkingDefault: Bool
        var thinkingDisplay: ThinkingDisplayMode
        var temperature: Double
        var topP: Double
        var topK: Int
        var repetitionPenalty: Double
        var maxTokens: Int
        var contextLength: Int
        var kvBits: Int
        var appearance: AppearanceMode
    }

    private func persist() {
        guard !loading else { return }
        let snap = Snapshot(defaultModelID: defaultModelID, enginePreference: enginePreference,
                            systemPrompt: systemPrompt,
                            thinkingDefault: thinkingDefault, thinkingDisplay: thinkingDisplay,
                            temperature: temperature, topP: topP, topK: topK,
                            repetitionPenalty: repetitionPenalty, maxTokens: maxTokens,
                            contextLength: contextLength, kvBits: kvBits, appearance: appearance)
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: key) }
    }

    private static func loadSnapshot(from defaults: UserDefaults, key: String) -> Snapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

// MARK: - Auto engine policy

public extension AppSettings {
    /// Pure Auto-policy: pick which `LLMVariant` to run for a model on this device given the engine
    /// preference. `.auto` chooses the greenest fit via the governor; ties break to the device-preferred
    /// engine — **MLX on Mac, llama.cpp on iPhone** (mmap'd weights favor the memory-tight phone) — then
    /// to the model's default quant, then to the smaller download. The explicit `.mlx` / `.llamaCpp`
    /// pin that engine's best variant, falling back to the other engine only if the model lacks it.
    ///
    /// Nonisolated + pure so it's unit-testable off the main actor; the governor call is MLX-free.
    nonisolated static func preferredVariant(for model: LLMModel, device: DeviceTier,
                                             preference: EnginePreference, context: Int) -> LLMVariant {
        let candidates: [LLMVariant]
        if let pinned = preference.pinnedEngine {
            let scoped = model.variants(for: pinned)
            candidates = scoped.isEmpty ? model.variants : scoped
        } else {
            candidates = model.variants
        }
        guard !candidates.isEmpty else { return model.defaultVariantValue }

        let tieBreakEngine: EngineKind = device.isPhone ? .llamaCpp : .mlx

        // Higher key wins: greenest fit, then the device-preferred engine, then the default quant, then
        // the smaller download (negated so smaller = larger key).
        func key(_ v: LLMVariant) -> (Int, Int, Int, Int64) {
            let fit = LLMMemoryGovernor.plan(model: model, variant: v, device: device, context: context)
            let fitRank = fit == .comfortable ? 2 : (fit.isSupported ? 1 : 0)
            let enginePref = v.engine == tieBreakEngine ? 1 : 0
            let quantPref = v.quant == model.defaultVariant ? 1 : 0
            return (fitRank, enginePref, quantPref, -v.onDiskBytes)
        }
        return candidates.max { key($0) < key($1) } ?? model.defaultVariantValue
    }
}
