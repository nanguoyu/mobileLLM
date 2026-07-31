// SPDX-License-Identifier: MIT

import Foundation

/// The cooperative controls an inference engine needs at safe decode boundaries.
///
/// Kept as a protocol so engine tests can inject a recorder without loading weights. Production uses
/// ``GenerationControl``.
public protocol GenerationControlling: Sendable {
    var isPaused: Bool { get }
    var isCancelled: Bool { get }
    func pause()
    func resume()
    func cancel()
    func checkpoint() async throws
}

/// Cooperative control for one in-flight generation.
///
/// Engines call ``checkpoint()`` at safe boundaries. `pause()` suspends the next checkpoint without
/// blocking an executor thread or trying to serialize model state; `cancel()` wakes every suspended
/// checkpoint with `CancellationError`. A control is single-run: cancellation is terminal.
public final class GenerationControl: GenerationControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init() {}

    public var isPaused: Bool {
        lock.withLock { paused }
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func pause() {
        lock.withLock {
            guard !cancelled else { return }
            paused = true
        }
    }

    public func resume() {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            paused = false
            let pending = Array(waiters.values)
            waiters.removeAll(keepingCapacity: true)
            return pending
        }
        pending.forEach { $0.resume() }
    }

    public func cancel() {
        let pending: [CheckedContinuation<Void, Error>] = lock.withLock {
            cancelled = true
            paused = false
            let pending = Array(waiters.values)
            waiters.removeAll(keepingCapacity: true)
            return pending
        }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    public func checkpoint() async throws {
        try Task.checkCancellation()

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let disposition: CheckpointDisposition = lock.withLock {
                    if cancelled || Task.isCancelled {
                        return .cancel
                    }
                    if paused {
                        waiters[waiterID] = continuation
                        return .wait
                    }
                    return .proceed
                }
                switch disposition {
                case .proceed:
                    continuation.resume()
                case .cancel:
                    continuation.resume(throwing: CancellationError())
                case .wait:
                    break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = self.lock.withLock {
                self.waiters.removeValue(forKey: waiterID)
            }
            continuation?.resume(throwing: CancellationError())
        }

        try Task.checkCancellation()
    }

    private enum CheckpointDisposition {
        case proceed
        case cancel
        case wait
    }
}

/// One generation's composed runtime policy.
///
/// `checkpoint()` deliberately checks the cooperative control both before and after the thermal wait:
/// a pause/cancel arriving while the device is cooling takes effect before the engine re-enters C/Metal.
/// Both dependencies are injectable, while the convenience initializer wires the production
/// ``GenerationControl`` and ``ThermalGovernor``.
public final class GenerationGovernance: @unchecked Sendable {
    public typealias MonotonicNow = @Sendable () -> UInt64

    private let control: any GenerationControlling
    private let thermalGovernor: any ThermalGoverning
    private let thermalCheckIntervalNanos: UInt64
    private let monotonicNow: MonotonicNow
    private let cadenceLock = NSLock()
    private var lastThermalCheckNanos: UInt64?

    public init(control: any GenerationControlling,
                thermalGovernor: any ThermalGoverning,
                thermalCheckIntervalNanos: UInt64 = 250_000_000,
                monotonicNow: @escaping MonotonicNow = { DispatchTime.now().uptimeNanoseconds }) {
        self.control = control
        self.thermalGovernor = thermalGovernor
        self.thermalCheckIntervalNanos = thermalCheckIntervalNanos
        self.monotonicNow = monotonicNow
    }

    public convenience init(clearCache: @escaping ThermalGovernor.ClearCacheFn = {}) {
        self.init(control: GenerationControl(),
                  thermalGovernor: ThermalGovernor(clearCache: clearCache))
    }

    public var isPaused: Bool { control.isPaused }
    public var isCancelled: Bool { control.isCancelled }

    public func pause() { control.pause() }
    public func resume() { control.resume() }
    public func cancel() { control.cancel() }

    /// Cancellation/pause only. Engines use this at very cheap boundaries such as every decoded token.
    public func cooperativeCheckpoint() async throws {
        try await control.checkpoint()
    }

    /// Full cancellation/pause + thermal/memory-pressure checkpoint.
    public func checkpoint(onCooling: (@Sendable () -> Void)? = nil) async throws {
        try await control.checkpoint()
        guard claimThermalCheckpointIfDue() else { return }
        try await thermalGovernor.throttleIfNeeded(onCooling: onCooling)
        try await control.checkpoint()
    }

    /// Model libraries can yield one chunk per token. Rate-limit system probes/cache relief to the
    /// governor's documented ~250 ms wall-clock boundary while retaining per-token pause/cancel checks.
    private func claimThermalCheckpointIfDue() -> Bool {
        let now = monotonicNow()
        return cadenceLock.withLock {
            guard let previous = lastThermalCheckNanos else {
                lastThermalCheckNanos = now
                return true
            }
            // Treat uptime wrap/reset as due. (A real UInt64 uptime wrap is practically unreachable,
            // but injected clocks use this branch in deterministic tests.)
            guard now >= previous, now - previous < thermalCheckIntervalNanos else {
                lastThermalCheckNanos = now
                return true
            }
            return false
        }
    }
}

