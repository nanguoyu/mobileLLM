// SPDX-License-Identifier: MIT

import XCTest
import AgentContracts
import AgentRuntime
@testable import MobileLLMUI

@MainActor
// TEST-ID: AHT-UI-001
// TEST-ID: AHT-LIFECYCLE-001
final class AgentRunStoreTests: XCTestCase {
    func testNeedsPanelOnlyForComplexRuns() throws {
        let runID = AgentRunID(rawValue: UUID())
        let base = AgentRunPresentation(conversationID: UUID(), runID: runID, state: .generating)
        XCTAssertFalse(base.needsPanel, "plain generating chat must look like ordinary chat")

        let completed = base.replacing(
            state: .completed,
            terminalReason: .completed,
            finalText: "answer"
        )
        XCTAssertFalse(completed.needsPanel, "a plain committed answer stays visually ordinary")

        let withTool = base.replacing(steps: [
            AgentRunStep(kind: .toolCall, title: "calculator", status: .running, sequence: 1),
        ])
        XCTAssertTrue(withTool.needsPanel, "tool activity must surface the agent panel")

        let waitingApproval = base.replacing(
            state: .waitingForApproval,
            blockingReason: .approval(approvalID: ApprovalID(rawValue: UUID())),
            pendingApproval: AgentApprovalCard(
                approvalID: ApprovalID(rawValue: UUID()),
                toolName: "web",
                destination: nil,
                preview: "preview",
                dataCategories: [],
                effects: [],
                isExternalWrite: false
            )
        )
        XCTAssertTrue(waitingApproval.needsPanel)

        let failed = base.replacing(
            state: .failed,
            terminalReason: .internalFailure,
            failureMessage: "boom"
        )
        XCTAssertTrue(failed.needsPanel, "failures need the recovery surface")
    }

    func testStartProjectsEventsAndDeliversCommittedAnswer() async throws {
        let executor = MockAgentExecutor()
        let builder = MockAgentRunRequestBuilder(submission: try makeSubmission())
        let store = AgentRunStore(executor: executor, requestBuilder: builder)
        let conversationID = UUID()
        let assistantID = UUID()
        var delivered: (String, String?)?
        store.onAnswer = { _, _, text, reasoning, _ in
            delivered = (text, reasoning)
        }

        let runID = try await store.start(
            conversationID: conversationID,
            userMessageID: UUID(),
            assistantMessageID: assistantID,
            text: "hello",
            imageRefs: []
        )
        let handle = try XCTUnwrap(executor.handle)
        try await waitUntil {
            store.presentation(for: conversationID)?.state == .created
        }

        handle.push(status: try AgentRunStatus(state: .generating, stateVersion: 2))
        try await waitUntil {
            store.presentation(for: conversationID)?.state == .generating
        }
        // Generating is token activity (rendered by the streaming row), not a user-facing step.
        XCTAssertTrue(
            store.presentation(for: conversationID)?.steps.isEmpty == true,
            "pipeline stages must not appear as steps"
        )

        // A semantic wait (approval) appears as a step; advancing settles it.
        let approvalID = ApprovalID(rawValue: UUID())
        handle.push(status: try AgentRunStatus(
            state: .waitingForApproval,
            stateVersion: 3,
            blockingReason: .approval(approvalID: approvalID)
        ))
        try await waitUntil {
            store.presentation(for: conversationID)?.steps.last?.kind == .approval
        }
        handle.push(status: try AgentRunStatus(state: .executingTools, stateVersion: 4))
        try await waitUntil {
            store.presentation(for: conversationID)?.state == .executingTools
        }
        XCTAssertEqual(
            store.presentation(for: conversationID)?.steps.last?.status,
            .succeeded,
            "the settled approval step must not keep waiting"
        )

        let answer = try AgentAnswer(text: "Hi there")
        handle.push(terminal: answer, runID: runID, stateVersion: 3)
        try await waitUntil {
            store.presentation(for: conversationID)?.state == .completed
        }

        let presentation = try XCTUnwrap(store.presentation(for: conversationID))
        XCTAssertEqual(presentation.state, .completed)
        XCTAssertEqual(presentation.finalText, "Hi there")
        XCTAssertEqual(delivered?.0, "Hi there")
        XCTAssertEqual(store.presentation(for: conversationID)?.steps.last?.status, .succeeded)
    }

