// SPDX-License-Identifier: MIT

import SwiftUI
import AppRuntime
import MobileLLMUI
import LLMCore
import LLMEngineMLX
import LLMEngineLlama

/// App assembly: a `RoutingEngine` fronting both concrete engines (MLX-fork + llama.cpp) and the
/// resumable `ModelDownloader` are injected into the `AppContainer` composition root here; everywhere
/// else runs against the `LLMEngine` protocol. The router loads each variant on the engine its
/// `backend` names and keeps at most one resident, so switching engines never doubles memory.
@main
struct MobileLLMApp: App {
    @State private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Multi-GB weights live under Application Support (a no-backup dir so they don't hit iCloud).
        let base = URL.applicationSupportDirectory.appending(path: "mobileLLM", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let downloader = ModelDownloader(downloadBase: base)
        // App.init runs on the main thread; adopt that isolation to build the @MainActor container.
        let engine = RoutingEngine(engines: [
            .mlx: MLXLLMEngine(),
            .llamaCpp: LlamaEngine(),
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
                downloader: { repoId, globs, progress in
                    _ = try await downloader.download(repoId: repoId, matching: globs, progress: progress)
                },
                eventStore: eventStore,
                locationProvider: locationProvider)
        }
        _container = State(initialValue: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                // `bootstrap()` is awaited by RootView's own `.task` and is idempotent — a second `.task`
                // here would race it (sessions decoded twice, default model loaded back-to-back), so it's
                // deliberately NOT started from the App scene.
                .onChange(of: scenePhase) { _, phase in
                    // Free the resident model when the app leaves the foreground: it stops a 5 GB model
                    // hogging memory while unused and stops iOS jetsam-killing the app in the background.
                    if phase == .background { container.suspendModel() }
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
