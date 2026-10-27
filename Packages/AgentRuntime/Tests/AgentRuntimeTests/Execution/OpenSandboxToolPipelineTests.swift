// SPDX-License-Identifier: MIT
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

// TEST-ID: AHT-SANDBOX-001
/// Deterministic action sequence, real Tool V2/authorization/runtime and real OpenSandbox commands.
/// This is a mechanism regression, separate from autonomous real-model task evaluation.
final class OpenSandboxToolPipelineTests: XCTestCase, @unchecked Sendable {
    func testFailedCommandCanBeRetriedAfterAnObservedEditInTheSameRun() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_SANDBOX_CONFIG"] else {
            throw XCTSkip("Explicit local OpenSandbox configuration is required")
        }
        struct Configuration: Decodable { let endpoint: String; let apiKey: String }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let connection = try await OpenSandboxHTTPClient.connect(endpoint: config.endpoint, apiKey: config.apiKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobilellm-tool-pipeline-" + UUID().uuidString)
        let scope = UUID()
        let template = try OpenSandboxProvider(connection: connection, scopeID: scope, directory: directory, apiKey: { config.apiKey })
        let descriptor = try XCTUnwrap(OpenSandboxTool.descriptors(connection: connection).first { $0.id.logicalID.name == "sandbox_run" })
        let model = try ExecutorTestModelDefinition(offset: 686)
        let check = "python3 -c \"assert open('value.txt').read() == 'fixed'\""
        func call(_ index: Int, _ command: String) throws -> ProposedToolCall {
            try ProposedToolCall(invocationID: ExecutorTestID.invocation(index), toolID: descriptor.id.logicalID,
                arguments: CanonicalJSON(.object(["command": .string(command), "timeoutSeconds": .integer(20)])))
        }
        let calls = try [call(686, "printf broken > value.txt"), call(687, check),
                         call(688, "printf fixed > value.txt"), call(689, check)]
        let outcomes = try calls.map { call in
            try AgentModelAttemptOutcome.completed(AgentModelCompletion(action: .callTools([call]),
                usage: modelUsage(input: 8, output: 3, milliseconds: 4, memory: 48)))
        } + [.completed(AgentModelCompletion(action: .finalAnswer(AgentAnswer(text: "The corrected source passed the same check.")),
            usage: modelUsage(input: 8, output: 3, milliseconds: 4, memory: 48)))]
        let modelProvider = SequencedModelOutcomeProvider(model: model, outcomes: outcomes)
        let catalog = PipelineSandboxCatalog(descriptor: descriptor)
        let defaults = try AgentBudget.firstReleaseDefaults(contextTokensPerAttempt: 4096, outputTokens: 6144, peakMemoryBytes: 2_147_483_648)
        var limits = Dictionary(uniqueKeysWithValues: defaults.limits.entries.map { ($0.dimension, $0.value) })
        limits[.networkRequestBytes] = 8_388_608
        limits[.networkResponseBytesTotal] = 8_388_608
        limits[.networkResponseBytesPerOperation] = 1_048_576
        limits[.toolInvocations] = 4
        limits[.activeMilliseconds] = 900_000
        let budget = try AgentBudget(limits: BudgetQuantities(limits),
            maximumThermalState: defaults.maximumThermalState, memoryPressureResponse: defaults.memoryPressureResponse)
        let harness = try ExecutorTestHarness(offset: 686, provider: modelProvider, model: model,
            toolDescriptors: [descriptor], tools: catalog, capabilityCeiling: RunCapabilityCeiling(authority: template.maximumAuthority),
            availableToolCapabilities: template.maximumAuthority.capabilities,
            explicitlyRequestedToolIDs: [descriptor.id.logicalID], clock: SystemAgentExecutionClock(),
            budget: budget, approvalMode: .fullAccess)
        let service = OpenSandboxToolService(repository: harness.repository, directory: directory, sanitizer: harness.attestor,
            credentials: { $0 == connection.fingerprint.rawValue ? OpenSandboxCredentials(connection: connection, apiKey: config.apiKey) : nil })
        await catalog.bind(service)
        addTeardownBlock {
            try await service.close(workspaceID: scope)
            await harness.repository.close()
            try? FileManager.default.removeItem(at: directory)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: harness.databaseURL.path + suffix) }
            let name = harness.databaseURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "mobilellm-executor-", with: "mobilellm-executor-artifacts-")
            try? FileManager.default.removeItem(at: harness.databaseURL.deletingLastPathComponent().appendingPathComponent(name))
        }
        let id = try await harness.executor.submit(harness.request, commandID: ExecutorTestID.command(686))
        let handle = try await harness.executor.attach(to: id)
        let events = try await collectTerminalEvents(from: handle)
        let result = try await handle.result()
        XCTAssertEqual(result?.status.state, .completed)
        XCTAssertEqual(result?.usage.quantities[.toolInvocations], 4)
        XCTAssertGreaterThan(result?.usage.quantities[.networkResponseBytesTotal] ?? 0, 0)
        let records = events.compactMap { event -> (ToolInvocationID, AgentToolInvocationOutcome)? in
            guard case .toolOutcomeRecorded(let id, let outcome) = event.payload.event else { return nil }
            return (id, outcome)
        }
        XCTAssertEqual(records.count, 4)
        guard records.count == 4 else { return }
        guard case .failed(let failure) = records[1].1 else { return XCTFail("The original assertion must fail, without reconciliation") }
        XCTAssertEqual(failure.code, "sandbox.opensandbox.execution")
        guard case .completed = records[3].1 else { return XCTFail("The byte-identical test command must run after the source changes") }
        XCTAssertEqual(calls[1].arguments, calls[3].arguments)
        XCTAssertFalse(events.contains { if case .statusChanged(let state) = $0.payload.event { return state.state == .waitingForReconciliation }; return false })
    }
}

private actor PipelineSandboxCatalog: ExecutableToolCatalog {
    let descriptor: AgentToolDescriptor
    var service: OpenSandboxToolService?
    init(descriptor: AgentToolDescriptor) { self.descriptor = descriptor }
    func bind(_ service: OpenSandboxToolService) { self.service = service }
    func localSnapshot() async throws -> ToolCatalogSnapshot { try ToolCatalogSnapshot(revision: 1, descriptors: [descriptor]) }
    func tool(for id: AgentToolDescriptorID) async throws -> (any ToolV2)? { try await service?.adapter(for: id) }
}
