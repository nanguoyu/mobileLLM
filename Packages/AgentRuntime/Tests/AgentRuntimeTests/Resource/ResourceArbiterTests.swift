// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-RESOURCE-001
final class ResourceArbiterTests: XCTestCase {
    func testRootAdmissionsUseDurableFIFOWithoutPreemption() async throws {
        let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())
        let ownerRun = resourceRun(1)
        let owner = try await arbiter.acquireRoot(runID: ownerRun, admissionSequence: 100)

        let run30 = resourceRun(30)
        let waiter30 = Task {
            try await arbiter.acquireRoot(runID: run30, admissionSequence: 30)
        }
        await waitForResourceWaiters(arbiter, expected: [30])

        let run20 = resourceRun(20)
        let waiter20 = Task {
            try await arbiter.acquireRoot(runID: run20, admissionSequence: 20)
        }
        await waitForResourceWaiters(arbiter, expected: [20, 30])

        let run40 = resourceRun(40)
        let waiter40 = Task {
            try await arbiter.acquireRoot(runID: run40, admissionSequence: 40)
        }
        await waitForResourceWaiters(arbiter, expected: [20, 30, 40])

        let beforeRelease = await arbiter.snapshot()
        XCTAssertEqual(beforeRelease.rootOwner?.runID, ownerRun)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(owner) }

        let lease20 = try await waiter20.value
        XCTAssertEqual(lease20.runID, run20)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(lease20) }

        let lease30 = try await waiter30.value
        XCTAssertEqual(lease30.runID, run30)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(lease30) }

        let lease40 = try await waiter40.value
        XCTAssertEqual(lease40.runID, run40)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(lease40) }

        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.rootOwner)
        XCTAssertTrue(snapshot.waiters.isEmpty)
        XCTAssertEqual(snapshot.metrics.rootGrants, 4)
        XCTAssertEqual(snapshot.metrics.maxRootOwners, 1)
    }

    func testManyConcurrentContendersNeverCreateParallelRootOwners() async throws {
        let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())
        let owner = try await arbiter.acquireRoot(
            runID: resourceRun(50),
            admissionSequence: 1_000
        )
        let sequences = (1...32).map(UInt64.init)
        var contenders: [(UInt64, Task<RootExecutionLease, Error>)] = []
        for sequence in sequences.reversed() {
            let task = Task {
                try await arbiter.acquireRoot(
                    runID: resourceRun(1_100 + Int(sequence)),
                    admissionSequence: sequence
                )
            }
            contenders.append((sequence, task))
        }
        await waitForResourceWaiters(arbiter, expected: sequences)

        await expectAsyncValue(.released) { await arbiter.releaseRoot(owner) }
        for (sequence, task) in contenders.sorted(by: { $0.0 < $1.0 }) {
            let lease = try await task.value
            XCTAssertEqual(lease.admissionSequence, sequence)
            await expectAsyncValue(.released) { await arbiter.releaseRoot(lease) }
        }

        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.rootOwner)
        XCTAssertTrue(snapshot.waiters.isEmpty)
        XCTAssertEqual(snapshot.metrics.rootGrants, 33)
        XCTAssertEqual(snapshot.metrics.maxRootOwners, 1)
    }

    func testAdmissionValidationAndCancellationSafeWaiterRemoval() async throws {
        let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())
        let run1 = resourceRun(101)

        await expectResourceError(.invalidAdmissionSequence) {
            try await arbiter.acquireRoot(runID: run1, admissionSequence: 0)
        }

        let owner = try await arbiter.acquireRoot(runID: run1, admissionSequence: 1)
        await expectResourceError(.runAlreadyQueued(run1)) {
            try await arbiter.acquireRoot(runID: run1, admissionSequence: 2)
        }
        await expectResourceError(.admissionSequenceInUse(1)) {
            try await arbiter.acquireRoot(runID: resourceRun(102), admissionSequence: 1)
        }

        let cancelledRun = resourceRun(103)
        let cancelled = Task {
            try await arbiter.acquireRoot(runID: cancelledRun, admissionSequence: 2)
        }
        await waitForResourceWaiters(arbiter, expected: [2])
        await expectResourceError(.runAlreadyQueued(cancelledRun)) {
            try await arbiter.acquireRoot(runID: cancelledRun, admissionSequence: 4)
        }

        let survivingRun = resourceRun(104)
        let surviving = Task {
            try await arbiter.acquireRoot(runID: survivingRun, admissionSequence: 3)
        }
        await waitForResourceWaiters(arbiter, expected: [2, 3])

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled queued admission must not receive a lease")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        await waitForResourceWaiters(arbiter, expected: [3])

        await expectAsyncValue(.released) { await arbiter.releaseRoot(owner) }
        let survivingLease = try await surviving.value
        XCTAssertEqual(survivingLease.runID, survivingRun)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(survivingLease) }

        let snapshot = await arbiter.snapshot()
        XCTAssertEqual(snapshot.metrics.rootGrants, 2)
        XCTAssertEqual(snapshot.metrics.maxRootOwners, 1)
    }

    func testLeaseIdentityDoubleReleaseAndDecodeExclusivity() async throws {
        let firstDriver = ScriptedModelResidencyDriver()
        let secondDriver = ScriptedModelResidencyDriver()
        let first = ResourceArbiter(driver: firstDriver)
        let second = ResourceArbiter(driver: secondDriver)
        let run = resourceRun(201)
        let selection = try resourceModel("alpha")
        let root = try await first.acquireRoot(runID: run, admissionSequence: 1)

        await expectAsyncValue(.wrongLease) { await second.releaseRoot(root) }
        await expectResourceError(.rootLeaseMismatch(run)) {
            try await second.acquireDecode(selection: selection, rootLease: root)
        }

        let decode = try await first.acquireDecode(selection: selection, rootLease: root)
        await expectResourceError(.decodeLeaseAlreadyActive(run)) {
            try await first.acquireDecode(selection: selection, rootLease: root)
        }
        await expectAsyncValue(.blockedByDecode) { await first.releaseRoot(root) }
        await expectAsyncValue(.wrongLease) { await second.releaseDecode(decode) }
        await expectAsyncValue(.wrongLease) {
            await second.cancelDrainAndReleaseDecode(decode)
        }
        await expectAsyncValue(.released) { await first.releaseDecode(decode) }
        await expectAsyncValue(.alreadyReleased) { await first.releaseDecode(decode) }
        await expectAsyncValue(.alreadyReleased) {
            await first.cancelDrainAndReleaseDecode(decode)
        }
        await expectAsyncValue(.released) { await first.releaseRoot(root) }
        await expectAsyncValue(.alreadyReleased) { await first.releaseRoot(root) }

        await expectResourceError(.rootLeaseRequired(run)) {
            try await first.acquireDecode(selection: selection, rootLease: root)
        }

        let snapshot = await first.snapshot()
        XCTAssertEqual(snapshot.metrics.maxRootOwners, 1)
        XCTAssertEqual(snapshot.metrics.maxDecodeOwners, 1)
        XCTAssertEqual(snapshot.metrics.maxResidentSelections, 1)
        XCTAssertEqual(snapshot.metrics.maxConcurrentResidencyTransitions, 1)
        let firstDriverSnapshot = await firstDriver.snapshot()
        XCTAssertEqual(firstDriverSnapshot.maxOperationsInFlight, 1)
    }

    func testModelSwitchIsDrainThenUnloadThenLoad() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let firstModel = try resourceModel("first")
        let secondModel = try resourceModel("second")
        let root = try await arbiter.acquireRoot(runID: resourceRun(301), admissionSequence: 1)

        let firstDecode = try await arbiter.acquireDecode(
            selection: firstModel,
            rootLease: root
        )
        await expectAsyncValue(.released) { await arbiter.releaseDecode(firstDecode) }

        let secondDecode = try await arbiter.acquireDecode(
            selection: secondModel,
            rootLease: root
        )
        await expectAsyncValue(.released) {
            await arbiter.cancelDrainAndReleaseDecode(secondDecode)
        }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }

        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(
            driverSnapshot.calls,
            [
                .init(operation: .load, selection: firstModel),
                .init(operation: .cancelAndDrain, selection: firstModel),
                .init(operation: .unload, selection: firstModel),
                .init(operation: .load, selection: secondModel),
                .init(operation: .cancelAndDrain, selection: secondModel),
            ]
        )
        XCTAssertEqual(driverSnapshot.residentSelection, secondModel)
        XCTAssertEqual(driverSnapshot.maxOperationsInFlight, 1)
        XCTAssertEqual(driverSnapshot.maxResidentSelections, 1)
        XCTAssertEqual(driverSnapshot.lifecycleViolations, 0)

        let arbiterSnapshot = await arbiter.snapshot()
        XCTAssertEqual(arbiterSnapshot.residentSelection, secondModel)
        XCTAssertEqual(arbiterSnapshot.metrics.rootGrants, 1)
        XCTAssertEqual(arbiterSnapshot.metrics.decodeGrants, 2)
        XCTAssertEqual(arbiterSnapshot.metrics.residencyTransitions, 3)
        XCTAssertEqual(arbiterSnapshot.metrics.maxRootOwners, 1)
        XCTAssertEqual(arbiterSnapshot.metrics.maxDecodeOwners, 1)
        XCTAssertEqual(arbiterSnapshot.metrics.maxResidentSelections, 1)
        XCTAssertEqual(arbiterSnapshot.metrics.maxConcurrentResidencyTransitions, 1)
    }

    func testStaleLoadCleansUpBeforeAQueuedOwnerCanRun() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("stale-load")
        await driver.blockNext(.load, selection: selection)

        let firstRoot = try await arbiter.acquireRoot(
            runID: resourceRun(401),
            admissionSequence: 1
        )
        let secondRootTask = Task {
            try await arbiter.acquireRoot(runID: resourceRun(402), admissionSequence: 2)
        }
        await waitForResourceWaiters(arbiter, expected: [2])

        let decodeTask = Task {
            try await arbiter.acquireDecode(selection: selection, rootLease: firstRoot)
        }
        await driver.waitForCallCount(1)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(firstRoot) }

        let cleanupPending = await arbiter.updatePressure(
            ResourcePressureSnapshot(thermal: .critical)
        )
        XCTAssertEqual(cleanupPending, .residencyCleanupPending(.thermalCritical))
        await expectAsyncValue(true) { await driver.resumeNext(.load, selection: selection) }

        await expectResourceError(.residencyOperationSuperseded) {
            try await decodeTask.value
        }
        let whileDeferred = await arbiter.snapshot()
        XCTAssertNil(whileDeferred.rootOwner)
        XCTAssertNil(whileDeferred.residentSelection)
        XCTAssertEqual(whileDeferred.waiters.map(\.admissionSequence), [2])

        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }
        let secondRoot = try await secondRootTask.value
        XCTAssertEqual(secondRoot.runID, resourceRun(402))
        await expectAsyncValue(.released) { await arbiter.releaseRoot(secondRoot) }

        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(
            driverSnapshot.calls,
            [
                .init(operation: .load, selection: selection),
                .init(operation: .cancelAndDrain, selection: selection),
                .init(operation: .unload, selection: selection),
            ]
        )
        XCTAssertNil(driverSnapshot.residentSelection)
        XCTAssertEqual(driverSnapshot.maxOperationsInFlight, 1)
        XCTAssertEqual(driverSnapshot.lifecycleViolations, 0)
    }

    func testOnlineDecodeSkipsResidencyDriverEntirely() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let online = try resourceModel("online")
        let root = try await arbiter.acquireRoot(runID: resourceRun(701), admissionSequence: 1)

        // The online provider is not in the local residency registry: acquiring its decode lane must
        // not call the driver at all, and cancelling must not drain a nonexistent local model.
        let decode = try await arbiter.acquireDecode(
            selection: online,
            rootLease: root,
            requiresResidency: false
        )
        await expectAsyncValue(.released) {
            await arbiter.cancelDrainAndReleaseDecode(decode)
        }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }

        let driverSnapshot = await driver.snapshot()
        XCTAssertTrue(
            driverSnapshot.calls.isEmpty,
            "online decode must never touch the local residency driver"
        )
        XCTAssertNil(driverSnapshot.residentSelection)
        XCTAssertEqual(driverSnapshot.maxOperationsInFlight, 0)
        XCTAssertEqual(driverSnapshot.maxResidentSelections, 0)
        let arbiterSnapshot = await arbiter.snapshot()
        XCTAssertEqual(arbiterSnapshot.metrics.residencyTransitions, 0)
    }

    func testStaleSwitchCompletionCannotCommitAfterRootRelease() async throws {
        let firstModel = try resourceModel("stale-switch-first")
        let secondModel = try resourceModel("stale-switch-second")

        do {
            let driver = ScriptedModelResidencyDriver()
            let arbiter = ResourceArbiter(driver: driver)
            let root = try await arbiter.acquireRoot(
                runID: resourceRun(451),
                admissionSequence: 1
            )
            let decode = try await arbiter.acquireDecode(
                selection: firstModel,
                rootLease: root
            )
            await expectAsyncValue(.released) { await arbiter.releaseDecode(decode) }
            await driver.blockNext(.cancelAndDrain, selection: firstModel)

            let switchTask = Task {
                try await arbiter.acquireDecode(selection: secondModel, rootLease: root)
            }
            await driver.waitForCallCount(2)
            await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }
            await expectAsyncValue(true) {
                await driver.resumeNext(.cancelAndDrain, selection: firstModel)
            }
            await expectResourceError(.residencyOperationSuperseded) {
                try await switchTask.value
            }

            let snapshot = await arbiter.snapshot()
            XCTAssertNil(snapshot.rootOwner)
            XCTAssertNil(snapshot.residentSelection)
            XCTAssertNil(snapshot.residencyTransition)
        }

        do {
            let driver = ScriptedModelResidencyDriver()
            let arbiter = ResourceArbiter(driver: driver)
            let root = try await arbiter.acquireRoot(
                runID: resourceRun(452),
                admissionSequence: 1
            )
            let decode = try await arbiter.acquireDecode(
                selection: firstModel,
                rootLease: root
            )
            await expectAsyncValue(.released) { await arbiter.releaseDecode(decode) }
            await driver.blockNext(.unload, selection: firstModel)

            let switchTask = Task {
                try await arbiter.acquireDecode(selection: secondModel, rootLease: root)
            }
            await driver.waitForCallCount(3)
            await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }
            await expectAsyncValue(true) {
                await driver.resumeNext(.unload, selection: firstModel)
            }
            await expectResourceError(.residencyOperationSuperseded) {
                try await switchTask.value
            }

            let snapshot = await arbiter.snapshot()
            XCTAssertNil(snapshot.rootOwner)
            XCTAssertNil(snapshot.residentSelection)
            XCTAssertNil(snapshot.residencyTransition)
        }
    }

    func testStaleLoadCleanupFailureFaultsClosed() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("stale-load-cleanup-failure")
        await driver.blockNext(.load, selection: selection)
        let root = try await arbiter.acquireRoot(runID: resourceRun(453), admissionSequence: 1)
        let decodeTask = Task {
            try await arbiter.acquireDecode(selection: selection, rootLease: root)
        }
        await driver.waitForCallCount(1)
        await driver.failNext(.unload, selection: selection)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }
        await expectAsyncValue(true) { await driver.resumeNext(.load, selection: selection) }

        let cleanupFailure = ModelResidencyFailure(
            operation: .unload,
            selection: selection,
            detail: "scriptedFailure"
        )
        await expectResourceError(.residencyFaulted(cleanupFailure)) {
            try await decodeTask.value
        }
        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.rootOwner)
        XCTAssertEqual(snapshot.residencyFault, cleanupFailure)
        XCTAssertEqual(snapshot.residentSelection, selection)
        XCTAssertNil(snapshot.residencyTransition)
    }

    func testStaleDrainCannotClearANewerDecodeOwner() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("stale-drain")
        let run = resourceRun(501)
        let root = try await arbiter.acquireRoot(runID: run, admissionSequence: 1)
        let firstDecode = try await arbiter.acquireDecode(
            selection: selection,
            rootLease: root
        )

        await driver.blockNext(.cancelAndDrain, selection: selection)
        let drainTask = Task {
            await arbiter.cancelDrainAndReleaseDecode(firstDecode)
        }
        await driver.waitForCallCount(2)

        await expectAsyncValue(.transitionInProgress) {
            await arbiter.cancelDrainAndReleaseDecode(firstDecode)
        }
        await expectAsyncValue(.released) { await arbiter.releaseDecode(firstDecode) }
        await expectResourceError(.residencyTransitionInProgress) {
            try await arbiter.acquireDecode(selection: selection, rootLease: root)
        }

        await expectAsyncValue(true) {
            await driver.resumeNext(.cancelAndDrain, selection: selection)
        }
        await expectAsyncValue(.superseded) { await drainTask.value }

        let secondDecode = try await arbiter.acquireDecode(
            selection: selection,
            rootLease: root
        )
        await expectAsyncValue(.alreadyReleased) { await arbiter.releaseDecode(firstDecode) }
        let withNewOwner = await arbiter.snapshot()
        XCTAssertEqual(withNewOwner.decodeOwner?.runID, run)
        XCTAssertEqual(withNewOwner.decodeOwner?.selection, selection)

        await expectAsyncValue(.released) { await arbiter.releaseDecode(secondDecode) }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }
        let finalSnapshot = await arbiter.snapshot()
        XCTAssertNil(finalSnapshot.decodeOwner)
        XCTAssertEqual(finalSnapshot.metrics.maxDecodeOwners, 1)
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(driverSnapshot.maxOperationsInFlight, 1)
    }

    func testPressureDefersAdmissionsWithoutPreemptingAndResumesQueue() async throws {
        let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())

        await expectAsyncValue(.noAction) { await arbiter.updatePressure(.nominal) }
        await expectAsyncValue(.noAction) {
            await arbiter.updatePressure(
                ResourcePressureSnapshot(thermal: .fair, memory: .warning)
            )
        }
        await expectAsyncValue(.admissionsDeferred(.thermalCritical)) {
            await arbiter.updatePressure(ResourcePressureSnapshot(thermal: .critical))
        }
        await expectResourceError(.admissionDeferred(.thermalCritical)) {
            try await arbiter.acquireRoot(runID: resourceRun(601), admissionSequence: 1)
        }
        await expectAsyncValue(.admissionsDeferred(.memoryCritical)) {
            await arbiter.updatePressure(
                ResourcePressureSnapshot(thermal: .nominal, memory: .critical)
            )
        }
        await expectAsyncValue(.admissionsDeferred(.thermalSerious)) {
            await arbiter.updatePressure(ResourcePressureSnapshot(thermal: .serious))
        }
        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }

        let ownerRun = resourceRun(602)
        let owner = try await arbiter.acquireRoot(runID: ownerRun, admissionSequence: 2)
        let waiterTask = Task {
            try await arbiter.acquireRoot(runID: resourceRun(603), admissionSequence: 3)
        }
        await waitForResourceWaiters(arbiter, expected: [3])

        await expectAsyncValue(
            .ownerMustQuiesce(runID: ownerRun, reason: .thermalSerious)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(thermal: .serious))
        }
        let pressureModel = try resourceModel("pressure-admission")
        await expectResourceError(.admissionDeferred(.thermalSerious)) {
            try await arbiter.acquireDecode(selection: pressureModel, rootLease: owner)
        }
        let stillOwned = await arbiter.snapshot()
        XCTAssertEqual(stillOwned.rootOwner?.runID, ownerRun)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(owner) }
        let deferred = await arbiter.snapshot()
        XCTAssertNil(deferred.rootOwner)
        XCTAssertEqual(deferred.waiters.map(\.admissionSequence), [3])

        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }
        let waiter = try await waiterTask.value
        XCTAssertEqual(waiter.runID, resourceRun(603))
        await expectResourceError(.rootLeaseMismatch(ownerRun)) {
            try await arbiter.acquireDecode(selection: pressureModel, rootLease: owner)
        }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(waiter) }
        let finalSnapshot = await arbiter.snapshot()
        XCTAssertEqual(finalSnapshot.metrics.maxRootOwners, 1)
    }

    func testIdlePressureEvictionReportsBothDriverFailurePhases() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("pressure")
        let root = try await arbiter.acquireRoot(runID: resourceRun(701), admissionSequence: 1)
        let decode = try await arbiter.acquireDecode(selection: selection, rootLease: root)
        await expectAsyncValue(.released) { await arbiter.releaseDecode(decode) }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }

        await driver.failNext(.cancelAndDrain, selection: selection)
        let cancelFailure = ModelResidencyFailure(
            operation: .cancelAndDrain,
            selection: selection,
            detail: "scriptedFailure"
        )
        await expectAsyncValue(
            .idleResidencyEvictionFailed(cancelFailure, reason: .memoryCritical)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(memory: .critical))
        }
        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }

        await driver.failNext(.unload, selection: selection)
        let unloadFailure = ModelResidencyFailure(
            operation: .unload,
            selection: selection,
            detail: "scriptedFailure"
        )
        await expectAsyncValue(
            .idleResidencyEvictionFailed(unloadFailure, reason: .thermalCritical)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(thermal: .critical))
        }
        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }

        await expectAsyncValue(
            .idleResidencyEvicted(selection: selection, reason: .memoryCritical)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(memory: .critical))
        }
        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.residentSelection)
        let driverSnapshot = await driver.snapshot()
        XCTAssertNil(driverSnapshot.residentSelection)
    }

    func testRootReleaseUnderPressurePerformsTypedIdleCleanup() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("release-pressure")
        let run = resourceRun(801)
        let root = try await arbiter.acquireRoot(runID: run, admissionSequence: 1)
        let decode = try await arbiter.acquireDecode(selection: selection, rootLease: root)
        await expectAsyncValue(.released) { await arbiter.releaseDecode(decode) }
        await expectAsyncValue(
            .ownerMustQuiesce(runID: run, reason: .memoryCritical)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(memory: .critical))
        }

        await driver.failNext(.cancelAndDrain, selection: selection)
        let failure = ModelResidencyFailure(
            operation: .cancelAndDrain,
            selection: selection,
            detail: "scriptedFailure"
        )
        await expectAsyncValue(.releasedWithCleanupFailure(failure)) {
            await arbiter.releaseRoot(root)
        }
        let released = await arbiter.snapshot()
        XCTAssertNil(released.rootOwner)
        XCTAssertEqual(released.residentSelection, selection)

        await expectAsyncValue(
            .idleResidencyEvicted(selection: selection, reason: .memoryCritical)
        ) {
            await arbiter.updatePressure(ResourcePressureSnapshot(memory: .critical))
        }
        await expectAsyncValue(.admissionsResumed) { await arbiter.updatePressure(.nominal) }
    }

    func testDriverFailuresKeepKnownResidencyRetryable() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let first = try resourceModel("failure-first")
        let second = try resourceModel("failure-second")
        let root = try await arbiter.acquireRoot(runID: resourceRun(901), admissionSequence: 1)

        await driver.failNext(.load, selection: first)
        await expectResourceError(
            .driverFailure(.init(operation: .load, selection: first, detail: "scriptedFailure"))
        ) {
            try await arbiter.acquireDecode(selection: first, rootLease: root)
        }
        let afterLoadFailure = await arbiter.snapshot()
        XCTAssertNil(afterLoadFailure.residentSelection)

        let firstDecode = try await arbiter.acquireDecode(selection: first, rootLease: root)
        await expectAsyncValue(.released) { await arbiter.releaseDecode(firstDecode) }

        await driver.failNext(.cancelAndDrain, selection: first)
        await expectResourceError(
            .driverFailure(.init(operation: .cancelAndDrain, selection: first, detail: "scriptedFailure"))
        ) {
            try await arbiter.acquireDecode(selection: second, rootLease: root)
        }
        let afterDrainFailure = await arbiter.snapshot()
        XCTAssertEqual(afterDrainFailure.residentSelection, first)

        await driver.failNext(.unload, selection: first)
        await expectResourceError(
            .driverFailure(.init(operation: .unload, selection: first, detail: "scriptedFailure"))
        ) {
            try await arbiter.acquireDecode(selection: second, rootLease: root)
        }
        let afterUnloadFailure = await arbiter.snapshot()
        XCTAssertEqual(afterUnloadFailure.residentSelection, first)

        let secondDecode = try await arbiter.acquireDecode(selection: second, rootLease: root)
        await driver.failNext(.cancelAndDrain, selection: second)
        await expectAsyncValue(
            .driverFailure(.init(operation: .cancelAndDrain, selection: second, detail: "scriptedFailure"))
        ) {
            await arbiter.cancelDrainAndReleaseDecode(secondDecode)
        }
        let afterDecodeDrainFailure = await arbiter.snapshot()
        XCTAssertEqual(afterDecodeDrainFailure.decodeOwner?.selection, second)
        await expectAsyncValue(.released) { await arbiter.releaseDecode(secondDecode) }
        await expectAsyncValue(.released) { await arbiter.releaseRoot(root) }

        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(driverSnapshot.maxOperationsInFlight, 1)
        XCTAssertEqual(driverSnapshot.maxResidentSelections, 1)
        XCTAssertEqual(driverSnapshot.lifecycleViolations, 0)
    }

    func testFailedLoadCleanupFaultsClosedAndFailsQueuedAdmissions() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try resourceModel("faulted")
        let owner = try await arbiter.acquireRoot(runID: resourceRun(1001), admissionSequence: 1)
        let waiter = Task {
            try await arbiter.acquireRoot(runID: resourceRun(1002), admissionSequence: 2)
        }
        await waitForResourceWaiters(arbiter, expected: [2])

        await driver.failNext(.load, selection: selection)
        await driver.failNext(.cancelAndDrain, selection: selection)
        let cleanupFailure = ModelResidencyFailure(
            operation: .cancelAndDrain,
            selection: selection,
            detail: "scriptedFailure"
        )
        await expectResourceError(.residencyFaulted(cleanupFailure)) {
            try await arbiter.acquireDecode(selection: selection, rootLease: owner)
        }
        await expectResourceError(.residencyFaulted(cleanupFailure)) {
            try await arbiter.acquireDecode(selection: selection, rootLease: owner)
        }
        await expectResourceError(.residencyFaulted(cleanupFailure)) {
            try await waiter.value
        }
        await expectResourceError(.residencyFaulted(cleanupFailure)) {
            try await arbiter.acquireRoot(runID: resourceRun(1003), admissionSequence: 3)
        }

        let faulted = await arbiter.snapshot()
        XCTAssertEqual(faulted.residencyFault, cleanupFailure)
        XCTAssertEqual(faulted.residentSelection, selection)
        XCTAssertTrue(faulted.waiters.isEmpty)
        await expectAsyncValue(.released) { await arbiter.releaseRoot(owner) }
        let afterRelease = await arbiter.snapshot()
        XCTAssertNil(afterRelease.rootOwner)
    }
}

private func resourceRun(_ value: Int) -> AgentRunID {
    AgentRunID(rawValue: RuntimeTestFixtures.uuid(10_000 + value))
}

private func resourceModel(_ name: String) throws -> AgentModelSelection {
    AgentModelSelection(
        providerID: try AgentModelProviderID("resource-tests"),
        modelID: try AgentModelID(name),
        variantID: try AgentModelVariantID("default"),
        capabilityVersion: try SemanticVersion(major: 1, minor: 0, patch: 0)
    )
}

private func waitForResourceWaiters(
    _ arbiter: ResourceArbiter,
    expected sequences: [UInt64],
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<10_000 {
        let actual = await arbiter.snapshot().waiters.map(\.admissionSequence)
        if actual == sequences { return }
        await Task.yield()
    }
    let actual = await arbiter.snapshot().waiters.map(\.admissionSequence)
    XCTFail("Expected queued sequences \(sequences), got \(actual)", file: file, line: line)
}

private func expectResourceError<T>(
    _ expected: ResourceArbiterError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ResourceArbiterError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

private func expectAsyncValue<T: Equatable>(
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async -> T
) async {
    let actual = await operation()
    XCTAssertEqual(actual, expected, file: file, line: line)
}
