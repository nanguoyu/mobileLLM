// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
@testable import mobileLLM
import LLMCore
import MobileLLMUI

// TEST-ID: AHT-DYNAMIC-LIVE-001
/// Real-model development through production launch, authorization and review.
/// Only task inputs are seeded. No external plans, answers or corrective turns reach the agents.
final class SandboxWorkflowLiveTests: XCTestCase, @unchecked Sendable {
    @MainActor func test01RestaurantWebsiteFromBrief() async throws {
        try await evaluate(name: "restaurant", goal: "开发一个中餐馆网站，支持在线订台。")
    }

    @MainActor func test02RepairExistingInventoryCode() async throws {
        try await evaluate(name: "repair", goal: "Fix the inventory.py project in the workspace. reserve(stock, requests) must aggregate repeated SKU requests, reject invalid quantities or insufficient stock without changing any input, and return remaining stock on success. Keep the public function signature and the existing tests. Run the tests, fix the code, verify it and deliver the repaired project.", seed: [
            "inventory.py": """
            def reserve(stock, requests):
                for sku, qty in requests:
                    if stock.get(sku, 0) < qty:
                        raise ValueError('insufficient stock')
                    stock[sku] -= qty
                return stock

            """,
            "test_inventory.py": """
            import unittest
            from inventory import reserve
            class InventoryTests(unittest.TestCase):
                def test_success_preserves_input(self):
                    stock = {'rice': 8, 'tea': 3}
                    self.assertEqual(reserve(stock, [('rice', 2), ('rice', 3)]), {'rice': 3, 'tea': 3})
                    self.assertEqual(stock, {'rice': 8, 'tea': 3})
                def test_failed_batch_is_atomic(self):
                    stock = {'rice': 8, 'tea': 3}
                    with self.assertRaises(ValueError): reserve(stock, [('rice', 3), ('tea', 4)])
                    self.assertEqual(stock, {'rice': 8, 'tea': 3})
                def test_invalid_quantities(self):
                    for qty in [0, -1, 1.5, True]:
                        with self.assertRaises(ValueError): reserve({'rice': 8}, [('rice', qty)])
            if __name__ == '__main__': unittest.main()

            """
        ])
    }

    @MainActor func test03ComputeAuditableSalesReport() async throws {
        try await evaluate(name: "sales", goal: "Create a reproducible Python sales analysis project from orders.csv. Deduplicate by order_id keeping the latest updated_at, exclude cancelled orders, and compute revenue in integer euro cents as quantity * unit_cents - refund_cents. Write totals.json with revenue_cents, order_count and by_country revenue totals. Include a concise human-readable report and tests, run them, and deliver the project.", seed: [
            "orders.csv": """
            order_id,updated_at,country,status,quantity,unit_cents,refund_cents
            A,2026-10-01T10:00:00Z,AT,paid,2,1299,0
            A,2026-10-01T12:00:00Z,AT,paid,3,1299,100
            B,2026-10-02T10:00:00Z,DE,cancelled,5,999,0
            C,2026-10-02T11:00:00Z,DE,paid,2,1050,350
            D,2026-10-03T11:00:00Z,AT,paid,1,599,599
            E,2026-10-04T11:00:00Z,FR,paid,4,225,25

            """
        ])
    }

