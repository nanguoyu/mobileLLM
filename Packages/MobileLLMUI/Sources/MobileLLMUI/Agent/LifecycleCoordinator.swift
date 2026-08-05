// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// One connected scene's presence, normalized so the lifecycle coordinator never depends on UIKit or
/// SwiftUI. On iOS the app bridge maps `UIScene.ActivationState` here; on macOS the app bridge maps
/// the single `scenePhase`.
public enum ScenePresence: Equatable, Sendable {
    case foregroundActive
    case foregroundInactive
    case background
    case unattached

    public var isForeground: Bool {
        self == .foregroundActive || self == .foregroundInactive
    }
}

/// A finite best-effort drain lease granted by the OS. Production iOS uses
/// `UIApplication.beginBackgroundTask`; tests inject a fake so the coordinator's state machine is
/// deterministic.
@MainActor
public protocol BackgroundDrainToken: AnyObject {
    var isExpired: Bool { get }
    func end()
}

/// The OS seam for acquiring the finite background drain window (spec §19.1).
@MainActor
public protocol BackgroundDrainProviding: AnyObject {
    func beginDrain(
        named name: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> any BackgroundDrainToken
}

/// Aggregates all connected-scene states and drives the bounded foreground-lost sequence:
/// stop admitting new actions, quiesce every active run at its nearest safe boundary inside a
/// finite `beginBackgroundTask` drain, drain generation, unload local weights, and leave resumable
/// work `waitingForForeground`.
///
/// Recovery never assumes iOS granted enough time or that the expiration handler completed: the
/// quiesce command is idempotent and versioned (each pause carries the run's `expectedRunStateVersion`),
/// so reissuing it after expiration is safe. Returning to the foreground never auto-resumes a run.
@MainActor
@Observable
public final class LifecycleCoordinator {
    public enum DrainState: Equatable, Sendable {
        case idle
        case draining
        case drained
        case expired
    }

    public private(set) var isInBackground = false
    public private(set) var drainState: DrainState = .idle
    /// How many times the idempotent quiesce command was issued for the current background episode.
    public private(set) var quiesceIssueCount: UInt64 = 0
    public private(set) var lastBackgroundTransitionAt: Date?
    public private(set) var didExpireDuringLastBackground = false
    public private(set) var sceneStates: [ScenePresence] = []

    /// Spec §19.1 step 1: stop admitting new actions.
    public var stopAdmittingActions: (@MainActor () -> Void)?
    /// Re-opens admission when a foreground scene exists again.
    public var resumeAdmittingActions: (@MainActor () -> Void)?
    /// The idempotent, versioned foreground-lost quiesce fan-out over active runs.
    public var quiesce: (@MainActor () async -> Void)?
    /// Unloads resident local weights when memory policy requires (online runs have nothing to unload).
    public var suspendModel: (@MainActor () -> Void)?

    private let drainProvider: (any BackgroundDrainProviding)?
    private var drainToken: (any BackgroundDrainToken)?
    private var quiesceGeneration: UInt64 = 0

    public init(drainProvider: (any BackgroundDrainProviding)? = nil) {
        self.drainProvider = drainProvider
    }

    /// Aggregate every connected scene. The app is backgrounded only when NO scene is in a
    /// foreground state, so on iPadOS/macOS another open scene keeps the app eligible while one
    /// scene hides. An empty snapshot at launch is treated as foreground so bootstrap never starts
    /// a spurious drain.
    public func updateSceneStates(_ states: [ScenePresence]) {
        sceneStates = states
        let backgrounded = !states.isEmpty && !states.contains(where: \.isForeground)
        if backgrounded {
            enterBackground()
        } else {
            enterForeground()
        }
    }

    public func enterBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        lastBackgroundTransitionAt = Date()
        didExpireDuringLastBackground = false
        stopAdmittingActions?()
        drainState = .draining
        if let drainProvider {
            drainToken = drainProvider.beginDrain(
                named: "mobileLLM.foregroundLost.quiesce"
            ) { [weak self] in
                self?.expirationFired()
            }
        }
        issueQuiesce()
    }

    public func enterForeground() {
        guard isInBackground else { return }
        isInBackground = false
        resumeAdmittingActions?()
        drainState = .idle
        drainToken?.end()
        drainToken = nil
        // A quiesce issued while backgrounded is intentionally NOT cancelled: the run paused at a
        // safe boundary, and foregrounding never auto-resumes it (spec §19.1).
    }

    /// The drain lease expired. Reissue the same idempotent, versioned quiesce command; the run
    /// store's versioned pause makes the second attempt harmless if the first already landed.
    private func expirationFired() {
        didExpireDuringLastBackground = true
        drainState = .expired
        issueQuiesce()
    }

    private func issueQuiesce() {
        quiesceIssueCount += 1
        let generation = quiesceGeneration + 1
        quiesceGeneration = generation
        // Deliberately no cancellation of a prior in-flight quiesce: aborting a pause mid-send could
        // strand the run outside a safe boundary. Reissue is safe because the command is versioned.
        Task { @MainActor [weak self] in
            await self?.quiesce?()
            guard let self, self.quiesceGeneration == generation else { return }
            // Unload local weights whenever the background episode is still active, even if the OS
            // lease expired while the idempotent quiesce was in flight. An expired drain keeps its
            // record that iOS ran out of time; only a non-expired drain transitions to .drained.
            if self.isInBackground,
               self.drainState == .draining || self.drainState == .expired
            {
                self.suspendModel?()
                if self.drainState == .draining {
                    self.drainState = .drained
                }
                self.drainToken?.end()
                self.drainToken = nil
            }
        }
    }
}
