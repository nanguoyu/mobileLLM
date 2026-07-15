// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

/// A lock-guarded counter usable from the governor's `@Sendable` injected closures.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
    func inc() { lock.lock(); _v += 1; lock.unlock() }
}

/// Emits a scripted sequence of severities (then repeats the last), so `.critical` cooling can be
/// driven deterministically without a device.
private final class SeqBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seq: [ThermalSeverity]
    private var i = 0
    init(_ seq: [ThermalSeverity]) { self.seq = seq }
    func next() -> ThermalSeverity {
        lock.lock(); defer { lock.unlock() }
        let v = seq[min(i, seq.count - 1)]; i += 1; return v
    }
}

final class ThermalGovernorTests: XCTestCase {

    /// `.nominal` → no sleep, no cache clear (zero tax in the common case).
    func testNominalIsNoop() async throws {
        let sleeps = Counter(), clears = Counter()
        let g = ThermalGovernor(thermalSource: { .nominal },
                                pressureSource: { .normal },
                                sleep: { _ in sleeps.inc() },
                                clearCache: { clears.inc() })
        try await g.throttleIfNeeded()
        XCTAssertEqual(sleeps.value, 0)
        XCTAssertEqual(clears.value, 0)
    }

    /// `.serious` → inserts a cooperative backoff sleep and clears the reuse pool.
    func testSeriousBacksOff() async throws {
        let sleeps = Counter(), clears = Counter()
        let g = ThermalGovernor(thermalSource: { .serious },
                                sleep: { _ in sleeps.inc() },
                                clearCache: { clears.inc() })
        try await g.throttleIfNeeded()
        XCTAssertGreaterThanOrEqual(sleeps.value, 1)
        XCTAssertGreaterThanOrEqual(clears.value, 1)
    }

    /// `.critical` → pauses (emits the "cooling" callback + clears cache), then recovers once the
    /// device drops below critical.
    func testCriticalPausesThenRecovers() async throws {
        let clears = Counter()
        // read #1 (switch) = .critical → enter pause; read #2 (while) = .nominal → exit.
        let seq = SeqBox([.critical, .nominal])
        var cooled = false
        let g = ThermalGovernor(thermalSource: { seq.next() },
                                sleep: { _ in },
                                clearCache: { clears.inc() })
        try await g.throttleIfNeeded(onCooling: { cooled = true })
        XCTAssertTrue(cooled, "critical pause must surface a cooling callback")
        XCTAssertGreaterThanOrEqual(clears.value, 1)
    }

    /// `.critical` that never cools → recoverable `ThermalError.pausedForHeat` (not a hang or crash),
    /// using a no-op sleep so the bounded poll loop runs instantly.
    func testCriticalThatNeverCoolsThrows() async {
        let g = ThermalGovernor(thermalSource: { .critical },
                                sleep: { _ in },
                                clearCache: {})
        do {
            try await g.throttleIfNeeded()
            XCTFail("expected pausedForHeat")
        } catch is ThermalError {
            // expected
        } catch {
            XCTFail("expected ThermalError.pausedForHeat, got \(error)")
        }
    }

    /// Memory pressure ≥ warning clears the cache even at `.nominal` thermal.
    func testMemoryPressureClearsCache() async throws {
        let clears = Counter()
        let g = ThermalGovernor(thermalSource: { .nominal },
                                pressureSource: { .warning },
                                sleep: { _ in },
                                clearCache: { clears.inc() })
        try await g.throttleIfNeeded()
        XCTAssertGreaterThanOrEqual(clears.value, 1)
    }
}
