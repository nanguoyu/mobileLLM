// SPDX-License-Identifier: MIT

import Foundation

/// Errors from the engine router.
public enum RoutingEngineError: Error, Equatable {
    /// No engine was registered for the kind a variant needs.
    case noEngine(EngineKind)
    /// `generate` was called before any successful `load`.
    case noActiveEngine
}

/// Routes `LLMEngine` calls to the right concrete engine by `variant.engine` (DESIGN §1 / §6). It holds
/// one engine per `EngineKind` (injected at init) and keeps AT MOST ONE resident at a time: loading a
/// variant on a *different* engine first `unload()`s the previously-active one, so two GPU/accelerator
/// weight stacks never co-reside — the on-device memory-safety guarantee. `generate` forwards to the
/// last-loaded engine; `unload` releases it.
///
/// MLX-free: it only knows the `LLMEngine` protocol, so the real MLX + llama.cpp engines inject here at
/// app assembly and this router (and its behavior) stays CLI-testable with mock engines.
public actor RoutingEngine: LLMEngine {

    private let engines: [EngineKind: any LLMEngine]
    /// The engine that currently holds (or is loading) weights, and its kind. `nil` when nothing is loaded.
    private var active: (kind: EngineKind, engine: any LLMEngine)?

    public init(engines: [EngineKind: any LLMEngine]) {
        self.engines = engines
    }

    /// Load `variant` on its engine. If a *different* engine is currently active, it is unloaded first
    /// (never keep two resident). The new engine becomes active before the load runs, so a mid-load
    /// failure still leaves `unload()` able to release it.
    public func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let kind = variant.engine
        guard let target = engines[kind] else { throw RoutingEngineError.noEngine(kind) }

        if let active, active.kind != kind {
            await active.engine.unload()   // cross-engine switch: drop the other stack first
        }
        active = (kind, target)
        try await target.load(model: model, variant: variant, weightsDir: weightsDir, progress: progress)
    }

    /// Release the active engine's weights (no-op when nothing is loaded).
    public func unload() async {
        guard let active else { return }
        await active.engine.unload()
        self.active = nil
    }

    /// Forward generation to the last-loaded engine. Cancelling the returned stream cancels the inner
    /// engine's stream too (the bridging task is cancelled on termination).
    public nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let engine = await self.activeEngine() else {
                    continuation.finish(throwing: RoutingEngineError.noActiveEngine)
                    return
                }
                do {
                    for try await delta in engine.generate(messages: messages, params: params) {
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The active engine (isolated read used by the nonisolated `generate` bridge).
    private func activeEngine() -> (any LLMEngine)? { active?.engine }

    /// The kind currently resident, for tests/diagnostics (`nil` when nothing is loaded).
    public var activeKind: EngineKind? { active?.kind }
}
