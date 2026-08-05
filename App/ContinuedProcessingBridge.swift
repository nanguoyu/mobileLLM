// SPDX-License-Identifier: MIT

import Foundation
import MobileLLMUI

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// Production `ContinuedProcessingScheduling` over `BGTaskScheduler` (iOS 26+, spec §19.2).
///
/// The first release uses the fail-if-not-immediately-runnable strategy: submissions never queue for
/// a later time, so work cannot start after the user has foreground-resumed the run. GPU resources
/// are requested only when the caller says the engine needs them AND the device reports support.
@MainActor
@available(iOS 26.0, *)
final class BGContinuedProcessingSchedulerAdapter: ContinuedProcessingScheduling {
    let identifierPrefix: String
    private(set) var isAvailable: Bool
    private(set) var supportedResources: Set<ContinuedProcessingResource>
    private var registeredHandler: (@MainActor (any ContinuedProcessingTaskHandle) -> Void)?

    init(identifierPrefix: String) {
        self.identifierPrefix = identifierPrefix
        isAvailable = true
        let resources = BGTaskScheduler.supportedResources
        supportedResources = resources.contains(.gpu) ? [.gpu] : []
    }

    /// Registers the launch handler for a (wildcard) identifier. Must happen at app launch; the
    /// handler is delivered with the granted task.
    func register(
        identifier: String,
        handler: @escaping @MainActor @Sendable (any ContinuedProcessingTaskHandle) -> Void
    ) {
        registeredHandler = handler
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in
                guard let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                let box = BGContinuedProcessingTaskHandleBox(task: continued)
                self.registeredHandler?(box)
            }
        }
    }

    func submit(_ request: ContinuedProcessingRequest) throws -> Bool {
        let bgRequest = BGContinuedProcessingTaskRequest(
            identifier: request.identifier,
            title: request.title,
            subtitle: request.subtitle
        )
        // Fail-if-not-immediately-runnable: never delayed queueing (spec §19.2).
        bgRequest.strategy = .fail
        if request.requiresGPU {
            bgRequest.requiredResources = [.gpu]
        }
        do {
            try BGTaskScheduler.shared.submit(bgRequest)
            return true
        } catch {
            if let schedulerError = error as? BGTaskScheduler.Error {
                switch schedulerError.code {
                case .immediateRunIneligible, .tooManyPendingTaskRequests:
                    throw ContinuedProcessingSubmissionError.notImmediatelyRunnable(
                        reason: "The system cannot start continued processing immediately."
                    )
                case .notPermitted:
                    throw ContinuedProcessingSubmissionError.notPermitted(
                        reason: "Continued processing is not permitted on this device or provisioning profile."
                    )
                default:
                    throw ContinuedProcessingSubmissionError.unavailable(
                        reason: schedulerError.localizedDescription
                    )
                }
            }
            throw ContinuedProcessingSubmissionError.unavailable(reason: error.localizedDescription)
        }
    }

    func cancelPending(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Wraps the system `BGContinuedProcessingTask` in the framework-free handle protocol, including the
/// expiration callback and system-visible progress reporting (Live Activity).
@MainActor
@available(iOS 26.0, *)
final class BGContinuedProcessingTaskHandleBox: ContinuedProcessingTaskHandle {
    let identifier: String
    private(set) var isExpired = false
    /// Set by the adapter when the box is created so expiration can reach the coordinator.
    var onExpirationForwarded: (@MainActor () -> Void)?

    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
        self.identifier = task.identifier
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isExpired = true
                self.onExpirationForwarded?()
            }
        }
    }

    func setProgress(completed: Int64, total: Int64) {
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = completed
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
#endif
