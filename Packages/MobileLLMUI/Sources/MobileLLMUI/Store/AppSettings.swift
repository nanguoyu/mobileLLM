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
    /// Dictation language as a locale identifier (`nil` = follow the system). One recognizer = one
    /// language, so code-switching users pick explicitly via the mic's long-press menu.
    public var dictationLocale: String? { didSet { persist() } }
    /// Remote MCP servers whose tools join the agent's tool set when tools are on. Bearer tokens are kept
    /// in the Keychain, not this snapshot (A2.9) — the didSet reconciles them on every change.
    public var mcpServers: [MCPServer] {
        didSet {
            if !loading { syncMCPTokens(old: oldValue) }
            persist()
        }
    }
    /// Which built-in tools the user turned OFF (raw `ToolID` values). Stored as the *disabled* set on
    /// purpose: a tool shipped in a later version is ON without a migration (it's simply absent here), and
    /// the privacy-sensitive tools (calendar / reminders / location) start disabled until the user opts in.
    public var disabledBuiltInTools: Set<String> { didSet { persist() } }
    /// Web-search engine priority — the first that returns results wins, the rest are fall-through. At least
    /// one is kept while `web_search` is on (the UI enforces it); an empty list falls back to both.
    public var searchEngines: [SearchEngine] { didSet { persist() } }

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
    /// Where MCP bearer tokens live (A2.9). Optional so tests can opt out; nil = tokens simply aren't
    /// persisted (they still work in memory for the session).
    private let keychain: KeychainBox?

    /// Default Keychain scope for MCP bearer tokens: reverse-DNS, stored this-device-only + off-backup.
    public nonisolated static var defaultKeychainService: String { "\(Bundle.main.bundleIdentifier ?? "mobileLLM").mcp" }

    public init(defaults: UserDefaults = .standard,
                fallbackDefaultModelID: String = "bonsai-8b",
                keychain: KeychainBox? = KeychainBox(service: AppSettings.defaultKeychainService)) {
        self.defaults = defaults
        self.keychain = keychain
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
        dictationLocale = snap?.dictationLocale ?? nil
        let (servers, migrated) = Self.loadMCPServers(from: snap, keychain: keychain)
        mcpServers = servers
        // Absent in pre-D2 snapshots → the default disabled set (privacy tools off), matching
        // `BuiltInToolConfig.defaultEnabled`, so an upgraded install behaves exactly like a fresh one.
        disabledBuiltInTools = snap?.disabledBuiltInTools ?? Self.defaultDisabledBuiltInTools
        searchEngines = snap?.searchEngines ?? [.duckduckgo, .bing]
        temperature = snap?.temperature ?? 0.7
        topP = snap?.topP ?? 0.95
        topK = snap?.topK ?? 20
        repetitionPenalty = snap?.repetitionPenalty ?? 1.05
        maxTokens = snap?.maxTokens ?? 1024
        contextLength = snap?.contextLength ?? 8192
        kvBits = snap?.kvBits ?? 4
        appearance = snap?.appearance ?? .system
        loading = false
        // First launch after the update: any plaintext token was just moved into the Keychain — re-persist
        // now so the scrubbed snapshot (no plaintext) replaces the one still on disk.
        if migrated { persist() }
    }

    /// Decode the persisted MCP servers, moving any legacy plaintext token into the Keychain and hydrating
    /// marked servers' tokens back from it. Returns whether a plaintext token was migrated (→ re-persist).
    private static func loadMCPServers(from snap: Snapshot?, keychain: KeychainBox?) -> (servers: [MCPServer], migrated: Bool) {
        let markers = snap?.mcpTokenMarkers ?? []
        var migrated = false
        let servers = (snap?.mcpServers ?? []).map { server -> MCPServer in
            var s = server
            if let plaintext = server.token, !plaintext.isEmpty {
                // Legacy: the token rode along in UserDefaults. Move it to the Keychain — and only mark it
                // migrated when the save actually LANDED; scrubbing the plaintext on a failed save would
                // destroy the only copy of the secret.
                if let keychain, (try? keychain.save(plaintext, account: server.id)) != nil {
                    migrated = true
                }
            } else if markers.contains(server.id), let keychain {
                s.token = (try? keychain.readString(account: server.id)) ?? nil
            }
            return s
        }
        return (servers, migrated)
    }

    /// Reconcile the Keychain with the current server list: store each server's token, and delete tokens
    /// for servers that were removed. Runs only after the initial load (guarded in the didSet).
    private func syncMCPTokens(old: [MCPServer]) {
        guard let keychain else { return }
        let currentIDs = Set(mcpServers.map(\.id))
        for server in old where !currentIDs.contains(server.id) {
            try? keychain.delete(account: server.id)   // removed → drop its secret
        }
        for server in mcpServers {
            if let token = server.token, !token.isEmpty {
                try? keychain.save(token, account: server.id)
            } else {
                try? keychain.delete(account: server.id)
            }
        }
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

    // MARK: - Built-in tool config

    /// The built-in tools OFF on a fresh install / in a pre-D2 snapshot: everything NOT in the config's
    /// default-enabled set — i.e. the privacy-sensitive calendar / reminders / location tools. Derived from
    /// `BuiltInToolConfig.defaultEnabled` so the two never drift.
    public static let defaultDisabledBuiltInTools: Set<String> =
        Set(ToolID.allCases.map(\.rawValue))
            .subtracting(BuiltInToolConfig.defaultEnabled.map(\.rawValue))

    /// The tool set to assemble, derived from the persisted toggles: every `ToolID` except the disabled
    /// ones, plus the chosen search-engine order (falling back to both if somehow empty). Fed to
    /// `ToolRegistry.assemble(config:…)` — the single mapping from Settings to the live registry.
    public var builtInToolConfig: BuiltInToolConfig {
        let enabled = Set(ToolID.allCases).subtracting(disabledBuiltInTools.compactMap(ToolID.init(rawValue:)))
        let engines = searchEngines.isEmpty ? [SearchEngine.duckduckgo, .bing] : searchEngines
        return BuiltInToolConfig(searchEngines: engines, enabled: enabled)
    }

    /// Whether the model may use what it remembers about the user — the Manage-tools "Memory" switch, and
    /// the one gate the prompt injector, the memory screen, and the tools all read. Keyed on `recall`
    /// because reading memory is what it authorizes: the system-prompt block IS an automatic recall, so a
    /// user who switched memory off must not keep getting it silently by another route. Note this is NOT
    /// gated on `toolsEnabled` — the block calls nothing, so facts still reach a model given no tools.
    public var memoryEnabled: Bool { !disabledBuiltInTools.contains(ToolID.recall.rawValue) }

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
        var dictationLocale: String? = nil
        var mcpServers: [MCPServer]? = []
        /// Ids of servers whose bearer token lives in the Keychain (A2.9). Absent in pre-migration
        /// snapshots — the loader then treats any inline `token` as legacy plaintext to migrate.
        var mcpTokenMarkers: Set<String>? = []
        /// Built-in tool toggles (D2). Optional → a pre-D2 snapshot decodes and the loader supplies the
        /// defaults (privacy tools off; both search engines on).
        var disabledBuiltInTools: Set<String>? = nil
        var searchEngines: [SearchEngine]? = nil
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
        // NEVER write a bearer token to UserDefaults (it rides device backups) — scrub them out and keep
        // only a marker of which servers have one. The secrets live in the Keychain (A2.9).
        let scrubbed = mcpServers.map { server -> MCPServer in var s = server; s.token = nil; return s }
        let markers = Set(mcpServers.filter { $0.token?.isEmpty == false }.map(\.id))
        let snap = Snapshot(defaultModelID: defaultModelID, enginePreference: enginePreference,
                            systemPrompt: systemPrompt, systemPromptSeeded: true,
                            thinkingDefault: thinkingDefault, thinkingDisplay: thinkingDisplay,
                            toolsEnabled: toolsEnabled, dictationLocale: dictationLocale,
                            mcpServers: scrubbed, mcpTokenMarkers: markers,
                            disabledBuiltInTools: disabledBuiltInTools, searchEngines: searchEngines,
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
        var candidates: [LLMVariant]
        if let pinned = preference.pinnedEngine {
            let scoped = model.variants(for: pinned)
            candidates = scoped.isEmpty ? model.variants : scoped
        } else {
            candidates = model.variants
        }
        #if targetEnvironment(simulator)
        // MLX can't run in the simulator — never auto-pick it there when a GGUF exists (llama.cpp
        // drops to CPU and works). Activation has its own hard guard; this keeps Auto from steering
        // into it in the first place.
        let simulatorSafe = candidates.filter { $0.engine == .llamaCpp }
        if !simulatorSafe.isEmpty { candidates = simulatorSafe }
        #endif
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
