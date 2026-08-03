// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import LLMCore
import XCTest

final class LocalModelResidencyTests: XCTestCase {
    func testLoadIsIdempotentAndUnloadOnlyTouchesExactResidentSelection() async throws {
        let harness = try LocalAdapterHarness.make(offset: 60)
        let driver = harness.provider.residencyDriver
        try await driver.load(selection: harness.request.selection)
        try await driver.load(selection: harness.request.selection)
        let firstLoadCount = await harness.engine.recordedLoadCount()
        let firstResident = await driver.currentResidentSelection
        XCTAssertEqual(firstLoadCount, 1)
        XCTAssertEqual(firstResident, harness.request.selection)

        let absent = AgentModelSelection(
            providerID: harness.descriptor.id,
            modelID: try AgentModelID("absent"),
            variantID: try AgentModelVariantID("absent"),
            capabilityVersion: harness.descriptor.capabilityVersion
        )
        try await driver.cancelAndDrain(selection: absent)
        try await driver.unload(selection: absent)
        let absentUnloadCount = await harness.engine.recordedUnloadCount()
        XCTAssertEqual(absentUnloadCount, 0)

        try await driver.unload(selection: harness.request.selection)
        try await driver.unload(selection: harness.request.selection)
        let residentAfterUnload = await driver.currentResidentSelection
        let finalUnloadCount = await harness.engine.recordedUnloadCount()
        XCTAssertNil(residentAfterUnload)
        XCTAssertEqual(finalUnloadCount, 1)
    }

    func testSwitchUnloadsBeforeLoadingAndNeverKeepsTwoSelections() async throws {
        let version = SemanticVersion("1.0.0")!
        let providerID = try AgentModelProviderID("local.switch")
        let first = try LocalModelRegistration(
            providerID: providerID,
            capabilityVersion: version,
            model: LLMCatalog.bonsai8b,
            variant: LLMCatalog.bonsai8b.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/first")
        )
        let second = try LocalModelRegistration(
            providerID: providerID,
            capabilityVersion: version,
            model: LLMCatalog.gemma4E2B,
            variant: LLMCatalog.gemma4E2B.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/second")
        )
        let engine = LocalAdapterScriptedEngine()
        let driver = try LLMCoreModelResidencyDriver(
            engine: engine,
            registrations: [first, second]
        )
        try await driver.load(selection: first.selection)
        try await driver.load(selection: second.selection)
        let loadCount = await engine.recordedLoadCount()
        let unloadCount = await engine.recordedUnloadCount()
        let resident = await driver.currentResidentSelection
        let resolvedFirst = try await driver.registration(for: first.selection)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(unloadCount, 1)
        XCTAssertEqual(resident, second.selection)
        XCTAssertEqual(resolvedFirst, first)
    }

    func testFailedLoadReconcilesToNoResidencyAndUnloadsPartialEngine() async throws {
        let harness = try LocalAdapterHarness.make(shouldFailLoad: true, offset: 61)
        do {
            try await harness.provider.residencyDriver.load(selection: harness.request.selection)
            XCTFail("expected load failure")
        } catch is LocalEngineFixtureError {}
        let resident = await harness.provider.residencyDriver.currentResidentSelection
        let unloadCount = await harness.engine.recordedUnloadCount()
        XCTAssertNil(resident)
        XCTAssertEqual(unloadCount, 1)

        try await harness.provider.residencyDriver.load(selection: harness.request.selection)
        let loadCount = await harness.engine.recordedLoadCount()
        XCTAssertEqual(loadCount, 2)
    }