    @MainActor private func evaluate(name: String, goal: String, seed: [String: String] = [:]) async throws {
        guard ProcessInfo.processInfo.environment["MOBILELLM_LIVE_WORKFLOWS"] == "1",
              let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_SANDBOX_CONFIG"] else {
            throw XCTSkip("Real model and sandbox evaluation requires explicit opt-in")
        }
        executionTimeAllowance = 1_200
        struct Config: Decodable { let endpoint: String; let apiKey: String }
        let sandbox = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let connection = try await OpenSandboxHTTPClient.connect(endpoint: sandbox.endpoint, apiKey: sandbox.apiKey)
        let client = OpenSandboxHTTPClient(connection: connection, apiKey: { sandbox.apiKey })
        let modelConfig = try LiveConfiguration.load()
        let model = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_MODEL"] ?? modelConfig.model
        let runID = WorkflowRunID()
        let base = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("mobilellm-sandbox-evaluations")
        let root = base.appendingPathComponent(name + "-" + runID.description)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let api = ResponsesAPIConfiguration(serviceID: "sandbox-evaluation", baseURL: modelConfig.baseURL, apiKey: modelConfig.apiKey)
        let assembly = try AgentRuntimeAssembly(engine: NoLocalEvaluationEngine(), downloadBase: root, conversationDirectory: root,
            models: [LLMCatalog.bonsai8b], snapshot: { _,_,_,_ in nil }, onlineConfiguration: { _ in api },
            sandboxCredentials: { $0 == connection.fingerprint.rawValue ? OpenSandboxCredentials(connection: connection, apiKey: sandbox.apiKey) : nil })
        var failures: [String] = []
        let start = Date()
        if !seed.isEmpty {
            _ = try await operation(client, workspace: runID, payload: ["action": .string("write"), "files": .array(seed.keys.sorted().map {
                .object(["path": .string($0), "content": .string(seed[$0]!), "expectedSHA256": .null])
            })])
        }
        let local = LLMCatalog.bonsai8b, turn = UUID()
        let snapshot = AgentRunRequestSnapshot(conversationID: UUID(), userTurnID: turn, text: goal, imageRefs: [],
            messages: [Message(id: turn, role: .user, answer: goal)], systemPrompt: "You are a capable assistant. Complete the user's task using the available tools and actual evidence.",
            memoryFacts: [], activeSkill: nil, model: local, variant: local.defaultVariantValue, weightsDirectory: root,
            thinkingEnabled: false, contextLength: 8192, maxTokens: 8192, temperature: 0.2, topP: 0.9, topK: 40, repetitionPenalty: 1,
            toolsEnabled: true, localToolNames: [], memorySeamAvailable: false, eventSeamAvailable: false, locationSeamAvailable: false,
            mcpToolDescriptors: [], webSearchDestinations: [], toolPolicy: nil, onlineModelEnabled: true, onlineModelID: model,
            onlineServiceID: "sandbox-evaluation", onlineConfigurationID: "sandbox-evaluation", onlineReasoningEnabled: true,
            onlineContextLength: 32768, onlineOutputBudgetAuto: true, onlineMaximumOutputTokens: nil,
            approvalMode: .fullAccess, onlineReasoningEffort: .low, availableSkills: Skill.builtIns, executionEnvironment: connection)
        do {
            _ = try await assembly.prepareCoordinatedWorkflow(snapshot: snapshot, runID: runID)
            _ = try await assembly.dynamicWorkflows.approveAndStart(runID: runID)
            let deadline = Date().addingTimeInterval(900)
            var previous = ""
            while Date() < deadline {
                if let state = try await assembly.dynamicWorkflowJournal.loadProjection(for: runID) {
                    let status = "\(state.state): \(state.calls.count) calls, \(state.currentPhase ?? "preparing")"
                    if status != previous { print("[SandboxWorkflow] \(name) \(status)"); previous = status }
                    if state.isTerminal || (state.state == .paused && state.taskGraph?.state != .active) { break }
                    if state.state == .waitingForReconciliation { failures.append("The autonomous task needs effect reconciliation"); break }
                    var blocked = false
                    for call in state.calls {
                        if try await assembly.repository.loadRunFacts(for: call.childRunID)?.projection.state == .waitingForApproval {
                            blocked = true; break
                        }
                    }
                    if blocked { failures.append("Full Access evaluation unexpectedly requested tool approval"); break }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch { failures.append(String(describing: error)) }
        let state = try await assembly.dynamicWorkflowJournal.loadProjection(for: runID)
        if state?.state != .completed { failures.append("Goal did not complete: \(state?.taskGraph?.reason ?? state?.state.rawValue ?? "no projection")") }
        var evidence: [WorkflowReviewToolEvidence] = []
        let spawner = DurableSubagentSpawner(executor: assembly.executor, repository: assembly.repository)
        let handles = state.map { Array($0.submittedHandles.values) } ?? []
        for handle in handles {
            if let entries = try? await spawner.reviewToolEvidence(handle) { evidence += entries }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: root.appendingPathComponent("tool-evidence.json"))
        if let graph = state?.taskGraph { try encoder.encode(graph).write(to: root.appendingPathComponent("task-graph.json")) }
        if let output = try await assembly.dynamicWorkflows.resolvedOutput(runID: runID) {
            try output.data.write(to: root.appendingPathComponent("answer.json"))
        }
        let artifacts = await assembly.artifactStore.allReferences().filter { $0.semanticType?.hasPrefix("sandbox.") == true }
        for artifact in artifacts {
            let suffix = artifact.mimeType == "application/zip" ? ".zip" : ".jpg"
            let data = try await assembly.artifactStore.data(for: artifact)
            try data.write(to: root.appendingPathComponent(artifact.id.description + suffix))
        }
        if artifacts.filter({ $0.semanticType == "sandbox.project-source" }).isEmpty { failures.append("No actual source archive") }
        if name == "restaurant" {
            let actions = Set(evidence.filter { $0.succeeded != false }.compactMap { $0.execution?.operation })
            if !actions.isSuperset(of: ["sandbox_start", "sandbox_browser", "sandbox_export"]) {
                failures.append("The website was not actually started, inspected and exported")
            }
        }
        // Independent assertions execute after the autonomous run and cannot send it corrective hints.
        if state?.state == .completed && name == "repair" {
            do { _ = try await operation(client, workspace: runID, payload: ["action": .string("exec"), "timeoutSeconds": .integer(20),
                "command": .string("""
                python3 -m unittest -v && python3 - <<'PY'
                from inventory import reserve
                s={'rice':5}; r=[('rice',3),('rice',3)]
                try: reserve(s,r)
                except ValueError: pass
                else: raise AssertionError('aggregate oversell')
                assert s=={'rice':5} and r==[('rice',3),('rice',3)]
                assert reserve({'tea':2},[])=={'tea':2}
                for q in ['2',None,True,0,-3,2.5]:
                 try: reserve({'tea':8},[('tea',q)])
                 except ValueError: pass
                 else: raise AssertionError('invalid quantity accepted')
                PY
                """)]) }
            catch { failures.append("Independent inventory oracle: \(error)") }
        }
        if state?.state == .completed && name == "sales" {
            do { _ = try await operation(client, workspace: runID, payload: ["action": .string("exec"), "timeoutSeconds": .integer(20),
                "command": .string("""
                python3 - <<'PY'
                import json
                x=json.load(open('totals.json'))
                assert x['revenue_cents']==6422 and x['order_count']==4, x
                assert x['by_country']=={'AT':3797,'DE':1750,'FR':875}, x
                PY
                """)]) }
            catch { failures.append("Independent exact sales oracle: \(error)") }
        }
        let workers = state?.calls.filter { $0.options.requestedAgentType != "workflow-supervisor" } ?? []
        if Set(workers.compactMap { $0.options.sessionKey }).count < 2 { failures.append("No independent collaborating agents") }
        let record: [String: Any] = ["case": name, "goal": goal, "runID": runID.description, "model": model,
            "codeRevision": ProcessInfo.processInfo.environment["MOBILELLM_LIVE_REVISION"] ?? "unrecorded",
            "durationSeconds": Date().timeIntervalSince(start), "state": state?.state.rawValue ?? "missing", "failures": failures,
            "workerCalls": workers.count, "recordedToolCalls": evidence.count, "artifactCount": artifacts.count]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: root.appendingPathComponent("public-result.json"))
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
        attachment.name = name + " result"; attachment.lifetime = .keepAlways; add(attachment)
        print("[SandboxWorkflow] retained \(root.path)")
        // Keep a successful website for independent browser validation. Other scopes close now.
        if name != "restaurant" || state?.state != .completed {
            if state?.isTerminal != true { try? await assembly.dynamicWorkflows.stop(runID: runID) }
            _ = try? await client.request("DELETE", path: "v1/workspaces/" + runID.description.lowercased())
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func operation(_ client: OpenSandboxHTTPClient, workspace: WorkflowRunID, payload: [String: JSONValue]) async throws -> OpenSandboxJob {
        let operation = UUID().uuidString.lowercased()
        let body = try CanonicalJSON(.object(["workspaceID": .string(workspace.description),
            "requestFingerprint": .string(StableDigest.sha256(try CanonicalJSON(.object(payload)).data).rawValue),
            "payload": .object(payload), "timeoutSeconds": .integer(60)]))
        _ = try await client.request("POST", path: "v1/operations/" + operation, body: body.data)
        for _ in 0..<600 {
            let result = try JSONDecoder().decode(OpenSandboxJob.self, from: await client.request("GET", path: "v1/operations/" + operation))
            if result.state == "completed" { return result }
            if ["failed", "uncertain", "cancelled"].contains(result.state) { throw LiveEvaluationError(result.error ?? result.state) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw LiveEvaluationError("Evaluator operation exceeded its deadline")
    }
}
