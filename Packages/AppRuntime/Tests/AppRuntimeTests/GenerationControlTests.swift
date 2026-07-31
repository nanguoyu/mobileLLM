// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func advance(by nanos: UInt64) {
        lock.lock()
        now += nanos
        lock.unlock()
    }
}

private final class RecordingControl: GenerationControlling, @unchecked Sendable {
    private let lock = NSLock()
    private let log: EventLog
    private var cancelled = false

    init(log: EventLog) { self.log = log }

    var isPaused: Bool { false }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func pause() {}
    func resume() {}
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkpoint() async throws {
        log.append("control")
        if isCancelled { throw CancellationError() }
    }
}

private final class RecordingThermalGovernor: ThermalGoverning, @unchecked Sendable {
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    func throttleIfNeeded(onCooling: (@Sendable () -> Void)?) async throws {
        log.append("thermal")
    }
}

final class GenerationControlTests: XCTestCase {

    func testCheckpointPassesImmediatelyWhenRunning() async throws {
        let control = GenerationControl()
        try await control.checkpoint()
        XCTAssertFalse(control.isPaused)
        XCTAssertFalse(control.isCancelled)
    }

    func testPauseSuspendsWithoutBlockingAndResumeWakesCheckpoint() async throws {
        let control = GenerationControl()
        control.pause()

        let entered = expectation(description: "checkpoint entered")
        let passed = expectation(description: "checkpoint passed")
        let task = Task {
            entered.fulfill()
            try await control.checkpoint()
            passed.fulfill()
        }

        await fulfillment(of: [entered], timeout: 1)
        let stillBlocked = expectation(description: "paused checkpoint stays suspended")
        stillBlocked.isInverted = true
        Task {
            try await task.value
            stillBlocked.fulfill()
        }
        await fulfillment(of: [stillBlocked], timeout: 0.05)
        XCTAssertTrue(control.isPaused)

        control.resume()
        try await task.value
        await fulfillment(of: [passed], timeout: 1)
        XCTAssertFalse(control.isPaused)
    }

