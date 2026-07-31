// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LLMCore

/// A solid-color PNG of the given pixel size — a valid, decodable image for the attachment tests, built
/// with ImageIO/CoreGraphics so it's platform-agnostic and runs in the plain SwiftPM harness.
func makeTestImageData(width: Int = 1200, height: Int = 900) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
    return out as Data
}

/// An `LLMEngine` that records the `ChatTurn`s each `generate` was handed (so a test can assert the send
/// path threaded the attached images onto the right turn), then emits a trivial answer + `.done`.
actor RecordingEngine: LLMEngine {
    private(set) var recordedTurns: [[ChatTurn]] = []

    func lastTurns() -> [ChatTurn]? { recordedTurns.last }
    private func record(_ turns: [ChatTurn]) { recordedTurns.append(turns) }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    nonisolated func generate(messages: [ChatTurn], params: Sampling)
        -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.record(messages)
                continuation.yield(.answer("ok"))
                continuation.yield(.done(Stats(promptTokens: 0, genTokens: 1, promptTPS: 0,
                                               tokensPerSecond: 1, peakMemoryBytes: 0, stopReason: .eos)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Holds ChatStore at its lazy-model readiness boundary so a test can mutate live settings after Send and
/// prove the in-flight turn still uses the authorization snapshot captured synchronously by `send()`.
actor ModelReadinessGate {
    private var isOpen = false
    private var didEnter = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        didEnter = true
        if isOpen { return true }
        return await withCheckedContinuation { waiter = $0 }
    }

    func entered() -> Bool { didEnter }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        waiter?.resume(returning: true)
        waiter = nil
    }
}
