// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// bootstrap() idempotency (B2.g): the App scene + RootView both await it at launch. It must run exactly
/// once no matter how many concurrent (or later) callers there are — otherwise sessions decode twice and
/// the default model loads back-to-back.
@MainActor
final class BootstrapIdempotencyTests: XCTestCase {

    /// Counts resident loads — bootstrap activates the default model exactly once when it runs once.
    private actor CountingEngine: LLMEngine {
        private(set) var loadCount = 0
        func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws { loadCount += 1 }
        func unload() async {}
        nonisolated func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func container(engine: CountingEngine) -> AppContainer {
        let defaults = UserDefaults(suiteName: "boot-idem-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.defaultModelID = LLMCatalog.bonsai8b.id
        return AppContainer(
            engine: engine,
            downloadBase: FileManager.default.temporaryDirectory.appending(component: "boot-idem-\(UUID().uuidString)"),
            downloader: { _, _, p in p(1) },
            device: DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false),
            settings: settings,
            conversationStore: ConversationStore(directory: FileManager.default.temporaryDirectory
                .appending(component: "boot-idem-conv-\(UUID().uuidString)")),
            installProbe: { _, _ in true },
            availableMemory: { .max })
    }

    func testConcurrentBootstrapsRunOnce() async {
        let engine = CountingEngine()
        let c = container(engine: engine)
        async let a: Void = c.bootstrap()
        async let b: Void = c.bootstrap()
        _ = await (a, b)
        await c.bootstrap()   // a later call also no-ops
        let loads = await engine.loadCount
        XCTAssertEqual(loads, 1, "the default model must be activated exactly once")
        XCTAssertEqual(c.models.active?.model.id, LLMCatalog.bonsai8b.id)
    }
}