    func testCancelIsTerminalAndWakesPausedCheckpoint() async {
        let control = GenerationControl()
        control.pause()
        let task = Task { try await control.checkpoint() }

        await Task.yield()
        control.cancel()

        do {
            try await task.value
            XCTFail("cancel must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertTrue(control.isCancelled)
        do {
            try await control.checkpoint()
            XCTFail("a cancelled control cannot be reused")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testGovernanceCallsControlBeforeAndAfterThermalBoundary() async throws {
        let log = EventLog()
        let governance = GenerationGovernance(
            control: RecordingControl(log: log),
            thermalGovernor: RecordingThermalGovernor(log: log))

        try await governance.checkpoint()

        XCTAssertEqual(log.snapshot, ["control", "thermal", "control"])
    }

    func testCooperativeCheckpointDoesNotRunThermalWork() async throws {
        let log = EventLog()
        let governance = GenerationGovernance(
            control: RecordingControl(log: log),
            thermalGovernor: RecordingThermalGovernor(log: log))

        try await governance.cooperativeCheckpoint()

        XCTAssertEqual(log.snapshot, ["control"])
    }

    func testThermalAndMemoryProbeIsRateLimitedWhileControlRemainsPerBoundary() async throws {
        let log = EventLog()
        let clock = TestClock()
        let governance = GenerationGovernance(
            control: RecordingControl(log: log),
            thermalGovernor: RecordingThermalGovernor(log: log),
            thermalCheckIntervalNanos: 250,
            monotonicNow: { clock.read() })

        try await governance.checkpoint()
        try await governance.checkpoint()
        XCTAssertEqual(log.snapshot, ["control", "thermal", "control", "control"],
                       "rapid token boundaries must not probe system state twice")

        clock.advance(by: 250)
        try await governance.checkpoint()
        XCTAssertEqual(log.snapshot,
                       ["control", "thermal", "control", "control", "control", "thermal", "control"])
    }
}

final class GenerationLifecycleTests: XCTestCase {

    private func governance(log: EventLog = EventLog()) -> GenerationGovernance {
        GenerationGovernance(
            control: RecordingControl(log: log),
            thermalGovernor: RecordingThermalGovernor(log: log))
    }

    func testStartingNewLeaseCancelsPreviousGenerationOnly() {
        let lifecycle = GenerationLifecycle()
        let firstLog = EventLog()
        let secondLog = EventLog()
        let firstGovernance = governance(log: firstLog)
        let secondGovernance = governance(log: secondLog)
        let first = lifecycle.begin(using: firstGovernance)
        let firstTaskCancelled = expectation(description: "first task cancelled")
        lifecycle.attachTaskCancellation({ firstTaskCancelled.fulfill() }, to: first)

        let second = lifecycle.begin(using: secondGovernance)

        wait(for: [firstTaskCancelled], timeout: 1)
        XCTAssertTrue(firstGovernance.isCancelled)
        XCTAssertFalse(secondGovernance.isCancelled)
        lifecycle.end(first)
        lifecycle.end(second)
    }

    func testAttachingTaskAfterCancellationClosesTheRace() {
        let lifecycle = GenerationLifecycle()
        let lease = lifecycle.begin(using: governance())
        lifecycle.cancel(lease)
        let cancelled = expectation(description: "late task cancelled immediately")

        lifecycle.attachTaskCancellation({ cancelled.fulfill() }, to: lease)

        wait(for: [cancelled], timeout: 1)
        lifecycle.end(lease)
    }

    func testCancelAllAndWaitDoesNotReturnBeforeTasksEnd() async {
        let lifecycle = GenerationLifecycle()
        let lease = lifecycle.begin(using: governance())
        let taskCancelled = expectation(description: "task cancellation requested")
        lifecycle.attachTaskCancellation({ taskCancelled.fulfill() }, to: lease)
        let returned = expectation(description: "cancelAllAndWait returned")

        let waiter = Task {
            await lifecycle.cancelAllAndWait()
            returned.fulfill()
        }

        await fulfillment(of: [taskCancelled], timeout: 1)
        let stillWaiting = expectation(description: "waits for native task exit")
        stillWaiting.isInverted = true
        Task {
            await waiter.value
            stillWaiting.fulfill()
        }
        await fulfillment(of: [stillWaiting], timeout: 0.05)

        lifecycle.end(lease)
        await waiter.value
        await fulfillment(of: [returned], timeout: 1)
    }

    func testLeaseStartedDuringDrainIsCancelledBeforeItCanRun() async {
        let lifecycle = GenerationLifecycle()
        let first = lifecycle.begin(using: governance())
        let firstCancelled = expectation(description: "first task cancellation requested")
        lifecycle.attachTaskCancellation({ firstCancelled.fulfill() }, to: first)

        let draining = Task { await lifecycle.cancelAllAndWait() }
        await fulfillment(of: [firstCancelled], timeout: 1)

        let lateGovernance = governance()
        let late = lifecycle.begin(using: lateGovernance)
        let lateTaskCancelled = expectation(description: "racing task cancelled immediately")
        lifecycle.attachTaskCancellation({ lateTaskCancelled.fulfill() }, to: late)
        await fulfillment(of: [lateTaskCancelled], timeout: 1)
        XCTAssertTrue(lateGovernance.isCancelled)

        lifecycle.end(first)
        lifecycle.end(late)
        await draining.value
    }

    func testExplicitDrainRemainsClosedAfterIdleUntilResourceMutationEnds() async {
        let lifecycle = GenerationLifecycle()
        let first = lifecycle.begin(using: governance())
        let firstCancelled = expectation(description: "resident generation cancelled")
        lifecycle.attachTaskCancellation({ firstCancelled.fulfill() }, to: first)

        let draining = Task { await lifecycle.beginDrain() }
        await fulfillment(of: [firstCancelled], timeout: 1)
        lifecycle.end(first)
        let drain = await draining.value

        // `beginDrain` has returned, proving the lifecycle is idle, but the caller has not yet completed
        // its protected resource release. A generation arriving in this exact former race window must die.
        let lateGovernance = governance()
        let late = lifecycle.begin(using: lateGovernance)
        let lateTaskCancelled = expectation(description: "late task cancelled during resource release")
        lifecycle.attachTaskCancellation({ lateTaskCancelled.fulfill() }, to: late)
        await fulfillment(of: [lateTaskCancelled], timeout: 1)
        XCTAssertTrue(lateGovernance.isCancelled)
        lifecycle.end(late)

        lifecycle.endDrain(drain)
        do {
            try await lateGovernance.cooperativeCheckpoint()
            XCTFail("ending the drain must not revive a lease cancelled in the release window")
        } catch is CancellationError {
            // expected: cancellation is terminal
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        let admittedGovernance = governance()
        let admitted = lifecycle.begin(using: admittedGovernance)
        XCTAssertFalse(admittedGovernance.isCancelled)
        lifecycle.end(admitted)
    }
}
