// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// bootstrap() idempotency (B2.g): the App scene + RootView both await it at launch. It must run exactly
/// once no matter how many concurrent (or later) callers there are, and cold launch must only restore
/// selection identity — never allocate model weights.
@MainActor
final class BootstrapIdempotencyTests: XCTestCase {

    /// Counts resident loads so the launch contract can prove bootstrap never touches the engine.
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
            downloader: { _, _, _, p in p(1) },
            device: DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false),
            settings: settings,
            conversationStore: ConversationStore(directory: FileManager.default.temporaryDirectory
                .appending(component: "boot-idem-conv-\(UUID().uuidString)")),
            installProbe: { _, _ in true },
            availableMemory: { .max })
    }

    func testConcurrentBootstrapsSelectDefaultWithoutLoadingEngine() async {
        let engine = CountingEngine()
        let c = container(engine: engine)
        async let a: Void = c.bootstrap()
        async let b: Void = c.bootstrap()
        _ = await (a, b)
        await c.bootstrap()   // a later call also no-ops
        let loads = await engine.loadCount
        XCTAssertEqual(loads, 0, "cold bootstrap must not allocate model weights")
        XCTAssertEqual(c.models.active?.model.id, LLMCatalog.bonsai8b.id)
        XCTAssertFalse(c.models.engineResident, "the restored selection remains non-resident until first use")
    }
}
