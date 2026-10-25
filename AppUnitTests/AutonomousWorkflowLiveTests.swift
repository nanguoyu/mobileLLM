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
    private func evaluate(_ task: WorkflowLiveCase) async throws {
        guard ProcessInfo.processInfo.environment["MOBILELLM_LIVE_WORKFLOWS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for real online workflow evaluation")
        }
        executionTimeAllowance = 1_200
        let config = try LiveConfiguration.load()
        let id = UUID()
        let outputBase = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_OUTPUT_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) }
            ?? FileManager.default.temporaryDirectory.appending(component:"mobilellm-live-evaluations")
        let root = outputBase.appending(component:task.rawValue+"-"+id.uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let serviceID = "live-evaluation"
        let model = ProcessInfo.processInfo.environment["MOBILELLM_LIVE_MODEL"] ?? config.model
        let api = ResponsesAPIConfiguration(serviceID:serviceID,baseURL:config.baseURL,apiKey:config.apiKey)
        let assembly = try AgentRuntimeAssembly(
            engine: NoLocalEvaluationEngine(), downloadBase:root, conversationDirectory:root,
            models:[LLMCatalog.bonsai8b], snapshot:{ _,_,_,_ in nil },
            onlineConfiguration:{ _ in api }
        )
        let runID = WorkflowRunID()
        let started = Date()
        var answer = ""
        var failures:[String] = []
        do {
            let snapshot = makeSnapshot(goal:task.goal,model:model,serviceID:serviceID,tools:task.usesCalculator)
            if task.usesCalculator {
                let id = try AgentToolLogicalID(providerID:"builtin",name:"calculator").description
                guard try assembly.availableWorkflowTools(snapshot:snapshot).contains(id) else {
                    throw LiveEvaluationError("Calculator capability is missing before model dispatch")
                }
            }
            _ = try await assembly.prepareCoordinatedWorkflow(snapshot:snapshot,runID:runID)
            _ = try await assembly.dynamicWorkflows.approveAndStart(runID:runID,reuseScope:nil)
            let deadline = Date().addingTimeInterval(900)
            var lastCount = -1
            while Date() < deadline {
                if let state = try await assembly.dynamicWorkflowJournal.loadProjection(for:runID) {
                    if state.calls.count != lastCount {
                        print("[LiveWorkflow] \(task.rawValue): \(state.calls.count) child invocations, phase=\(state.currentPhase ?? "preparing")")
                        lastCount = state.calls.count
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
            if projection.state != .completed { failures.append("Workflow state \(projection.state): \(projection.failure ?? projection.taskGraph?.reason ?? "no final output")") }
            if let object = try? JSONSerialization.jsonObject(with:Data(answer.utf8)) as? [String:Any] {
                failures += try task.verify(object)
            } else { failures.append("Final answer is not the requested JSON artifact") }
            let trace = try await inspectTrace(assembly,projection:projection)
            failures += trace.failures
            if task.usesCalculator, trace.completedCalculatorCalls == 0 { failures.append("Required Calculator operation was not executed") }
            let summary = try await assembly.dynamicWorkflows.projection(runID:runID)
            let evidence:[String:Any] = [
                "case":task.rawValue,"model":model,"goal":task.goal,"sourceSHA256":projection.launch.scriptReference.sourceDigest.rawValue,
                "codeRevision":ProcessInfo.processInfo.environment["MOBILELLM_LIVE_REVISION"] ?? "unrecorded",
                "state":projection.state.rawValue,"elapsedSeconds":Date().timeIntervalSince(started),
                "toolCalls":projection.usage.quantities[.toolInvocations],
                "inputTokens":summary?.usage.quantities[.inputTokens] ?? 0,"outputTokens":summary?.usage.quantities[.outputTokens] ?? 0,
                "successfulToolCalls":trace.completedToolCalls,"workerWaves":trace.waves,"dependentWorkers":trace.dependencies,"distinctWorkerIDs":trace.workerIDs.sorted(),
                "successfulCalculatorCalls":trace.completedCalculatorCalls,
                "calls":trace.calls,"checksPassed":failures.isEmpty,"failures":failures,"answer":answer,
                "intervention":"Original task only. No corrective external prompts or model-output fixtures."
            ]
            try publish(evidence,root:root)
        } catch {
            try? await assembly.dynamicWorkflows.stop(runID:runID)
            try publish(["case":task.rawValue,"model":model,"goal":task.goal,"checksPassed":false,
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
        var workerIDs = Set<String>()
        var calls:[[String:Any]] = []
    }

    @MainActor
    private func inspectTrace(_ assembly:AgentRuntimeAssembly,projection:WorkflowRunProjectionV1) async throws -> Trace {
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
            let terminal = try await spawner.terminalResult(handle)
            let output:String?
            let completed:Bool
            if case .completed(let answer, _) = terminal?.outcome { output = answer.text; completed = true }
            else { output = nil; completed = false }
            var item:[String:Any] = ["ordinal":call.ordinal,"label":call.options.label ?? "", "role":request.role,
                "submittedSequence":submitted[call.callID] ?? 0,"settledSequence":settled[call.callID] ?? 0,
                "completed":completed]
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
        if result.waves < 3 || result.dependencies < 2 || result.workerIDs.count < 3 {
            result.failures.append("Requested staged collaboration missing: \(result.waves) dependency stages, \(result.dependencies) dependent workers, \(result.workerIDs.count) distinct agent identities")
        }
        return result
    }

    private func makeSnapshot(goal:String,model:String,serviceID:String,tools:Bool) -> AgentRunRequestSnapshot {
        let local = LLMCatalog.bonsai8b
        let messageID = UUID()
        return AgentRunRequestSnapshot(
            conversationID:UUID(),userTurnID:messageID,text:goal,imageRefs:[],
            messages:[Message(id:messageID,role:.user,answer:goal)],systemPrompt:"You are a capable assistant. Complete the user's task with accurate evidence and explicit uncertainty.",
            memoryFacts:[],activeSkill:nil,model:local,variant:local.defaultVariantValue,weightsDirectory:FileManager.default.temporaryDirectory,
            thinkingEnabled:false,contextLength:8192,maxTokens:8192,temperature:0.2,topP:0.9,topK:40,repetitionPenalty:1,
            toolsEnabled:tools,localToolNames:tools ? ["calculator"] : [],memorySeamAvailable:false,eventSeamAvailable:false,
            locationSeamAvailable:false,mcpToolDescriptors:[],webSearchDestinations:[],toolPolicy:nil,
            onlineModelEnabled:true,onlineModelID:model,onlineServiceID:serviceID,onlineConfigurationID:"live-frozen-config",
            onlineReasoningEnabled:true,onlineContextLength:32768,onlineOutputBudgetAuto:true,onlineMaximumOutputTokens:nil,
            approvalMode:.safePreset,onlineReasoningEffort:nil,deepSeekWebServiceID:nil,availableSkills:Skill.builtIns)
    }
}

private struct LiveConfiguration:Decodable,Sendable {
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
private struct LiveEvaluationError:Error,LocalizedError { let message:String; init(_ message:String){self.message=message};var errorDescription:String?{message} }
private actor NoLocalEvaluationEngine:LLMEngine {
    func load(model:LLMModel,variant:LLMVariant,weightsDir:URL,progress:@escaping @Sendable(Double)->Void) async throws { throw LiveEvaluationError("Unexpected local-model path in online evaluation") }
    func unload() async {}
    nonisolated func generate(messages:[ChatTurn],params:Sampling) -> AsyncThrowingStream<EngineDelta,Error> {
        AsyncThrowingStream { $0.finish(throwing:LiveEvaluationError("No synthetic model outputs are available")) }
    }
}