/// Tracks generation ownership independently of an engine actor.
///
/// `generate` starts a lease before scheduling its actor task. A load/unload drain cancels every lease,
/// awaits `end`, and remains closed across the caller's resource mutation, so no admitted decode task can
/// overlap resource replacement or release. Replacing a generation cancels the previous active lease.
/// Tests use the same type without loading an ML model.
public final class GenerationLifecycle: @unchecked Sendable {
    public struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Ownership token for a generation-excluding resource-mutation window.
    ///
    /// A drain remains active after all generation tasks have exited. Call ``endDrain(_:)`` only after
    /// the protected model resources have been released or replaced; generations started before then
    /// are terminally cancelled.
    public struct DrainLease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Entry {
        let governance: GenerationGovernance
        var cancelTask: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var activeID: UUID?
    private var activeDrains: Set<UUID> = []
    private var idleWaiters: [CheckedContinuation<Bool, Never>] = []

    public init() {}

    public var hasActiveGeneration: Bool {
        lock.withLock { activeID != nil }
    }

    /// Starts a generation and cooperatively cancels the previously active one, if any.
    public func begin(using governance: GenerationGovernance) -> Lease {
        let lease = Lease(id: UUID())
        let state: (previous: Lease?, mustCancel: Bool) = lock.withLock {
            let previous = activeID.map(Lease.init(id:))
            entries[lease.id] = Entry(governance: governance)
            let mustCancel = !activeDrains.isEmpty
            activeID = mustCancel ? nil : lease.id
            return (previous, mustCancel)
        }
        if let previous = state.previous { cancel(previous) }
        if state.mustCancel { cancel(lease) }
        return lease
    }

    /// Attaches the task cancellation hook after task creation. If the lease lost a race with unload,
    /// the hook is fired immediately.
    public func attachTaskCancellation(_ cancelTask: @escaping @Sendable () -> Void,
                                       to lease: Lease) {
        let cancelImmediately: Bool = lock.withLock {
            guard var entry = entries[lease.id] else { return true }
            entry.cancelTask = cancelTask
            entries[lease.id] = entry
            return entry.cancelled
        }
        if cancelImmediately { cancelTask() }
    }

    public func pauseActive() {
        activeGovernance()?.pause()
    }

    public func resumeActive() {
        activeGovernance()?.resume()
    }

    public func cancelActive() {
        guard let lease = lock.withLock({ activeID.map(Lease.init(id:)) }) else { return }
        cancel(lease)
    }

    /// Targeted cancellation used by a stream's termination handler. It cannot cancel a newer run.
    public func cancel(_ lease: Lease) {
        let action: (GenerationGovernance, (@Sendable () -> Void)?)? = lock.withLock {
            guard var entry = entries[lease.id], !entry.cancelled else { return nil }
            entry.cancelled = true
            entries[lease.id] = entry
            if activeID == lease.id { activeID = nil }
            return (entry.governance, entry.cancelTask)
        }
        action?.0.cancel()
        action?.1?()
    }

    /// Marks the task finished. Only this releases the lease; cancellation alone does not prove that
    /// native inference has stopped touching its resources.
    public func end(_ lease: Lease) {
        let waiters: [CheckedContinuation<Bool, Never>] = lock.withLock {
            entries.removeValue(forKey: lease.id)
            if activeID == lease.id { activeID = nil }
            guard entries.isEmpty else { return [] }
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: true)
            return waiters
        }
        waiters.forEach { $0.resume(returning: false) }
    }

    /// Opens an exclusive resource-mutation window, cancels every current/retiring generation, and
    /// waits until all tasks have called ``end(_:)``.
    ///
    /// Unlike ``cancelAllAndWait()``, the drain remains active after this method returns. This closes
    /// the gap between observing an idle lifecycle and actually freeing/replacing native resources:
    /// any nonisolated `generate` racing in that interval receives a terminally-cancelled lease.
    public func beginDrain() async -> DrainLease {
        let drain = DrainLease(id: UUID())
        let actions: [(GenerationGovernance, (@Sendable () -> Void)?)] = lock.withLock {
            activeID = nil
            activeDrains.insert(drain.id)
            // Snapshot keys before updating values; never mutate a Dictionary through its live Keys view.
            return Array(entries.keys).compactMap { id in
                guard var entry = entries[id], !entry.cancelled else { return nil }
                entry.cancelled = true
                entries[id] = entry
                return (entry.governance, entry.cancelTask)
            }
        }
        for action in actions {
            action.0.cancel()
            action.1?()
        }

        // A nonisolated `generate` can race with this wait. `begin` terminally cancels leases while
        // this drain remains active; loop because a cancelled late lease still has to start and call `end`.
        while true {
            let finished = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                let resumeImmediately: Bool = lock.withLock {
                    guard entries.isEmpty else {
                        idleWaiters.append(continuation)
                        return false
                    }
                    return true
                }
                if resumeImmediately { continuation.resume(returning: true) }
            }
            if finished { return drain }
        }
    }

    /// Closes a resource-mutation window. New generations are admitted only after the final overlapping
    /// drain has ended.
    public func endDrain(_ drain: DrainLease) {
        lock.withLock {
            activeDrains.remove(drain.id)
        }
    }

    /// Cancels every current/retiring generation and waits until all tasks have called ``end(_:)``.
    ///
    /// This one-shot helper releases its drain immediately on return. Code that mutates model resources
    /// must instead hold ``beginDrain()``'s lease across that mutation and end it in a `defer`.
    public func cancelAllAndWait() async {
        let drain = await beginDrain()
        endDrain(drain)
    }

    private func activeGovernance() -> GenerationGovernance? {
        lock.withLock {
            guard let activeID else { return nil }
            return entries[activeID]?.governance
        }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
