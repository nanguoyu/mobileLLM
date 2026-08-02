// SPDX-License-Identifier: MIT

import AgentContracts

/// Platform-neutral thermal pressure consumed by resource-admission policy.
public enum ResourceThermalState: String, CaseIterable, Hashable, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Platform-neutral memory pressure consumed by resource-admission policy.
public enum ResourceMemoryPressureState: String, CaseIterable, Hashable, Codable, Sendable {
    case nominal
    case warning
    case critical
}

/// One atomic observation supplied by platform lifecycle/pressure adapters.
public struct ResourcePressureSnapshot: Hashable, Codable, Sendable {
    public let thermal: ResourceThermalState
    public let memory: ResourceMemoryPressureState

    public init(
        thermal: ResourceThermalState = .nominal,
        memory: ResourceMemoryPressureState = .nominal
    ) {
        self.thermal = thermal
        self.memory = memory
    }

    public static let nominal = ResourcePressureSnapshot()
}

/// Typed reason that prevents a new root/model admission without preempting an existing owner.
public enum ResourceAdmissionDeferral: Hashable, Codable, Sendable {
    case thermalSerious
    case thermalCritical
    case memoryCritical
}

/// A driver lifecycle phase, also used for deterministic failure reporting.
public enum ModelResidencyOperation: String, CaseIterable, Hashable, Codable, Sendable {
    case load
    case cancelAndDrain
    case unload
}

/// Stable, non-sensitive description of a failed residency operation.
public struct ModelResidencyFailure: Error, Hashable, Sendable {
    public let operation: ModelResidencyOperation
    public let selection: AgentModelSelection

    public init(operation: ModelResidencyOperation, selection: AgentModelSelection) {
        self.operation = operation
        self.selection = selection
    }
}

/// Typed failures returned by resource acquisition.
enum ResourceArbiterError: Error, Hashable, Sendable {
    case invalidAdmissionSequence
    case admissionSequenceInUse(UInt64)
    case runAlreadyQueued(AgentRunID)
    case admissionDeferred(ResourceAdmissionDeferral)
    case rootLeaseRequired(AgentRunID)
    case rootLeaseMismatch(AgentRunID)
    case decodeLeaseAlreadyActive(AgentRunID)
    case residencyTransitionInProgress
    case residencyOperationSuperseded
    case driverFailure(ModelResidencyFailure)
    case residencyFaulted(ModelResidencyFailure)
}

/// Result of explicitly releasing the app-wide root execution slot.
enum RootLeaseReleaseOutcome: Hashable, Sendable {
    case released
    case alreadyReleased
    case wrongLease
    case blockedByDecode
    case releasedWithCleanupFailure(ModelResidencyFailure)
}

/// Result of explicitly releasing a local decode permit.
enum DecodeLeaseReleaseOutcome: Hashable, Sendable {
    case released
    case alreadyReleased
    case wrongLease
}

/// Result of cancelling/draining a decode and then releasing its permit.
enum DecodeLeaseDrainOutcome: Hashable, Sendable {
    case released
    case alreadyReleased
    case wrongLease
    case transitionInProgress
    case superseded
    case driverFailure(ModelResidencyFailure)
}

/// Effect of applying a thermal/memory observation.
enum ResourcePressureOutcome: Hashable, Sendable {
    case noAction
    case admissionsResumed
    case admissionsDeferred(ResourceAdmissionDeferral)
    case ownerMustQuiesce(runID: AgentRunID, reason: ResourceAdmissionDeferral)
    case residencyCleanupPending(ResourceAdmissionDeferral)
    case idleResidencyEvicted(selection: AgentModelSelection, reason: ResourceAdmissionDeferral)
    case idleResidencyEvictionFailed(ModelResidencyFailure, reason: ResourceAdmissionDeferral)
}

/// Stable read-only projection of one root-slot owner.
struct RootResourceOwnerSnapshot: Hashable, Sendable {
    let runID: AgentRunID
    let admissionSequence: UInt64
}

/// Stable read-only projection of one queued root admission.
struct RootResourceWaiterSnapshot: Hashable, Sendable {
    let runID: AgentRunID
    let admissionSequence: UInt64
}

/// Stable read-only projection of the one active decode permit.
struct DecodeResourceOwnerSnapshot: Hashable, Sendable {
    let runID: AgentRunID
    let selection: AgentModelSelection
}

/// Concurrency high-water marks and grant counts used by diagnostics and invariant tests.
struct ResourceArbiterMetrics: Hashable, Sendable {
    let rootGrants: UInt64
    let decodeGrants: UInt64
    let residencyTransitions: UInt64
    let maxRootOwners: Int
    let maxDecodeOwners: Int
    let maxResidentSelections: Int
    let maxConcurrentResidencyTransitions: Int
}

/// Read-only resource state; waiting/reconciliation never appears as ownership.
struct ResourceArbiterSnapshot: Hashable, Sendable {
    let rootOwner: RootResourceOwnerSnapshot?
    let waiters: [RootResourceWaiterSnapshot]
    let decodeOwner: DecodeResourceOwnerSnapshot?
    let residentSelection: AgentModelSelection?
    let residencyTransition: ModelResidencyOperation?
    let pressure: ResourcePressureSnapshot
    let admissionDeferral: ResourceAdmissionDeferral?
    let residencyFault: ModelResidencyFailure?
    let metrics: ResourceArbiterMetrics
}
