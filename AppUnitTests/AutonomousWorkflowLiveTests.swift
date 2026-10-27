// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
@testable import mobileLLM
import LLMCore
import MobileLLMUI

// TEST-ID: AHT-DYNAMIC-LIVE-001
/// Opt-in real-model evaluation through the SAME production launch/authorization/executor path as chat.
/// No fixed model outputs, model-as-judge, UI navigation, or automatic calls in ordinary test runs.
final class AutonomousWorkflowLiveTests: XCTestCase, @unchecked Sendable {
    @MainActor func test11TransactionalMigrationWithDependentReview() async throws { try await evaluate(.migration) }
    @MainActor func test12MaintenancePlanAndOutageReplanning() async throws { try await evaluate(.rollout) }
    @MainActor func test13IncidentEvidenceAndSafeRecovery() async throws { try await evaluate(.incident) }
    @MainActor func test14SourceResearchAndAttribution() async throws { try await evaluate(.research) }
    @MainActor func test15InteractiveCorrectionAndMessaging() async throws { try await evaluate(.correction) }
    @MainActor func test16OriginalContextAndLaterCorrection() async throws { try await evaluate(.longContext) }
    @MainActor func test17WholeDeliverableAndWorkerLimits() async throws { try await evaluate(.formatting) }
    @MainActor func test18SimpleReservationGoalPlansAndReviewsWithoutAssignedRoles() async throws { try await evaluate(.reservation) }
    @MainActor func test19WebsiteRequestReportsMissingExecutionInsteadOfClaimingDelivery() async throws { try await evaluate(.website) }

    func testReservationOracleRejectsDoubleBookingAfterHoursAndWrongDeposits() throws {
        var rows: [[String: Any]] = [
            ["id":"A","status":"confirmed","tableID":"T1"], ["id":"B","status":"confirmed","tableID":"T2"],
            ["id":"C","status":"confirmed","tableID":"T3"], ["id":"D","status":"waitlist","tableID":NSNull()],
            ["id":"E","status":"confirmed","tableID":"T3"], ["id":"F","status":"rejected","tableID":NSNull()]
        ]
        XCTAssertTrue(try WorkflowLiveCase.reservation.verify(["allocations":rows,"depositEUR":90]).isEmpty)
        XCTAssertFalse(try WorkflowLiveCase.reservation.verify(["allocations":rows,"depositEUR":95]).isEmpty)
        rows[3] = ["id":"D","status":"confirmed","tableID":"T2"]
        XCTAssertFalse(try WorkflowLiveCase.reservation.verify(["allocations":rows,"depositEUR":90]).isEmpty)
        rows[3] = ["id":"D","status":"waitlist","tableID":NSNull()]
        rows[5] = ["id":"F","status":"confirmed","tableID":"T3"]
        XCTAssertFalse(try WorkflowLiveCase.reservation.verify(["allocations":rows,"depositEUR":90]).isEmpty)
    }

