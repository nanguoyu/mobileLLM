// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class StreamingAuthorizationTests: XCTestCase {
    func testModelDeltasArriveWhileAuthorizedOperationIsStillRunning() async throws {
        let fixture = try modelBoundaryFixture(seed: 300, responseLimit: 16)
        let sink = RecordingModelSink()
        let firstDeltaForwarded = AsyncGate()
        let allowCompletion = AsyncGate()
        let completion = try successfulCompletion(text: "hello")

        let task = Task {
            try await fixture.authorized.performGenerationBoundary(
                observation: fixture.observation,
                attempt: fixture.attempt,
                hop: fixture.hop,
                sink: sink
            ) { _, emitter in
                try await emitter.emit(.answerDelta("hel"), responseBytes: 3)
                await firstDeltaForwarded.open()
                await allowCompletion.wait()
                try await emitter.emit(.completed(completion), responseBytes: 2)
                return AgentModelBoundaryCompletion(
                    outcome: .completed(completion),
                    responseDigest: TestValues.digest("4")
                )
            }
        }

        await firstDeltaForwarded.wait()
        let eventsBeforeReturn = await sink.snapshot()
        XCTAssertEqual(eventsBeforeReturn, [.answerDelta("hel")])
        await allowCompletion.open()

        let result = try await task.value
        XCTAssertEqual(result.outcome, .completed(completion))
        XCTAssertEqual(result.responseBytes, 5)
        XCTAssertEqual(result.responseDigest, TestValues.digest("4"))
        let finalEvents = await sink.snapshot()
        XCTAssertEqual(finalEvents, [.answerDelta("hel"), .completed(completion)])
    }

    func testEscapedEmitterAndBoundaryControlAreInvalidAfterCompletion() async throws {
        let fixture = try modelBoundaryFixture(seed: 310, responseLimit: 8)
        let sink = RecordingModelSink()
        let capture = EmitterCapture()
        let completion = try successfulCompletion(text: "done")

        let result = try await fixture.authorized.performGenerationBoundary(
            observation: fixture.observation,
            attempt: fixture.attempt,
            hop: fixture.hop,
            sink: sink
        ) { _, emitter in
            await capture.store(emitter)
            try await emitter.emit(.completed(completion), responseBytes: 1)
            return AgentModelBoundaryCompletion(outcome: .completed(completion))
        }
        XCTAssertEqual(result.responseBytes, 1)

        let capturedEmitter = await capture.value()
        let escaped = try XCTUnwrap(capturedEmitter)
        await XCTAssertThrowsAgentContractError {
            try await escaped.emit(.answerDelta("late"), responseBytes: 1)
        }
        let events = await sink.snapshot()
        XCTAssertEqual(events, [.completed(completion)])
    }

    func testGateRejectsOverLimitChunkBeforeItReachesModelSink() async throws {
        let fixture = try modelBoundaryFixture(
            seed: 320,
            responseLimit: 10,
            observedResponseLimit: 4
        )
        let sink = RecordingModelSink()

        await XCTAssertThrowsAgentContractError {
            _ = try await fixture.authorized.performGenerationBoundary(
                observation: fixture.observation,
                attempt: fixture.attempt,
                hop: fixture.hop,
                sink: sink
            ) { _, emitter in
                try await emitter.emit(.answerDelta("oversized"), responseBytes: 5)
                return AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            }
        }
        let events = await sink.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func testEmitterRejectsConcurrentEmissionWithoutChargingOrForwardingSecondEvent() async throws {
        let fixture = try modelBoundaryFixture(seed: 330, responseLimit: 8)
        let enteredSink = AsyncGate()
        let releaseSink = AsyncGate()
        let sink = BlockingFirstModelSink(entered: enteredSink, release: releaseSink)
        let concurrentCallRejected = BooleanRecorder()
        let completion = try successfulCompletion(text: "done")

        let result = try await fixture.authorized.performGenerationBoundary(
            observation: fixture.observation,
            attempt: fixture.attempt,
            hop: fixture.hop,
            sink: sink
        ) { _, emitter in
            let first = Task {
                try await emitter.emit(.answerDelta("a"), responseBytes: 1)
            }
            await enteredSink.wait()
            do {
                try await emitter.emit(.answerDelta("b"), responseBytes: 1)
                await concurrentCallRejected.store(false)
            } catch {
                await concurrentCallRejected.store(true)
            }
            await releaseSink.open()
            try await first.value
            try await emitter.emit(.completed(completion), responseBytes: 1)
            return AgentModelBoundaryCompletion(outcome: .completed(completion))
        }

        let wasConcurrentCallRejected = await concurrentCallRejected.value()
        XCTAssertTrue(wasConcurrentCallRejected)
        XCTAssertEqual(result.responseBytes, 2)
        let events = await sink.snapshot()
        XCTAssertEqual(events, [.answerDelta("a"), .completed(completion)])
    }

    func testFinishFailsClosedWhileAnEmitIsSuspended() async throws {
        let fixture = try modelBoundaryFixture(seed: 340, responseLimit: 8)
        let enteredSink = AsyncGate()
        let releaseSink = AsyncGate()
        let producerFinished = AsyncGate()
        let producerWasRejected = BooleanRecorder()
        let sink = BlockingFirstModelSink(entered: enteredSink, release: releaseSink)

        let boundary = Task {
            try await fixture.authorized.performGenerationBoundary(
                observation: fixture.observation,
                attempt: fixture.attempt,
                hop: fixture.hop,
                sink: sink
            ) { _, emitter in
                _ = Task {
                    do {
                        try await emitter.emit(.answerDelta("in-flight"), responseBytes: 1)
                        await producerWasRejected.store(false)
                    } catch {
                        await producerWasRejected.store(true)
                    }
                    await producerFinished.open()
                }
                await enteredSink.wait()
                return AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            }
        }

        await enteredSink.wait()
        await XCTAssertThrowsAgentContractError { _ = try await boundary.value }
        await releaseSink.open()
        await producerFinished.wait()
        let wasProducerRejected = await producerWasRejected.value()
        XCTAssertTrue(wasProducerRejected)
    }

    func testActionSignalsPermanentlyCloseBothValidatorsToLaterDeltas() async throws {
        let call = try ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 350),
            toolID: AgentToolLogicalID(providerID: "test", name: "lookup"),
            arguments: CanonicalJSON(.object(["query": .string("value")]))
        )
        let interaction = try UserInputRequest(
            id: TestValues.id(InteractionRequestIDDomain.self, 351),
            runID: TestValues.id(AgentRunIDDomain.self, 352),
            prompt: "Which value should be used?",
            creationStateVersion: 1
        )

        XCTAssertNoThrow(try AgentModelEventStreamValidator.validate(
            [.answerDelta("provisional"), .toolCalls([call])],
            requireTerminal: false
        ))
        XCTAssertThrowsError(try AgentModelEventStreamValidator.validate(
            [.toolCalls([call]), .answerDelta("must not escape")],
            requireTerminal: false
        ))
        XCTAssertThrowsError(try AgentModelEventStreamValidator.validate(
            [.requestUserInput(interaction), .reasoningDelta("must not escape")],
            requireTerminal: false
        ))

        let toolFixture = try modelBoundaryFixture(seed: 360, responseLimit: 8)
        let toolSink = RecordingModelSink()
        await XCTAssertThrowsAgentContractError {
            _ = try await toolFixture.authorized.performGenerationBoundary(
                observation: toolFixture.observation,
                attempt: toolFixture.attempt,
                hop: toolFixture.hop,
                sink: toolSink
            ) { _, emitter in
                try await emitter.emit(.toolCalls([call]), responseBytes: 1)
                try await emitter.emit(.answerDelta("late"), responseBytes: 1)
                return AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            }
        }
        let toolEvents = await toolSink.snapshot()
        XCTAssertEqual(toolEvents, [.toolCalls([call])])

        let inputFixture = try modelBoundaryFixture(seed: 370, responseLimit: 8)
        let inputSink = RecordingModelSink()
        await XCTAssertThrowsAgentContractError {
            _ = try await inputFixture.authorized.performGenerationBoundary(
                observation: inputFixture.observation,
                attempt: inputFixture.attempt,
                hop: inputFixture.hop,
                sink: inputSink
            ) { _, emitter in
                try await emitter.emit(.requestUserInput(interaction), responseBytes: 1)
                try await emitter.emit(.reasoningDelta("late"), responseBytes: 1)
                return AgentModelBoundaryCompletion(outcome: .interrupted(nil))
            }
        }
        let inputEvents = await inputSink.snapshot()
        XCTAssertEqual(inputEvents, [.requestUserInput(interaction)])
    }
}

