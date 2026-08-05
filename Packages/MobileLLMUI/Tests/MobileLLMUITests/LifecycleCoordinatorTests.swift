// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

// TEST-ID: AHT-LIFECYCLE-001
// TEST-ID: AHT-LIFECYCLE-003
@MainActor
final class LifecycleCoordinatorTests: XCTestCase {
    func testMultiSceneAggregationOnlyBackgroundsWhenEverySceneLeavesForeground() async throws {
        let provider = FakeDrainProvider()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        var admitted = true
        var quiesceCount = 0
        var unloadCount = 0
        coordinator.stopAdmittingActions = { admitted = false }
        coordinator.resumeAdmittingActions = { admitted = true }
        coordinator.quiesce = { quiesceCount += 1 }
        coordinator.suspendModel = { unloadCount += 1 }

        // One scene hidden, another still foreground-active: the app must NOT background (iPadOS).
        coordinator.updateSceneStates([.foregroundInactive, .background])
        XCTAssertFalse(coordinator.isInBackground)
        XCTAssertTrue(admitted)
        XCTAssertEqual(provider.beginCount, 0)

        coordinator.updateSceneStates([.background, .background])
        XCTAssertTrue(coordinator.isInBackground)
        XCTAssertFalse(admitted)
        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(coordinator.quiesceIssueCount, 1)
        XCTAssertEqual(coordinator.drainState, .draining)

        try await waitUntil {
            coordinator.drainState == .drained
        }
        XCTAssertEqual(quiesceCount, 1)
        XCTAssertEqual(unloadCount, 1)
        XCTAssertTrue(provider.tokens.first?.didEnd == true)

        coordinator.updateSceneStates([.foregroundActive])
        XCTAssertFalse(coordinator.isInBackground)
        XCTAssertTrue(admitted)
        XCTAssertEqual(coordinator.drainState, .idle)
        // Foreground return never auto-resumes; quiesce stays issued exactly once for this episode.
        XCTAssertEqual(quiesceCount, 1)
    }

    func testEmptySceneSnapshotAtLaunchIsTreatedAsForeground() async {
        let provider = FakeDrainProvider()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        coordinator.updateSceneStates([])
        XCTAssertFalse(coordinator.isInBackground)
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExpirationReissuesTheSameIdempotentQuiesceCommand() async throws {
        let provider = FakeDrainProvider()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        var quiesceCount = 0
        coordinator.quiesce = { quiesceCount += 1 }
        coordinator.suspendModel = {}

        coordinator.enterBackground()
        try await waitUntil {
            coordinator.drainState == .drained
        }
        XCTAssertEqual(quiesceCount, 1)

        // The OS lease expires after the first drain: the expiration handler issues the SAME
        // idempotent, versioned quiesce command (spec §19.1) and the record keeps the expired state.
        provider.fireExpiration()
        XCTAssertTrue(coordinator.didExpireDuringLastBackground)
        XCTAssertEqual(coordinator.drainState, .expired)
        XCTAssertEqual(coordinator.quiesceIssueCount, 2)

        try await waitUntil {
            quiesceCount == 2
        }
        // Recovery never assumes the expiration handler completed: the state stays expired, and the
        // run's own versioned pause receipt decides whether the second command lands.
        XCTAssertEqual(coordinator.drainState, .expired)
    }

    func testBackgroundWithoutAgentRuntimeStillUnloadsWeightsAndStopsAdmission() async throws {
        let provider = FakeDrainProvider()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        var admitted = true
        var unloaded = 0
        coordinator.stopAdmittingActions = { admitted = false }
        coordinator.resumeAdmittingActions = { admitted = true }
        coordinator.suspendModel = { unloaded += 1 }
        // No quiesce closure: rollout-off state (no agent runtime).

        coordinator.enterBackground()
        XCTAssertFalse(admitted)
        XCTAssertEqual(provider.beginCount, 1)
        try await waitUntil {
            coordinator.drainState == .drained
        }
        XCTAssertEqual(unloaded, 1)
    }

    func testExpirationDuringInFlightQuiesceStillUnloadsWeights() async throws {
        let provider = FakeDrainProvider()
        let coordinator = LifecycleCoordinator(drainProvider: provider)
        var continuations: [CheckedContinuation<Void, Never>] = []
        var unloaded = 0
        coordinator.quiesce = {
            await withCheckedContinuation { continuations.append($0) }
        }
        coordinator.suspendModel = { unloaded += 1 }

        coordinator.enterBackground()
        try await waitUntil { continuations.count == 1 }
        // The OS lease expires while the first quiesce is still in flight; the expiration handler
        // reissues the same idempotent command (spec §19.1).
        provider.fireExpiration()
        XCTAssertEqual(coordinator.drainState, .expired)
        XCTAssertEqual(coordinator.quiesceIssueCount, 2)
        try await waitUntil { continuations.count == 2 }

        for continuation in continuations { continuation.resume() }
        try await waitUntil { unloaded == 1 }
        // Recovery does not assume the expiration handler completed: the record stays expired but
        // the weights were still unloaded.
        XCTAssertEqual(coordinator.drainState, .expired)
        XCTAssertTrue(provider.tokens.first?.didEnd == true)
    }
}

@MainActor
private final class FakeDrainProvider: BackgroundDrainProviding {
    private(set) var beginCount = 0
    private(set) var tokens: [FakeDrainToken] = []
    private var expiration: (@MainActor () -> Void)?

    func beginDrain(
        named name: String,
        expiration: @escaping @MainActor () -> Void
    ) -> any BackgroundDrainToken {
        beginCount += 1
        let token = FakeDrainToken()
        tokens.append(token)
        self.expiration = expiration
        return token
    }

    func fireExpiration() {
        expiration?()
    }
}

@MainActor
private final class FakeDrainToken: BackgroundDrainToken {
    private(set) var isExpired = false
    private(set) var didEnd = false

    func end() {
        didEnd = true
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition timed out")
}