    @MainActor func test30ResumeRetainedPausedGoalWithItsOriginalBudget() async throws {
        executionTimeAllowance = 1_200
        guard let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_RESUME_ROOT"],
              let raw = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_RESUME_ID"], let id = WorkflowRunID(raw) else {
            throw XCTSkip("An explicit retained evaluation and goal ID are required")
        }
        let root = URL(fileURLWithPath: path)
        guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(component: "public-result.json"))) as? [String: Any],
              let name = record["case"] as? String, let task = WorkflowLiveCase(rawValue: name) else {
            throw LiveEvaluationError("The retained task definition is missing")
        }
        try await evaluate(task, heldOut: true, resume: (root, id))
    }

    @MainActor func test31AffectedFamiliesAfterRepair() async throws {
        executionTimeAllowance = 3_600
        for repetition in 1...3 { try await evaluate(.rollout, heldOut: true, repetition: repetition) }
        try await evaluate(.migration, heldOut: true)
    }

    @MainActor func test20FrozenSixFamilyQualification() async throws {
        guard ProcessInfo.processInfo.environment["MOBILELLM_LIVE_WORKFLOWS"] == "1" else { throw XCTSkip("Explicit real-model opt-in required") }
        executionTimeAllowance = 21_600
        let repetitions = Int(ProcessInfo.processInfo.environment["MOBILELLM_LIVE_REPETITIONS"] ?? "3") ?? 3
        guard (1...3).contains(repetitions) else { throw LiveEvaluationError("Qualification allows one to three repetitions") }
        let tasks: [WorkflowLiveCase] = [.research, .rollout, .incident, .migration, .correction, .longContext]
        if let path = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_OUTPUT_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let inputs: [[String: Any]] = tasks.map { task in
                ["case": task.rawValue, "variant": "held-out", "goal": task.goal(heldOut: true),
                 "history": task.history(heldOut: true), "amendment": task.amendment(heldOut: true) ?? "",
                 "amendmentTrigger": "First worker submission", "model": "deepseek-v4-flash", "reasoningEffort": "low",
                 "maximumModelRequests": 32, "maximumWorkerActivations": 12, "maximumToolCalls": 24,
                 "contextTokens": 32_768, "maximumOutputTokens": 24_576, "deadlineSeconds": 900]
            }
            try JSONSerialization.data(withJSONObject: inputs, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appending(component: "frozen-inputs.json"), options: .atomic)
        }
        for repetition in 1...repetitions {
            for task in tasks {
                do { try await evaluate(task, heldOut: true, repetition: repetition) }
                catch { XCTFail("\(task.rawValue) attempt \(repetition): \(error.localizedDescription)") }
            }
        }
    }

    func testPlanningOracleAcceptsAProofWithoutRelaxingCostOrFeasibility() throws {
        let resources = ["DB", "App", "DB", "App", "DB", "DB", "QA", "App"]
        func plan(_ starts: [Int], _ ends: [Int]) -> [String: Any] {
            ["makespan": ends.max()!, "tasks": Array("ABCDEFGH").enumerated().map { index, id in
                ["id": String(id), "start": starts[index], "end": ends[index], "resource": resources[index]] as [String: Any]
            }]
        }
        var result: [String: Any] = ["marker": "EVAL_ROLLOUT", "laborCostEUR": 1605, "changedStartIDs": ["G", "H"],
            "baseline": plan([0,0,3,5,5,9,9,12], [3,2,5,7,9,11,12,13]),
            "revised": plan([0,0,3,5,5,9,13,16], [3,2,5,7,9,11,16,17]),
            "lowerBounds": ["baseline": "Critical path A->C->E->G->H = 13, and the schedule attains it.",
                            "outage": "QA outage delays G until 13, so H ends no earlier than 17."]]
        XCTAssertTrue(try WorkflowLiveCase.rollout.verify(result, heldOut: true).isEmpty)
        result["laborCostEUR"] = 1606
        XCTAssertFalse(try WorkflowLiveCase.rollout.verify(result, heldOut: true).isEmpty)
        result["laborCostEUR"] = 1605
        result["revised"] = plan([0,0,3,5,5,9,12,16], [3,2,5,7,9,11,15,17])
        XCTAssertFalse(try WorkflowLiveCase.rollout.verify(result, heldOut: true).isEmpty)
    }

    func testSourceQuoteCheckHandlesRenderedEscapesWithoutAcceptingAnotherPageOrParaphrase() {
        let fact: [String: Any] = ["id": "F1", "url": "https://sqlite.org/isolation.html",
            "quote": "There can only be a single writer at a time to an SQLite database."]
        let body = "There can only be a single writer at a time to an SQLite database\\."
        XCTAssertTrue(WorkflowLiveEvidence.verify(facts: [fact], observations: [.init(url: "https://www.sqlite.org/isolation.html", text: body)]).isEmpty)
        XCTAssertFalse(WorkflowLiveEvidence.verify(facts: [fact], observations: [.init(url: "https://sqlite.org/wal.html", text: body)]).isEmpty)
        XCTAssertFalse(WorkflowLiveEvidence.verify(facts: [fact], observations: [.init(url: "https://sqlite.org/isolation.html", text: "SQLite serializes database writes.")]).isEmpty)
    }

    func testExecutableOracleRejectsDataLossNonatomicityAndWeakUniqueness() throws {
        let correct = """
        PRAGMA busy_timeout=5000;
        BEGIN IMMEDIATE;
        CREATE TEMP TABLE migration_map AS
        SELECT c.id AS old_id, COALESCE((SELECT d.id FROM contacts d
          WHERE c.email IS NOT NULL AND trim(c.email) <> '' AND d.tenant_id=c.tenant_id
          AND lower(trim(d.email))=lower(trim(c.email))
          ORDER BY d.updated_at DESC,d.id DESC LIMIT 1),c.id) AS winner FROM contacts c;
        UPDATE tickets SET contact_id=(SELECT winner FROM migration_map WHERE old_id=tickets.contact_id);
        DELETE FROM contacts WHERE id IN (SELECT old_id FROM migration_map WHERE old_id<>winner);
        UPDATE contacts SET email=nullif(lower(trim(email)),'');
        CREATE UNIQUE INDEX IF NOT EXISTS contact_identity ON contacts(tenant_id,lower(trim(email)))
          WHERE email IS NOT NULL AND trim(email)<>'';
        DROP TABLE migration_map;
        COMMIT;
        """
        func failures(_ sql:String) throws -> [String] {
            try WorkflowLiveCase.migration.verify(["marker":"EVAL_MIGRATION","sql":sql])
        }
        XCTAssertTrue(try failures(correct).isEmpty)
        XCTAssertFalse(try failures("BEGIN; COMMIT;").isEmpty)
        XCTAssertFalse(try failures(correct.replacingOccurrences(of:"BEGIN IMMEDIATE;",with:"").replacingOccurrences(of:"COMMIT;",with:"")).isEmpty)
        XCTAssertFalse(try failures(correct.replacingOccurrences(of:"ON contacts(tenant_id,lower(trim(email)))",with:"ON contacts(tenant_id,email)")).isEmpty)
        XCTAssertFalse(try failures(correct.replacingOccurrences(of:"d.updated_at DESC,d.id DESC",with:"d.updated_at ASC,d.id ASC")).isEmpty)
        XCTAssertFalse(try failures(correct.replacingOccurrences(of:"c.email IS NOT NULL AND trim(c.email) <> ''",with:"c.email IS NOT NULL")).isEmpty)
    }

    @MainActor
    private func evaluate(_ task: WorkflowLiveCase, heldOut: Bool = false, repetition: Int = 1,
                          resume: (root: URL, runID: WorkflowRunID)? = nil) async throws {
        guard ProcessInfo.processInfo.environment["MOBILELLM_LIVE_WORKFLOWS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for real online workflow evaluation")
        }
        if !heldOut { executionTimeAllowance = 1_200 }
        let config = try LiveConfiguration.load()
        let id = UUID()
        let outputBase = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_OUTPUT_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) }
            ?? FileManager.default.temporaryDirectory.appending(component:"mobilellm-live-evaluations")
        let root = outputBase.appending(component:task.rawValue+"-"+id.uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if let resume {
            try FileManager.default.copyItem(at: resume.root.appending(component: "agent"), to: root.appending(component: "agent"))
        }
        let serviceID = "live-evaluation"
        let model = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_MODEL"] ?? config.model
        let api = ResponsesAPIConfiguration(serviceID:serviceID,baseURL:config.baseURL,apiKey:config.apiKey)
        let assembly = try AgentRuntimeAssembly(
            engine: NoLocalEvaluationEngine(), downloadBase:root, conversationDirectory:root,
            models:[LLMCatalog.bonsai8b], snapshot:{ _,_,_,_ in nil },
            onlineConfiguration:{ _ in api }, deepSeekAPIKey: { _ in config.apiKey }
        )
        let runID = resume?.runID ?? WorkflowRunID()
        let started = Date()
        var answer = ""
        var failures:[String] = []
        let goal = task.goal(heldOut: heldOut)
        var amendmentID: MessageID?
        var beforeResume: WorkflowRunProjectionV1?
        do {
            let snapshot = makeSnapshot(goal:goal,model:model,serviceID:serviceID,task:task,heldOut:heldOut)
            if task.usesCalculator {
                let id = try AgentToolLogicalID(providerID:"builtin",name:"calculator").description
                guard try assembly.availableWorkflowTools(snapshot:snapshot).contains(id) else {
                    throw LiveEvaluationError("Calculator capability is missing before model dispatch")
                }
            }
            if resume != nil {
                beforeResume = try await assembly.dynamicWorkflowJournal.loadProjection(for: runID)
                guard beforeResume?.state == .paused else { throw LiveEvaluationError("Only an explicitly paused goal can resume") }
                try await assembly.dynamicWorkflows.resume(runID: runID)
            } else {
                _ = try await assembly.prepareCoordinatedWorkflow(snapshot:snapshot,runID:runID)
                _ = try await assembly.dynamicWorkflows.approveAndStart(runID:runID,reuseScope:nil)
            }
            let deadline = Date().addingTimeInterval(900)
            var lastCount = -1
            while Date() < deadline {
                if let state = try await assembly.dynamicWorkflowJournal.loadProjection(for:runID) {
                    if state.calls.count != lastCount {
                        print("[LiveWorkflow] \(task.rawValue): \(state.calls.count) child invocations, phase=\(state.currentPhase ?? "preparing")")
                        lastCount = state.calls.count
                    }
                    if amendmentID == nil, let update = task.amendment(heldOut: heldOut),
                       state.calls.contains(where: { $0.options.requestedAgentType != "workflow-supervisor" && state.submittedHandles[$0.callID] != nil }) {
                        let messageID = MessageID()
                        try await assembly.dynamicWorkflows.amendGoal(runID: runID, messageID: messageID, text: update)
                        amendmentID = messageID
                    }
                    if state.isTerminal || (state.state == .paused && state.taskGraph?.state != .active) { break }
                }
                try await Task.sleep(nanoseconds:500_000_000)
            }
            guard let projection = try await assembly.dynamicWorkflowJournal.loadProjection(for:runID),
                  projection.isTerminal || (projection.state == .paused && projection.taskGraph?.state != .active) else {
                try await assembly.dynamicWorkflows.stop(runID:runID)
                throw LiveEvaluationError("Runtime did not finish within the evaluation deadline")
            }
            if let output = try await assembly.dynamicWorkflows.resolvedOutput(runID:runID),
               case .string(let text) = try JSONDecoder().decode(JSONValue.self,from:output.data) { answer = text }
            if task == .website {
                let reason = projection.taskGraph?.reason?.lowercased() ?? ""
                if projection.state != .paused || projection.taskGraph?.state != .blocked || projection.output != nil
                    || !["execution", "filesystem", "workspace", "browser", "sandbox", "file", "运行", "执行", "文件", "浏览器", "沙盒", "工作区"].contains(where: reason.contains) {
                    failures.append("The website request did not retain an explicit execution-capability blocker")
                }
            } else if projection.state != .completed { failures.append("Workflow state \(projection.state): \(projection.failure ?? projection.taskGraph?.reason ?? "no final output")") }
            if let beforeResume {
                if projection.launch.budget != beforeResume.launch.budget || projection.preparationUsage != beforeResume.preparationUsage {
                    failures.append("Resume changed the original allowance or preparation accounting")
                }
                for (id, outcome) in beforeResume.outcomes where projection.outcomes[id] != outcome {
                    failures.append("Resume replaced a settled outcome instead of preserving it")
                }
                for (id, handle) in beforeResume.submittedHandles where projection.submittedHandles[id] != handle {
                    failures.append("Resume resubmitted an existing child with a different handle")
                }
            }
            if task == .website { /* Capability refusal is the expected outcome, not a completed website. */ }
            else if task == .formatting { failures += task.verifyText(answer) }
            else if let object = try? JSONSerialization.jsonObject(with:Data(answer.utf8)) as? [String:Any] {
                failures += try task.verify(object, heldOut: heldOut)
            } else { failures.append("Final answer is not the requested JSON artifact") }
            let trace = try await inspectTrace(assembly,projection:projection,requiresStages:task.requiresStages)
            failures += trace.failures
            if task == .reservation {
                if let graph = projection.taskGraph { do { try graph.requireAcceptedReviews() } catch { failures.append(error.localizedDescription) } }
                else { failures.append("No native review graph was recorded") }
            }
            if task == .formatting {
                let current = Set(projection.taskGraph?.tasks.compactMap(\.outputArtifactID) ?? [])
                let producers = Set(projection.taskGraph?.artifacts.filter { current.contains($0.id) }.map { $0.callID.description } ?? [])
                for call in trace.calls where producers.contains(call["callID"] as? String ?? "") {
                    if (call["outputWords"] as? Int ?? .max) >= 120 { failures.append("An accepted worker result exceeds the requested limit") }
                }
            }
            if task.usesCalculator, trace.completedCalculatorCalls == 0 { failures.append("Required Calculator operation was not executed") }
            if task == .correction {
                if amendmentID == nil { failures.append("The scripted human amendment was never accepted") }
                if trace.successfulToolNames["send_message", default: 0] == 0 { failures.append("No actual peer/coordinator message was sent") }
                if let id = amendmentID {
                    let session = try await assembly.repository.session(for: projection.launch.initiatingRunID)
                    if session?.inclusions.contains(where: { $0.messageID == id }) != true { failures.append("The coordinator never consumed the accepted amendment") }
                }
            }
            if task == .longContext, trace.originalContextReads == 0 { failures.append("No original source was retrieved after context reduction") }
            if task.usesWeb {
                if trace.successfulToolNames["web_search", default: 0] == 0 || trace.successfulToolNames["fetch_webpage", default: 0] < 2 {
                    failures.append("Research did not actually search and fetch both sources")
                }
                if let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
                   let facts = object["facts"] as? [[String: Any]] {
                    failures += WorkflowLiveEvidence.verify(facts: facts, observations: trace.webObservations)
                }
                try JSONEncoder().encode(trace.webObservations).write(to: root.appending(component: "retrieved-sources.json"), options: .atomic)
            }
            let summary = try await assembly.dynamicWorkflows.projection(runID:runID)
            let evidence:[String:Any] = [
                "case":task.rawValue,"variant":heldOut ? "held-out" : "development","repetition":repetition,"model":model,"goal":goal,"sourceSHA256":projection.launch.scriptReference.sourceDigest.rawValue,
                "codeRevision":ProcessInfo.processInfo.environment["MOBILELLM_LIVE_REVISION"] ?? "unrecorded",
                "state":projection.state.rawValue,"elapsedSeconds":Date().timeIntervalSince(started),
                "toolCalls":projection.usage.quantities[.toolInvocations],
                "inputTokens":summary?.usage.quantities[.inputTokens] ?? 0,"outputTokens":summary?.usage.quantities[.outputTokens] ?? 0,
                "successfulToolCalls":trace.completedToolCalls,"workerWaves":trace.waves,"dependentWorkers":trace.dependencies,"distinctWorkerIDs":trace.workerIDs.sorted(),
                "successfulCalculatorCalls":trace.completedCalculatorCalls,"successfulTools":trace.successfulToolNames,"originalContextReads":trace.originalContextReads,
                "calls":trace.calls,"checksPassed":failures.isEmpty,"failures":failures,"answer":answer,
                "goalState":projection.taskGraph?.state.rawValue ?? "unavailable", "blocker":projection.taskGraph?.reason ?? "",
                "reviews": try (projection.taskGraph?.artifacts ?? []).compactMap { artifact -> [String:Any]? in
                    guard let review = artifact.reviewResult else { return nil }
                    var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as! [String:Any]
                    record["artifactID"] = artifact.id; record["status"] = review.status.rawValue
                    return record
                },
                "intervention":resume != nil ? "Explicit resume of a retained paused goal, in a copy of its original journal and artifacts. No corrective prompt or answer supplied. Original allowance, preparation usage, settled outcomes and handles are checked unchanged."
                    : task.amendment(heldOut:heldOut).map { "Scripted human amendment after first worker submission: " + $0 } ?? "Original task only. No corrective external prompts or model-output fixtures."
            ]
            try publish(evidence,root:root)
        } catch {
            try? await assembly.dynamicWorkflows.stop(runID:runID)
            try publish(["case":task.rawValue,"variant":heldOut ? "held-out" : "development","repetition":repetition,"codeRevision":ProcessInfo.processInfo.environment["MOBILELLM_LIVE_REVISION"] ?? "unrecorded","model":model,"goal":goal,"checksPassed":false,
                         "failures":[error.localizedDescription],"answer":answer],root:root)
            await assembly.repository.close()
            await assembly.dynamicWorkflowJournal.close()
            throw error
        }
        await assembly.repository.close()
        await assembly.dynamicWorkflowJournal.close()
        XCTAssertTrue(failures.isEmpty,failures.joined(separator:"\n"))
    }

    private func publish(_ evidence:[String:Any],root:URL) throws {
        let data = try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let url = root.appending(component:"public-result.json")
        try data.write(to:url,options:.atomic)
        let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.json")
        attachment.name = "Autonomous workflow evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[LiveWorkflow] evidence: \(url.path)")
    }

    private struct Trace {
        var failures:[String] = []
        var waves = 0
        var dependencies = 0
        var completedToolCalls = 0
        var completedCalculatorCalls = 0
        var successfulToolNames: [String: Int] = [:]
        var originalContextReads = 0
        var webObservations: [WorkflowLiveEvidence] = []
        var workerIDs = Set<String>()
        var calls:[[String:Any]] = []
    }

    @MainActor
    private func inspectTrace(_ assembly:AgentRuntimeAssembly,projection:WorkflowRunProjectionV1,requiresStages:Bool = true) async throws -> Trace {
        var result = Trace()
        let calculatorID = try AgentToolLogicalID(providerID: "builtin", name: "calculator").description
        let spawner = DurableSubagentSpawner(executor:assembly.executor,repository:assembly.repository)
        var events:[WorkflowRunEventV1] = []
        var cursor:UInt64 = 0
        while true {
            let page = try await assembly.dynamicWorkflowJournal.readEvents(runID:projection.runID,after:cursor,limit:256)
            events += page.events
            guard !page.reachedEnd, let last = page.events.last else { break }
            cursor = last.sequence
        }
        var submitted:[WorkflowAgentCallID:UInt64] = [:]
        var settled:[WorkflowAgentCallID:UInt64] = [:]
        for event in events {
            switch event.kind {
            case .agentChildSubmitted(let id,_): submitted[id] = event.sequence
            case .agentCallSettled(let id,_): settled[id] = event.sequence
            default: break
            }
        }
        var completedDepths: [Int] = []
        var artifactCount = 0
        var artifacts:[String:(text:String,settled:UInt64,depth:Int)] = [:]
        for call in projection.calls {
            let supervisor = call.options.requestedAgentType == "workflow-supervisor"
            guard let handle = projection.submittedHandles[call.callID],
                  let snapshot = try await assembly.repository.loadRunSnapshot(for:call.childRunID),
                  let request = snapshot.facts.submission?.request.payload else { continue }
            if request.modelPolicy.localOnly || request.modelPolicy.allowedSelections.contains(where: { $0.providerID.description != ResponsesAPIModelProvider.providerID }) {
                result.failures.append("A model invocation did not use the real online provider")
            }
            let history = try ExecutionHistory(events:snapshot.events,projection:snapshot.facts.projection)
            result.completedToolCalls += history.toolOutcomes.values.filter {
                if case .completed = $0.1 { return true }; return false
            }.count
            result.completedCalculatorCalls += history.toolOutcomes.filter { id, value in
                guard case .completed = value.1 else { return false }
                return history.toolIntents[id]?.1.plan.subjectID == calculatorID
            }.count
            for (invocation, pair) in history.toolOutcomes {
                guard case .completed = pair.1, let plan = history.toolIntents[invocation]?.1.plan else { continue }
                let names = ["calculator", "web_search", "fetch_webpage", "send_message", "read_context", "read_artifact", "read_skill", "list_skills", "list_agents"]
                let name = names.first { plan.subjectID == (try? AgentToolLogicalID(providerID: ["send_message","read_context","read_artifact","read_skill","list_skills","list_agents"].contains($0) ? "agent" : "builtin", name: $0).description) } ?? plan.subjectID
                result.successfulToolNames[name, default: 0] += 1
                if name == "read_context", let args = plan.canonicalArguments,
                   let object = try? JSONSerialization.jsonObject(with: args.value.data) as? [String: Any],
                   let id = object["id"] as? String, id.hasPrefix("history:") { result.originalContextReads += 1 }
            }
            for observation in try await spawner.webObservations(handle)
                where observation.status == "completed" && (observation.toolID.name == "fetch_webpage" || observation.sourceKind == .searchContent) {
                if let url = observation.sourceURL ?? observation.requestedURL {
                    result.webObservations.append(WorkflowLiveEvidence(url: url, text: observation.text))
                }
            }
            let terminal = try await spawner.terminalResult(handle)
            let output:String?
            let completed:Bool
            if case .completed(let answer, _) = terminal?.outcome {
                output = supervisor ? answer.text : try await assembly.dynamicWorkflows.result(runID: projection.runID, callID: call.callID)
                completed = true
            }
            else { output = nil; completed = false }
            var item:[String:Any] = ["ordinal":call.ordinal,"callID":call.callID.description,"label":call.options.label ?? "", "role":request.role,
                "submittedSequence":submitted[call.callID] ?? 0,"settledSequence":settled[call.callID] ?? 0,
                "completed":completed]
            if let output { item["outputWords"] = WorkflowLiveCase.words(output) }
            if let failure = projection.taskGraph?.artifacts.first(where: { $0.callID == call.callID })?.validationFailure {
                item["outputValidationFailure"] = failure
            }
            if !supervisor {
                artifactCount += 1
                let label = call.options.label ?? "unnamed"
                if completed { result.workerIDs.insert(call.options.sessionKey ?? label) }
                let delimiter = request.instruction.contains("\n<original-dependency-artifacts>\n")
                    ? "original-dependency-artifacts" : "input-artifacts"
                let marker = "\n<" + delimiter + ">\n"
                var inputIDs:[String] = []
                if let start = request.instruction.range(of:marker),
                   let end = request.instruction.range(of:"\n</" + delimiter + ">",range:start.upperBound..<request.instruction.endIndex),
                   let inputs = try JSONSerialization.jsonObject(with:Data(request.instruction[start.upperBound..<end.lowerBound].utf8)) as? [[String:Any]] {
                    for input in inputs {
                        guard let id = input["id"] as? String, let origin = artifacts[id],
                              let offset = input["offset"] as? Int, let next = input["nextOffset"] as? Int,
                              let content = input["content"] as? String,
                              offset >= 0, next >= offset, next <= (origin.text as NSString).length,
                              origin.settled < (submitted[call.callID] ?? 0),
                              let range = Range(NSRange(location:offset,length:next-offset), in:origin.text),
                              Data(origin.text[range].utf8) == Data(content.utf8)
                        else { result.failures.append("A dependent input was not an exact prior settled artifact"); continue }
                        inputIDs.append(id)
                    }
                }
                if completed && !inputIDs.isEmpty { result.dependencies += 1 }
                if let descriptor = call.options.task, Set(descriptor.inputArtifactIDs) != Set(inputIDs) {
                    result.failures.append("Recorded task inputs do not match the original excerpts actually handed to its model")
                }
                let depth = (inputIDs.compactMap { artifacts[$0]?.depth }.max() ?? -1) + 1
                if completed { completedDepths.append(depth) }
                item["inputArtifactIDs"] = inputIDs
                item["dependencyDepth"] = depth
                if let output, let end = settled[call.callID] {
                    artifacts[call.options.task?.outputArtifactID ?? label+":"+String(artifactCount)] = (output,end,depth)
                }
            }
            result.calls.append(item)
        }
        result.waves = (completedDepths.max() ?? -1) + 1
        if requiresStages && (result.waves < 3 || result.dependencies < 2 || result.workerIDs.count < 3) {
            result.failures.append("Requested staged collaboration missing: \(result.waves) dependency stages, \(result.dependencies) dependent workers, \(result.workerIDs.count) distinct agent identities")
        }
        return result
    }

    private func makeSnapshot(goal:String,model:String,serviceID:String,task:WorkflowLiveCase,heldOut:Bool) -> AgentRunRequestSnapshot {
        let local = LLMCatalog.bonsai8b
        let messageID = UUID()
        return AgentRunRequestSnapshot(
            conversationID:UUID(),userTurnID:messageID,text:goal,imageRefs:[],
            messages:task.history(heldOut:heldOut).map { Message(role:.user,answer:$0) } + [Message(id:messageID,role:.user,answer:goal)],systemPrompt:"You are a capable assistant. Complete the user's task with accurate evidence and explicit uncertainty.",
            memoryFacts:[],activeSkill:nil,model:local,variant:local.defaultVariantValue,weightsDirectory:FileManager.default.temporaryDirectory,
            thinkingEnabled:false,contextLength:8192,maxTokens:8192,temperature:0.2,topP:0.9,topK:40,repetitionPenalty:1,
            toolsEnabled:task.usesCalculator || task.usesWeb,localToolNames:task.usesCalculator ? ["calculator"] : task.usesWeb ? ["web_search","fetch_webpage"] : [],memorySeamAvailable:false,eventSeamAvailable:false,
            locationSeamAvailable:false,mcpToolDescriptors:[],webSearchDestinations:task.usesWeb ? [try! AppDeepSeekWebToolAdapter.destination()] : [],toolPolicy:nil,
            onlineModelEnabled:true,onlineModelID:model,onlineServiceID:serviceID,onlineConfigurationID:"live-frozen-config",
            onlineReasoningEnabled:true,onlineContextLength:32768,onlineOutputBudgetAuto:true,onlineMaximumOutputTokens:nil,
            approvalMode:.safePreset,onlineReasoningEffort:.low,deepSeekWebServiceID:task.usesWeb ? serviceID : nil,availableSkills:Skill.builtIns)
    }
}

