// SPDX-License-Identifier: MIT

import Foundation
import MobileLLMUI

#if os(iOS)
import UIKit

/// Production `BackgroundDrainToken` over `UIBackgroundTaskIdentifier` (spec §19.1).
@MainActor
final class UIKitBackgroundDrainToken: BackgroundDrainToken {
    private(set) var isExpired = false
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    func attach(_ identifier: UIBackgroundTaskIdentifier) {
        self.identifier = identifier
    }

    func markExpired() {
        isExpired = true
    }

    func end() {
        guard !ended, identifier != .invalid else { return }
        ended = true
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Production `BackgroundDrainProviding` over `UIApplication.beginBackgroundTask`. The expiration
/// handler is delivered on an arbitrary queue, so it hops back to the main actor before reissuing
/// the idempotent quiesce command.
@MainActor
final class UIKitBackgroundDrainProvider: BackgroundDrainProviding {
    func beginDrain(
        named name: String,
        expiration: @escaping @MainActor @Sendable () -> Void
    ) -> any BackgroundDrainToken {
        let token = UIKitBackgroundDrainToken()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor [weak token] in
                token?.markExpired()
                expiration()
            }
        }
        token.attach(identifier)
        return token
    }
}

/// Aggregates every connected `UIWindowScene` activation state instead of relying on one SwiftUI
/// view's `scenePhase` (spec §19.1). Observes scene-level notifications so iPadOS Split View and
/// multi-scene states are reflected truthfully.
@MainActor
final class iOSSceneLifecycleMonitor {
    private weak var coordinator: LifecycleCoordinator?

    init(coordinator: LifecycleCoordinator) {
        self.coordinator = coordinator
        let center = NotificationCenter.default
        for name in [
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.willEnterForegroundNotification,
        ] {
            // The monitor is app-lifetime and the blocks capture the coordinator weakly, so no
            // explicit removal is needed; an inert observer is harmless after deallocation.
            _ = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        coordinator.updateSceneStates(Self.currentSceneStates())
    }

    private func refresh() {
        coordinator?.updateSceneStates(Self.currentSceneStates())
    }

    private static func currentSceneStates() -> [ScenePresence] {
        UIApplication.shared.connectedScenes.map { scene in
            switch scene.activationState {
            case .foregroundActive: .foregroundActive
            case .foregroundInactive: .foregroundInactive
            case .background: .background
            case .unattached: .unattached
            @unknown default: .unattached
            }
        }
    }
}
#endif
