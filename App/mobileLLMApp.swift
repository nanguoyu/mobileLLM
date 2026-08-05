// SPDX-License-Identifier: MIT

import SwiftUI
import AppRuntime
import MobileLLMUI
import LLMCore
import LLMEngineMLX
import LLMEngineLlama
import LLMEngineApple

#if DEBUG && os(macOS)
import AppKit

/// Opt-in, in-process Mac screenshot configuration. Rendering the target window's own view hierarchy
/// avoids depending on the active display, Spaces, screen-capture permission, or which of several remote
/// monitors happens to be focused. Normal launches do not create this request and pay no runtime cost.
private struct MacScreenshotRequest {
    let outputURL: URL
    let errorURL: URL
    let section: AppSection
    let appearance: AppearanceMode?

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MacScreenshotRequest? {
        guard let outputPath = environment["MOBILELLM_MAC_SCREENSHOT_PATH"], !outputPath.isEmpty else {
            return nil
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let errorPath = environment["MOBILELLM_MAC_SCREENSHOT_ERROR_PATH"]
        let errorURL = errorPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? outputURL.appendingPathExtension("error.txt")
        let section = environment["MOBILELLM_MAC_SCREENSHOT_SECTION"]
            .flatMap(AppSection.init(rawValue:)) ?? .chat
        let appearance: AppearanceMode? = switch environment["MOBILELLM_MAC_SCREENSHOT_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        case "system": .system
        default: nil
        }
        return MacScreenshotRequest(outputURL: outputURL, errorURL: errorURL,
                                    section: section, appearance: appearance)
    }
}

/// Captures the largest app window from inside the process. `screencapture` and CGWindow snapshots can
/// omit privacy-protected SwiftUI windows, especially over remote desktop; an NSView cache is independent
/// of window-sharing flags, active Spaces, physical monitor geometry, and frontmost-app state.
@MainActor
private enum MacWindowSnapshotter {
    static func capture(_ request: MacScreenshotRequest) async {
        // Bootstrap has completed before this method starts. Let SwiftUI commit that observable state,
        // initial navigation, and sidebar animation before sampling rendered pixels.
        try? await Task.sleep(for: .milliseconds(700))
        var previousBounds: CGRect?
        var previousPNG: Data?
        var stablePasses = 0
        for _ in 0..<100 {
            guard !Task.isCancelled else { return }
            guard let window = captureWindow(), let contentView = window.contentView else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let targetView = contentView.superview ?? contentView
            window.layoutIfNeeded()
            targetView.layoutSubtreeIfNeeded()
            targetView.displayIfNeeded()
            let bounds = targetView.bounds.integral
            guard bounds.width >= 640, bounds.height >= 480 else {
                stablePasses = 0
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if bounds != previousBounds {
                previousBounds = bounds
                previousPNG = nil
                stablePasses = 0
            }
            do {
                let png = try renderPNG(targetView)
                if png == previousPNG {
                    stablePasses += 1
                } else {
                    previousPNG = png
                    stablePasses = 0
                }
                // Stable geometry alone is insufficient: async bootstrap can change the content without
                // resizing the window. Publish only after three identical rendered frames.
                if stablePasses >= 2 {
                    try FileManager.default.createDirectory(
                        at: request.outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try png.write(to: request.outputURL, options: .atomic)
                    return
                }
            } catch {
                report(error, to: request.errorURL)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        report(MacScreenshotError.windowNeverSettled, to: request.errorURL)
    }

    private static func captureWindow() -> NSWindow? {
        NSApplication.shared.windows
            .filter { window in
                guard window.isVisible, let content = window.contentView else { return false }
                return content.bounds.width >= 640 && content.bounds.height >= 480
            }
            .max { lhs, rhs in lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height }
    }

    private static func renderPNG(_ view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw MacScreenshotError.bitmapAllocationFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MacScreenshotError.pngEncodingFailed
        }
        return png
    }

    private static func report(_ error: Error, to errorURL: URL) {
        let message = "macOS screenshot failed: \(error.localizedDescription)\n"
        do {
            try FileManager.default.createDirectory(at: errorURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(message.utf8).write(to: errorURL, options: .atomic)
        } catch {
            print(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private enum MacScreenshotError: LocalizedError {
    case windowNeverSettled
    case bitmapAllocationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .windowNeverSettled: "the app window did not reach a stable capture size"
        case .bitmapAllocationFailed: "AppKit could not allocate a window bitmap"
        case .pngEncodingFailed: "AppKit could not encode the window bitmap as PNG"
        }
    }
}
#endif

/// App assembly: a `RoutingEngine` fronting the three concrete engines (MLX-fork, llama.cpp, and Apple's
/// system model) and the resumable `ModelDownloader` are injected into the `AppContainer` composition root
/// here; everywhere else runs against the `LLMEngine` protocol. The router loads each variant on the engine
/// its `backend` names and keeps at most one resident, so switching engines never doubles memory.
@main
struct MobileLLMApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG && os(macOS)
    private let macScreenshotRequest = MacScreenshotRequest.current()
    #endif
    #if DEBUG && os(iOS)
    private let deviceE2E = DeviceE2EConfiguration.current()
    #endif

    init() {
        // Device-test harness opt-out for cooperative thermal pacing (production never sets this).
        if ProcessInfo.processInfo.environment["MOBILELLM_DISABLE_THERMAL"] == "1" {
            ThermalGovernor.isPacingEnabled = false
        }
        // Multi-GB weights live under Application Support (a no-backup dir so they don't hit iCloud).
        let base = URL.applicationSupportDirectory.appending(path: "mobileLLM", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let downloader = ModelDownloader(downloadBase: base)
        // App.init runs on the main thread; adopt that isolation to build the @MainActor container.
        // The Apple engine is registered unconditionally, even on an OS with no FoundationModels: it owns
        // no weights and costs nothing to hold, and being present is what lets the Models card say WHY the
        // system model can't run instead of the UI having to guess.
        let engine = RoutingEngine(engines: [
            .mlx: MLXLLMEngine(),
            .llamaCpp: LlamaEngine(),
            .apple: AppleLLMEngine(),
        ])
        // The privacy-gated tool adapters are wired here (the composition root for platform frameworks,
        // like the engines above): construction is cheap and prompts for nothing — EventKit/CoreLocation
        // only ask for access lazily, on the first tool call, and only if the user enabled that tool.
        #if canImport(EventKit)
        let eventStore: (any EventStoring)? = EventKitStore()
        #else
        let eventStore: (any EventStoring)? = nil
        #endif
        #if canImport(CoreLocation)
        let locationProvider: (any LocationProviding)? = CoreLocationProvider()
        #else
        let locationProvider: (any LocationProviding)? = nil
        #endif
        let container = MainActor.assumeIsolated {
            AppContainer(
                engine: engine,
                downloadBase: base,
                downloader: { repoId, revision, globs, progress in
                    _ = try await downloader.download(repoId: repoId, revision: revision,
                                                      matching: globs, progress: progress)
                },
                // The model layer is engine-free, so only this layer can ask the OS about its own model.
                // This IS the system model's install state: available ⇒ ready to use, nothing downloaded.
                systemModelProbe: { AppleSystemModel.status() },
                eventStore: eventStore,
                locationProvider: locationProvider)
        }
        // Online Responses config box: the provider reads it on worker threads; the app refreshes the
        // non-secret values from Settings on the main actor at every submission.
        let onlineConfigBox = OpenAIOnlineConfigurationBox(
            baseURL: container.settings.openAIBaseURL,
            modelID: container.settings.openAIModelID,
            credentials: container.openAICredentials
        )
        #if DEBUG
        // Local OpenAI-compatible service config: the developer stores it once at
        // ~/.mobilellm/openai.json (outside the repo); the macOS DEBUG app reads it directly, and the
        // simulator/device test runners inject the same values through launch environment variables,
        // which this block applies with env winning over the file. The key then goes into the device
        // Keychain store; base URL and model are non-secret settings.
        do {
            var config = OpenAILocalConfigLoader.loadDefault()
                ?? OpenAILocalConfig(
                    apiKey: "",
                    baseURL: OpenAIServiceConfiguration.defaultBaseURL
                )
            OpenAILocalConfigLoader.applyEnvironment(
                ProcessInfo.processInfo.environment,
                to: &config
            )
            if !config.apiKey.isEmpty {
                try? container.openAICredentials.saveAPIKey(config.apiKey)
            }
            if let baseURL = OpenAIServiceConfiguration.normalizedBaseURL(config.baseURL) {
                container.settings.openAIBaseURL = baseURL
            }
            if let model = config.model, !model.isEmpty {
                container.settings.openAIModelID = model
            }
        }
        #endif
        // Attach the durable agent runtime (spec §6 / §20): SQLite journal, artifact store, local
        // model providers over the same routing engine, and the run store the UI projects. A failure
        // here keeps the legacy in-process loop — the rollout switch (spec §26) is the assembly's
        // presence, and the app never crashes on it.
        MainActor.assumeIsolated {
            if let assembly = try? AgentRuntimeAssembly(
                engine: engine,
                downloadBase: base,
                conversationDirectory: container.conversationStore.directory,
                snapshot: { [weak container] conversationID, userTurnID, text, imageRefs in
                    guard let container else { return nil }
                    return makeAgentSnapshot(
                        container: container,
                        conversationID: conversationID,
                        userTurnID: userTurnID,
                        text: text,
                        imageRefs: imageRefs,
                        downloadBase: base,
                        onlineConfigBox: onlineConfigBox
                    )
                },
                memoryStore: container.chat.memoryBook?.store,
                eventStore: container.toolEventStore,
                locationProvider: container.toolLocationProvider,
                mcpDiscovery: container.mcpDiscovery,
                onlineConfiguration: { onlineConfigBox.configuration() }
            ) {
                container.attachAgentRuns(assembly.runStore)
                container.chat.agentMCPToolLogicalIDs = { [weak container] in
                    guard let container else { return [] }
                    return container.mcpDiscovery
                        .descriptors(for: container.settings.mcpServers)
                        .map(\.id.logicalID)
                }
                container.agentDiagnosticSnapshot = { @MainActor in
                    await assembly.diagnosticLogger.snapshot()
                        .map { entry in
                            let fields = entry.metadata
                                .map { "\($0.key)=\($0.value)" }
                                .sorted()
                                .joined(separator: ",")
                            return "\(entry.code):\(fields)"
                        }
                        .joined(separator: "|")
                }
                AgentRuntimeAssembly.logger(
                    "Agent runtime attached (journal: \(assembly.repository.location.path))"
                )
            } else {
                // Diagnose the exact assembly failure instead of silently falling back, so device
                // tests can distinguish a healthy rollout-off state from a wiring bug.
                do {
                    _ = try AgentRuntimeAssembly(
                        engine: engine,
                        downloadBase: base,
                        conversationDirectory: container.conversationStore.directory,
                        snapshot: { [weak container] conversationID, userTurnID, text, imageRefs in
                            guard let container else { return nil }
                            return makeAgentSnapshot(
                                container: container,
                                conversationID: conversationID,
                                userTurnID: userTurnID,
                                text: text,
                                imageRefs: imageRefs,
                                downloadBase: base,
                                onlineConfigBox: onlineConfigBox
                            )
                        },
                        memoryStore: container.chat.memoryBook?.store,
                        eventStore: container.toolEventStore,
                        locationProvider: container.toolLocationProvider,
                        mcpDiscovery: container.mcpDiscovery,
                        onlineConfiguration: { onlineConfigBox.configuration() }
                    )
                } catch {
                    container.recordAgentRuntimeFailure(error)
                    AgentRuntimeAssembly.logger(
                        "Agent runtime unavailable: \(error.localizedDescription)"
                    )
                }
                AgentRuntimeAssembly.logger("Agent runtime unavailable — legacy chat loop active")
            }
        }
        #if DEBUG && os(macOS)
        if let appearance = macScreenshotRequest?.appearance {
            container.settings.appearance = appearance
        }
        #endif
        _container = State(initialValue: container)
        #if DEBUG && os(macOS)
        // Keep screenshot automation independent of SwiftUI view identity. A view-scoped `.task` can be
        // cancelled while bootstrap publishes its first observable changes, leaving a remote QA runner
        // waiting forever even though the app window is healthy. This unstructured MainActor task lives
        // for the short capture attempt and finds the app-owned window after launch has settled.
        if let request = macScreenshotRequest {
            let screenshotContainer = container
            Task { @MainActor in
                // Capture a fully hydrated page, not merely a stable-sized window. `bootstrap()` is
                // idempotent, so RootView can safely await the same operation at the same time.
                await screenshotContainer.bootstrap()
                await Task.yield()
                await MacWindowSnapshotter.capture(request)
            }
        }
        #endif
    }

    private var initialSection: AppSection {
        #if DEBUG && os(macOS)
        macScreenshotRequest?.section ?? .chat
        #else
        .chat
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container, initialSection: initialSection)
                #if DEBUG && os(iOS)
                .overlay(alignment: .topLeading) {
                    if deviceE2E != nil { DeviceE2EDiagnosticsOverlay(container: container) }
                }
                #endif
                // `bootstrap()` is awaited by RootView's own `.task` and is idempotent — a second `.task`
                // here would race it (sessions decoded and selection restored twice), so it's
                // deliberately NOT started from the App scene.
                .onChange(of: scenePhase) { _, phase in
                    // Free the resident model when the app leaves the foreground: it stops a 5 GB model
                    // hogging memory while unused and stops iOS jetsam-killing the app in the background.
                    if phase == .background {
                        container.suspendModel()
                        // Durable agent quiescence (spec §19.1): every active run pauses at its next
                        // safe boundary; recovery is explicit user Resume, never automatic.
                        Task { await container.chat.agentRuns?.quiesceForBackground() }
                    }
                }
        }
        // A postfix `#if` may contain ONLY member-expression continuations (SE-0308), so the Settings
        // scene sits in its own block below rather than sharing this one.
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands { AppCommands(container: container) }
        #endif

        // macOS Settings scene (⌘,) — the same Settings surface, hosted in its own window.
        #if os(macOS)
        Settings {
            MacSettingsWindow(container: container)
        }
        #endif
    }
}

@MainActor
private func makeAgentSnapshot(
    container: AppContainer,
    conversationID: UUID,
    userTurnID: UUID,
    text: String,
    imageRefs: [ImageRef],
    downloadBase: URL,
    onlineConfigBox: OpenAIOnlineConfigurationBox
) -> AgentRunRequestSnapshot? {
    guard let active = container.chat.activeModel else { return nil }
    // Keep the provider's config box in step with Settings before the snapshot freezes the selection.
    onlineConfigBox.update(
        baseURL: container.settings.openAIBaseURL,
        modelID: container.settings.openAIModelID
    )
    return AgentRunRequestSnapshot(
        conversationID: conversationID,
        userTurnID: userTurnID,
        text: text,
        imageRefs: imageRefs,
        messages: container.chat.activeConversation?.messages ?? [],
        systemPrompt: container.settings.systemPrompt,
        memoryFacts: container.chat.memoryBook?.facts ?? [],
        activeSkill: container.chat.activeSkill,
        model: active.model,
        variant: active.variant,
        weightsDirectory: ModelDownloader(downloadBase: downloadBase)
            .localURL(repoId: active.variant.source.huggingFaceRepo),
        thinkingEnabled: container.chat.thinkingEnabled,
        contextLength: container.settings.contextLength,
        maxTokens: container.settings.maxTokens,
        temperature: container.settings.temperature,
        topP: container.settings.topP,
        topK: container.settings.topK,
        repetitionPenalty: container.settings.repetitionPenalty,
        toolsEnabled: container.settings.toolsEnabled,
        localToolNames: container.settings.builtInToolConfig.enabled.map(\.rawValue),
        memorySeamAvailable: container.chat.memoryBook != nil,
        eventSeamAvailable: container.toolEventStore != nil,
        locationSeamAvailable: container.toolLocationProvider != nil,
        mcpToolDescriptors: container.settings.toolsEnabled
            ? container.mcpDiscovery.descriptors(for: container.settings.mcpServers)
            : [],
        webSearchDestinations: container.settings.toolsEnabled
            ? (try? container.settings.builtInToolConfig.searchEngines.map {
                try AppWebSearchToolAdapter.destination(engine: $0)
            }) ?? []
            : [],
        toolPolicy: container.chat.activeConversation?.toolPolicy,
        onlineModelEnabled: container.settings.openAIOnlineEnabled,
        onlineModelID: container.settings.openAIModelID
    )
}

#if os(macOS)
/// The macOS menu-bar commands (DESIGN §4): the keyboard-first affordances a Mac app is expected to have,
/// acting on the container the App owns. New Chat (⌘N, replacing the default File ▸ New), and a Model menu
/// with Switch Model (⌘L → the quick switcher), Toggle Thinking (⇧⌘T), and Stop Generating (⌘.).
struct AppCommands: Commands {
    let container: AppContainer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { container.chat.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Model") {
            Button("Switch Model…") { container.switcherRequested = true }
                .keyboardShortcut("l", modifiers: .command)
            Button("Toggle Thinking") { container.chat.thinkingEnabled.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Stop Generating") { container.chat.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!container.chat.isStreaming)
        }
    }
}
#endif
