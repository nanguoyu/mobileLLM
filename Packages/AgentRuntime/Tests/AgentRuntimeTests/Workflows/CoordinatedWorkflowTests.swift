// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import XCTest

// TEST-ID: AHT-DYNAMIC-001

/// Control-flow regressions. Task correctness is measured separately against real output oracles.
final class CoordinatedWorkflowTests: XCTestCase, @unchecked Sendable {
    func testSupervisorReceivesActualParallelResultsAndContinuesExistingTask() async throws {
        let probe = CoordinationProbe()
        let result = try await run(initial: decision("work", tasks: [task("cost"), task("constraints")]), tools: ["builtin.web_search"]) { call in
            await probe.enter(call)
            let label = call.options.label ?? ""
            if label != "coordinator" { try await Task.sleep(nanoseconds: 20_000_000) }
            await probe.leave()
            switch label {
            case "cost":
                if await probe.count(label) == 1 { return .value(.string("FULL-COST-DERIVATION: 19 + 23 = 42")) }
                XCTAssertTrue(call.prompt.contains("FULL-COST-DERIVATION"))
                XCTAssertTrue(call.prompt.contains("CONSTRAINT-COUNTEREXAMPLE"))
                XCTAssertTrue(call.prompt.contains("ORIGINAL-RECORDED-PAGE-FACT"))
                XCTAssertTrue(call.prompt.contains("Investigate cost"), "Continuation retains prior assignment")
                XCTAssertNil(call.options.schema, "Worker returns its artifact without a redundant JSON wrapper")
                return .value(.string("Corrected total: 43"))
            case "constraints": return .value(.string("CONSTRAINT-COUNTEREXAMPLE: one additional unit"))
            case "coordinator":
                if await probe.count(label) == 1 {
                    XCTAssertTrue(call.prompt.contains("FULL-COST-DERIVATION"))
                    XCTAssertTrue(call.prompt.contains("CONSTRAINT-COUNTEREXAMPLE"))
                    return .value(decision("work", tasks: [task("cost", inputs: ["constraints:2"], instruction: "Correct the omitted unit.")], notes: "Keep the counterexample."))
                }
                XCTAssertTrue(call.prompt.contains("Keep the counterexample."))
                XCTAssertTrue(call.prompt.contains("Corrected total: 43"))
                return .value(decision("deliver", answer: "43"))
            default: XCTFail("Unexpected mandatory role: \(label)"); return .stopped
            }
        }
        XCTAssertEqual(result, .string("43"))
        let peak = await probe.peak
        let count = await probe.total
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(count, 5, "Two workers, one continued worker and two supervisor turns suffice")
    }

    func testSupervisorReadsUntruncatedArtifactLocallyWithoutAnotherWorkerOrWebCall() async throws {
        let probe = CoordinationProbe()
        let content = String(repeating: "a", count: 20_000) + "UNABRIDGED-TAIL-事实😀"
        let result = try await run(initial: decision("work", tasks: [task("source")])) { call in
            await probe.enter(call); await probe.leave()
            switch call.options.label {
            case "source": return .value(.string(content))
            case "coordinator":
                if await probe.count("coordinator") == 1 {
                    XCTAssertFalse(call.prompt.contains("UNABRIDGED-TAIL"))
                    XCTAssertTrue(call.prompt.contains("\"truncated\":true"))
                    return .value(decision("read", reads: [.object(["id": .string("source:1"), "offset": .integer(20_000), "length": .integer(100)])]))
                }
                XCTAssertTrue(call.prompt.contains("UNABRIDGED-TAIL-事实😀"))
                return .value(decision("deliver", answer: "Read the original tail"))
            default: XCTFail("Reading must not dispatch another worker"); return .stopped
            }
        }
        XCTAssertEqual(result, .string("Read the original tail"))
        let total = await probe.total
        XCTAssertEqual(total, 3)
    }

    func testInvalidReferencesAreRejectedAndFailedWorkersStayVisible() async throws {
        let probe = CoordinationProbe()
        do {
            _ = try await run(initial: decision("work", tasks: [task("invalid", inputs: ["future:1"])])) { call in
                await probe.enter(call); await probe.leave()
                switch call.options.label {
                case "invalid": XCTFail("Unknown input must not dispatch"); return .stopped
                case "coordinator":
                    if await probe.count("coordinator") == 1 {
                        XCTAssertTrue(call.prompt.contains("already settled artifact"))
                        XCTAssertFalse(try XCTUnwrap(call.options.schema).validates(instance: decision("work", tasks: [task("x", inputs: ["future:1"])])))
                        return .value(decision("work", tasks: [task("fails"), task("survives")]))
                    }
                    XCTAssertTrue(call.prompt.contains("read unavailable"))
                    XCTAssertTrue(call.prompt.contains("\"status\":\"failed\""))
                    XCTAssertTrue(call.prompt.contains("PRESERVED-SIBLING"))
                    return .value(decision("blocked"))
                case "fails": throw WorkflowScriptRuntimeError.hostFailure("read unavailable")
                case "survives": return .value(.string("PRESERVED-SIBLING"))
                default: return .stopped
                }
            }
            XCTFail("Blocked task must not complete")
        } catch { XCTAssertTrue(String(describing: error).contains("Task incomplete")) }
        let count = await probe.count("invalid")
        XCTAssertEqual(count, 0)
    }

