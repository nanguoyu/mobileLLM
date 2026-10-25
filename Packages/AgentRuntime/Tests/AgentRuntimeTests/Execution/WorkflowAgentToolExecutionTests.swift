// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-SESSION-002
final class WorkflowAgentToolExecutionTests: XCTestCase {
    func testModelMessageUsesAuthorizedBoundaryAndWaitsForBudgetedCoordinatorActivation() async throws {
        let offset = 842
        let model = try ExecutorTestModelDefinition(offset: offset)
        let descriptor = try WorkflowAgentTool.descriptor(.sendMessage)
        let invocationID = ToolInvocationID()
        let proposed = try ProposedToolCall(invocationID: invocationID, toolID: descriptor.id.logicalID,
            arguments: CanonicalJSON(.object(["target": .string("coordinator"), "text": .string("The source changed to fourteen days."), "mode": .string("steer")])))
        func outcome(_ action: AgentAction) throws -> AgentModelAttemptOutcome {
            .completed(try AgentModelCompletion(action: action, usage: modelUsage(input: 8, output: 3, milliseconds: 4, memory: 48)))
        }
        let provider = try SequencedModelOutcomeProvider(model: model, outcomes: [
            outcome(.finalAnswer(AgentAnswer(text: "Initial assignment"))), outcome(.callTools([proposed])),
            outcome(.finalAnswer(AgentAnswer(text: "Sent the evidence"))), outcome(.finalAnswer(AgentAnswer(text: "Used the received evidence")))])
        let catalog = DeferredWorkflowToolCatalog(descriptor: descriptor)
        let conversation = ExecutorTestID.conversation(offset)
        let authority = try AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead, .localWrite]),
            destinations: [WorkflowAgentTool.destination(conversation)], dataCategories: [WorkflowAgentTool.dataCategory])
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model, toolDescriptors: [descriptor],
            tools: catalog, capabilityCeiling: RunCapabilityCeiling(authority: authority),
            availableToolCapabilities: AgentCapabilitySet([.localRead, .localWrite]),
            explicitlyRequestedToolIDs: [descriptor.id.logicalID], provenance: AgentRequestProvenance(source: .workflow))
        let root = harness.request
        let journal = InMemoryDynamicWorkflowJournal()
        let service = WorkflowAgentToolService(repository: harness.repository, journal: journal, values: InlineWorkflowValueStore())
        service.bind(harness.executor.controller)
        await catalog.install(try WorkflowAgentTool(operation: .sendMessage, service: service))
        let rootHandle = try await harness.executor.submit(root, commandID: ExecutorTestID.command(offset))
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: rootHandle))
        let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1,
            source: "export const meta={name:'tool-test',description:'Tool test'}; return null;")
        try await journal.saveScript(SavedWorkflowScriptV1(script: script,
            metadata: DynamicWorkflowScriptAnalyzer().analyze(script).metadata,
            owner: .conversation(conversation), createdAt: AgentTimestamp(rawValue: 1)))
        let workflowID = WorkflowRunID()
        let launch = WorkflowLaunchSnapshotV1(runID: workflowID, scriptReference: script.reference,
            args: try CanonicalJSON(.object(["goal": .string("Exchange evidence within this team.")])),
            conversationID: conversation, initiatingRunID: root.runID, initiatingRequestID: root.id,
            requestingStepID: AgentStepID(), capabilityCeiling: root.capabilityCeiling, budget: root.budget,
            defaultModelPolicy: root.modelPolicy, toolPolicyDigest: StableDigest.sha256(Data("tools".utf8)),
            policySnapshotDigest: StableDigest.sha256(Data("policy".utf8)))
        var graph = try WorkflowTaskGraph(objective: "Exchange evidence within this team.")
        try graph.update([WorkflowTaskUpdate(id: "evidence", expectedRevision: 0, agent: "researcher", instruction: "Send evidence", maximumToolCalls: 1)], expectedRevision: 1)
        let childRunID = ExecutorTestID.run(8421)
        let call = try WorkflowAgentCallV1(callID: WorkflowAgentCallID(), ordinal: 1, attempt: 1,
            prefixKey: StableDigest.sha256(Data("prefix".utf8)), promptDigest: StableDigest.sha256(Data("Send evidence".utf8)),
            options: WorkflowAgentOptionsV1(task: WorkflowTaskDescriptorV1(taskID: "evidence", instruction: "Send evidence",
                inputArtifactIDs: [], outputArtifactID: "evidence:1", expectedRevision: 1), sessionKey: "researcher"), childRunID: childRunID)
        let kinds: [WorkflowRunEventKindV1] = [.created(launch), .launchApproved(ApprovalID()),
            .stateChanged(from: .waitingForLaunchApproval, to: .queued, reason: nil),
            .stateChanged(from: .queued, to: .running, reason: nil),
            .collaborationRecorded(WorkflowCollaborationReceipt(index: 1, commandDigest: StableDigest.sha256(Data("init".utf8)), senderRunID: root.runID, graph: graph)),
            .agentCallPrepared(call)]
        var events: [WorkflowRunEventV1] = []
        for (index, kind) in kinds.enumerated() {
            events.append(try WorkflowRunEventV1(eventID: WorkflowEventID(), runID: workflowID, sequence: UInt64(index + 1),
                timestamp: AgentTimestamp(rawValue: Int64(index + 1)), previousDigest: events.last?.recordDigest, kind: kind))
        }
        _ = try await journal.append(WorkflowEventAppendRequestV1(runID: workflowID, expectedSequence: 0, expectedDigest: nil, events: events))
        let childCeiling = RunCapabilityCeiling(authority: try AgentAuthorityScope(capabilities: AgentCapabilitySet([.localWrite]),
            destinations: authority.destinations, dataCategories: authority.dataCategories))
        let child = try AgentRequest(id: ExecutorTestID.request(8421), runID: childRunID, conversationID: conversation,
            userTurnID: root.userTurnID, parent: ParentAgentContext(runID: root.runID, requestingStepID: AgentStepID(), capabilityCeiling: root.capabilityCeiling),
            role: "worker", instruction: "Send evidence", outputRequirement: .text, modelPolicy: root.modelPolicy,
            capabilityCeiling: childCeiling, budget: root.budget,
            labels: [AgentRequestLabel(key: "workflow.run", value: workflowID.description)],
            provenance: AgentRequestProvenance(source: .workflow, parentRequestID: root.id))
        let childHandle = try await harness.executor.submit(child, commandID: ExecutorTestID.command(8421))
        let childEvents = try await collectTerminalEvents(from: harness.executor.attach(to: childHandle))
        XCTAssertTrue(childEvents.contains { if case .toolOutcomeRecorded(_, .completed) = $0.payload.event { return true }; return false })
        let result = try await harness.executor.attach(to: childHandle).result()
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 1)
        let accepted = try await harness.repository.session(for: root.runID)
        XCTAssertEqual(accepted?.inputs.count, 1)
        XCTAssertEqual(accepted?.inputs.first?.sender, .agent(childRunID))
        XCTAssertEqual(accepted?.inputs.first?.mode, .nextTurn, "The completed coordinator anchor must queue its next activation")
        XCTAssertEqual(accepted?.activations.count, 1)
        let coordinator = try AgentRequest(id: ExecutorTestID.request(8422), runID: ExecutorTestID.run(8422), conversationID: conversation,
            userTurnID: root.userTurnID, parent: child.parent, role: "coordinator", instruction: "Use the new evidence.",
            outputRequirement: .text, modelPolicy: root.modelPolicy, capabilityCeiling: childCeiling,
            budget: root.budget, provenance: AgentRequestProvenance(source: .workflow, parentRequestID: root.id))
        let continued = try await harness.executor.controller.submitWorkflowActivation(coordinator, commandID: ExecutorTestID.command(8422),
            seedRunID: root.runID, senderRunID: childRunID)
        _ = try await collectTerminalEvents(from: harness.executor.attach(to: continued))
        let requests = await provider.script.capturedRequests()
        XCTAssertTrue(requests.last!.messages.contains { $0.content.contains("The source changed to fourteen days.") })
        let consumed = try await harness.repository.session(for: root.runID)
        XCTAssertEqual(consumed?.inclusions.count, 2)
        do { _ = try await service.list(sender: root.runID); XCTFail("Unbound root IDs do not grant tool membership") }
        catch AgentSessionError.invalidHistory {}
    }
}

private actor DeferredWorkflowToolCatalog: ExecutableToolCatalog {
    let descriptor: AgentToolDescriptor
    private var installed: (any ToolV2)?
    init(descriptor: AgentToolDescriptor) { self.descriptor = descriptor }
    func install(_ tool: any ToolV2) { installed = tool }
    func localSnapshot() async throws -> ToolCatalogSnapshot { try ToolCatalogSnapshot(revision: 1, descriptors: [descriptor]) }
    func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? { descriptorID == descriptor.id ? installed : nil }
}
