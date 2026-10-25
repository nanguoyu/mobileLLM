// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-SESSION-002
final class AgentSessionExecutionTests: XCTestCase {
    func testGoalCompletionBarrierOrdersConcurrentMessageAcceptance() async throws {
        let model = try ExecutorTestModelDefinition(offset: 843)
        let provider = try SessionProbeProvider(model: model, script: SessionRequestProbe())
        let harness = try ExecutorTestHarness(offset: 843, provider: provider, model: model)
        let root = harness.request
        let handle = try await harness.executor.submit(root, commandID: ExecutorTestID.command(843))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: handle))
        let controller = harness.executor.controller
        let gate = BlockingModelGate()
        let cut = Task {
            try await controller.withSessionInputBarrier(runIDs: [root.runID]) {
                await gate.suspendUntilReleased()
                return .integer(Int64(try await controller.pendingSessionInputs(runIDs: [root.runID]).count))
            }
        }
        try await waitForExecutorCondition { await gate.hasEntered() }
        let acceptance = Task {
            try await controller.sendSessionInput(seedRunID: root.runID, conversationID: root.conversationID,
                messageID: MessageID(), text: "A later request", mode: .nextTurn, startNextTurn: false)
        }
        let sessionID = AgentSessionID(rawValue: root.runID.rawValue)
        try await waitForExecutorCondition { await controller.sessionGates[sessionID]?.waiters.count == 1 }
        await gate.release()
        let atCut = try await cut.value
        XCTAssertEqual(atCut, .integer(0))
        try await acceptance.value
        let after = try await controller.pendingSessionInputs(runIDs: [root.runID])
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.messages.first?.preview, "A later request")
    }

    func testAutomaticContinuationKeepsReservedBudgetSenderAndSessionWithoutHumanTurnAdmission() async throws {
        let model = try ExecutorTestModelDefinition(offset: 836)
        let probe = SessionRequestProbe()
        let provider = try SessionProbeProvider(model: model, script: probe)
        let harness = try ExecutorTestHarness(offset: 836, provider: provider, model: model)
        let root = harness.request
        let parentHandle = try await harness.executor.submit(root, commandID: ExecutorTestID.command(836))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: parentHandle))
        func child(_ number: Int, _ instruction: String) throws -> AgentRequest {
            var quantities = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, root.budget.limits[$0]) })
            quantities[.modelAttempts] = 2
            let budget = try AgentBudget(limits: BudgetQuantities(quantities),
                maximumThermalState: root.budget.maximumThermalState, memoryPressureResponse: root.budget.memoryPressureResponse)
            return try AgentRequest(id: ExecutorTestID.request(number), runID: ExecutorTestID.run(number),
                conversationID: root.conversationID, userTurnID: root.userTurnID,
                parent: ParentAgentContext(runID: root.runID, requestingStepID: AgentStepID(), capabilityCeiling: root.capabilityCeiling),
                role: "worker", instruction: instruction, outputRequirement: .text, modelPolicy: root.modelPolicy,
                capabilityCeiling: root.capabilityCeiling, budget: budget,
                provenance: AgentRequestProvenance(source: .workflow, parentRequestID: root.id))
        }
        let seed = try child(8361, "Remember Cedar.")
        let seedHandle = try await harness.executor.submit(seed, commandID: ExecutorTestID.command(8361))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: seedHandle))
        for number in [8362, 8363] {
            if number == 8363 {
                let messageID = MessageID(rawValue: ExecutorTestID.uuid(83629))
                for _ in 0..<2 {
                    try await harness.executor.controller.sendAgentSessionInput(seedRunID: seed.runID,
                        senderRunID: ExecutorTestID.run(8362), messageID: messageID,
                        text: "Peer evidence: retain the original source URL.", mode: .nextTurn)
                }
                let beforeAdmission = await probe.values().count
                XCTAssertEqual(beforeAdmission, 3, "Peer acceptance cannot mint an activation or a new budget")
                do {
                    try await harness.executor.controller.sendSessionInput(seedRunID: seed.runID, conversationID: root.conversationID,
                        messageID: messageID, text: "Peer evidence: retain the original source URL.", mode: .nextTurn, startNextTurn: false)
                    XCTFail("An agent message must not be replayed as a human instruction")
                } catch AgentSessionError.inputConflict {}
            }
            let request = try child(number, number == 8362 ? "Retain Cedar for 7 days." : "Recall the previous decision.")
            let handle = try await harness.executor.controller.submitWorkflowActivation(request,
                commandID: ExecutorTestID.command(number), seedRunID: seed.runID, senderRunID: root.runID)
            _ = try await collectTerminalEvents(from: harness.executor.attach(to: handle))
            let saved = try await harness.repository.loadRunFacts(for: request.runID)
            XCTAssertEqual(saved?.submission?.request.payload.budget, request.budget)
            let duplicate = try await harness.executor.controller.submitWorkflowActivation(request,
                commandID: ExecutorTestID.command(number), seedRunID: seed.runID, senderRunID: root.runID)
            XCTAssertEqual(duplicate, handle)
        }
        let recordedSession = try await harness.repository.session(for: ExecutorTestID.run(8363))
        let session = try XCTUnwrap(recordedSession)
        XCTAssertEqual(session.activations.count, 3)
        XCTAssertEqual(session.inputs.map(\.sender), [.agent(root.runID), .agent(ExecutorTestID.run(8362)), .agent(root.runID)])
        XCTAssertEqual(session.inclusions.count, 3)
        XCTAssertEqual(session.activations.last?.workflowManaged, true)
        let captured = await probe.values()
        XCTAssertEqual(captured.count, 4)
        XCTAssertTrue(captured.last!.messages.contains { $0.content.contains("Retain Cedar for 7 days") })
        XCTAssertTrue(captured.last!.messages.contains { $0.content.contains("Peer evidence: retain the original source URL.") })
        XCTAssertTrue(captured.last!.messages.contains { $0.content.contains("Agent run " + ExecutorTestID.run(8362).description) })
        let view = try await harness.executor.controller.sessionView(seedRunID: ExecutorTestID.run(8363), conversationID: root.conversationID)
        XCTAssertEqual(view.snapshot.id.rawValue, seed.runID.rawValue)
        do {
            _ = try await harness.executor.controller.submitWorkflowActivation(child(8364, "Not admitted"),
                commandID: ExecutorTestID.command(8364), seedRunID: seed.runID, senderRunID: ExecutorTestID.run(99999))
            XCTFail("An unbound sender must not write to the session")
        } catch AgentSessionError.invalidHistory {}
    }

    func testSteeringDuringGenerationCannotBeLostByFinalAnswerAndRetryDoesNotDuplicate() async throws {
        let model = try ExecutorTestModelDefinition(offset: 830)
        let script = SessionRequestProbe()
        let gate = BlockingModelGate()
        let provider = try SessionProbeProvider(model: model, script: script, firstGate: gate)
        let harness = try ExecutorTestHarness(offset: 830, provider: provider, model: model)
        let id = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(830))
        let handle = try await harness.executor.attach(to: id)
        try await waitForExecutorCondition { await gate.hasEntered() }
        // Equal UUIDs in different identifier domains must not hide an actual steering message.
        let message = MessageID(rawValue: harness.request.userTurnID.rawValue)
        for _ in 0..<2 {
            try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
                conversationID: harness.request.conversationID, messageID: message,
                text: "Use the 14-day retention limit.", mode: .steer, startNextTurn: false)
        }
        let pending = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertEqual(pending.messages.count, 1)
        XCTAssertFalse(pending.messages[0].included)
        await gate.release()
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed, events.map { String(describing: $0.payload.event) }.joined(separator: "\n"))
        let requests = await script.values()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[0].messages.contains { $0.content.contains("14-day") })
        XCTAssertTrue(requests.last!.messages.contains { $0.role == .user && $0.content.contains("14-day") })
        let settled = try await harness.repository.session(for: harness.request.runID)
        XCTAssertEqual(settled?.inclusions, [AgentSessionInputInclusion(messageID: message,
            runID: harness.request.runID, stepID: requests.last!.stepID)])
    }

    func testThreeTurnsKeepSessionAndHistoryAcrossExecutorRecreation() async throws {
        let model = try ExecutorTestModelDefinition(offset: 831)
        let script = SessionRequestProbe()
        let provider = try SessionProbeProvider(model: model, script: script)
        let harness = try ExecutorTestHarness(offset: 831, provider: provider, model: model)
        let id = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(831))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: id))
        let second = MessageID(rawValue: ExecutorTestID.uuid(83_002))
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: second,
            text: "Keep project Cedar and add a 14-day limit.", mode: .nextTurn, startNextTurn: true)
        let view = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        let secondHandle = try XCTUnwrap(view.turns.last?.handleID)
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: secondHandle))
        try await waitForWorkerToStop(AgentRunID(rawValue: second.rawValue), controller: harness.executor.controller)
        await harness.repository.close()
        let restored = makeRestored(harness, provider: provider)
        let before = try await restored.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertEqual(before.turns.count, 2)
        try await restored.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: second,
            text: "Keep project Cedar and add a 14-day limit.", mode: .nextTurn, startNextTurn: true)
        let third = MessageID(rawValue: ExecutorTestID.uuid(83_003))
        try await restored.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: third,
            text: "State the project and retention decision from our earlier turns.", mode: .nextTurn, startNextTurn: true)
        let current = try await restored.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        let thirdHandle = try XCTUnwrap(current.turns.last?.handleID)
        _ = try await collectTerminalEvents(from: restored.attach(to: thirdHandle))
        let requests = await script.values()
        XCTAssertEqual(requests.count, 3)
        let text = requests.last!.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains("project Cedar"))
        XCTAssertTrue(text.contains("14-day limit"))
        XCTAssertTrue(text.contains("Recorded response 1"))
        XCTAssertTrue(text.contains("Recorded response 2"))
        let latest = try await restored.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertEqual(latest.snapshot.id, before.snapshot.id)
        XCTAssertEqual(latest.turns.count, 3)
        XCTAssertEqual(latest.snapshot.inclusions.count, 2)
    }

    func testPausedSteerRemainsPendingAfterRecreationUntilExplicitResume() async throws {
        let model = try ExecutorTestModelDefinition(offset: 832)
        let script = PauseThenAnswerModelScript()
        let provider = try PauseThenAnswerModelProvider(model: model, answer: "Continued", script: script)
        let harness = try ExecutorTestHarness(offset: 832, provider: provider, model: model)
        let id = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(832))
        let handle = try await harness.executor.attach(to: id)
        try await waitForExecutorCondition { await script.hasStartedFirstAttempt() }
        let state = try await handle.status()
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(8_321), runID: harness.request.runID,
            expectedRunStateVersion: state.stateVersion, action: .pause(reason: .userRequested),
            issuedAt: AgentTimestamp(rawValue: 50_000))))
        _ = try await waitForStatus(.paused, handle: handle)
        try await waitForWorkerToStop(harness.request.runID, controller: harness.executor.controller)
        let message = MessageID(rawValue: ExecutorTestID.uuid(83_004))
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: message,
            text: "The required region is Europe.", mode: .steer, startNextTurn: true)
        await harness.repository.close()
        let restored = makeRestored(harness, provider: provider)
        let pending = try await restored.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertEqual(pending.turns[0].status?.state, .paused)
        XCTAssertEqual(pending.messages.map(\.included), [false])
        let count = await script.capturedRequests().count
        XCTAssertEqual(count, 1)
        _ = try await restored.controller.resumeSession(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        _ = try await collectTerminalEvents(from: restored.attach(to: id))
        let requests = await script.capturedRequests()
        XCTAssertTrue(requests.last!.messages.contains { $0.content.contains("required region is Europe") })
    }

    func testUnconsumedInputSurvivesCancellationAndIsCarriedIntoNextExplicitTurn() async throws {
        let model = try ExecutorTestModelDefinition(offset: 833)
        let script = PauseThenAnswerModelScript()
        let provider = try PauseThenAnswerModelProvider(model: model, answer: "Continued", script: script)
        let harness = try ExecutorTestHarness(offset: 833, provider: provider, model: model)
        let id = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(833))
        let handle = try await harness.executor.attach(to: id)
        try await waitForExecutorCondition { await script.hasStartedFirstAttempt() }
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: MessageID(rawValue: ExecutorTestID.uuid(83_005)),
            text: "Keep the audit log for 14 days.", mode: .steer, startNextTurn: false)
        let status = try await handle.status()
        _ = try await handle.send(AgentCommandEnvelope(payload: AgentCommand(
            commandID: ExecutorTestID.command(8_331), runID: harness.request.runID,
            expectedRunStateVersion: status.stateVersion, action: .cancel, issuedAt: AgentTimestamp(rawValue: 50_000))))
        _ = try await collectTerminalEvents(from: handle)
        try await waitForWorkerToStop(harness.request.runID, controller: harness.executor.controller)
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: MessageID(rawValue: ExecutorTestID.uuid(83_006)),
            text: "Now change the retention period to 7 days.", mode: .nextTurn, startNextTurn: true)
        let view = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        let next = try XCTUnwrap(view.turns.last?.handleID)
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: next))
        let requests = await script.capturedRequests()
        let current = try XCTUnwrap(requests.last?.messages.last(where: { $0.role == .user })?.content)
        let earlier = try XCTUnwrap(current.range(of: "audit log for 14 days"))
        let latest = try XCTUnwrap(current.range(of: "retention period to 7 days"))
        XCTAssertLessThan(earlier.lowerBound, latest.lowerBound)
        let completed = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertTrue(completed.messages.allSatisfy(\.included))
        XCTAssertEqual(completed.turns.first?.status?.state, .cancelled)
        XCTAssertEqual(completed.turns.last?.status?.state, .completed)
    }

    func testBackgroundQuiescenceCoversUnobservedFollowupsAndKeepsQueuedInput() async throws {
        let model = try ExecutorTestModelDefinition(offset: 834)
        let script = SessionRequestProbe()
        let gate = BlockingModelGate()
        let provider = try SessionProbeProvider(model: model, script: script, firstGate: gate, gateAt: 2)
        let harness = try ExecutorTestHarness(offset: 834, provider: provider, model: model)
        let seed = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(834))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: seed))
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: MessageID(rawValue: ExecutorTestID.uuid(83_007)),
            text: "Add a retention decision.", mode: .nextTurn, startNextTurn: true)
        try await waitForExecutorCondition { await gate.hasEntered() }
        try await harness.executor.controller.sendSessionInput(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID, messageID: MessageID(rawValue: ExecutorTestID.uuid(83_008)),
            text: "Then summarize the decision.", mode: .nextTurn, startNextTurn: true)
        try await harness.executor.controller.quiesceSessionsForBackground()
        await gate.release()
        let view = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        let current = try XCTUnwrap(view.turns.last?.handleID)
        _ = try await waitForStatus(.paused, handle: harness.executor.attach(to: current))
        try await waitForWorkerToStop(view.turns.last!.runID, controller: harness.executor.controller)
        let pending = try await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        XCTAssertEqual(pending.turns.count, 2)
        XCTAssertEqual(pending.snapshot.pendingTurns.count, 1)
        _ = try await harness.executor.controller.resumeSession(seedRunID: harness.request.runID,
            conversationID: harness.request.conversationID)
        try await waitForExecutorCondition {
            guard let latest = try? await harness.executor.controller.sessionView(seedRunID: harness.request.runID,
                conversationID: harness.request.conversationID) else { return false }
            return latest.turns.count == 3 && latest.turns.last?.status?.state == .completed
        }
        let requests = await script.values()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.last!.messages.contains { $0.content.contains("Then summarize the decision") })
    }

    private func makeRestored(_ harness: ExecutorTestHarness, provider: any AgentModelProvider) -> DurableAgentExecutor {
        DurableAgentExecutor(repository: SQLiteRunJournal(databaseURL: harness.databaseURL), payloadStore: harness.payloadStore,
            inputFreezer: StaticAgentRunInputFreezer(inputs: harness.frozenInputs),
            modelProviders: try! StaticAgentModelProviderCatalog(providers: [provider]),
            policyEngine: try! DefaultApprovalPolicyEngine(policyVersion: 1, sanitizationValidator: harness.attestor),
            sanitizer: harness.attestor, residencyDriver: ScriptedModelResidencyDriver(), clock: FixedExecutorClock())
    }
}

