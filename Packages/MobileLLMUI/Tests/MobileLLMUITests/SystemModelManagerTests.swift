// SPDX-License-Identifier: MIT

import XCTest
import AppRuntime
@testable import MobileLLMUI
@testable import LLMCore

/// Records any download the manager attempts, so a test can prove one never starts.
private actor DownloadSpy {
    private(set) var repos: [String] = []
    func record(_ repo: String) { repos.append(repo) }
    func get() -> [String] { repos }
}

/// How `ModelManager` treats a zero-byte, OS-provided model (the `.apple` engine): its install state comes
/// from the system's availability rather than the disk, it never downloads, and it never costs memory.
///
/// No test here needs Apple Intelligence — the system probe is injected, so every state (available,
/// ineligible, off, still downloading) is exercised on any machine.
@MainActor
final class SystemModelManagerTests: XCTestCase {

    private let phone8 = DeviceTier(physicalMemoryBytes: 8_000_000_000, isPhone: true)
    private let mac16  = DeviceTier(physicalMemoryBytes: 16_000_000_000, isPhone: false)

    private var appleModel: LLMModel { LLMCatalog.appleSystem }
    private var appleVariant: LLMVariant { LLMCatalog.appleSystem.defaultVariantValue }

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "mm-system-\(UUID().uuidString)")
    }

    /// `diskInstalled` is what the DISK probe claims for every variant — deliberately independent of the
    /// system model's status, so the tests can prove the two never cross over.
    private func manager(_ device: DeviceTier = .init(physicalMemoryBytes: 8_000_000_000, isPhone: true),
                         status: SystemModelStatus,
                         diskInstalled: Bool = false,
                         spy: DownloadSpy? = nil) -> ModelManager {
        ModelManager(engine: MockLLMEngine(), device: device, downloadBase: tempBase(),
                     downloader: { repo, _, progress in await spy?.record(repo); progress(1) },
                     installProbe: { _, _ in diskInstalled },
                     systemModelProbe: { status },
                     availableMemory: { .max })
    }

    // MARK: - Install state comes from availability, not the disk

    /// Available ⇒ installed, with nothing on disk. This is the whole point: no download, ready to use.
    func testAvailableSystemModelIsInstalledWithNothingOnDisk() {
        let models = manager(status: .available, diskInstalled: false)
        models.refreshInstalled()
        XCTAssertTrue(models.isInstalled(appleVariant))
        XCTAssertEqual(models.systemModelStatus, .available)
    }

    /// Every unavailable reason ⇒ NOT installed, and the reason is preserved verbatim for the card to
    /// show. A model reported installed here is a Use button that can only fail.
    func testUnavailableSystemModelIsNotInstalledWhateverTheReason() {
        for reason in [SystemModelStatus.Reason.unsupportedOS, .deviceNotEligible,
                       .notEnabled, .modelNotReady, .unknown] {
            let models = manager(status: .unavailable(reason), diskInstalled: true)
            models.refreshInstalled()
            XCTAssertFalse(models.isInstalled(appleVariant), "\(reason) must not read as installed")
            XCTAssertEqual(models.systemModelStatus.unavailableReason, reason)
        }
    }

    /// The disk probe must not be able to make the system model appear installed: even a probe that says
    /// "yes" to everything can't override the OS's verdict.
    func testDiskProbeCannotFakeAnUnavailableSystemModel() {
        let models = manager(status: .unavailable(.notEnabled), diskInstalled: true)
        models.refreshInstalled()
        XCTAssertFalse(models.isInstalled(appleVariant))
        // ...while ordinary variants still follow the disk probe.
        XCTAssertTrue(models.isInstalled(LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)!))
    }

    /// Turning Apple Intelligence off mid-session removes it on the next scan, exactly like deleting
    /// weights would for any other model.
    func testStatusIsRefreshedOnEachScan() {
        let flag = MutableStatus(.available)
        let models = ModelManager(engine: MockLLMEngine(), device: phone8, downloadBase: tempBase(),
                                  downloader: { _, _, progress in progress(1) },
                                  installProbe: { _, _ in false },
                                  systemModelProbe: { flag.value },
                                  availableMemory: { .max })
        models.refreshInstalled()
        XCTAssertTrue(models.isInstalled(appleVariant))

        flag.value = .unavailable(.notEnabled)
        models.refreshInstalled()
        XCTAssertFalse(models.isInstalled(appleVariant), "switched off ⇒ gone from the installed set")
        XCTAssertEqual(models.systemModelStatus.unavailableReason, .notEnabled)
    }

    /// The default probe never pretends: a manager built without app assembly (previews, unit tests)
    /// reports the system model as unavailable rather than ready.
    func testDefaultProbeDoesNotPretendTheModelIsReady() {
        let models = ModelManager(engine: MockLLMEngine(), device: phone8, downloadBase: tempBase(),
                                  downloader: { _, _, progress in progress(1) },
                                  installProbe: { _, _ in false },
                                  availableMemory: { .max })
        models.refreshInstalled()
        XCTAssertEqual(models.systemModelStatus, .unavailable(.unsupportedOS))
        XCTAssertFalse(models.isInstalled(appleVariant))
    }

    // MARK: - It costs nothing

    /// Free on every device: the OS holds the weights out of process, so the fit is comfortable and the
    /// pre-flight has nothing to weigh — even where a resident model of any size would be refused.
    func testSystemModelIsFreeAndAlwaysComfortable() {
        for device in [phone8, mac16] {
            let models = manager(device, status: .available)
            XCTAssertEqual(models.fitPresentation(appleModel, appleVariant, context: 4096), .comfortable)
        }
        XCTAssertEqual(ModelManager.estimatedResidentPeakBytes(model: appleModel, variant: appleVariant,
                                                              context: 262_144), 0,
                       "the OS runs it out of process: there is nothing of ours to weigh")
    }

    /// Even with almost no free memory the pre-flight must not refuse it — the estimate is 0, so
    /// `activate` can't trip the insufficient-memory guard.
    func testActivateIsNotRefusedWhenMemoryIsTight() async throws {
        let models = ModelManager(engine: MockLLMEngine(), device: phone8, downloadBase: tempBase(),
                                  downloader: { _, _, progress in progress(1) },
                                  installProbe: { _, _ in false },
                                  systemModelProbe: { .available },
                                  availableMemory: { 1 })   // 1 byte free
        models.refreshInstalled()
        let loaded = try await models.activate(appleModel, variant: appleVariant, context: 4096)
        XCTAssertEqual(loaded.variant.id, appleVariant.id)
        XCTAssertEqual(models.active?.model.id, appleModel.id)
    }

    /// It contributes nothing to the storage total, however many other models are installed.
    func testSystemModelAddsNoStorage() {
        let models = manager(status: .available, diskInstalled: false)
        models.refreshInstalled()
        XCTAssertEqual(models.installedBytes, 0)
    }

    /// Activating it before any scan still refuses — `notInstalled` is the honest answer when the OS
    /// hasn't been asked yet.
    func testActivateBeforeScanRefusesLikeAnyOtherModel() async {
        let models = manager(status: .available)
        do {
            _ = try await models.activate(appleModel, variant: appleVariant, context: 4096)
            XCTFail("expected notInstalled before the first scan")
        } catch {
            XCTAssertEqual(error as? ModelActivationError, .notInstalled)
        }
    }

    // MARK: - No download, no delete

    /// There is no repo behind the system model: a download must never be attempted, even if some path
    /// asks for one (its source id is synthetic and would 404).
    func testDownloadIsANoOp() async throws {
        let spy = DownloadSpy()
        let models = manager(status: .available, spy: spy)
        models.download(appleVariant)
        XCTAssertFalse(models.isDownloading(appleVariant))
        XCTAssertNil(models.downloadState(appleVariant), "no download state may be invented")
        try await Task.sleep(nanoseconds: 20_000_000)
        let attempted = await spy.get()
        XCTAssertTrue(attempted.isEmpty, "no network fetch may be started for an OS-provided model")
    }

    /// Delete is a no-op too: none of it is ours to remove, and it must not deactivate the model.
    func testDeleteIsANoOp() async throws {
        let models = manager(status: .available)
        models.refreshInstalled()
        _ = try await models.activate(appleModel, variant: appleVariant, context: 4096)
        models.delete(appleVariant)
        XCTAssertTrue(models.isInstalled(appleVariant), "still available ⇒ still installed")
        XCTAssertEqual(models.active?.variant.id, appleVariant.id, "delete must not deactivate it")
    }

    // MARK: - The card's honesty rules (A4)

    /// The card decides what to show from these two facts. Pinned together because they're contradictory
    /// if either drifts: the memory verdict is ALWAYS comfortable (it costs us nothing), so availability
    /// is the only thing that can say "you can't use this" — and it must, or a green "Runs great" badge
    /// ends up next to "Apple Intelligence is turned off".
    func testUnavailableSystemModelIsComfortableButNotUsable() {
        let models = manager(status: .unavailable(.notEnabled))
        models.refreshInstalled()
        XCTAssertEqual(models.fitPresentation(appleModel, appleVariant, context: 4096), .comfortable,
                       "memory is never the reason the system model can't run")
        XCTAssertFalse(models.isInstalled(appleVariant), "…so availability must be what blocks it")
        XCTAssertNotNil(models.systemModelStatus.unavailableReason, "and the card must have a reason to show")
    }

    /// The user-facing sentence the card renders comes from the OS's own verdict, unedited.
    func testCardReasonComesFromTheSystemsVerdict() {
        let models = manager(status: .unavailable(.deviceNotEligible))
        models.refreshInstalled()
        XCTAssertEqual(models.systemModelStatus.unavailableReason?.message,
                       SystemModelStatus.Reason.deviceNotEligible.message)
    }
}

/// A mutable status holder for the "switched off mid-session" test (the probe is `@Sendable`, so it can't
/// close over a `var`).
private final class MutableStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SystemModelStatus
    init(_ value: SystemModelStatus) { stored = value }
    var value: SystemModelStatus {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
