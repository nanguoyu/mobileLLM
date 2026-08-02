// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

final class ResourceArbiterCancellationInvariantTests: XCTestCase {
    func testCancellationAndPressureCannotReorderSurvivingAdmissions() async throws {
        let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())
        let owner = try await arbiter.acquireRoot(
            runID: invariantRun(100),
            admissionSequence: 100
        )
        let waiter30 = Task {
            try await arbiter.acquireRoot(runID: invariantRun(30), admissionSequence: 30)
        }
        let waiter10 = Task {
            try await arbiter.acquireRoot(runID: invariantRun(10), admissionSequence: 10)
        }
        let waiter20 = Task {
            try await arbiter.acquireRoot(runID: invariantRun(20), admissionSequence: 20)
        }
        await waitForInvariantWaiters(arbiter, expected: [10, 20, 30])

        let pressure = await arbiter.updatePressure(
            ResourcePressureSnapshot(thermal: .serious)
        )
        XCTAssertEqual(
            pressure,
            .ownerMustQuiesce(runID: owner.runID, reason: .thermalSerious)
        )
        waiter10.cancel()
        await assertCancelled { try await waiter10.value }
        await waitForInvariantWaiters(arbiter, expected: [20, 30])

        let ownerRelease = await arbiter.releaseRoot(owner)
        XCTAssertEqual(ownerRelease, .released)
        let deferred = await arbiter.snapshot()
        XCTAssertNil(deferred.rootOwner)
        XCTAssertEqual(deferred.waiters.map(\.admissionSequence), [20, 30])

        let resumed = await arbiter.updatePressure(.nominal)
        XCTAssertEqual(resumed, .admissionsResumed)
        let lease20 = try await waiter20.value
        XCTAssertEqual(lease20.admissionSequence, 20)
        let release20 = await arbiter.releaseRoot(lease20)
        XCTAssertEqual(release20, .released)
        let lease30 = try await waiter30.value
        XCTAssertEqual(lease30.admissionSequence, 30)
        let release30 = await arbiter.releaseRoot(lease30)
        XCTAssertEqual(release30, .released)