    func testGenerateNeverAutoLoadsAnAbsentModel() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([
                .answer("must not run"),
                .done(localStats()),
            ])],
            offset: 62
        )
        let result = try await harness.execute(load: false)
        assertResidencyFailure(result, code: "model.provider-runtime")
        let loadCount = await harness.engine.recordedLoadCount()
        let captures = await harness.engine.recordedCaptures()
        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(captures.isEmpty)
    }

    func testCancelAndDrainStopsActiveDecodeAndUnloadRejectsUntilQuiescent() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([
                .answer("partial"),
            ], ending: .waitForCancellation)],
            offset: 63
        )
        let task = Task { try await harness.execute() }
        try await waitForGeneration(harness.engine)

        do {
            try await harness.provider.residencyDriver.unload(selection: harness.request.selection)
            XCTFail("expected active-generation rejection")
        } catch LocalModelAdapterError.unloadWhileGenerating {}

        try await harness.provider.residencyDriver.cancelAndDrain(selection: harness.request.selection)
        let result = try await task.value
        guard case .interrupted = result.outcome else {
            return XCTFail("expected interrupted attempt")
        }
        XCTAssertEqual(result.interruption?.reason, .cancelled)
        XCTAssertEqual(result.provisionalAnswer, .discarded("partial"))
        try await harness.provider.residencyDriver.unload(selection: harness.request.selection)
        let resident = await harness.provider.residencyDriver.currentResidentSelection
        XCTAssertNil(resident)
    }

    func testSecondGenerationIsRejectedWhileDecodeLaneIsOccupied() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([], ending: .waitForCancellation)],
            offset: 64
        )
        let first = Task { try await harness.execute() }
        try await waitForGeneration(harness.engine)
        let sink = RecordingModelEventSink()
        let rejected = try await harness.execute(sink: sink, load: false)
        assertResidencyFailure(rejected, code: "model.provider-runtime")
        XCTAssertEqual(rejected.provisionalAnswer, .none)
        let events = await sink.events()
        XCTAssertEqual(events, [.provisionalAnswerResolved(.none)])
        try await harness.provider.residencyDriver.cancelAndDrain(selection: harness.request.selection)
        _ = try await first.value
    }

    func testLoadIsRejectedWhileDecodeLaneIsOccupied() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([.answer("x")], ending: .waitForCancellation)],
            offset: 65
        )
        let task = Task { try await harness.execute() }
        try await waitForGeneration(harness.engine)

        do {
            try await harness.provider.residencyDriver.load(
                selection: harness.request.selection
            )
            XCTFail("Expected an active-generation rejection")
        } catch LocalModelAdapterError.generationAlreadyActive {
            // Expected: residency cannot change while a decode lane is occupied.
        }

        try await harness.provider.residencyDriver.cancelAndDrain(
            selection: harness.request.selection
        )
        _ = try await task.value
    }

    func testConcurrentResidencyOperationsRejectTransitionsInProgress() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([.answer("x"), .done(localStats())])],
            offset: 66
        )
        await harness.engine.blockNextLoad()
        let loadTask = Task {
            try await harness.provider.residencyDriver.load(
                selection: harness.request.selection
            )
        }
        await harness.engine.waitForBlockedLoad()

        do {
            try await harness.provider.residencyDriver.load(
                selection: harness.request.selection
            )
            XCTFail("Expected a transition-in-progress rejection")
        } catch LocalModelAdapterError.residencyTransitionInProgress {
            // Expected.
        }
        do {
            try await harness.provider.residencyDriver.cancelAndDrain(
                selection: harness.request.selection
            )
            XCTFail("Expected a transition-in-progress rejection")
        } catch LocalModelAdapterError.residencyTransitionInProgress {
            // Expected.
        }
        do {
            try await harness.provider.residencyDriver.unload(
                selection: harness.request.selection
            )
            XCTFail("Expected a transition-in-progress rejection")
        } catch LocalModelAdapterError.residencyTransitionInProgress {
            // Expected.
        }
        do {
            _ = try await harness.provider.residencyDriver.runGeneration(
                selection: harness.request.selection
            ) { _ in
                throw LocalEngineFixtureError()
            }
            XCTFail("Expected a transition-in-progress rejection")
        } catch LocalModelAdapterError.residencyTransitionInProgress {
            // Expected.
        }

        await harness.engine.releaseBlockedLoad()
        _ = try await loadTask.value
    }

    func testSingleDriverServesMultipleProvidersWithExactPerSelectionCapabilities() async throws {
        let engine = LocalAdapterScriptedEngine()
        let version = SemanticVersion("1.0.0")!
        let bonsai = LLMCatalog.bonsai8b
        let gemma = LLMCatalog.gemma4E2B
        let bonsaiRegistration = try LocalModelRegistration(
            providerID: try AgentModelProviderID("local.multi.bonsai"),
            capabilityVersion: version,
            model: bonsai,
            variant: bonsai.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/mobilellm-multi-bonsai")
        )
        let gemmaRegistration = try LocalModelRegistration(
            providerID: try AgentModelProviderID("local.multi.gemma"),
            capabilityVersion: version,
            model: gemma,
            variant: gemma.defaultVariantValue,
            weightsDirectory: URL(fileURLWithPath: "/tmp/mobilellm-multi-gemma")
        )
        let driver = try LLMCoreModelResidencyDriver(
            engine: engine,
            registrations: [bonsaiRegistration, gemmaRegistration]
        )
        let bonsaiProvider = try LocalModelProvider(
            descriptor: AgentModelProviderDescriptor(
                id: bonsaiRegistration.selection.providerID,
                adapterVersion: version,
                capabilityVersion: version,
                location: .onDevice
            ),
            residencyDriver: driver
        )
        let gemmaProvider = try LocalModelProvider(
            descriptor: AgentModelProviderDescriptor(
                id: gemmaRegistration.selection.providerID,
                adapterVersion: version,
                capabilityVersion: version,
                location: .onDevice
            ),
            residencyDriver: driver
        )

        let bonsaiCaps = try await bonsaiProvider.capabilities(for: bonsaiRegistration.selection)
        let gemmaCaps = try await gemmaProvider.capabilities(for: gemmaRegistration.selection)
        XCTAssertEqual(bonsaiCaps, bonsaiRegistration.capabilities)
        XCTAssertEqual(gemmaCaps, gemmaRegistration.capabilities)
        XCTAssertNotEqual(bonsaiCaps.maximumContextTokens, gemmaCaps.maximumContextTokens)
    }

    func testCancellingCallerPropagatesToDecodeAndReleasesGenerationLane() async throws {
        let harness = try LocalAdapterHarness.make(
            scripts: [LocalEngineScript([
                .answer("partial"),
            ], ending: .waitForCancellation)],
            offset: 65
        )
        let task = Task { try await harness.execute() }
        try await waitForGeneration(harness.engine)
        task.cancel()

        let result = try await task.value
        guard case .interrupted = result.outcome else {
            return XCTFail("expected cancelled attempt, got \(result.outcome)")
        }
        XCTAssertEqual(result.interruption?.reason, .cancelled)
        XCTAssertEqual(result.provisionalAnswer, .discarded("partial"))

        // The cancelled operation must clear the lane without an explicit drain.
        await harness.engine.enqueue(LocalEngineScript([
            .answer("next"),
            .done(localStats()),
        ]))
        let next = try await harness.execute()
        guard case .completed = next.outcome else {
            return XCTFail("expected generation lane to be reusable")
        }
    }
}

private func waitForGeneration(_ engine: LocalAdapterScriptedEngine) async throws {
    for _ in 0..<100 {
        let captures = await engine.recordedCaptures()
        if !captures.isEmpty { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw LocalEngineFixtureError()
}

private func assertResidencyFailure(
    _ result: AgentModelExecutionResult,
    code: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let failure) = result.outcome else {
        return XCTFail("expected failure", file: file, line: line)
    }
    XCTAssertEqual(failure.code, code, file: file, line: line)
}
