// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

/// Exercises the shipped program with controlled child outcomes. These are scheduler/control-flow
/// regressions, not evidence that a live model can solve the corresponding user tasks.
final class CoordinatedWorkflowTests: XCTestCase, @unchecked Sendable {
    func testStructuredRepairDiagnosticLocatesTheConstraintWithoutEchoingOutput() throws {
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"), "properties": .object([
                "content": .object(["type": .string("string"), "maxLength": .integer(5)])]),
            "required": .array([.string("content")]),
        ]))
        let diagnostic = ModelOutputInstructions.mismatch(.object(["content": .string("private-output-value")]), schema: schema)
        XCTAssertTrue(diagnostic.contains("$.content"))
        XCTAssertTrue(diagnostic.contains("maxLength"))
        XCTAssertFalse(diagnostic.contains("private-output-value"))
    }

    func testParallelWorkDependentHandoffAndRejectedDeliveryAreCorrectedInsideOneRun() async throws {
        let probe = CoordinationProbe()
        let result = try await run(initial: decision("work", tasks: [task("cost"), task("constraints")])) { call in
            await probe.enter(call)
            let label = call.options.label ?? ""
            if label == "cost" || label == "constraints" {
                try await Task.sleep(nanoseconds: 20_000_000)
                await probe.leave()
                return .value(worker(label + "-evidence"))
            }
            await probe.leave()
            switch label {
            case "coordinator":
                switch await probe.count(label) {
                case 1: return .value(decision("work", tasks: [task("reconcile", inputs: ["cost", "constraints"])]))
                case 2: return .value(decision("deliver"))
                case 3:
                    XCTAssertTrue(call.prompt.contains("wrong total"))
                    return .value(decision("work", tasks: [task("correct", inputs: ["reconcile"])]))
                default: return .value(decision("deliver"))
                }
            case "reconcile":
                XCTAssertTrue(call.prompt.contains("cost-evidence"))
                XCTAssertTrue(call.prompt.contains("constraints-evidence"))
                return .value(worker("combined derivation", content: "FULL-DERIVATION-BODY"))
            case "correct":
                XCTAssertTrue(call.prompt.contains("combined derivation"))
                XCTAssertTrue(call.prompt.contains("FULL-DERIVATION-BODY"))
                return .value(worker("corrected total 42"))
            case "draft":
                return .value(.string(await probe.count(label) == 1 ? "wrong total" : "corrected total 42"))
            case "acceptance-review":
                XCTAssertFalse(call.prompt.contains("FULL-DERIVATION-BODY"),
                    "Review uses the deliverable, artifact index and recorded evidence, not every intermediate body again")
                return .value(review(approved: await probe.count(label) > 1, gap: await probe.count(label) == 1 ? "wrong total" : ""))
            default: XCTFail("Unexpected child \(label)"); return .stopped
            }
        }
        XCTAssertEqual(result, .string("corrected total 42"))
        let peak = await probe.peak
        XCTAssertEqual(peak, 2, "Independent work really overlaps, not just source mentioning parallel")
        let reviewerCount = await probe.count("acceptance-review")
        XCTAssertEqual(reviewerCount, 2)
    }

    func testMissingDependencyIsRejectedBeforeDispatchAndIncompleteReviewCannotApprove() async throws {
        let probe = CoordinationProbe()
        do {
            _ = try await run(initial: decision("work", tasks: [task("invalid", inputs: ["future"])])) { call in
                await probe.enter(call); await probe.leave()
                switch call.options.label {
                case "invalid": XCTFail("Invalid dependency must not dispatch"); return .stopped
                case "coordinator":
                    switch await probe.count("coordinator") {
                    case 1:
                        XCTAssertTrue(call.prompt.contains("already settled artifacts"))
                        return .value(decision("work", tasks: [task("valid")]))
                    case 2: return .value(decision("deliver"))
                    default:
                        XCTAssertTrue(call.prompt.contains("omitted a required check"))
                        return .value(decision("blocked"))
                    }
                case "valid": return .value(worker("evidence"))
                case "draft": return .value(.string("A confident but unreviewed answer"))
                case "acceptance-review":
                    return .value(.object(["approved": .bool(true), "checks": .array([]), "issues": .array([])]))
                default: XCTFail("Unexpected child"); return .stopped
                }
            }
            XCTFail("An approved boolean cannot replace full acceptance checks")
        } catch { XCTAssertTrue(String(describing: error).contains("Task incomplete")) }
        let invalidCount = await probe.count("invalid")
        XCTAssertEqual(invalidCount, 0)
    }

    func testFailedWorkerPreservesSiblingArtifactAndCannotBecomeSuccessfulEvidence() async throws {
        let probe = CoordinationProbe()
        do {
            _ = try await run(initial: decision("work", tasks: [task("fails"), task("survives")])) { call in
                await probe.enter(call); await probe.leave()
                switch call.options.label {
                case "fails": throw WorkflowScriptRuntimeError.hostFailure("read unavailable")
                case "survives": return .value(worker("retained finding"))
                case "coordinator":
                    XCTAssertTrue(call.prompt.contains("retained finding"))
                    XCTAssertTrue(call.prompt.contains("failed"))
                    XCTAssertTrue(call.prompt.contains("read unavailable"))
                    return .value(decision("blocked"))
                default: XCTFail("Failure must not be presented as a reviewed delivery"); return .stopped
                }
            }
            XCTFail("Blocked work must not be a successful result")
        } catch { XCTAssertTrue(String(describing: error).contains("Task incomplete")) }
        let survivorCount = await probe.count("survives")
        XCTAssertEqual(survivorCount, 1)
    }

    func testFrozenProgramAndSchemasPassTheSameAnalyzerAndSchemaEnforcement() throws {
        let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: CoordinatedWorkflow.source)
        let analyzed = try DynamicWorkflowScriptAnalyzer().analyze(script)
        XCTAssertEqual(analyzed.staticAgentCallSites, analyzed.explicitlyBudgetedAgentCallSites)
        XCTAssertGreaterThan(analyzed.staticParallelCallSites, 0)
        XCTAssertFalse(analyzed.hasUnawaitedHostReturnInCatch)
        XCTAssertEqual(CoordinatedWorkflow.planSchema.enforcement, .fullyEnforced)
        XCTAssertEqual(CoordinatedWorkflow.decisionSchema.enforcement, .fullyEnforced)
    }

    private func run(
        initial: JSONValue,
        agent: @escaping @Sendable (WorkflowAgentInvocation) async throws -> WorkflowAgentBridgeResult
    ) async throws -> JSONValue {
        let script = try WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: CoordinatedWorkflow.source)
        let analyzed = try DynamicWorkflowScriptAnalyzer().analyze(script)
        let args = try CanonicalJSON(.object([
            "goal": .string("Determine the total under the supplied constraints."),
            "availableTools": .array([]),
            "plan": .object(["criteria": .array([.object(["id": .string("correct"), "requirement": .string("Correct total")])]),
                             "decision": initial]),
        ]))
        let result = try await JavaScriptCoreWorkflowRuntime().execute(analyzed, args: args,
            limits: .iPhoneDefault(), requirement: .init(), host: WorkflowScriptHost(agent: agent))
        return try JSONDecoder().decode(JSONValue.self, from: result.data)
    }
}

