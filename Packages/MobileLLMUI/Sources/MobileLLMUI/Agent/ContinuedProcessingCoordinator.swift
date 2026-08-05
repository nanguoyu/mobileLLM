// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// A system resource a continued-processing task may require (iOS 26 `BGTaskScheduler.supportedResources`).
public enum ContinuedProcessingResource: String, Hashable, Sendable {
    case gpu
}

/// The bounded submission request for one run (spec §19.2).
public struct ContinuedProcessingRequest: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let subtitle: String
    public let requiresGPU: Bool

    public init(
        identifier: String,
        title: String,
        subtitle: String,
        requiresGPU: Bool
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.requiresGPU = requiresGPU
    }
}

/// Typed submission failure for the fail-if-not-immediately-runnable strategy.
public enum ContinuedProcessingSubmissionError: Error, Equatable, Sendable {
    case unavailable(reason: String)
    case notPermitted(reason: String)
    case notImmediatelyRunnable(reason: String)
}

/// The granted continued-processing task. Production wraps `BGContinuedProcessingTask`; tests use a
/// fake so the coordinator state machine is deterministic and framework-free.
@MainActor
public protocol ContinuedProcessingTaskHandle: AnyObject {
    var identifier: String { get }
    var isExpired: Bool { get }
    func setProgress(completed: Int64, total: Int64)
    func setTaskCompleted(success: Bool)
}

/// The OS scheduling seam. Production uses `BGTaskScheduler` (iOS 26+); tests inject a fake.
@MainActor
public protocol ContinuedProcessingScheduling: AnyObject {
    var isAvailable: Bool { get }
    var supportedResources: Set<ContinuedProcessingResource> { get }
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any ContinuedProcessingTaskHandle) -> Void
    )
    func submit(_ request: ContinuedProcessingRequest) throws -> Bool
    func cancelPending(identifier: String)
}

/// Coordinates explicit, bounded continued background processing (spec §19.2 / AH-IOS-003).
///
/// The first release uses the scheduler's fail-if-not-immediately-runnable strategy, never delayed
/// queueing. A rejected submission leaves the run `waitingForForeground` with a diagnostic reason;
/// any pre-existing queued request is explicitly cancelled and journaled before that transition.
/// Expiration and system cancellation first attempt safe quiescence and then leave resumable work
/// `waitingForForeground`; user cancellation maps to the explicit cancellation policy. No case
/// silently restarts inference or an external action.
@MainActor
@Observable
public final class ContinuedProcessingCoordinator {
    public enum Phase: Equatable, Sendable {
        case idle
        case submitted
        case running
        case rejected(diagnostic: String)
        case expired
        case cancelled
        case finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var activeConversationID: UUID?
    public private(set) var activeIdentifier: String?
    public private(set) var lastDiagnostic: String?

    /// Whether the user has explicitly enabled continued processing (default off).
    public var isEnabled: () -> Bool = { false }
    /// Whether the run is an eligible finite run (active, not waiting on the user).
    public var isRunEligible: (UUID) -> Bool = { _ in true }
    /// Whether the active run's engine requires background GPU resources.
    public var requiresGPUForRun: (UUID) -> Bool = { _ in false }
    /// Truthful bounded progress (0...1) for the active run.
    public var progressFraction: (UUID) -> Double? = { _ in nil }
    /// Safe quiescence: pauses active runs at their nearest safe boundary (`foregroundLost`).
    public var quiesce: (@MainActor () async -> Void)?
    /// Explicit user cancellation of a run (runtime `.cancel` command, durable journal).
    public var cancelRun: (@MainActor (UUID) async -> Void)?
    /// App-level audit journal for submission/cancellation/expiration bookkeeping.
    public var journal: (String) -> Void = { _ in }

    /// Identifier prefix; production passes the app's bundle-id-based prefix, tests pass a fixture.
    public let identifierPrefix: String
    public var scheduler: (any ContinuedProcessingScheduling)?
    private var task: (any ContinuedProcessingTaskHandle)?
    private var pendingQuiesceTask: Task<Void, Never>?

    public init(
        scheduler: (any ContinuedProcessingScheduling)? = nil,
        identifierPrefix: String = "wang.wangdongdong.mobileLLM.continuedProcessing"
    ) {
        self.scheduler = scheduler
        self.identifierPrefix = identifierPrefix
    }

    public func identifier(for conversationID: UUID) -> String {
        "\(identifierPrefix).\(conversationID.uuidString.lowercased())"
    }

    /// Reverse of `identifier(for:)`: recovers the run's conversation id from a system-delivered task
    /// identifier, or nil when the identifier does not belong to this prefix.
    public static func conversationID(fromIdentifier identifier: String, prefix: String) -> UUID? {
        let prefixWithDot = prefix.hasSuffix(".") ? prefix : prefix + "."
        guard identifier.hasPrefix(prefixWithDot) else { return nil }
        let suffix = String(identifier.dropFirst(prefixWithDot.count))
        return UUID(uuidString: suffix)
    }

    // MARK: - Submission