    func testCancelCommandTargetsTheRunWithCurrentVersion() async throws {
        let executor = MockAgentExecutor()
        let builder = MockAgentRunRequestBuilder(submission: try makeSubmission())
        let store = AgentRunStore(executor: executor, requestBuilder: builder)
        let conversationID = UUID()
        _ = try await store.start(
            conversationID: conversationID,
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            text: "hello",
            imageRefs: []
        )
        let handle = try XCTUnwrap(executor.handle)
        handle.currentStatus = try AgentRunStatus(
            state: .paused,
            stateVersion: 7,
            blockingReason: .paused
        )

        await store.cancel(conversationID: conversationID)

        let command = try XCTUnwrap(handle.receivedCommands.last)
        XCTAssertEqual(command.payload.runID, builder.submission.request.runID)
        XCTAssertEqual(command.payload.expectedRunStateVersion, 7)
        XCTAssertEqual(command.payload.action, .cancel)
    }

    func testWaitingForUserRespondsWithoutCreatingANewRun() async throws {
        let executor = MockAgentExecutor()
        let builder = MockAgentRunRequestBuilder(submission: try makeSubmission())
        let store = AgentRunStore(executor: executor, requestBuilder: builder)
        let conversationID = UUID()
        let runID = try await store.start(
            conversationID: conversationID,
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            text: "hello",
            imageRefs: []
        )
        let handle = try XCTUnwrap(executor.handle)
        let interaction = try UserInputRequest(
            id: InteractionRequestID(rawValue: UUID()),
            runID: runID,
            prompt: "Which option?",
            creationStateVersion: 5
        )
        handle.currentStatus = try AgentRunStatus(
            state: .waitingForUser,
            stateVersion: 5,
            blockingReason: .userInput(requestID: interaction.id)
        )
        handle.push(userInput: interaction, runID: runID, stateVersion: 5)
        try await waitUntil {
            store.presentation(for: conversationID)?.pendingUserInput?.id == interaction.id
        }

        await store.respond(conversationID: conversationID, text: "  Option B  ")

        let command = try XCTUnwrap(handle.receivedCommands.last)
        guard case .respond(let response) = command.payload.action else {
            return XCTFail("expected a respond command")
        }
        XCTAssertEqual(response.requestID, interaction.id)
        XCTAssertEqual(response.value, .string("Option B"))
        XCTAssertEqual(executor.submitCount, 1, "responding must not create a new root run")
    }

    func testQuiesceForBackgroundPausesEveryActiveRunWithForegroundLost() async throws {
        let executor = MockAgentExecutor()
        let builder = MockAgentRunRequestBuilder(submission: try makeSubmission())
        let store = AgentRunStore(executor: executor, requestBuilder: builder)
        let first = UUID()
        let second = UUID()
        _ = try await store.start(
            conversationID: first,
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            text: "one",
            imageRefs: []
        )
        _ = try await store.start(
            conversationID: second,
            userMessageID: UUID(),
            assistantMessageID: UUID(),
            text: "two",
            imageRefs: []
        )
        let handle = try XCTUnwrap(executor.handle)
        handle.currentStatus = try AgentRunStatus(state: .generating, stateVersion: 4)

        await store.quiesceForBackground()

        let pauses = handle.receivedCommands.compactMap { envelope -> AgentQuiescenceReason? in
            guard case .pause(let reason) = envelope.payload.action else { return nil }
            return reason
        }
        XCTAssertEqual(pauses, [.foregroundLost, .foregroundLost])
        XCTAssertEqual(handle.receivedCommands.count, 2)
    }

    func testEphemeralDeltasForwardToStreamingSurfaceAndTerminalSettles() async throws {
        let executor = MockAgentExecutor()
        let builder = MockAgentRunRequestBuilder(submission: try makeSubmission())
        let store = AgentRunStore(executor: executor, requestBuilder: builder)
        let conversationID = UUID()
        let assistantID = UUID()
        var deltas: [(AgentEphemeralDeltaKind, String)] = []
        store.onEphemeral = { _, kind, text in deltas.append((kind, text)) }
        var terminated: (AgentTerminalReason, String?)?
        store.onRunTerminated = { _, _, reason, message in terminated = (reason, message) }

        _ = try await store.start(
            conversationID: conversationID,
            userMessageID: UUID(),
            assistantMessageID: assistantID,
            text: "hello",
            imageRefs: []
        )
        let handle = try XCTUnwrap(executor.handle)
        try await waitUntil {
            store.presentation(for: conversationID) != nil
        }
        handle.pushEphemeral(.visibleReasoningDelta("reasoning "))
        handle.pushEphemeral(.provisionalAnswerDelta("answer "))
        try await waitUntil { deltas.count == 2 }
        XCTAssertEqual(deltas[0].0, .reasoning)
        XCTAssertEqual(deltas[0].1, "reasoning ")
        XCTAssertEqual(deltas[1].0, .answer)
        XCTAssertEqual(deltas[1].1, "answer ")

        // A terminal event without an answer must settle the run through onRunTerminated.
        handle.push(
            terminal: try AgentAnswer(text: "unused"),
            runID: builder.submission.request.runID,
            stateVersion: 4
        )
        _ = terminated // Terminal-with-answer path uses onAnswer; the no-answer path is below.
        terminated = nil
        handle.push(
            terminal: nil,
            runID: builder.submission.request.runID,
            stateVersion: 5
        )
        try await waitUntil { terminated != nil }
        XCTAssertEqual(terminated?.0, .cancelledByUser)
    }
}