private actor CoordinationProbe {
    private var calls: [String: Int] = [:]
    private var active = 0
    var peak = 0
    func enter(_ call: WorkflowAgentInvocation) {
        calls[call.options.label ?? "", default: 0] += 1
        active += 1; peak = max(peak, active)
    }
    func leave() { active -= 1 }
    func count(_ label: String) -> Int { calls[label, default: 0] }
}

private func task(_ id: String, inputs: [String] = []) -> JSONValue {
    .object(["id": .string(id), "instruction": .string("Investigate " + id),
             "criteria": .array([.string("correct")]), "inputs": .array(inputs.map(JSONValue.string)), "maxToolCalls": .integer(0)])
}

private func decision(_ action: String, tasks: [JSONValue] = []) -> JSONValue {
    .object(["action": .string(action), "stage": .string("Work"), "reason": .string("Resolve the task"), "tasks": .array(tasks)])
}

private func worker(_ text: String, content: String? = nil) -> JSONValue {
    .object(["status": .string("completed"), "summary": .string(text), "content": .string(content ?? text), "unresolved": .array([])])
}

private func review(approved: Bool, gap: String) -> JSONValue {
    .object(["approved": .bool(approved), "issues": .array(gap.isEmpty ? [] : [.string(gap)]),
             "checks": .array([.object(["criterionID": .string("correct"),
                 "status": .string(approved ? "satisfied" : "unmet"), "evidence": .string("Recomputed total"), "gap": .string(gap)])])])
}
