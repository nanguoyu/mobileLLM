// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Thrown when the device stays `.critical` past the bounded cooling timeout — a recoverable event
/// (the run can be retried), never a silent thermal shutdown.
public enum ThermalError: Error, CustomStringConvertible {
    case pausedForHeat
    public var description: String {
        switch self { case .pausedForHeat: "Paused to let the device cool." }
    }
}

/// Thermal severity, a Sendable mirror of `ProcessInfo.ThermalState`.
public enum ThermalSeverity: Int, Sendable, Comparable {
    case nominal = 0, fair, serious, critical
    public static func < (a: ThermalSeverity, b: ThermalSeverity) -> Bool { a.rawValue < b.rawValue }
}

/// Memory-pressure level reported by the dispatch memory-pressure source.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 0, warning, critical
    public static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// On-device thermal & memory-pressure governor — the single hard guarantee against a thermal
/// shutdown while generating.
///
/// The only lever the runtime has to shed heat is to stop feeding the accelerator, so the governor
/// reads `ProcessInfo.thermalState` (cached, updated by the system notification so the hot loop never
/// makes a syscall) and, between token/decode steps:
///   • `.nominal` / `.fair`  → returns immediately (zero tax in the common case);
///   • `.serious`            → clears the reuse pool (via the injected `clearCache`) and inserts a
///                             short cooperative sleep, lowering the *duty cycle* so the junction
///                             temperature climbs more slowly (trades wall-clock for a gentler slope);
///   • `.critical`           → PAUSES the loop until the device cools, surfacing a non-error
///                             "cooling" progress; after a bounded timeout it throws the recoverable
///                             `ThermalError.pausedForHeat` rather than letting iOS thermal-shutdown.
///
/// On macOS the governor is a runtime no-op: the default thermal source reports `.nominal` and the
/// memory source reports `.normal`, so `throttleIfNeeded` falls straight through the `.nominal` branch.
///
/// ## MLX-free
/// This is the diffusion-core governor with MLX removed: the three `MLX.GPU.clearCache()` call sites
/// are replaced by an injected `clearCache: @Sendable () -> Void` (default no-op). The LLM engine
/// injects `{ MLX.GPU.clearCache() }` from inside its own MLX-linked package; every layer below it
/// stays MLX-free and testable deviceless.
///
/// ## Testability
/// The thermal-state and memory-pressure inputs, the cooperative sleep, and the cache-clear are all
/// injected. A test constructs a governor with scripted sources and no-op sleep/clearCache to exercise
/// the real pacing logic deterministically without a device or wall-clock waits.
public final class ThermalGovernor: @unchecked Sendable {
    public static let shared = ThermalGovernor()

    public typealias ThermalSource = @Sendable () -> ThermalSeverity
    public typealias PressureSource = @Sendable () -> MemoryPressure
    public typealias SleepFn = @Sendable (UInt64) async throws -> Void
    public typealias ClearCacheFn = @Sendable () -> Void

    /// Reads the current thermal severity, re-read on demand so an injected script flows through.
    private let thermalSource: ThermalSource
    /// Reads the current memory-pressure level.
    private let pressureSource: PressureSource
    /// Cooperative, cancellation-aware sleep. Defaults to `Task.sleep`; tests inject a no-op.
    private let sleepFn: SleepFn
    /// Relieves accelerator memory (injected). MLX-free default is a no-op.
    private let clearCache: ClearCacheFn

    private let lock = NSLock()
    private var _severity: ThermalSeverity = .nominal
    private var _pressure: MemoryPressure = .normal
    /// How many consecutive `.serious` throttles we've inserted — lengthens the backoff.
    private var consecutiveSeriousThrottles = 0

    #if os(iOS)
    private var thermalObserver: NSObjectProtocol?
    private var memorySource: DispatchSourceMemoryPressure?
    #endif

