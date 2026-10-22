// SPDX-License-Identifier: MIT

import Foundation
import AgentContracts

public struct SubagentStallTimeout: Error, Sendable {
    public let milliseconds: UInt64
}

/// Monotonic inactivity timer; a stream delta or journal event advances the deadline.
actor SubagentProgressDeadline {
    private let clock = ContinuousClock()
    private let milliseconds: UInt64
    private var deadline: ContinuousClock.Instant
    init(milliseconds: UInt64) {
        self.milliseconds = milliseconds
        deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(milliseconds)))
    }
    func markProgress() { deadline = clock.now.advanced(by: .milliseconds(Int64(milliseconds))) }
    func waitForStall() async throws -> SubagentResult {
        while true {
            try await clock.sleep(until: deadline)
            try Task.checkCancellation()
            if clock.now >= deadline { throw SubagentStallTimeout(milliseconds: milliseconds) }
        }
    }
}
