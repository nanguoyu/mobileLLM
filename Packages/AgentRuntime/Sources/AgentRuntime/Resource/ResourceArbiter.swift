// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Capability proving ownership of the one app-wide root execution slot.
///
/// The type and its identity are module-internal, and its initializer is file-private. Correctness
/// never depends on destruction of a lease; every owner must release it explicitly.
struct RootExecutionLease: Hashable, Sendable {
    let runID: AgentRunID
    let admissionSequence: UInt64
    fileprivate let arbiterID: UUID
    fileprivate let token: UUID
    fileprivate let originWaiterID: UUID?

    fileprivate init(
        runID: AgentRunID,
        admissionSequence: UInt64,
        arbiterID: UUID,
        token: UUID,
        originWaiterID: UUID?
    ) {
        self.runID = runID
        self.admissionSequence = admissionSequence
        self.arbiterID = arbiterID
        self.token = token
        self.originWaiterID = originWaiterID
    }
}

/// Capability proving ownership of the one local decode lane for one resident selection.
struct ModelDecodeLease: Hashable, Sendable {
    let runID: AgentRunID
    let admissionSequence: UInt64
    let selection: AgentModelSelection
    fileprivate let arbiterID: UUID
    fileprivate let rootToken: UUID
    fileprivate let token: UUID
    fileprivate let residencyGeneration: UInt64

    fileprivate init(
        rootLease: RootExecutionLease,
        selection: AgentModelSelection,
        token: UUID,
        residencyGeneration: UInt64
    ) {
        runID = rootLease.runID
        admissionSequence = rootLease.admissionSequence
        self.selection = selection
        arbiterID = rootLease.arbiterID
        rootToken = rootLease.token
        self.token = token
        self.residencyGeneration = residencyGeneration
    }
}