private extension StreamingAuthorizationTests {
    struct ModelBoundaryFixture {
        let authorized: AuthorizedModelRequest
        let observation: ExternalOperationObservation
        let attempt: ExternalOperationAttempt
        let hop: ExternalOperationBoundaryHop
    }

    func modelBoundaryFixture(
        seed: UInt16,
        responseLimit: UInt64,
        observedResponseLimit: UInt64? = nil
    ) throws -> ModelBoundaryFixture {
        let request = try AgentModelRequest(
            requestID: TestValues.id(AgentRequestIDDomain.self, seed),
            runID: TestValues.id(AgentRunIDDomain.self, seed + 1),
            stepID: TestValues.id(AgentStepIDDomain.self, seed + 2),
            selection: AgentModelSelection(
                providerID: try AgentModelProviderID("local"),
                modelID: try AgentModelID("bonsai"),
                variantID: try AgentModelVariantID("8b-1bit"),
                capabilityVersion: SemanticVersion("1.0.0")!
            ),
            compiledManifestDigest: TestValues.digest("5"),
            messages: [try AgentModelMessage(
                role: .user,
                content: "Answer locally.",
                isUntrustedData: false
            )],
            advertisedTools: [],
            toolSelectionSnapshot: try AgentToolSelectionSnapshot(
                selectorID: "runtime.tool-selector",
                policyVersion: 1,
                inputDigest: TestValues.digest("6"),
                decisions: []
            ),
            generationParameters: .standard,
            outputRequirement: .text
        )
        let canonical = try request.authorizationPayload()
        let payload = TestValues.sanitized(canonical)
        let ceiling = RunCapabilityCeiling(authority: .empty)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: .empty)
        let plan = try ExternalOperationPlan(
            kind: .localPure,
            subjectID: "local.model.generate",
            payloadDigest: canonical.fingerprint,
            effects: [AgentEffect.localPure],
            requiredCapabilities: AgentCapabilitySet([]),
            maximumRequestBytes: UInt64(canonical.data.count + 16),
            maximumResponseBytes: responseLimit,
            timeoutMilliseconds: 1_000,
            retryPolicy: .never,
            idempotency: .pureRead,
            userPreview: ""
        )
        let prepared = try PreparedExternalOperationRequest(
            requestID: request.requestID,
            runID: request.runID,
            conversationID: TestValues.id(ConversationIDDomain.self, seed + 3),
            stepID: request.stepID,
            plan: plan,
            payload: payload,
            capabilityGrant: grant
        )
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, seed + 4),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1),
            expiresAt: AgentTimestamp(rawValue: 100)
        )
        let trusted = try TrustedRunAuthority(
            runID: request.runID,
            ceiling: ceiling,
            policyRevision: 1
        )
        let external = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trusted
        )
        let authorized = try AuthorizedModelRequest(
            request: request,
            authorization: external,
            clock: FixedClock(timestamp: AgentTimestamp(rawValue: 10)),
            policyValidator: AllowingAuthorizationPolicy(),
            attemptLedger: FreshBoundaryLedger()
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        return try ModelBoundaryFixture(
            authorized: authorized,
            observation: ExternalOperationObservation(
                destination: nil,
                dataCategories: [],
                effects: [AgentEffect.localPure],
                requestBytes: UInt64(payload.data.count),
                responseBytesLimit: observedResponseLimit ?? responseLimit,
                payloadDigest: canonical.fingerprint
            ),
            attempt: attempt,
            hop: ExternalOperationBoundaryHop(
                prepared: prepared,
                attempt: attempt,
                destination: nil
            )
        )
    }

    func successfulCompletion(text: String) throws -> AgentModelCompletion {
        try AgentModelCompletion(
            action: .finalAnswer(AgentAnswer(text: text)),
            usage: AgentModelUsage(
                inputTokens: 1,
                outputTokens: 1,
                activeMilliseconds: 1,
                peakMemoryBytes: 1
            )
        )
    }
}

