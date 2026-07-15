// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

/// A recording `LLMEngine` double: counts load/unload, tags its answer so we can tell which engine
/// generated, and can stall so cancellation is observable.
private actor RecordingEngine: LLMEngine {
    let tag: String
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var isLoaded = false
    private(set) var cancelled = false
    /// When true, `generate` streams slowly so the test can cancel mid-stream.
    let stall: Bool

    init(tag: String, stall: Bool = false) {
        self.tag = tag
        self.stall = stall
    }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {
        loadCount += 1
        isLoaded = true
        progress(1)
    }

    func unload() async {
        unloadCount += 1
        isLoaded = false
    }

    func markCancelled() { cancelled = true }

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if stall {
                        // Emit one token, then wait long enough for the test to cancel us.
                        continuation.yield(.answer("[\(tag)]…"))
                        for _ in 0..<200 {
                            try Task.checkCancellation()
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                    }
                    continuation.yield(.answer("[\(tag)] done"))
                    continuation.yield(.done(Stats(promptTokens: 0, genTokens: 1, promptTPS: 0,
                                                   tokensPerSecond: 0, peakMemoryBytes: 0, stopReason: .eos)))
                    continuation.finish()
                } catch {
                    await self.markCancelled()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class RoutingEngineTests: XCTestCase {

    private var mlxVariant: LLMVariant   { LLMCatalog.bonsai8b.variant(engine: .mlx, quant: .binary1bit)! }
    private var ggufVariant: LLMVariant  { LLMCatalog.bonsai8b.variant(engine: .llamaCpp, quant: .binary1bit)! }
    private let dir = URL(fileURLWithPath: "/tmp/routing-test")

    /// `load` routes to the engine matching `variant.engine`, and `generate` forwards to it.
    func testRoutesByVariantEngine() async throws {
        let mlx = RecordingEngine(tag: "mlx")
        let gguf = RecordingEngine(tag: "gguf")
        let router = RoutingEngine(engines: [.mlx: mlx, .llamaCpp: gguf])

        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })
        let mlxLoaded = await mlx.loadCount
        let ggufLoaded = await gguf.loadCount
        XCTAssertEqual(mlxLoaded, 1)
        XCTAssertEqual(ggufLoaded, 0)
        let kind = await router.activeKind
        XCTAssertEqual(kind, .mlx)

        var answer = ""
        for try await d in router.generate(messages: [], params: Sampling()) {
            if case .answer(let s) = d { answer += s }
        }
        XCTAssertTrue(answer.contains("[mlx]"), "generate must forward to the routed (MLX) engine")
    }

    /// A cross-engine switch unloads the previously-active engine BEFORE loading the new one — never
    /// two resident stacks (the on-device memory-safety guarantee).
    func testCrossEngineSwitchUnloadsTheOther() async throws {
        let mlx = RecordingEngine(tag: "mlx")
        let gguf = RecordingEngine(tag: "gguf")
        let router = RoutingEngine(engines: [.mlx: mlx, .llamaCpp: gguf])

        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })
        try await router.load(model: LLMCatalog.bonsai8b, variant: ggufVariant, weightsDir: dir, progress: { _ in })

        let mlxUnloaded = await mlx.unloadCount
        let ggufLoaded = await gguf.loadCount
        let ggufUnloaded = await gguf.unloadCount
        XCTAssertEqual(mlxUnloaded, 1, "switching engines must unload the previously-active one")
        XCTAssertEqual(ggufLoaded, 1)
        XCTAssertEqual(ggufUnloaded, 0)
        let kind = await router.activeKind
        XCTAssertEqual(kind, .llamaCpp)
    }

    /// Re-loading on the SAME engine does not spuriously unload it (only cross-engine switches unload).
    func testSameEngineReloadDoesNotUnload() async throws {
        let mlx = RecordingEngine(tag: "mlx")
        let gguf = RecordingEngine(tag: "gguf")
        let router = RoutingEngine(engines: [.mlx: mlx, .llamaCpp: gguf])

        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })
        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })
        let mlxUnloaded = await mlx.unloadCount
        XCTAssertEqual(mlxUnloaded, 0)
    }

    /// `unload` releases the active engine and clears the active kind.
    func testUnloadReleasesActive() async throws {
        let mlx = RecordingEngine(tag: "mlx")
        let router = RoutingEngine(engines: [.mlx: mlx])
        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })
        await router.unload()
        let unloaded = await mlx.unloadCount
        let kind = await router.activeKind
        XCTAssertEqual(unloaded, 1)
        XCTAssertNil(kind)
    }

    /// `generate` before any load throws `noActiveEngine`.
    func testGenerateWithoutLoadThrows() async {
        let router = RoutingEngine(engines: [.mlx: RecordingEngine(tag: "mlx")])
        do {
            for try await _ in router.generate(messages: [], params: Sampling()) {}
            XCTFail("expected noActiveEngine")
        } catch let error as RoutingEngineError {
            XCTAssertEqual(error, .noActiveEngine)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Loading a variant whose engine isn't registered throws `noEngine`.
    func testLoadUnknownEngineThrows() async {
        let router = RoutingEngine(engines: [.mlx: RecordingEngine(tag: "mlx")])   // no llama.cpp engine
        do {
            try await router.load(model: LLMCatalog.bonsai8b, variant: ggufVariant, weightsDir: dir, progress: { _ in })
            XCTFail("expected noEngine")
        } catch let error as RoutingEngineError {
            XCTAssertEqual(error, .noEngine(.llamaCpp))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Cancelling the router's stream cancels the inner engine's stream too.
    func testCancellationForwardsToActiveEngine() async throws {
        let mlx = RecordingEngine(tag: "mlx", stall: true)
        let router = RoutingEngine(engines: [.mlx: mlx])
        try await router.load(model: LLMCatalog.bonsai8b, variant: mlxVariant, weightsDir: dir, progress: { _ in })

        let consume = Task {
            var first = ""
            for try await d in router.generate(messages: [], params: Sampling()) {
                if case .answer(let s) = d { first += s; break }   // stop after the first token
            }
            return first
        }
        // Let the first token arrive, then cancel the consuming task (terminates the router stream).
        try await Task.sleep(nanoseconds: 60_000_000)
        consume.cancel()
        _ = try? await consume.value

        // The inner engine should observe cancellation shortly after.
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelled = await mlx.cancelled
        XCTAssertTrue(cancelled, "cancelling the router stream must cancel the inner engine's stream")
    }
}