private actor SessionRequestProbe {
    private var requests: [AgentModelRequest] = []
    func record(_ request: AgentModelRequest) -> Int { requests.append(request); return requests.count }
    func values() -> [AgentModelRequest] { requests }
}

private struct SessionProbeProvider: AgentModelProvider, Sendable {
    let wrapped: FixedCompletionModelProvider
    let script: SessionRequestProbe
    let firstGate: BlockingModelGate?
    let gateAt: Int
    var descriptor: AgentModelProviderDescriptor { wrapped.descriptor }
    init(model: ExecutorTestModelDefinition, script: SessionRequestProbe, firstGate: BlockingModelGate? = nil, gateAt: Int = 1) throws {
        wrapped = try FixedCompletionModelProvider(model: model, answer: "unused")
        self.script = script
        self.firstGate = firstGate
        self.gateAt = gateAt
    }
    func capabilities(for selection: AgentModelSelection) async throws -> AgentModelCapabilities {
        try await wrapped.capabilities(for: selection)
    }
    func prepare(_ request: AgentModelRequest, context: ModelPreparationContext) async throws -> PreparedModelRequest {
        try await wrapped.prepare(request, context: context)
    }
    func generate(_ request: AgentModelRequest, emitter: AgentModelBoundaryEmitter) async throws -> AgentModelBoundaryCompletion {
        let index = await script.record(request)
        if index == gateAt { await firstGate?.suspendUntilReleased() }
        let completion = try AgentModelCompletion(action: .finalAnswer(AgentAnswer(text: "Recorded response \(index), project Cedar")),
            usage: modelUsage(input: 12, output: 8, milliseconds: 2, memory: 128))
        try await emitter.emit(.completed(completion), responseBytes: 64)
        return AgentModelBoundaryCompletion(outcome: .completed(completion))
    }
}