// MARK: - Fakes

private struct MockAgentRunRequestBuilder: AgentRunRequestBuilding {
    let submission: AgentRunSubmission

    func buildSubmission(
        conversationID: UUID,
        userTurnID: UUID,
        text: String,
        imageRefs: [ImageRef]
    ) async throws -> AgentRunSubmission {
        submission
    }
}

private final class MockAgentExecutor: AgentExecutor, @unchecked Sendable {
    let handle = MockAgentExecutionHandle()
    private(set) var submitCount = 0

    func submit(
        _ request: AgentRequest,
        commandID: AgentCommandID
    ) async throws -> AgentExecutionHandleID {
        submitCount += 1
        return handle.id
    }

    func attach(to id: AgentExecutionHandleID) async throws -> any AgentExecutionHandle {
        handle
    }
}

private final class MockAgentExecutionHandle: AgentExecutionHandle, @unchecked Sendable {
    let id = AgentExecutionHandleID(rawValue: UUID())
    private let requestID = AgentRequestID(rawValue: UUID())
    var currentStatus: AgentRunStatus = try! AgentRunStatus(state: .created, stateVersion: 1)
    private var eventContinuations: [AsyncThrowingStream<AgentEventEnvelope, Error>.Continuation] = []
    private var pendingEvents: [AgentEventEnvelope] = []
    private var ephemeralContinuations: [
        AsyncThrowingStream<AgentEphemeralEventEnvelope, Error>.Continuation
    ] = []
    private(set) var receivedCommands: [AgentCommandEnvelope] = []

    func events(
        after cursor: AgentEventCursor?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        let existing = pendingEvents
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            for event in existing { continuation.yield(event) }
            eventContinuations.append(continuation)
        }
    }

    func ephemeralEvents() async -> AsyncThrowingStream<AgentEphemeralEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            ephemeralContinuations.append(continuation)
        }
    }

    func status() async throws -> AgentRunStatus { currentStatus }

    func result() async throws -> AgentResult? { nil }

    func send(_ command: AgentCommandEnvelope) async throws -> AgentCommandReceipt {
        receivedCommands.append(command)
        return try AgentCommandReceipt(
            commandID: command.payload.commandID,
            runID: command.payload.runID,
            disposition: .accepted,
            currentStatus: currentStatus
        )
    }

    func push(status: AgentRunStatus) {
        let envelope = makeEnvelope(
            status: status,
            event: .statusChanged(status),
            runID: AgentRunID(rawValue: UUID())
        )
        for continuation in eventContinuations { continuation.yield(envelope) }
        pendingEvents.append(envelope)
    }

    func push(status: AgentRunStatus, runID: AgentRunID, stateVersion: UInt64) {
        currentStatus = status
        let envelope = makeEnvelope(
            status: status,
            event: .statusChanged(status),
            runID: runID
        )
        for continuation in eventContinuations { continuation.yield(envelope) }
        pendingEvents.append(envelope)
    }

    func pushEphemeral(_ event: AgentEphemeralModelEvent) {
        let envelope = AgentEphemeralEventEnvelope(
            executionHandleID: id,
            runID: AgentRunID(rawValue: UUID()),
            stepID: AgentStepID(rawValue: UUID()),
            emittedAt: AgentTimestamp(rawValue: 1),
            event: .model(event)
        )
        for continuation in ephemeralContinuations { continuation.yield(envelope) }
    }

    func push(userInput: UserInputRequest, runID: AgentRunID, stateVersion: UInt64) {
        let envelope = makeEnvelope(
            status: try! AgentRunStatus(
                state: .waitingForUser,
                stateVersion: stateVersion,
                blockingReason: .userInput(requestID: userInput.id)
            ),
            event: .userInputRequested(userInput),
            runID: runID
        )
        for continuation in eventContinuations { continuation.yield(envelope) }
        pendingEvents.append(envelope)
    }

    func push(terminal answer: AgentAnswer?, runID: AgentRunID, stateVersion: UInt64) {
        let status = try! AgentRunStatus(
            state: answer == nil ? .cancelled : .completed,
            stateVersion: stateVersion,
            terminalReason: answer == nil ? .cancelledByUser : .completed,
            failure: answer == nil
                ? try! AgentFailure(
                    code: "execution.cancelled",
                    classification: .cancelled,
                    safeMessage: "Stopped",
                    retryAdvice: .never,
                    externalEffect: .confirmedNone,
                    requiredUserAction: .none,
                    redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
                )
                : nil
        )
        let result = try! AgentResult(
            requestID: requestID,
            executionHandleID: id,
            runID: runID,
            status: status,
            answer: answer,
            usage: .zero
        )
        currentStatus = status
        let envelope = makeEnvelope(status: status, event: .terminal(result), runID: runID)
        for continuation in eventContinuations { continuation.yield(envelope) }
        pendingEvents.append(envelope)
    }

    private func makeEnvelope(
        status: AgentRunStatus,
        event: AgentEvent,
        runID: AgentRunID
    ) -> AgentEventEnvelope {
        try! AgentEventEnvelope(payload: AgentEventRecord(
            eventID: AgentEventID(rawValue: UUID()),
            requestID: requestID,
            executionHandleID: id,
            runID: runID,
            sequence: 1,
            runStateVersion: status.stateVersion,
            runState: status.state,
            timestamp: AgentTimestamp(rawValue: 1),
            event: event,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1),
            cumulativeUsage: .zero,
            previousRecordDigest: nil
        ))
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw AgentExecutionError.internalInvariant("condition timed out")
}

