// SPDX-License-Identifier: MIT

import Foundation

/// Cooperative control for one in-flight generation.
///
/// Engines call `checkpoint()` at safe boundaries. `pause()` blocks the next checkpoint without
/// trying to serialize model state; `cancel()` wakes any paused checkpoint and throws
/// `CancellationError`. This keeps pause/resume session-only and token-boundary scoped. (Ported
/// verbatim — MLX-free.)
public final class GenerationControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    public var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    public func pause() {
        condition.lock(); paused = true; condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func checkpoint() throws {
        try Task.checkCancellation()
        condition.lock()
        while paused && !cancelled { condition.wait() }
        let shouldCancel = cancelled
        condition.unlock()
        if shouldCancel { throw CancellationError() }
        try Task.checkCancellation()
    }
}
