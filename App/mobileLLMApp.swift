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
        let container = MainActor.assumeIsolated {
            AppContainer(
                engine: engine,
                downloadBase: base,
                downloader: { repoId, globs, progress in
                    _ = try await downloader.download(repoId: repoId, matching: globs, progress: progress)
                })
        }
        _container = State(initialValue: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
                .task { await container.bootstrap() }
                // Free the resident model when the app leaves the foreground: it stops a 5 GB model
                // hogging memory while unused and stops iOS jetsam-killing the app in the background.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { container.suspendModel() }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