    /// Production initializer — wires the live system thermal/memory sources and `Task.sleep`.
    /// `clearCache` is injected by the caller (the MLX-linked engine passes `MLX.GPU.clearCache`).
    public convenience init(clearCache: @escaping ClearCacheFn = {}) {
        #if os(iOS)
        let box = SeverityBox(.nominal)
        let pressureBox = PressureBox(.normal)
        self.init(
            thermalSource: { box.value },
            pressureSource: { pressureBox.value },
            sleep: { try await Task.sleep(nanoseconds: $0) },
            clearCache: clearCache)
        box.value = Self.map(ProcessInfo.processInfo.thermalState)
        _severity = box.value
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            box.value = Self.map(ProcessInfo.processInfo.thermalState)
        }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak source] in
            guard let source else { return }
            // Record only; never clear the cache from the dispatch thread (the accelerator may be
            // mid-eval on the generation task). The next `throttleIfNeeded` clears it on that task.
            pressureBox.value = source.data.contains(.critical) ? .critical : .warning
        }
        source.resume()
        memorySource = source
        #else
        // macOS: plugged in, always nominal — a true runtime no-op.
        self.init(
            thermalSource: { .nominal },
            pressureSource: { .normal },
            sleep: { try await Task.sleep(nanoseconds: $0) },
            clearCache: clearCache)
        #endif
    }

    /// Designated initializer with injectable inputs. Use directly in tests to script the device's
    /// thermal/memory state and bypass real sleeps / cache clears.
    public init(thermalSource: @escaping ThermalSource,
                pressureSource: @escaping PressureSource = { .normal },
                sleep: @escaping SleepFn = { try await Task.sleep(nanoseconds: $0) },
                clearCache: @escaping ClearCacheFn = {}) {
        self.thermalSource = thermalSource
        self.pressureSource = pressureSource
        self.sleepFn = sleep
        self.clearCache = clearCache
    }

    deinit {
        #if os(iOS)
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        memorySource?.cancel()
        #endif
    }

    // MARK: - Cached state

    /// Latest thermal severity, re-read from the source. `.nominal` on macOS.
    public func currentSeverity() -> ThermalSeverity {
        let s = thermalSource()
        lock.lock(); _severity = s; lock.unlock()
        return s
    }

    /// Latest memory-pressure level, re-read from the source. `.normal` on macOS.
    public func currentPressure() -> MemoryPressure {
        let p = pressureSource()
        lock.lock(); _pressure = p; lock.unlock()
        return p
    }

    // MARK: - Start gate

    /// True when it is unsafe to BEGIN a heavy run right now because the device is already hot. The
    /// caller should defer with a "cooling" message or fall back to a lighter request. Always `false`
    /// on macOS (source reports `.nominal`).
    public func shouldDeferHeavyStart() -> Bool {
        return currentSeverity() >= .serious
    }

    // MARK: - Per-step throttle

    /// Pace the decode loop according to the current thermal state. Call on a wall-clock boundary
    /// (~every 250 ms of decode). Cooperative and cancellation-aware.
    ///
    /// On macOS this is a fall-through no-op (`.nominal` source): no sleep, no cache clear.
    ///
    /// - Parameter onCooling: invoked (once, when a `.critical` pause begins) so the engine can emit
    ///   a non-error "cooling" progress to the UI.
    /// - Throws: `CancellationError` if cancelled while throttling; `ThermalError.pausedForHeat` if
    ///   the device stays `.critical` past the bounded cooling timeout.
    public func throttleIfNeeded(onCooling: (@Sendable () -> Void)? = nil) async throws {
        // Relieve memory pressure on the generation task (never from the dispatch handler).
        if currentPressure() >= .warning { clearCache() }

        switch currentSeverity() {
        case .nominal, .fair:
            resetSeriousBackoff()
            return

        case .serious:
            clearCache()
            try await sleepFn(seriousBackoffNanos())

        case .critical:
            try await pauseUntilCool(onCooling: onCooling)
        }
    }

    // MARK: - Pacing logic

    /// Backoff at `.serious`: 250 ms, lengthening 100 ms per consecutive serious throttle up to
    /// 750 ms, so a device that stays hot opens progressively wider idle gaps.
    private func seriousBackoffNanos() -> UInt64 {
        lock.lock()
        consecutiveSeriousThrottles = min(consecutiveSeriousThrottles + 1, 5)
        let steps = consecutiveSeriousThrottles
        lock.unlock()
        let millis = 250 + 100 * (steps - 1)            // 250…650 (+ the cap below)
        return UInt64(min(millis, 750)) * 1_000_000
    }

    private func resetSeriousBackoff() {
        lock.lock(); consecutiveSeriousThrottles = 0; lock.unlock()
    }

    /// Hold the loop until the device drops out of `.critical`, polling its current state. Bounded so
    /// a device that simply won't cool surfaces a recoverable error instead of hanging the run.
    private func pauseUntilCool(onCooling: (@Sendable () -> Void)?) async throws {
        clearCache()
        onCooling?()
        let pollNanos: UInt64 = 500_000_000                 // 0.5 s
        let maxPolls = 240                                  // up to ~120 s of cooling
        var polls = 0
        while currentSeverity() >= .critical {
            try Task.checkCancellation()
            if polls >= maxPolls { throw ThermalError.pausedForHeat }
            try await sleepFn(pollNanos)
            polls += 1
        }
        resetSeriousBackoff()
    }

    // MARK: - Helpers

    #if os(iOS)
    private static func map(_ state: ProcessInfo.ThermalState) -> ThermalSeverity {
        switch state {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
    #endif
}

#if os(iOS)
/// A tiny lock-guarded box so the notification/dispatch handlers can publish state into the closures
/// the governor reads, without capturing `self` (avoids retain cycles on the singleton).
private final class SeverityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ThermalSeverity
    init(_ v: ThermalSeverity) { _value = v }
    var value: ThermalSeverity {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class PressureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: MemoryPressure
    init(_ v: MemoryPressure) { _value = v }
    var value: MemoryPressure {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
#endif
