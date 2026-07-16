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
    /// Let the model call on-device tools (calculator, date/time) via the agent loop. Off by default —
    /// it adds a round-trip and only some models call tools reliably.
    public var toolsEnabled: Bool { didSet { persist() } }
    /// Remote MCP servers whose tools join the agent's tool set when tools are on.
    public var mcpServers: [MCPServer] { didSet { persist() } }

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
        // The stock prompt arrived after v1 shipped with no prompt at all, so seed it once into installs
        // that predate it. `systemPromptSeeded` is what makes that a migration and not a bug: without it,
        // "" is indistinguishable from "the user cleared it on purpose" and every launch would undo them.
        if let snap {
            systemPrompt = (snap.systemPromptSeeded != true && snap.systemPrompt.isEmpty)
                ? SystemPrompt.standard : snap.systemPrompt
        } else {
            systemPrompt = SystemPrompt.standard
        }
        thinkingDefault = snap?.thinkingDefault ?? true
        thinkingDisplay = snap?.thinkingDisplay ?? .autoCollapse
        toolsEnabled = snap?.toolsEnabled ?? false
        mcpServers = snap?.mcpServers ?? []
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
    ///
    /// `contextLength` is a *request*: pass the model in and it's clamped to what that model was actually
    /// trained for, since asking a 4K checkpoint for 32K doesn't extend it, it degrades it. (Live case:
    /// Explore models, where the global setting has no idea what it's aimed at.)
    public func sampling(thinking: Bool, model: LLMModel? = nil) -> Sampling {
        Sampling(temperature: temperature, topP: topP, topK: topK,
                 repetitionPenalty: repetitionPenalty, maxTokens: maxTokens, thinking: thinking,
                 contextTokenCap: effectiveContext(for: model), kvBits: kvBits)
    }

    /// The context the engine really gets for a model — the setting, clamped by the model's native ceiling.
    public func effectiveContext(for model: LLMModel?) -> Int {
        guard let model else { return contextLength }
        return ContextPolicy.effective(requested: contextLength, model: model)
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var defaultModelID: String
        /// Optional so an older persisted snapshot (pre-engine-picker) still decodes; defaults to `.auto`.
        var enginePreference: EnginePreference?
        var systemPrompt: String
        /// One-time marker that the stock prompt has been offered; absent in pre-v1.1 snapshots.
        var systemPromptSeeded: Bool? = true
        var thinkingDefault: Bool
        var thinkingDisplay: ThinkingDisplayMode
        var toolsEnabled: Bool? = false   // optional → old snapshots decode
        var mcpServers: [MCPServer]? = []
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
                            systemPrompt: systemPrompt, systemPromptSeeded: true,
                            thinkingDefault: thinkingDefault, thinkingDisplay: thinkingDisplay,
                            toolsEnabled: toolsEnabled, mcpServers: mcpServers,
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