struct LiveConfiguration:Decodable,Sendable {
    let apiKey:String
    let baseURL:String
    let model:String
    static func load() throws -> Self {
        #if os(macOS)
        let fallback:URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mobilellm/openai.json")
        #else
        let fallback:URL? = nil
        #endif
        let file = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_CONFIG_PATH"].map { URL(fileURLWithPath:$0) }
            ?? Bundle.main.url(forResource:"openai-config",withExtension:"json")
            ?? fallback
        guard let file, let bytes = try? Data(contentsOf:file), let value = try? JSONDecoder().decode(Self.self,from:bytes),
              !value.apiKey.isEmpty, !value.baseURL.isEmpty, !value.model.isEmpty else {
            throw LiveEvaluationError("A valid private online service configuration is required; no fallback model is used")
        }
        return value
    }
}
struct LiveEvaluationError:Error,LocalizedError { let message:String; init(_ message:String){self.message=message};var errorDescription:String?{message} }
actor NoLocalEvaluationEngine:LLMEngine {
    func load(model:LLMModel,variant:LLMVariant,weightsDir:URL,progress:@escaping @Sendable(Double)->Void) async throws { throw LiveEvaluationError("Unexpected local-model path in online evaluation") }
    func unload() async {}
    nonisolated func generate(messages:[ChatTurn],params:Sampling) -> AsyncThrowingStream<EngineDelta,Error> {
        AsyncThrowingStream { $0.finish(throwing:LiveEvaluationError("No synthetic model outputs are available")) }
    }
}