private actor RecordingModelSink: AgentModelEventSink {
    private var events: [AgentModelEvent] = []

    func receive(_ event: AgentModelEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentModelEvent] { events }
}

private actor BlockingFirstModelSink: AgentModelEventSink {
    private let entered: AsyncGate
    private let release: AsyncGate
    private var events: [AgentModelEvent] = []

    init(entered: AsyncGate, release: AsyncGate) {
        self.entered = entered
        self.release = release
    }

    func receive(_ event: AgentModelEvent) async {
        events.append(event)
        if events.count == 1 {
            await entered.open()
            await release.wait()
        }
    }

    func snapshot() -> [AgentModelEvent] { events }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor BooleanRecorder {
    private var storedValue = false
    func store(_ value: Bool) { storedValue = value }
    func value() -> Bool { storedValue }
}

private actor EmitterCapture {
    private var emitter: AgentModelBoundaryEmitter?
    func store(_ emitter: AgentModelBoundaryEmitter) { self.emitter = emitter }
    func value() -> AgentModelBoundaryEmitter? { emitter }
}

private struct FixedClock: AgentAuthorizationClock {
    let timestamp: AgentTimestamp
    func now() async throws -> AgentTimestamp { timestamp }
}

private struct AllowingAuthorizationPolicy: AgentAuthorizationPolicyValidating {
    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {}
}

private actor FreshBoundaryLedger: ExternalOperationAttemptClaiming {
    private var claimed: Set<StableDigest> = []

    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) -> Bool {
        claimed.insert(hop.fingerprint).inserted
    }
}

private func XCTAssertThrowsAgentContractError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected AgentContractError", file: file, line: line)
    } catch is AgentContractError {
        // Expected.
    } catch {
        XCTFail("Expected AgentContractError, received \(error)", file: file, line: line)
    }
}
