// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Launch-time engine choice (DESIGN §6): the user's persisted `Inference engine` preference must be
/// honored when the app auto-activates the default model on bootstrap — never silently overridden by
/// the MLX-first default or a platform tie-break. This is the durable half of "the user freely chooses".
@MainActor
final class AppContainerBootstrapTests: XCTestCase {

    private let phone = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let mac   = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func container(preference: EnginePreference, device: DeviceTier,
                           installed: Bool = true) -> AppContainer {
        let defaults = UserDefaults(suiteName: "boot-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.defaultModelID = LLMCatalog.bonsai8b.id
        settings.enginePreference = preference
        return AppContainer(
            engine: MockLLMEngine(),
            downloadBase: FileManager.default.temporaryDirectory.appending(component: "boot-\(UUID().uuidString)"),
            downloader: { _, _, p in p(1) },
            device: device,
            settings: settings,
            conversationStore: ConversationStore(directory: FileManager.default.temporaryDirectory
                .appending(component: "boot-conv-\(UUID().uuidString)")),
            installProbe: { _, _ in installed },
            availableMemory: { .max })
    }

    func testBootstrapHonorsLlamaCppPreference() async {
        let c = container(preference: .llamaCpp, device: mac)
        await c.bootstrap()
        XCTAssertEqual(c.models.active?.variant.engine, .llamaCpp,
                       "a persisted llama.cpp preference must be honored on launch, even on Mac where the default is MLX")
    }

    func testBootstrapHonorsMLXPreference() async {
        let c = container(preference: .mlx, device: phone)
        await c.bootstrap()
        XCTAssertEqual(c.models.active?.variant.engine, .mlx,
                       "a persisted MLX preference must be honored on launch, even on a phone where Auto leans llama.cpp")
    }

    func testAutoTieBreaksByDevice() async {
        let onPhone = container(preference: .auto, device: phone)
        await onPhone.bootstrap()
        XCTAssertEqual(onPhone.models.active?.variant.engine, .llamaCpp, "Auto on a phone leans llama.cpp (mmap)")

        let onMac = container(preference: .auto, device: mac)
        await onMac.bootstrap()
        XCTAssertEqual(onMac.models.active?.variant.engine, .mlx, "Auto on a Mac leans MLX (resident, fastest)")
    }

    func testNothingInstalledActivatesNothing() async {
        let c = container(preference: .llamaCpp, device: mac, installed: false)
        await c.bootstrap()
        XCTAssertNil(c.models.active, "no install → no auto-activation (no crash, no wrong-engine boot)")
    }
}
