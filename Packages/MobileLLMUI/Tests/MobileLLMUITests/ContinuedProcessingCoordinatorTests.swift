// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

// TEST-ID: AHT-LIFECYCLE-002
@MainActor
final class ContinuedProcessingCoordinatorTests: XCTestCase {
    private let conversationID = UUID()
    private let prefix = "fixture.mobilellm.continuedProcessing"

    func testDisabledNeverSubmits() {
        let scheduler = FakeScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        coordinator.isEnabled = { false }

        coordinator.submitIfEligible(conversationID: conversationID)

        XCTAssertEqual(scheduler.submitted.count, 0)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testEligibleRunSubmitsWithGpuWhenDeviceSupportsIt() {
        let scheduler = FakeScheduler()
        scheduler.supportedResources = [.gpu]
        let coordinator = makeCoordinator(scheduler: scheduler)
        coordinator.requiresGPUForRun = { _ in true }

        coordinator.submitIfEligible(conversationID: conversationID)

        XCTAssertEqual(scheduler.submitted.count, 1)
        let request = scheduler.submitted[0]
        XCTAssertEqual(request.identifier, coordinator.identifier(for: conversationID))
        XCTAssertTrue(request.requiresGPU)
        XCTAssertEqual(coordinator.phase, .submitted)
        XCTAssertEqual(coordinator.activeConversationID, conversationID)
    }

    func testGpuUnsupportedRejectsAndQuiescesIntoForegroundWait() async throws {
        let scheduler = FakeScheduler()
        scheduler.supportedResources = []
        let coordinator = makeCoordinator(scheduler: scheduler)
        coordinator.requiresGPUForRun = { _ in true }
        var quiesceCount = 0
        coordinator.quiesce = { quiesceCount += 1 }

        coordinator.submitIfEligible(conversationID: conversationID)

        guard case .rejected(let reason) = coordinator.phase else {
            return XCTFail("expected rejection, got \(coordinator.phase)")
        }
        XCTAssertTrue(reason.contains("GPU"))
        XCTAssertEqual(scheduler.submitted.count, 0)
        try await waitUntil { quiesceCount == 1 }
    }

    func testImmediateRejectionCancelsPendingAndQuiesces() async throws {
        let scheduler = FakeScheduler()
        scheduler.submitError = .notImmediatelyRunnable(
            reason: "The system cannot start continued processing immediately."
        )
        let coordinator = makeCoordinator(scheduler: scheduler)
        var quiesceCount = 0
        coordinator.quiesce = { quiesceCount += 1 }

        coordinator.submitIfEligible(conversationID: conversationID)

        guard case .rejected(let reason) = coordinator.phase else {
            return XCTFail("expected rejection, got \(coordinator.phase)")
        }
        XCTAssertTrue(reason.contains("immediately"))
        // Any pre-existing queued request was explicitly cancelled before the transition.
        XCTAssertEqual(scheduler.cancelled, [coordinator.identifier(for: conversationID)])
        try await waitUntil { quiesceCount == 1 }
    }

    func testGrantedTaskReportsTruthfulProgress() {
        let scheduler = FakeScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        coordinator.progressFraction = { _ in 0.42 }
        let task = FakeTask(identifier: coordinator.identifier(for: conversationID))

        coordinator.handleTask(task, conversationID: conversationID)

        XCTAssertEqual(coordinator.phase, .running)
        XCTAssertEqual(task.lastProgress?.completed, 42)
        XCTAssertEqual(task.lastProgress?.total, 100)
    }

    func testExpirationQuiescesAndCompletesTaskUnsuccessfully() async throws {
        let scheduler = FakeScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let task = FakeTask(identifier: coordinator.identifier(for: conversationID))
        var quiesceCount = 0
        coordinator.quiesce = { quiesceCount += 1 }
        coordinator.handleTask(task, conversationID: conversationID)

        coordinator.handleExpiration()

        XCTAssertEqual(coordinator.phase, .expired)
        XCTAssertEqual(task.completedSuccess, false)
        try await waitUntil { quiesceCount == 1 }
        XCTAssertNotNil(coordinator.lastDiagnostic)
    }

    func testUserCancellationMapsToExplicitCancelCommand() async throws {
        let scheduler = FakeScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let task = FakeTask(identifier: coordinator.identifier(for: conversationID))
        var cancelledIDs: [UUID] = []
        coordinator.cancelRun = { id in cancelledIDs.append(id) }
        coordinator.handleTask(task, conversationID: conversationID)

        coordinator.handleUserCancellation()

        XCTAssertEqual(coordinator.phase, .cancelled)
        XCTAssertEqual(task.completedSuccess, false)
        XCTAssertEqual(scheduler.cancelled, [coordinator.identifier(for: conversationID)])
        try await waitUntil { cancelledIDs.count == 1 }
        XCTAssertEqual(cancelledIDs, [conversationID])
    }

    func testRunFinishedCompletesTaskSuccessfully() {
        let scheduler = FakeScheduler()
        let coordinator = makeCoordinator(scheduler: scheduler)
        let task = FakeTask(identifier: coordinator.identifier(for: conversationID))
        coordinator.handleTask(task, conversationID: conversationID)

        coordinator.runFinished(conversationID: conversationID)

        XCTAssertEqual(coordinator.phase, .finished)
        XCTAssertEqual(task.completedSuccess, true)
        XCTAssertNil(coordinator.activeConversationID)
        XCTAssertEqual(scheduler.cancelled, [coordinator.identifier(for: conversationID)])
    }

    func testIdentifierRoundTrip() {
        let coordinator = makeCoordinator(scheduler: FakeScheduler())
        let identifier = coordinator.identifier(for: conversationID)
        let recovered = ContinuedProcessingCoordinator.conversationID(
            fromIdentifier: identifier,
            prefix: prefix
        )
        XCTAssertEqual(recovered, conversationID)
        XCTAssertNil(ContinuedProcessingCoordinator.conversationID(
            fromIdentifier: "other.app.task.123",
            prefix: prefix
        ))
    }

    func testRejectionClearsSlotSoAnotherConversationCanSubmit() {
        let scheduler = FakeScheduler()
        scheduler.submitError = .notImmediatelyRunnable(
            reason: "The system cannot start continued processing immediately."
        )
        let coordinator = makeCoordinator(scheduler: scheduler)

        coordinator.submitIfEligible(conversationID: conversationID)
        guard case .rejected = coordinator.phase else {
            return XCTFail("expected rejection, got \(coordinator.phase)")
        }
        XCTAssertNil(coordinator.activeConversationID)
        XCTAssertNil(coordinator.activeIdentifier)

        scheduler.submitError = nil
        let other = UUID()
        coordinator.submitIfEligible(conversationID: other)
        XCTAssertEqual(coordinator.phase, .submitted)
        XCTAssertEqual(coordinator.activeConversationID, other)
    }

    private func makeCoordinator(scheduler: FakeScheduler) -> ContinuedProcessingCoordinator {
        let coordinator = ContinuedProcessingCoordinator(
            scheduler: scheduler,
            identifierPrefix: prefix
        )
        coordinator.isEnabled = { true }
        coordinator.isRunEligible = { _ in true }
        coordinator.requiresGPUForRun = { _ in false }
        coordinator.progressFraction = { _ in 0.5 }
        return coordinator
    }
}

@MainActor
private final class FakeScheduler: ContinuedProcessingScheduling {
    var isAvailable = true
    var supportedResources: Set<ContinuedProcessingResource> = []
    var submitted: [ContinuedProcessingRequest] = []
    var cancelled: [String] = []
    var submitError: ContinuedProcessingSubmissionError?

    func register(
        identifier: String,
        handler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
    ) {}

    func submit(_ request: ContinuedProcessingRequest) throws -> Bool {
        if let submitError { throw submitError }
        submitted.append(request)
        return true
    }

    func cancelPending(identifier: String) {
        cancelled.append(identifier)
    }
}

@MainActor
private final class FakeTask: ContinuedProcessingTaskHandle {
    let identifier: String
    private(set) var isExpired = false
    private(set) var lastProgress: (completed: Int64, total: Int64)?
    private(set) var completedSuccess: Bool?

    init(identifier: String) {
        self.identifier = identifier
    }

    func setProgress(completed: Int64, total: Int64) {
        lastProgress = (completed, total)
    }

    func setTaskCompleted(success: Bool) {
        completedSuccess = success
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
