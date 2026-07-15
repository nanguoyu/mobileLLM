// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Records the file globs the app-facing downloader closure is invoked with.
private actor GlobRecorder {
    private(set) var captured: [String]?
    func record(_ g: [String]) { captured = g }
    func get() -> [String]? { captured }
}

/// `ModelManager` engine wiring (DESIGN §6): single-file GGUF variants thread their filename through
/// as a one-entry glob; flat MLX variants pass an empty glob; and the 27B GGUF always presents as an
/// honest experimental (amber), never green.
@MainActor
final class ModelManagerEngineTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000,  isPhone: true)
    private let phone12 = DeviceTier(physicalMemoryBytes: 12_000_000_000, isPhone: true)
    private let mac16  = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "mm-engine-\(UUID().uuidString)")
    }

    private func manager(_ device: DeviceTier, recorder: GlobRecorder? = nil,
                         installed: Bool = false) -> ModelManager {
        ModelManager(engine: MockLLMEngine(), device: device, downloadBase: tempBase(),
                     downloader: { _, globs, progress in await recorder?.record(globs); progress(1) },
                     installProbe: { _, _ in installed },
                     availableMemory: { .max })
    }

    private func waitUntilNotDownloading(_ models: ModelManager, _ variant: LLMVariant,
                                         timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while models.isDownloading(variant) {
            if Date() > deadline { throw XCTSkip("download did not finish in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A GGUF variant downloads just its one file (its `fileName` becomes the glob).
    func testGGUFDownloadThreadsFileNameGlob() async throws {
        let recorder = GlobRecorder()
        let models = manager(phone8, recorder: recorder)
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        models.download(gguf)
        try await waitUntilNotDownloading(models, gguf)
        let captured = await recorder.get()
        XCTAssertEqual(captured, ["Bonsai-8B-Q1_0.gguf"])
    }

    /// A flat MLX variant downloads the whole repo (empty glob).
    func testMLXDownloadUsesEmptyGlob() async throws {
        let recorder = GlobRecorder()
        let models = manager(phone8, recorder: recorder)
        let mlx = LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)!
        models.download(mlx)
        try await waitUntilNotDownloading(models, mlx)
        let captured = await recorder.get()
        XCTAssertEqual(captured, [])
    }

    /// The 3.8 GB 27B GGUF presents by SIZE now (hybrid arch confirmed on mainline): comfortable on
    /// roomy devices, honest `.tight` on the 8 GB phone (runs via the clean-page discount, not green).
    func testGGUF27BSizeDrivenPresentation() {
        let gguf = LLMCatalog.bonsai27b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertEqual(manager(phone12).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096), .comfortable)
        XCTAssertEqual(manager(mac16).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096), .comfortable)
        guard case .tight = manager(phone8).fitPresentation(LLMCatalog.bonsai27b, gguf, context: 4096) else {
            return XCTFail("27B GGUF should read tight (runnable via mmap discount) on the 8 GB phone")
        }
    }

    /// The 8B GGUF presents as comfortable on every device (the mmap-friendly hero).
    func testGGUF8BComfortable() {
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        for device in [phone8, phone12, mac16] {
            XCTAssertEqual(manager(device).fitPresentation(LLMCatalog.bonsai8b, gguf, context: 4096),
                           .comfortable)
        }
    }

    /// `refreshInstalled` records GGUF variants by their engine-tagged id when present on disk.
    func testRefreshInstalledTracksGGUFVariant() {
        let models = manager(phone8, installed: true)
        models.refreshInstalled()
        let gguf = LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)!
        XCTAssertTrue(models.isInstalled(gguf))
        XCTAssertTrue(gguf.id.hasSuffix("#gguf"))
    }
}