/// Serializes app-wide agent execution and local-model residency.
///
/// Actor isolation protects bookkeeping, while explicit capability values protect callbacks that
/// resume after an `await`. A residency transition remains exclusive until its driver operation has
/// either committed or reconciled, even if its originating root owner has already released.
actor ResourceArbiter {
    private struct RootOwner {
        let lease: RootExecutionLease
    }

    private struct DecodeOwner {
        let lease: ModelDecodeLease
    }

    private struct RootWaiter {
        let id: UUID
        let runID: AgentRunID
        let admissionSequence: UInt64
        let continuation: CheckedContinuation<RootExecutionLease, Error>
    }

    private struct ResidencyTransition {
        let id: UUID
        let generation: UInt64
        let rootToken: UUID?
        let decodeToken: UUID?
        var operation: ModelResidencyOperation
    }

    private let driver: any ModelResidencyDriver
    private let arbiterID = UUID()

    private var rootOwner: RootOwner?
    private var rootWaiters: [RootWaiter] = []
    private var decodeOwner: DecodeOwner?
    private var residentSelection: AgentModelSelection?
    private var activeTransition: ResidencyTransition?
    private var residencyGeneration: UInt64 = 0
    private var pressure: ResourcePressureSnapshot = .nominal
    private var residencyFault: ModelResidencyFailure?

    private var releasedRootTokens: Set<UUID> = []
    private var releasedDecodeTokens: Set<UUID> = []

    private var rootGrants: UInt64 = 0
    private var decodeGrants: UInt64 = 0
    private var residencyTransitions: UInt64 = 0
    private var maxRootOwners = 0
    private var maxDecodeOwners = 0
    private var maxResidentSelections = 0
    private var maxConcurrentResidencyTransitions = 0

    init(driver: any ModelResidencyDriver) {
        self.driver = driver
    }

    /// Acquires the single root slot, queueing by a unique durable admission sequence.
    ///
    /// Older queued sequences are granted first. An existing owner is never preempted, including
    /// when a newly queued sequence is numerically older.
    func acquireRoot(
        runID: AgentRunID,
        admissionSequence: UInt64
    ) async throws -> RootExecutionLease {
        guard admissionSequence > 0 else {
            throw ResourceArbiterError.invalidAdmissionSequence
        }
        try Task.checkCancellation()

        if let residencyFault {
            throw ResourceArbiterError.residencyFaulted(residencyFault)
        }
        if rootOwner?.lease.runID == runID || rootWaiters.contains(where: { $0.runID == runID }) {
            throw ResourceArbiterError.runAlreadyQueued(runID)
        }
        if rootOwner?.lease.admissionSequence == admissionSequence
            || rootWaiters.contains(where: { $0.admissionSequence == admissionSequence })
        {
            throw ResourceArbiterError.admissionSequenceInUse(admissionSequence)
        }
        if let deferral = admissionDeferral(for: pressure) {
            throw ResourceArbiterError.admissionDeferred(deferral)
        }

        if rootOwner == nil, rootWaiters.isEmpty, activeTransition == nil {
            return grantRoot(
                runID: runID,
                admissionSequence: admissionSequence,
                originWaiterID: nil
            )
        }

        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RootExecutionLease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    rootWaiters.append(
                        RootWaiter(
                            id: waiterID,
                            runID: runID,
                            admissionSequence: admissionSequence,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelRootWaiter(waiterID) }
        }

        if Task.isCancelled {
            if rootOwner?.lease.token == lease.token, decodeOwner == nil {
                rootOwner = nil
                releasedRootTokens.insert(lease.token)
                if activeTransition?.rootToken == lease.token {
                    invalidateActiveTransition()
                } else {
                    grantNextRootWaiterIfPossible()
                }
            }
            throw CancellationError()
        }
        return lease
    }

    /// Explicitly releases the root slot. A decode permit must be released first.
    @discardableResult
    func releaseRoot(_ lease: RootExecutionLease) async -> RootLeaseReleaseOutcome {
        guard lease.arbiterID == arbiterID else { return .wrongLease }
        if releasedRootTokens.contains(lease.token) { return .alreadyReleased }
        guard rootOwner?.lease.token == lease.token else { return .wrongLease }
        guard decodeOwner == nil else { return .blockedByDecode }

        rootOwner = nil
        releasedRootTokens.insert(lease.token)

        if activeTransition?.rootToken == lease.token {
            invalidateActiveTransition()
            return .released
        }

        if admissionDeferral(for: pressure) != nil, let residentSelection {
            if let failure = await evictIdleResidency(residentSelection) {
                return .releasedWithCleanupFailure(failure)
            }
        }
        grantNextRootWaiterIfPossible()
        return .released
    }

    /// Acquires the single decode permit, loading or switching residency when required.
    func acquireDecode(
        selection: AgentModelSelection,
        rootLease: RootExecutionLease
    ) async throws -> ModelDecodeLease {
        try validateCurrentRoot(rootLease)
        if let residencyFault {
            throw ResourceArbiterError.residencyFaulted(residencyFault)
        }
        if decodeOwner != nil {
            throw ResourceArbiterError.decodeLeaseAlreadyActive(rootLease.runID)
        }
        if activeTransition != nil {
            throw ResourceArbiterError.residencyTransitionInProgress
        }
        if let deferral = admissionDeferral(for: pressure) {
            throw ResourceArbiterError.admissionDeferred(deferral)
        }

        let generation: UInt64
        if residentSelection == selection {
            generation = residencyGeneration
        } else {
            generation = try await prepareResidency(selection, for: rootLease)
            try validateCurrentRoot(rootLease)
        }

        let lease = ModelDecodeLease(
            rootLease: rootLease,
            selection: selection,
            token: UUID(),
            residencyGeneration: generation
        )
        decodeOwner = DecodeOwner(lease: lease)
        decodeGrants &+= 1
        maxDecodeOwners = max(maxDecodeOwners, decodeOwner == nil ? 0 : 1)
        return lease
    }

    /// Releases a decode permit without claiming that in-flight engine work was drained.
    ///
    /// Use this for a normally completed decode. Cancellation/pause paths use
    /// `cancelDrainAndReleaseDecode(_:)` instead.
    @discardableResult
    func releaseDecode(_ lease: ModelDecodeLease) -> DecodeLeaseReleaseOutcome {
        guard lease.arbiterID == arbiterID else { return .wrongLease }
        if releasedDecodeTokens.contains(lease.token) { return .alreadyReleased }
        guard decodeOwner?.lease.token == lease.token else { return .wrongLease }

        decodeOwner = nil
        releasedDecodeTokens.insert(lease.token)
        if activeTransition?.decodeToken == lease.token {
            invalidateActiveTransition()
        }
        return .released
    }

    /// Cancels/drains a decode to a stable boundary before explicitly releasing its permit.
    func cancelDrainAndReleaseDecode(_ lease: ModelDecodeLease) async -> DecodeLeaseDrainOutcome {
        guard lease.arbiterID == arbiterID else { return .wrongLease }
        if releasedDecodeTokens.contains(lease.token) { return .alreadyReleased }
        guard decodeOwner?.lease.token == lease.token else { return .wrongLease }
        guard activeTransition == nil else { return .transitionInProgress }

        let transition = beginTransition(
            operation: .cancelAndDrain,
            rootToken: lease.rootToken,
            decodeToken: lease.token
        )
        if let failure = await invokeDriver(.cancelAndDrain, selection: lease.selection) {
            finishTransition(transition)
            return .driverFailure(failure)
        }
        guard transitionIsCurrent(transition), decodeOwner?.lease.token == lease.token else {
            finishTransition(transition)
            return .superseded
        }

        decodeOwner = nil
        releasedDecodeTokens.insert(lease.token)
        finishTransition(transition)
        return .released
    }

    /// Applies platform pressure without silently preempting an existing root owner.
    func updatePressure(_ newPressure: ResourcePressureSnapshot) async -> ResourcePressureOutcome {
        let previousDeferral = admissionDeferral(for: pressure)
        pressure = newPressure
        guard let reason = admissionDeferral(for: newPressure) else {
            grantNextRootWaiterIfPossible()
            return previousDeferral == nil ? .noAction : .admissionsResumed
        }

        if let owner = rootOwner {
            return .ownerMustQuiesce(runID: owner.lease.runID, reason: reason)
        }
        if activeTransition != nil {
            return .residencyCleanupPending(reason)
        }
        guard let residentSelection else {
            return .admissionsDeferred(reason)
        }

        if let failure = await evictIdleResidency(residentSelection) {
            return .idleResidencyEvictionFailed(failure, reason: reason)
        }
        return .idleResidencyEvicted(selection: residentSelection, reason: reason)
    }

    /// Returns a projection that cannot be used as a capability.
    func snapshot() -> ResourceArbiterSnapshot {
        ResourceArbiterSnapshot(
            rootOwner: rootOwner.map {
                RootResourceOwnerSnapshot(
                    runID: $0.lease.runID,
                    admissionSequence: $0.lease.admissionSequence
                )
            },
            waiters: rootWaiters
                .sorted(by: waiterPrecedes)
                .map {
                    RootResourceWaiterSnapshot(
                        runID: $0.runID,
                        admissionSequence: $0.admissionSequence
                    )
                },
            decodeOwner: decodeOwner.map {
                DecodeResourceOwnerSnapshot(
                    runID: $0.lease.runID,
                    selection: $0.lease.selection
                )
            },
            residentSelection: residentSelection,
            residencyTransition: activeTransition?.operation,
            pressure: pressure,
            admissionDeferral: admissionDeferral(for: pressure),
            residencyFault: residencyFault,
            metrics: ResourceArbiterMetrics(
                rootGrants: rootGrants,
                decodeGrants: decodeGrants,
                residencyTransitions: residencyTransitions,
                maxRootOwners: maxRootOwners,
                maxDecodeOwners: maxDecodeOwners,
                maxResidentSelections: maxResidentSelections,
                maxConcurrentResidencyTransitions: maxConcurrentResidencyTransitions
            )
        )
    }

    private func validateCurrentRoot(_ lease: RootExecutionLease) throws {
        guard lease.arbiterID == arbiterID else {
            throw ResourceArbiterError.rootLeaseMismatch(lease.runID)
        }
        guard let rootOwner else {
            throw ResourceArbiterError.rootLeaseRequired(lease.runID)
        }
        guard rootOwner.lease.token == lease.token else {
            throw ResourceArbiterError.rootLeaseMismatch(lease.runID)
        }
    }

    private func grantRoot(
        runID: AgentRunID,
        admissionSequence: UInt64,
        originWaiterID: UUID?
    ) -> RootExecutionLease {
        let lease = RootExecutionLease(
            runID: runID,
            admissionSequence: admissionSequence,
            arbiterID: arbiterID,
            token: UUID(),
            originWaiterID: originWaiterID
        )
        rootOwner = RootOwner(lease: lease)
        rootGrants &+= 1
        maxRootOwners = max(maxRootOwners, rootOwner == nil ? 0 : 1)
        return lease
    }

    private func grantNextRootWaiterIfPossible() {
        guard rootOwner == nil, activeTransition == nil, residencyFault == nil,
              admissionDeferral(for: pressure) == nil, !rootWaiters.isEmpty
        else { return }

        rootWaiters.sort(by: waiterPrecedes)
        let waiter = rootWaiters.removeFirst()
        let lease = grantRoot(
            runID: waiter.runID,
            admissionSequence: waiter.admissionSequence,
            originWaiterID: waiter.id
        )
        waiter.continuation.resume(returning: lease)
    }

    private func waiterPrecedes(_ lhs: RootWaiter, _ rhs: RootWaiter) -> Bool {
        lhs.admissionSequence < rhs.admissionSequence
    }

    private func cancelRootWaiter(_ waiterID: UUID) {
        if let index = rootWaiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = rootWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        guard rootOwner?.lease.originWaiterID == waiterID, decodeOwner == nil,
              let lease = rootOwner?.lease
        else { return }
        rootOwner = nil
        releasedRootTokens.insert(lease.token)
        if activeTransition?.rootToken == lease.token {
            invalidateActiveTransition()
        } else {
            grantNextRootWaiterIfPossible()
        }
    }

    private func prepareResidency(
        _ target: AgentModelSelection,
        for rootLease: RootExecutionLease
    ) async throws -> UInt64 {
        let previous = residentSelection
        let transition = beginTransition(
            operation: previous == nil ? .load : .cancelAndDrain,
            rootToken: rootLease.token,
            decodeToken: nil
        )

        if let previous {
            if let failure = await invokeDriver(.cancelAndDrain, selection: previous) {
                finishTransition(transition)
                throw ResourceArbiterError.driverFailure(failure)
            }
            guard transitionIsCurrentAndOwned(transition, by: rootLease) else {
                setTransitionOperation(.unload, transition: transition)
                if let failure = await invokeDriver(.unload, selection: previous) {
                    markResidencyFault(failure)
                    finishTransition(transition)
                    throw ResourceArbiterError.residencyFaulted(failure)
                }
                residentSelection = nil
                finishTransition(transition)
                throw ResourceArbiterError.residencyOperationSuperseded
            }

            setTransitionOperation(.unload, transition: transition)
            if let failure = await invokeDriver(.unload, selection: previous) {
                finishTransition(transition)
                throw ResourceArbiterError.driverFailure(failure)
            }
            residentSelection = nil
            guard transitionIsCurrentAndOwned(transition, by: rootLease) else {
                finishTransition(transition)
                throw ResourceArbiterError.residencyOperationSuperseded
            }
        }

        setTransitionOperation(.load, transition: transition)
        if let failure = await invokeDriver(.load, selection: target) {
            if let cleanupFailure = await cleanupPossiblyLoadedSelection(target, transition: transition) {
                markResidencyFault(cleanupFailure)
                finishTransition(transition)
                throw ResourceArbiterError.residencyFaulted(cleanupFailure)
            }
            finishTransition(transition)
            throw ResourceArbiterError.driverFailure(failure)
        }
        guard transitionIsCurrentAndOwned(transition, by: rootLease) else {
            if let cleanupFailure = await cleanupPossiblyLoadedSelection(target, transition: transition) {
                markResidencyFault(cleanupFailure)
                finishTransition(transition)
                throw ResourceArbiterError.residencyFaulted(cleanupFailure)
            }
            finishTransition(transition)
            throw ResourceArbiterError.residencyOperationSuperseded
        }

        residentSelection = target
        maxResidentSelections = max(maxResidentSelections, residentSelection == nil ? 0 : 1)
        finishTransition(transition)
        return transition.generation
    }

    private func cleanupPossiblyLoadedSelection(
        _ selection: AgentModelSelection,
        transition: ResidencyTransition
    ) async -> ModelResidencyFailure? {
        setTransitionOperation(.cancelAndDrain, transition: transition)
        if let failure = await invokeDriver(.cancelAndDrain, selection: selection) {
            residentSelection = selection
            maxResidentSelections = max(maxResidentSelections, 1)
            return failure
        }
        setTransitionOperation(.unload, transition: transition)
        if let failure = await invokeDriver(.unload, selection: selection) {
            residentSelection = selection
            maxResidentSelections = max(maxResidentSelections, 1)
            return failure
        }
        residentSelection = nil
        return nil
    }

    private func evictIdleResidency(
        _ selection: AgentModelSelection
    ) async -> ModelResidencyFailure? {
        let transition = beginTransition(
            operation: .cancelAndDrain,
            rootToken: nil,
            decodeToken: nil
        )
        if let failure = await invokeDriver(.cancelAndDrain, selection: selection) {
            finishTransition(transition)
            return failure
        }
        setTransitionOperation(.unload, transition: transition)
        if let failure = await invokeDriver(.unload, selection: selection) {
            finishTransition(transition)
            return failure
        }
        residentSelection = nil
        finishTransition(transition)
        return nil
    }

    private func beginTransition(
        operation: ModelResidencyOperation,
        rootToken: UUID?,
        decodeToken: UUID?
    ) -> ResidencyTransition {
        precondition(activeTransition == nil)
        residencyGeneration &+= 1
        let transition = ResidencyTransition(
            id: UUID(),
            generation: residencyGeneration,
            rootToken: rootToken,
            decodeToken: decodeToken,
            operation: operation
        )
        activeTransition = transition
        residencyTransitions &+= 1
        maxConcurrentResidencyTransitions = max(maxConcurrentResidencyTransitions, 1)
        return transition
    }

    private func setTransitionOperation(
        _ operation: ModelResidencyOperation,
        transition: ResidencyTransition
    ) {
        guard activeTransition?.id == transition.id else { return }
        activeTransition?.operation = operation
    }

    private func invalidateActiveTransition() {
        guard activeTransition != nil else { return }
        residencyGeneration &+= 1
    }

    private func transitionIsCurrent(_ transition: ResidencyTransition) -> Bool {
        activeTransition?.id == transition.id && residencyGeneration == transition.generation
    }

    private func transitionIsCurrentAndOwned(
        _ transition: ResidencyTransition,
        by rootLease: RootExecutionLease
    ) -> Bool {
        transitionIsCurrent(transition) && rootOwner?.lease.token == rootLease.token
    }

    private func finishTransition(_ transition: ResidencyTransition) {
        guard activeTransition?.id == transition.id else { return }
        activeTransition = nil
        grantNextRootWaiterIfPossible()
    }

    private func invokeDriver(
        _ operation: ModelResidencyOperation,
        selection: AgentModelSelection
    ) async -> ModelResidencyFailure? {
        do {
            switch operation {
            case .load:
                try await driver.load(selection: selection)
            case .cancelAndDrain:
                try await driver.cancelAndDrain(selection: selection)
            case .unload:
                try await driver.unload(selection: selection)
            }
            return nil
        } catch {
            return ModelResidencyFailure(operation: operation, selection: selection)
        }
    }

    private func markResidencyFault(_ failure: ModelResidencyFailure) {
        residencyFault = failure
        let waiters = rootWaiters
        rootWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(
                throwing: ResourceArbiterError.residencyFaulted(failure)
            )
        }
    }

    private func admissionDeferral(
        for pressure: ResourcePressureSnapshot
    ) -> ResourceAdmissionDeferral? {
        if pressure.memory == .critical { return .memoryCritical }
        switch pressure.thermal {
        case .critical:
            return .thermalCritical
        case .serious:
            return .thermalSerious
        case .nominal, .fair:
            return nil
        }
    }
}