    func testRepeatedLocalReadsStopWithoutSpawningWorkers() async throws {
        let probe = CoordinationProbe()
        do {
            _ = try await run(initial: decision("work", tasks: [task("source")])) { call in
                await probe.enter(call); await probe.leave()
                if call.options.label == "source" { return .value(.string("Original")) }
                return .value(decision("read", reads: [.object(["id": .string("source:1"), "offset": .integer(0), "length": .integer(8)])]))
            }
            XCTFail("A no-progress reading loop must stop")
        } catch { XCTAssertTrue(String(describing: error).contains("without progress")) }
        let workers = await probe.count("source")
        XCTAssertEqual(workers, 1)
    }

    func testFrozenProgramAndSchemasPassTheSameAnalyzerAndSchemaEnforcement() throws {
        let analyzed = try DynamicWorkflowScriptAnalyzer().analyze(WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: CoordinatedWorkflow.source))
        XCTAssertEqual(analyzed.staticAgentCallSites, analyzed.explicitlyBudgetedAgentCallSites)
        XCTAssertGreaterThan(analyzed.staticParallelCallSites, 0)
        XCTAssertFalse(analyzed.hasUnawaitedHostReturnInCatch)
        XCTAssertEqual(CoordinatedWorkflow.decisionSchema.enforcement, .fullyEnforced)
        XCTAssertFalse(try CoordinatedWorkflow.decisionSchema.validates(instance: decision("work", tasks: [task("x", tools: 7)])))
    }

    func testStructuredRepairDiagnosticLocatesTheConstraintWithoutEchoingOutput() throws {
        let schema = try JSONSchemaDocument(root: .object(["type": .string("object"), "properties": .object([
            "content": .object(["type": .string("string"), "maxLength": .integer(5)])]), "required": .array([.string("content")])]))
        let diagnostic = ModelOutputInstructions.mismatch(.object(["content": .string("private-output-value")]), schema: schema)
        XCTAssertTrue(diagnostic.contains("$.content"))
        XCTAssertTrue(diagnostic.contains("maxLength"))
        XCTAssertFalse(diagnostic.contains("private-output-value"))
    }

    private func run(initial: JSONValue, tools: [String] = [],
                     agent: @escaping @Sendable (WorkflowAgentInvocation) async throws -> WorkflowAgentBridgeResult) async throws -> JSONValue {
        let analyzed = try DynamicWorkflowScriptAnalyzer().analyze(WorkflowScriptV1(scriptID: WorkflowScriptID(), version: 1, source: CoordinatedWorkflow.source))
        let args = try CanonicalJSON(.object(["goal": .string("Determine the total under supplied constraints."),
            "availableTools": .array(tools.map(JSONValue.string)), "runDate": .string("2026-10-23"), "plan": initial]))
        let result = try await JavaScriptCoreWorkflowRuntime().execute(analyzed, args: args, limits: .iPhoneDefault(), requirement: .init(),
            host: WorkflowScriptHost(agent: agent, webEvidence: {
                .object(["observations": .array([.object(["excerpt": .string("ORIGINAL-RECORDED-PAGE-FACT")])]), "sources": .array([])])
            }))
        return try JSONDecoder().decode(JSONValue.self, from: result.data)
    }
}

private actor CoordinationProbe {
    private var calls: [String: Int] = [:]
    private var active = 0
    var peak = 0
    var total: Int { calls.values.reduce(0, +) }
    func enter(_ call: WorkflowAgentInvocation) {
        calls[call.options.label ?? "", default: 0] += 1
        active += 1; peak = max(peak, active)
    }
    func leave() { active -= 1 }
    func count(_ label: String) -> Int { calls[label, default: 0] }
}
private func task(_ id: String, inputs: [String] = [], instruction: String? = nil, tools: Int64 = 0) -> JSONValue {
    .object(["id": .string(id), "instruction": .string(instruction ?? "Investigate " + id), "inputs": .array(inputs.map(JSONValue.string)), "maxToolCalls": .integer(tools)])
}
private func decision(_ action: String, tasks: [JSONValue] = [], reads: [JSONValue] = [], notes: String = "", answer: String = "") -> JSONValue {
    .object(["action": .string(action), "stage": .string("Work"), "reason": .string("Resolve the task"), "tasks": .array(tasks),
             "reads": .array(reads), "notes": .string(notes), "answer": .string(answer), "query": .string("")])
}