    /// Attempts to register this run for continued processing. Safe to call repeatedly; a running or
    /// already-submitted run is not double-submitted.
    public func submitIfEligible(conversationID: UUID) {
        guard isEnabled() else { return }
        guard let scheduler, scheduler.isAvailable else {
            reject(
                conversationID: conversationID,
                reason: "Continued processing is not available on this device or OS."
            )
            return
        }
        guard phase != .running, phase != .submitted else { return }
        guard activeConversationID == nil || activeConversationID == conversationID else { return }
        guard isRunEligible(conversationID) else { return }

        let request = ContinuedProcessingRequest(
            identifier: identifier(for: conversationID),
            title: "mobileLLM agent run",
            subtitle: "Finishing your request in the background",
            requiresGPU: requiresGPUForRun(conversationID)
        )

        if request.requiresGPU, !scheduler.supportedResources.contains(.gpu) {
            reject(
                conversationID: conversationID,
                reason: "Background GPU processing is not supported on this device."
            )
            return
        }

        // Fail-if-not-immediately-runnable: cancel any pre-existing queued request for the same
        // identifier and journal that cancellation before the transition (spec §19.2).
        scheduler.cancelPending(identifier: request.identifier)
        journal("continued-processing: cancelled pending \(request.identifier)")
        do {
            let accepted = try scheduler.submit(request)
            if accepted {
                activeConversationID = conversationID
                activeIdentifier = request.identifier
                lastDiagnostic = nil
                phase = .submitted
            } else {
                let reason = "The system could not start continued processing immediately."
                reject(conversationID: conversationID, reason: reason)
            }
        } catch {
            let reason = (error as? ContinuedProcessingSubmissionError)
                .map { Self.describe($0) }
                ?? error.localizedDescription
            reject(conversationID: conversationID, reason: reason)
        }
    }

    /// The system granted the task. From here the run keeps executing while the app is backgrounded;
    /// progress is reported to the system Live Activity through `refreshProgress`.
    public func handleTask(_ task: any ContinuedProcessingTaskHandle, conversationID: UUID) {
        self.task = task
        activeConversationID = conversationID
        activeIdentifier = task.identifier
        phase = .running
        lastDiagnostic = nil
        refreshProgress(conversationID: conversationID)
    }

    // MARK: - Progress

    /// Push the run's truthful bounded progress into the system-visible task progress.
    public func refreshProgress(conversationID: UUID) {
        guard activeConversationID == conversationID, let task else { return }
        guard let fraction = progressFraction(conversationID) else { return }
        let total: Int64 = 100
        let completed = Int64((fraction * 100).rounded())
        task.setProgress(completed: min(max(completed, 0), total), total: total)
    }

    // MARK: - Terminal outcomes

    /// The run reached a durable terminal state (completed/failed/cancelled). Completes the task
    /// successfully and clears the scheduling slot.
    public func runFinished(conversationID: UUID) {
        guard activeConversationID == conversationID else { return }
        phase = .finished
        lastDiagnostic = nil
        task?.setTaskCompleted(success: true)
        task = nil
        if let scheduler, let identifier = activeIdentifier {
            scheduler.cancelPending(identifier: identifier)
        }
        activeConversationID = nil
        activeIdentifier = nil
    }

    /// The system expired the task (or cancelled it for resource pressure): safe quiescence first,
    /// then leave resumable work `waitingForForeground`. Never silently restarts inference.
    public func handleExpiration(conversationID: UUID? = nil) {
        let id = conversationID ?? activeConversationID
        guard phase == .running || phase == .submitted, let id else { return }
        phase = .expired
        lastDiagnostic = "The system ended continued processing before the run finished."
        journal("continued-processing: expired \(id.uuidString)")
        task?.setTaskCompleted(success: false)
        task = nil
        activeIdentifier = nil
        quiesceAndWaitForForeground(conversationID: id)
    }

    /// System-level cancellation follows the same policy as expiration: safe quiescence, then a
    /// resumable foreground wait.
    public func handleSystemCancellation() {
        handleExpiration()
    }

    /// User cancellation from the system Live Activity maps to the explicit cancellation policy:
    /// cancel pending work, journal, and issue the runtime `.cancel` command.
    public func handleUserCancellation() {
        guard let id = activeConversationID, phase != .idle, phase != .finished else { return }
        phase = .cancelled
        lastDiagnostic = "Continued processing was cancelled by the user."
        journal("continued-processing: user-cancelled \(id.uuidString)")
        if let scheduler, let identifier = activeIdentifier {
            scheduler.cancelPending(identifier: identifier)
        }
        task?.setTaskCompleted(success: false)
        task = nil
        activeIdentifier = nil
        if let cancelRun {
            Task { @MainActor in await cancelRun(id) }
        } else {
            quiesceAndWaitForForeground(conversationID: id)
        }
        activeConversationID = nil
    }

    /// Called when the user toggles the setting: enabling submits for the given active conversation,
    /// disabling cancels any in-flight continued processing.
    public func setEnabled(_ enabled: Bool, activeConversationID: UUID?) {
        if enabled {
            if let activeConversationID {
                submitIfEligible(conversationID: activeConversationID)
            }
        } else {
            handleUserCancellation()
        }
    }

    // MARK: - Internals

    private func reject(conversationID: UUID, reason: String) {
        phase = .rejected(diagnostic: reason)
        lastDiagnostic = reason
        activeConversationID = nil
        activeIdentifier = nil
        journal("continued-processing: rejected \(conversationID.uuidString): \(reason)")
        quiesceAndWaitForForeground(conversationID: conversationID)
    }

    private func quiesceAndWaitForForeground(conversationID: UUID) {
        guard let quiesce else { return }
        // Deliberately no cancellation of an in-flight quiesce: aborting a pause mid-send could
        // strand the run outside a safe boundary. The versioned pause command makes reissue safe.
        pendingQuiesceTask = Task { @MainActor in
            await quiesce()
        }
    }

    private static func describe(_ error: ContinuedProcessingSubmissionError) -> String {
        switch error {
        case .unavailable(let reason), .notPermitted(let reason), .notImmediatelyRunnable(let reason):
            return reason
        }
    }
}