        let final = await arbiter.snapshot()
        XCTAssertNil(final.rootOwner)
        XCTAssertTrue(final.waiters.isEmpty)
        XCTAssertEqual(final.metrics.rootGrants, 3)
        XCTAssertEqual(final.metrics.maxRootOwners, 1)
    }

    func testCancellationRacingOwnerHandoffNeverStrandsTheNextWaiter() async throws {
        for iteration in 0..<32 {
            let arbiter = ResourceArbiter(driver: ScriptedModelResidencyDriver())
            let owner = try await arbiter.acquireRoot(
                runID: invariantRun(1_000 + iteration * 10),
                admissionSequence: 100
            )
            let cancelled = Task {
                try await arbiter.acquireRoot(
                    runID: invariantRun(1_001 + iteration * 10),
                    admissionSequence: 1
                )
            }
            let survivor = Task {
                try await arbiter.acquireRoot(
                    runID: invariantRun(1_002 + iteration * 10),
                    admissionSequence: 2
                )
            }
            await waitForInvariantWaiters(arbiter, expected: [1, 2])

            cancelled.cancel()
            async let releaseOutcome = arbiter.releaseRoot(owner)
            await assertCancelled { try await cancelled.value }
            let ownerRelease = await releaseOutcome
            XCTAssertEqual(ownerRelease, .released)

            let survivorLease = try await survivor.value
            XCTAssertEqual(survivorLease.admissionSequence, 2)
            let survivorRelease = await arbiter.releaseRoot(survivorLease)
            XCTAssertEqual(survivorRelease, .released)
            let snapshot = await arbiter.snapshot()
            XCTAssertNil(snapshot.rootOwner, "iteration \(iteration)")
            XCTAssertTrue(snapshot.waiters.isEmpty, "iteration \(iteration)")
            XCTAssertEqual(snapshot.metrics.maxRootOwners, 1, "iteration \(iteration)")
        }
    }

    func testRootReleaseUnderPressureReportsUnloadFailureWithoutLosingResidency() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let selection = try invariantModel("release-unload-failure")
        let root = try await arbiter.acquireRoot(
            runID: invariantRun(3_000),
            admissionSequence: 1
        )
        let decode = try await arbiter.acquireDecode(selection: selection, rootLease: root)
        let decodeRelease = await arbiter.releaseDecode(decode)
        XCTAssertEqual(decodeRelease, .released)

        let pressure = await arbiter.updatePressure(
            ResourcePressureSnapshot(memory: .critical)
        )
        XCTAssertEqual(
            pressure,
            .ownerMustQuiesce(runID: root.runID, reason: .memoryCritical)
        )
        await driver.failNext(.unload, selection: selection)
        let expectedFailure = ModelResidencyFailure(operation: .unload, selection: selection)
        let release = await arbiter.releaseRoot(root)
        XCTAssertEqual(release, .releasedWithCleanupFailure(expectedFailure))

        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.rootOwner)
        XCTAssertEqual(snapshot.residentSelection, selection)
        XCTAssertEqual(snapshot.admissionDeferral, .memoryCritical)
        let driverSnapshot = await driver.snapshot()
        XCTAssertEqual(driverSnapshot.residentSelection, selection)
        XCTAssertEqual(
            Array(driverSnapshot.calls.suffix(2)),
            [
                .init(operation: .cancelAndDrain, selection: selection),
                .init(operation: .unload, selection: selection),
            ]
        )
    }

    func testSupersededSwitchUnloadFailureFaultsQueuedAdmissionsClosed() async throws {
        let driver = ScriptedModelResidencyDriver()
        let arbiter = ResourceArbiter(driver: driver)
        let first = try invariantModel("stale-first")
        let second = try invariantModel("stale-second")
        let root = try await arbiter.acquireRoot(
            runID: invariantRun(4_000),
            admissionSequence: 1
        )
        let firstDecode = try await arbiter.acquireDecode(selection: first, rootLease: root)
        let firstDecodeRelease = await arbiter.releaseDecode(firstDecode)
        XCTAssertEqual(firstDecodeRelease, .released)
        await driver.blockNext(.cancelAndDrain, selection: first)

        let queued = Task {
            try await arbiter.acquireRoot(runID: invariantRun(4_001), admissionSequence: 2)
        }
        await waitForInvariantWaiters(arbiter, expected: [2])
        let switchTask = Task {
            try await arbiter.acquireDecode(selection: second, rootLease: root)
        }
        await driver.waitForCallCount(2)
        await driver.failNext(.unload, selection: first)
        let rootRelease = await arbiter.releaseRoot(root)
        XCTAssertEqual(rootRelease, .released)
        let resumed = await driver.resumeNext(.cancelAndDrain, selection: first)
        XCTAssertTrue(resumed)

        let expectedFailure = ModelResidencyFailure(operation: .unload, selection: first)
        await assertResourceFault(expectedFailure) { try await switchTask.value }
        await assertResourceFault(expectedFailure) { try await queued.value }

        let snapshot = await arbiter.snapshot()
        XCTAssertNil(snapshot.rootOwner)
        XCTAssertEqual(snapshot.residentSelection, first)
        XCTAssertEqual(snapshot.residencyFault, expectedFailure)
        XCTAssertTrue(snapshot.waiters.isEmpty)
    }
}

private func invariantRun(_ value: Int) -> AgentRunID {
    AgentRunID(rawValue: RuntimeTestFixtures.uuid(200_000 + value))
}

private func invariantModel(_ name: String) throws -> AgentModelSelection {
    AgentModelSelection(
        providerID: try AgentModelProviderID("resource-invariant-tests"),
        modelID: try AgentModelID(name),
        variantID: try AgentModelVariantID("default"),
        capabilityVersion: try SemanticVersion(major: 1, minor: 0, patch: 0)
    )
}

private func waitForInvariantWaiters(
    _ arbiter: ResourceArbiter,
    expected: [UInt64],
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<10_000 {
        let actual = await arbiter.snapshot().waiters.map(\.admissionSequence)
        if actual == expected { return }
        await Task.yield()
    }
    let actual = await arbiter.snapshot().waiters.map(\.admissionSequence)
    XCTFail("Expected queued sequences \(expected), got \(actual)", file: file, line: line)
}

private func assertCancelled<T>(
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
        // Expected.
    } catch {
        XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
    }
}

private func assertResourceFault<T>(
    _ expected: ModelResidencyFailure,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected residency fault \(expected)", file: file, line: line)
    } catch ResourceArbiterError.residencyFaulted(let failure) {
        XCTAssertEqual(failure, expected, file: file, line: line)
    } catch {
        XCTFail("Expected residency fault \(expected), got \(error)", file: file, line: line)
    }
}
