// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppRuntime
import MobileLLMUI
import LLMEngineMLX

/// App assembly: the real MLX-fork engine (`MLXLLMEngine`) + the resumable `ModelDownloader` are
/// injected into the `AppContainer` composition root here; everywhere else runs against protocols.
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
        let container = MainActor.assumeIsolated {
            AppContainer(
                engine: MLXLLMEngine(),
                downloadBase: base,
                downloader: { repoId, progress in
                    _ = try await downloader.download(repoId: repoId, progress: progress)
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