private func makeSubmission() throws -> AgentRunSubmission {
    guard let version = SemanticVersion("1.0.0") else {
        throw AgentExecutionError.internalInvariant("test version")
    }
    let selection = AgentModelSelection(
        providerID: try AgentModelProviderID("local.test"),
        modelID: try AgentModelID("test-model"),
        variantID: try AgentModelVariantID("test-variant"),
        capabilityVersion: version
    )
    let runID = AgentRunID(rawValue: UUID())
    let request = try AgentRequest(
        id: AgentRequestID(rawValue: UUID()),
        runID: runID,
        conversationID: ConversationID(rawValue: UUID()),
        userTurnID: UserTurnID(rawValue: UUID()),
        role: "assistant",
        instruction: "hello",
        outputRequirement: .text,
        modelPolicy: AgentModelPolicy(
            localOnly: true,
            allowedSelections: [selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        ),
        capabilityCeiling: RunCapabilityCeiling(authority: .empty),
        budget: try AgentBudget.firstReleaseDefaults(
            contextTokensPerAttempt: 4_096,
            outputTokens: 1_024,
            peakMemoryBytes: 1_073_741_824
        ),
        provenance: AgentRequestProvenance(source: .user)
    )
    let frozen = try FrozenAgentRunInputs(
        modelSelection: selection,
        generationParameters: try AgentModelGenerationParameters(
            maximumOutputTokens: 1_024,
            maximumContextTokens: 4_096,
            temperature: 0.8,
            topP: 0.9,
            topK: nil,
            repetitionPenalty: 1.0,
            thinkingMode: .disabled,
            seed: nil
        ),
        contextBudget: try ContextTokenBudget(
            maximumContextTokens: 4_096,
            reservedOutputTokens: 1_024,
            maximumToolSchemaTokens: 1_024
        ),
        baseSystem: try BaseSystemContextSource(revision: "v1", content: "policy"),
        currentUser: try CurrentUserContextSource(
            userTurnID: request.userTurnID,
            revision: "v1",
            content: "hello"
        ),
        toolCatalog: try ToolCatalogSnapshot(revision: 1, descriptors: []),
        toolPolicy: try ConversationToolPolicy(
            masterEnabled: false,
            allowedToolIDs: [],
            pinnedToolIDs: [],
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: false
        ),
        availableToolCapabilities: AgentCapabilitySet([]),
        contextPolicyVersion: 1,
        approvalPolicyVersion: 1
    )
    return AgentRunSubmission(request: request, frozenInputs: frozen)
}
