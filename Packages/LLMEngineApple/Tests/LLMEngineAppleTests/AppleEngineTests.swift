// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import LLMEngineApple

/// The engine's honesty contract: it exists on every OS, reports the REAL reason it can't run, and never
/// pretends to have weights.
///
/// NOTHING here requires Apple Intelligence — nor could it: the tests must pass on a machine whose OS
/// predates FoundationModels entirely, where `#available(macOS 26)` is false. Real inference is left to
/// the orchestrator / a device run; see `testRealInferenceIsNotCoveredHere`.
final class AppleEngineTests: XCTestCase {

    /// Collects the engine's `progress` callbacks. The callback is `@Sendable` (it can be invoked from any
    /// isolation), so the test can't just close over a `var`.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func record(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
        var recorded: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    // MARK: - Availability → state

    /// The probe answers on ANY OS rather than trapping. Below iOS 26 / macOS 26 that answer must be
    /// exactly `.unsupportedOS` — the framework is weak-linked and never touched.
    func testStatusIsAnswerableOnThisOS() {
        let status = AppleSystemModel.status()
        if #available(iOS 26, macOS 26, *) {
            // A machine that HAS the framework: any verdict is legitimate (it depends on the device and
            // whether the user enabled Apple Intelligence) — but it must never be `.unsupportedOS`.
            XCTAssertNotEqual(status, .unavailable(.unsupportedOS),
                              "this OS ships the framework, so the reason can't be 'OS too old'")
        } else {
            XCTAssertEqual(status, .unavailable(.unsupportedOS))
            XCTAssertFalse(status.isAvailable)
        }
    }

    /// The engine mirrors the probe: `status` is what the Models card and the install probe read.
    func testEngineStatusMatchesTheProbe() {
        XCTAssertEqual(AppleLLMEngine().status, AppleSystemModel.status())
    }

    // MARK: - Loading

    /// `load` fetches nothing and throws the REAL reason when the model can't run — so a tap on Use
    /// reports the problem instead of appearing to work and dead-ending at the first message.
    func testLoadThrowsTheRealReasonWhenUnavailable() async {
        let engine = AppleLLMEngine()
        let status = engine.status
        let model = LLMCatalog.appleSystem
        let progress = ProgressRecorder()
        do {
            try await engine.load(model: model, variant: model.defaultVariantValue,
                                  weightsDir: URL(fileURLWithPath: "/nonexistent"),
                                  progress: { progress.record($0) })
            XCTAssertTrue(status.isAvailable, "load only succeeds when the OS says the model is available")
            XCTAssertEqual(progress.recorded, [1], "nothing downloads: it's ready immediately")
        } catch let error as AppleEngineError {
            guard let reason = status.unavailableReason else {
                return XCTFail("load threw \(error) although the model is available")
            }
            XCTAssertEqual(error, .unavailable(reason), "the thrown error must carry the OS's real reason")
            // The failure the user reads is the actionable one, not a generic "couldn't load the model".
            XCTAssertEqual(error.localizedDescription, reason.message)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// `weightsDir` is meaningless here — there are no weights — so a nonexistent path must not fail the
    /// load. This pins that the engine never touches the filesystem.
    func testLoadIgnoresTheWeightsDirectory() async throws {
        try XCTSkipUnless(AppleLLMEngine().status.isAvailable, "needs an available system model")
        let model = LLMCatalog.appleSystem
        try await AppleLLMEngine().load(model: model, variant: model.defaultVariantValue,
                                        weightsDir: URL(fileURLWithPath: "/no/such/dir"),
                                        progress: { _ in })
    }

    /// `unload` holds nothing and must be safe to call at any time, including before a load.
    func testUnloadIsANoOp() async {
        await AppleLLMEngine().unload()
    }

    // MARK: - Generation

    /// On an OS without the system model, `generate` fails with the real reason rather than hanging, and
    /// the error is the one the chat UI shows.
    func testGenerateFailsWithTheRealReasonWhenUnavailable() async throws {
        let engine = AppleLLMEngine()
        guard let reason = engine.status.unavailableReason else {
            throw XCTSkip("the system model is available here; the unavailable path can't be exercised")
        }
        do {
            for try await _ in engine.generate(messages: [ChatTurn(role: .user, content: "hi")],
                                               params: Sampling()) {
                XCTFail("an unavailable model must not stream anything")
            }
            XCTFail("expected the stream to throw")
        } catch let error as AppleEngineError {
            XCTAssertEqual(error, .unavailable(reason))
        }
    }

    /// The availability check comes FIRST: with no user turn AND no system model, the reason the user
    /// can act on wins. (Where the model is available, the mapping error surfaces instead.)
    func testGenerateWithNoUserMessageFails() async {
        let engine = AppleLLMEngine()
        let expected: AppleEngineError = engine.status.unavailableReason.map { .unavailable($0) }
            ?? .noUserMessage
        do {
            for try await _ in engine.generate(messages: [], params: Sampling()) {
                XCTFail("nothing to answer — must not stream")
            }
            XCTFail("expected the stream to throw")
        } catch let error as AppleEngineError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Error localization

    /// Every case reads as guidance. These strings ARE the UI: a raw enum dump or an empty string is a
    /// dead end for the user.
    func testEveryErrorIsLocalized() {
        let errors: [AppleEngineError] = [
            .unavailable(.notEnabled), .unavailable(.deviceNotEligible), .unavailable(.unsupportedOS),
            .unavailable(.modelNotReady), .unavailable(.unknown),
            .noUserMessage, .contextWindowExceeded, .guardrailViolation, .unsupportedLanguage,
            .generationFailed(reason: "the model went away"),
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty, "\(error) needs user-facing text")
            XCTAssertFalse(text.contains("AppleEngineError"), "\(error) must not dump its type")
            XCTAssertFalse(text.hasPrefix("The operation couldn"),
                           "\(error) must not fall through to Foundation's default description")
        }
    }

    /// An unavailability error speaks with the reason's own voice — the actionable sentence, unwrapped.
    func testUnavailableErrorUsesTheReasonsMessage() {
        XCTAssertEqual(AppleEngineError.unavailable(.notEnabled).localizedDescription,
                       SystemModelStatus.Reason.notEnabled.message)
    }

    /// A failure we don't model keeps the framework's OWN description instead of a message we invented.
    func testGenerationFailedCarriesTheFrameworksReason() {
        let text = AppleEngineError.generationFailed(reason: "rate limited").localizedDescription
        XCTAssertTrue(text.contains("rate limited"), "the real reason must survive: \(text)")
    }

    /// Distinct failures must read differently, or naming them was pointless.
    func testErrorMessagesAreDistinct() {
        let messages = [
            AppleEngineError.contextWindowExceeded, .guardrailViolation, .unsupportedLanguage, .noUserMessage,
        ].map(\.localizedDescription)
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    // MARK: - What this suite deliberately does not cover

    /// Real inference needs Apple Intelligence enabled on an eligible iOS 26 / macOS 26 device, which no
    /// unit test may require. This documents the seam: set `APPLE_LLM_LIVE=1` on such a device to run one
    /// real round-trip through the engine and prove the cumulative→delta path against the actual stream.
    func testRealInferenceIsNotCoveredHere() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLE_LLM_LIVE"] == "1",
                          "set APPLE_LLM_LIVE=1 on a device with Apple Intelligence enabled")
        let engine = AppleLLMEngine()
        try XCTSkipUnless(engine.status.isAvailable, "Apple Intelligence is not available on this machine")
        let model = LLMCatalog.appleSystem
        try await engine.load(model: model, variant: model.defaultVariantValue,
                              weightsDir: URL(fileURLWithPath: "/"), progress: { _ in })
        var answer = ""
        var done = false
        for try await delta in engine.generate(
            messages: [ChatTurn(role: .system, content: "Reply with exactly one word."),
                       ChatTurn(role: .user, content: "Say hello.")],
            params: Sampling()) {
            switch delta {
            case .answer(let s): answer += s
            case .reasoning: break
            case .done: done = true
            }
        }
        XCTAssertTrue(done, "the stream must end with .done(Stats)")
        XCTAssertFalse(answer.isEmpty, "a live round-trip must produce an answer")
        // The cumulative→delta bug's signature: the answer repeats itself as the snapshots grow.
        XCTAssertFalse(answer.hasPrefix(answer.prefix(answer.count / 2) + answer.prefix(answer.count / 2)),
                       "deltas must not repeat the answer — snapshots are cumulative")
    }
}
