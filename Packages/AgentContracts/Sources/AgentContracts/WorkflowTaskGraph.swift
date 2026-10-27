// SPDX-License-Identifier: MIT

import Foundation

public enum WorkflowGoalState: String, Codable, Sendable {
    case active, paused, blocked, budgetExhausted, cancelled, completed
}

public enum WorkflowTaskState: String, Codable, Sendable {
    case pending, running, completed, failed, needsReview
}

public struct WorkflowGoalAmendment: Hashable, Codable, Sendable {
    public let id: MessageID
    public let text: String
    public let acceptedAt: AgentTimestamp
    /// Runtime-chosen recipients present at acceptance. Missing seed runs are delivered after spawn.
    public let targetRunIDs: [AgentRunID]?

    public init(id: MessageID, text: String, acceptedAt: AgentTimestamp, targetRunIDs: [AgentRunID]? = nil) {
        self.id = id; self.text = text; self.acceptedAt = acceptedAt; self.targetRunIDs = targetRunIDs
    }
}

public struct WorkflowTaskUpdate: Hashable, Codable, Sendable {
    public let id: String
    public let expectedRevision: UInt64
    public let agent: String
    public let instruction: String
    public let dependencies: [String]
    public let required: Bool
    public let maximumToolCalls: UInt64
    public let model: String?
    public let inputRanges: [WorkflowTaskInputRange]?
    public let artifactInputs: [String]?
    public let profile: WorkflowAgentProfileV1?
    public let review: WorkflowTaskReview?

    public init(id: String, expectedRevision: UInt64, agent: String, instruction: String,
                dependencies: [String] = [], required: Bool = true, maximumToolCalls: UInt64 = 0, model: String? = nil,
                inputRanges: [WorkflowTaskInputRange]? = nil, artifactInputs: [String]? = nil,
                profile: WorkflowAgentProfileV1? = nil, review: WorkflowTaskReview? = nil) {
        self.id = id; self.expectedRevision = expectedRevision; self.agent = agent
        self.instruction = instruction; self.dependencies = dependencies; self.required = required
        self.maximumToolCalls = maximumToolCalls; self.model = model
        self.inputRanges = inputRanges
        self.artifactInputs = artifactInputs
        self.profile = profile
        self.review = review
    }
}

public struct WorkflowTaskInputRange: Hashable, Codable, Sendable {
    public let taskID: String
    public let offset: Int
    public let length: Int
}

public struct WorkflowTaskNode: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public var revision: UInt64
    public var agent: String
    public var instruction: String
    public var dependencies: [String]
    public let required: Bool
    public var maximumToolCalls: UInt64
    public var model: String?
    public var state: WorkflowTaskState
    public var activeCallID: WorkflowAgentCallID?
    public var inputArtifactIDs: [String]
    public var outputArtifactID: String?
    public var failure: String?
    public var inputRanges: [WorkflowTaskInputRange]?
    /// Exact historical versions, such as a review of this task's previous output. These are
    /// immutable data edges, not a cycle between the current task revisions.
    public var artifactInputs: [String]?
    public var profile: WorkflowAgentProfileV1?
    public var outputCorrectionAmendmentCount: Int? = nil
    public var review: WorkflowTaskReview? = nil
    public var reviewCorrectionBudget: WorkflowReviewCorrectionBudget? = nil
}

public struct WorkflowTaskArtifact: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let taskID: String
    public let taskRevision: UInt64
    public let callID: WorkflowAgentCallID
    public let inputArtifactIDs: [String]
    public let value: WorkflowValueReferenceV1
    public var validationFailure: String? = nil
    public var reviewResult: WorkflowTaskReviewResult? = nil
}

public enum WorkflowTaskGraphError: String, Error, Sendable, LocalizedError {
    case invalid = "Invalid task graph."
    case stale = "The task changed; use its current revision."
    case busy = "The task or its assigned agent is already running."
    case cycle = "Task dependencies must not contain a cycle."
    case unavailableInput = "A required dependency has no current completed result."
    case ownership = "This call does not own the task."
    case incomplete = "Required tasks or running agents remain unfinished."
    case terminal = "The goal has already ended."
    case invalidReview = "The review must report every declared criterion exactly once with an explanation."
    case unreviewed = "Required deliverables need a passing independent review of their current versions and human amendments."
    public var errorDescription: String? { rawValue }
}

/// Versioned task and goal facts. Immutable outputs remain available after reassignment or reopening.
public struct WorkflowTaskGraph: Hashable, Codable, Sendable {
    public let objective: String
    public private(set) var revision: UInt64 = 1
    public private(set) var amendments: [WorkflowGoalAmendment] = []
    public private(set) var state: WorkflowGoalState = .active
    public private(set) var reason: String?
    public private(set) var tasks: [WorkflowTaskNode] = []
    public private(set) var artifacts: [WorkflowTaskArtifact] = []

    public init(objective: String) throws {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              objective.utf8.count <= 262_144 else { throw WorkflowTaskGraphError.invalid }
        self.objective = objective
    }

    public var readyTasks: [WorkflowTaskNode] {
        tasks.filter { task in
            (task.state == .pending || task.state == .needsReview)
                && task.dependencies.allSatisfy { id in tasks.contains { $0.id == id && $0.state == .completed } }
                && !tasks.contains { $0.state == .running && $0.agent == task.agent }
        }
    }

    public var unfinishedRequiredTasks: [WorkflowTaskNode] {
        tasks.filter { $0.required && $0.state != .completed }
    }

    public mutating func update(_ changes: [WorkflowTaskUpdate], expectedRevision: UInt64) throws {
        guard state == .active else { throw WorkflowTaskGraphError.terminal }
        guard revision == expectedRevision else { throw WorkflowTaskGraphError.stale }
        guard !changes.isEmpty, changes.count <= 32, Set(changes.map(\.id)).count == changes.count else {
            throw WorkflowTaskGraphError.invalid
        }
        var next = self
        var reopened: Set<String> = []
        for change in changes {
            guard AgentWireValidation.isNonblankControlFree(change.id, maximumLength: 48),
                  AgentWireValidation.isNonblankControlFree(change.agent, maximumLength: 48),
                  change.agent != "coordinator",
                  !change.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.instruction.utf8.count <= 16_384, change.maximumToolCalls <= 6,
                  change.dependencies.count <= 32, Set(change.dependencies).count == change.dependencies.count,
                  (change.inputRanges?.count ?? 0) <= 8,
                  change.inputRanges?.allSatisfy({ (change.dependencies.contains($0.taskID) || (change.artifactInputs ?? []).contains($0.taskID))
                    && $0.offset >= 0 && (1...12_000).contains($0.length) }) ?? true,
                  (change.artifactInputs?.count ?? 0) <= 32,
                  Set(change.artifactInputs ?? []).count == (change.artifactInputs?.count ?? 0),
                  change.artifactInputs?.allSatisfy({ id in artifacts.contains { $0.id == id } }) ?? true,
                  change.model.map({ AgentWireValidation.isNonblankControlFree($0, maximumLength: 256) }) ?? true
            else { throw WorkflowTaskGraphError.invalid }
            try change.review?.validate()
            if let index = next.tasks.firstIndex(where: { $0.id == change.id }) {
                let old = next.tasks[index]
                guard old.revision == change.expectedRevision else { throw WorkflowTaskGraphError.stale }
                guard old.state != .running else { throw WorkflowTaskGraphError.busy }
                guard old.required == change.required else { throw WorkflowTaskGraphError.invalid }
                guard old.review == change.review else { throw WorkflowTaskGraphError.invalid }
                next.tasks[index] = WorkflowTaskNode(id: old.id, revision: old.revision + 1,
                    agent: change.agent, instruction: change.instruction, dependencies: change.dependencies,
                    required: old.required, maximumToolCalls: change.maximumToolCalls, model: change.model,
                    state: .pending, inputArtifactIDs: [], inputRanges: change.inputRanges, artifactInputs: change.artifactInputs, profile: change.profile)
                next.tasks[index].outputCorrectionAmendmentCount = old.outputCorrectionAmendmentCount
                next.tasks[index].review = old.review
                next.tasks[index].reviewCorrectionBudget = old.reviewCorrectionBudget
                reopened.insert(old.id)
            } else {
                guard change.expectedRevision == 0 else { throw WorkflowTaskGraphError.stale }
                next.tasks.append(WorkflowTaskNode(id: change.id, revision: 1, agent: change.agent,
                    instruction: change.instruction, dependencies: change.dependencies, required: change.required,
                    maximumToolCalls: change.maximumToolCalls, model: change.model, state: .pending, inputArtifactIDs: [],
                    inputRanges: change.inputRanges, artifactInputs: change.artifactInputs, profile: change.profile))
                next.tasks[next.tasks.count - 1].review = change.review
            }
        }
        try next.validate()
        // Propagate invalidation even through running consumers. Their exact historical input
        // remains recorded; settlement will mark them for review if that input is no longer current.
        var affected = reopened
        for _ in 0..<next.tasks.count {
            let children = next.tasks.filter { !$0.dependencies.allSatisfy { !affected.contains($0) } }.map(\.id)
            let previous = affected
            affected.formUnion(children)
            if previous == affected { break }
        }
        for index in next.tasks.indices where affected.contains(next.tasks[index].id) && !reopened.contains(next.tasks[index].id) {
            if next.tasks[index].state != .running {
                next.tasks[index].state = .needsReview
                next.tasks[index].revision += 1
                next.tasks[index].outputArtifactID = nil
            }
        }
        next.revision += 1
        self = next
    }

    public mutating func claim(taskID: String, expectedRevision: UInt64, call: WorkflowAgentCallV1) throws {
        guard state == .active else { throw WorkflowTaskGraphError.terminal }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].revision == expectedRevision else {
            throw WorkflowTaskGraphError.stale
        }
        let task = tasks[index]
        if let count = call.options.task?.goalAmendmentCount, count != amendments.count { throw WorkflowTaskGraphError.stale }
        guard task.state != .running, !tasks.contains(where: { $0.state == .running && $0.agent == task.agent }) else {
            throw WorkflowTaskGraphError.busy
        }
        guard readyTasks.contains(where: { $0.id == taskID }), let descriptor = call.options.task,
              descriptor.taskID == taskID, descriptor.instruction == task.instruction,
              call.options.sessionKey == task.agent, call.options.profile == task.profile else { throw WorkflowTaskGraphError.ownership }
        if task.profile != nil {
            guard call.options.maximumToolCalls == task.maximumToolCalls, call.options.requestedModel == task.model else {
                throw WorkflowTaskGraphError.ownership
            }
        }
        let dependencyInputs = try task.dependencies.map { id -> String in
            guard let source = tasks.first(where: { $0.id == id }), source.state == .completed,
                  let artifact = source.outputArtifactID else { throw WorkflowTaskGraphError.unavailableInput }
            return artifact
        }
        let inputs = Self.unique(dependencyInputs + (task.artifactInputs ?? []))
        guard descriptor.inputArtifactIDs == inputs,
              !artifacts.contains(where: { $0.id == descriptor.outputArtifactID }) else { throw WorkflowTaskGraphError.unavailableInput }
        tasks[index].state = .running
        tasks[index].activeCallID = call.callID
        tasks[index].inputArtifactIDs = inputs
        tasks[index].outputArtifactID = nil
        tasks[index].failure = nil
        tasks[index].revision += 1
        revision += 1
    }

    public mutating func settle(call: WorkflowAgentCallV1, outcome: WorkflowAgentOutcomeV1) throws {
        guard let index = tasks.firstIndex(where: { $0.activeCallID == call.callID && $0.state == .running }),
              let descriptor = call.options.task else { throw WorkflowTaskGraphError.ownership }
        switch outcome {
        case .completed(let value, _):
            guard artifacts.count < 128, !artifacts.contains(where: { $0.id == descriptor.outputArtifactID }) else {
                throw WorkflowTaskGraphError.invalid
            }
            artifacts.append(WorkflowTaskArtifact(id: descriptor.outputArtifactID, taskID: tasks[index].id,
                taskRevision: tasks[index].revision, callID: call.callID, inputArtifactIDs: tasks[index].inputArtifactIDs, value: value))
            let currentDependencies = tasks[index].dependencies.compactMap { id in
                tasks.first(where: { $0.id == id && $0.state == .completed })?.outputArtifactID
            }
            let currentInputs = Self.unique(currentDependencies + (tasks[index].artifactInputs ?? []))
            let current = currentInputs == tasks[index].inputArtifactIDs
            tasks[index].state = current ? .completed : .needsReview
            tasks[index].outputArtifactID = current ? descriptor.outputArtifactID : nil
        case .failed(let failure, _): tasks[index].state = .failed; tasks[index].failure = failure.safeMessage
        case .unavailable(let reason, _): tasks[index].state = .failed; tasks[index].failure = reason
        case .stopped: tasks[index].state = .failed; tasks[index].failure = "The assigned agent was stopped."
        }
        tasks[index].activeCallID = nil
        tasks[index].revision += 1
        revision += 1
    }

    /// Keeps the rejected original, then permits one bounded correction per human requirement
    /// revision. A second invalid output remains failed; neither the model nor retry widens limits.
    public mutating func rejectOutput(callID: WorkflowAgentCallID, reason: String) {
        guard let artifactIndex = artifacts.firstIndex(where: { $0.callID == callID }) else { return }
        artifacts[artifactIndex].validationFailure = reason
        let artifact = artifacts[artifactIndex]
        guard let index = tasks.firstIndex(where: { $0.id == artifact.taskID && $0.outputArtifactID == artifact.id }) else { return }
        let old = tasks[index]
        if old.outputCorrectionAmendmentCount != amendments.count {
            do {
                try update([WorkflowTaskUpdate(id: old.id, expectedRevision: old.revision, agent: old.agent,
                    instruction: old.instruction + "\n\n[Required output correction]\n" + reason,
                    dependencies: old.dependencies, required: old.required, maximumToolCalls: old.maximumToolCalls,
                    model: old.model, inputRanges: old.inputRanges,
                    artifactInputs: Self.unique((old.artifactInputs ?? []) + [artifact.id]), profile: old.profile,
                    review: old.review)], expectedRevision: revision)
                tasks[index].outputCorrectionAmendmentCount = amendments.count
                tasks[index].failure = reason
                return
            } catch { /* Failed correction admission must not make the rejected output acceptable. */ }
        }
        tasks[index].state = .failed; tasks[index].outputArtifactID = nil
        tasks[index].failure = reason; tasks[index].revision += 1; revision += 1
    }

    public mutating func setGoalState(_ next: WorkflowGoalState, reason: String?) throws {
        guard state != .completed && state != .cancelled else { throw WorkflowTaskGraphError.terminal }
        if next == .completed {
            guard unfinishedRequiredTasks.isEmpty, !tasks.contains(where: { $0.state == .running }) else {
                throw WorkflowTaskGraphError.incomplete
            }
        }
        guard reason.map({ $0.utf8.count <= 16_384 }) ?? true else { throw WorkflowTaskGraphError.invalid }
        state = next; self.reason = reason; revision += 1
    }

    /// Host-only settlement. The model cannot submit a verdict through a coordinator command.
    /// Failed criteria reopen just their producers and invalidate consumers using ordinary revisions.
    public mutating func recordReview(callID: WorkflowAgentCallID, report: WorkflowReviewReport,
                                      toolEvidence: [WorkflowReviewToolEvidence], goalAmendmentCount: Int) throws {
        guard let artifactIndex = artifacts.firstIndex(where: { $0.callID == callID }),
              let index = tasks.firstIndex(where: { $0.id == artifacts[artifactIndex].taskID }),
              let contract = tasks[index].review else { throw WorkflowTaskGraphError.invalidReview }
        try report.validate(against: contract)
        let artifact = artifacts[artifactIndex]
        // An in-flight review of a superseded producer remains historical, never current acceptance.
        guard tasks[index].state == .completed, tasks[index].outputArtifactID == artifact.id else { return }
        var next = self
        let missing = contract.requiredTools.filter { tool in !toolEvidence.contains { $0.toolID == tool && $0.succeeded != false } }
        let review = WorkflowTaskReviewResult(contract: contract, report: report,
            inputArtifactIDs: artifact.inputArtifactIDs, toolEvidence: toolEvidence,
            goalAmendmentCount: goalAmendmentCount, missingTools: missing)
        next.artifacts[artifactIndex].reviewResult = review
        if goalAmendmentCount != amendments.count {
            next.tasks[index].state = .needsReview; next.tasks[index].outputArtifactID = nil
            next.tasks[index].failure = "Review the current human amendments before accepting this result."
            next.tasks[index].revision += 1; next.revision += 1; self = next
            return
        }
        if review.status != .pass {
            let findings = report.checks.filter { $0.status != .pass }.map { "\($0.id): \($0.detail)" }
            let reason = (missing.isEmpty ? findings : ["Required tool execution was not recorded: " + missing.joined(separator: ", ")] + findings)
                .joined(separator: "\n")
            next.artifacts[artifactIndex].validationFailure = reason
            next.tasks[index].state = .failed
            next.tasks[index].failure = reason
            next.tasks[index].outputArtifactID = nil
            if review.status == .revise {
                let failedIDs = Set(report.checks.filter { $0.status == .revise }.map(\.id))
                let targets = Set(contract.criteria.filter { failedIDs.contains($0.id) }.flatMap(\.targetTaskIDs))
                let producers = next.tasks.filter { targets.contains($0.id) }
                let canCorrect = producers.allSatisfy { task in
                    task.state == .completed && (task.reviewCorrectionBudget?.goalAmendmentCount != amendments.count
                        || (task.reviewCorrectionBudget?.attempts ?? 0) < 2)
                }
                if canCorrect {
                    let changes = producers.map { task in
                        WorkflowTaskUpdate(id: task.id, expectedRevision: task.revision, agent: task.agent,
                            instruction: task.instruction,
                            dependencies: task.dependencies, required: task.required, maximumToolCalls: task.maximumToolCalls,
                            model: task.model, inputRanges: task.inputRanges,
                            artifactInputs: Self.unique((task.artifactInputs ?? []) + [task.outputArtifactID!, artifact.id]),
                            profile: task.profile, review: task.review)
                    }
                    try next.update(changes, expectedRevision: next.revision)
                    for producer in producers {
                        let at = next.tasks.firstIndex { $0.id == producer.id }!
                        let attempts = producer.reviewCorrectionBudget?.goalAmendmentCount == amendments.count
                            ? producer.reviewCorrectionBudget!.attempts + 1 : 1
                        next.tasks[at].reviewCorrectionBudget = WorkflowReviewCorrectionBudget(goalAmendmentCount: amendments.count, attempts: attempts)
                        next.tasks[at].failure = "Address review \(artifact.id): " + reason
                    }
                } else {
                    next.tasks[index].failure = "Automatic review corrections exhausted or a producer is unavailable. " + reason
                }
            }
        }
        next.revision += 1
        self = next
    }

    /// Covers current required work through actual independent reviews, including their source ancestry.
    /// A passing review is still a model judgement, not a substitute for domain-specific outcome checks.
    public func requireAcceptedReviews() throws {
        var covered: Set<String> = []
        func include(_ id: String) {
            guard covered.insert(id).inserted, let task = tasks.first(where: { $0.id == id }) else { return }
            task.dependencies.forEach(include)
        }
        for task in tasks where task.required && task.state == .completed && task.review != nil {
            guard let artifact = artifacts.first(where: { $0.id == task.outputArtifactID }),
                  let review = artifact.reviewResult, review.status == .pass,
                  review.goalAmendmentCount == amendments.count,
                  review.contract == task.review, review.inputArtifactIDs == task.inputArtifactIDs else { continue }
            covered.insert(task.id)
            review.contract.targetTaskIDs.forEach(include)
        }
        guard !covered.isEmpty, tasks.filter(\.required).allSatisfy({ covered.contains($0.id) }) else {
            throw WorkflowTaskGraphError.unreviewed
        }
    }

    /// Trusted human API only. The model-facing command has no amendment or objective setter.
    public mutating func amend(_ amendment: WorkflowGoalAmendment) throws {
        if let existing = amendments.first(where: { $0.id == amendment.id }) {
            guard existing == amendment else { throw WorkflowTaskGraphError.stale }
            return
        }
        guard state != .completed && state != .cancelled, amendments.count < 64,
              !amendment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              amendment.text.utf8.count <= 16_384 else { throw WorkflowTaskGraphError.invalid }
        if let targets = amendment.targetRunIDs {
            guard targets.count <= 1_001, Set(targets).count == targets.count else { throw WorkflowTaskGraphError.invalid }
        }
        amendments.append(amendment)
        for index in tasks.indices where tasks[index].review != nil && tasks[index].state == .completed {
            tasks[index].state = .needsReview; tasks[index].outputArtifactID = nil
            tasks[index].failure = "Review the updated human requirements."
            tasks[index].revision += 1
        }
        revision += 1
    }

    public func validate() throws {
        guard revision > 0, tasks.count <= 32, Set(tasks.map(\.id)).count == tasks.count,
              artifacts.count <= 128, Set(artifacts.map(\.id)).count == artifacts.count else { throw WorkflowTaskGraphError.invalid }
        let ids = Set(tasks.map(\.id))
        guard tasks.allSatisfy({ $0.dependencies.allSatisfy(ids.contains) }) else { throw WorkflowTaskGraphError.unavailableInput }
        for task in tasks {
            if let review = task.review {
                try review.validate()
                guard task.required, review.targetTaskIDs.isSubset(of: Set(task.dependencies)),
                      review.targetTaskIDs.allSatisfy({ id in
                          tasks.contains { $0.id == id && $0.agent != task.agent && $0.review == nil }
                      }) else { throw WorkflowTaskGraphError.invalid }
            }
        }
        var visited: Set<String> = []
        func visit(_ id: String, path: Set<String>) throws {
            guard !path.contains(id) else { throw WorkflowTaskGraphError.cycle }
            if visited.contains(id) { return }
            for dependency in tasks.first(where: { $0.id == id })!.dependencies {
                try visit(dependency, path: path.union([id]))
            }
            visited.insert(id)
        }
        for task in tasks { try visit(task.id, path: []) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

/// A replay receipt for one model-facing host operation. Returned state never incorporates future events.
public struct WorkflowCollaborationReceipt: Hashable, Codable, Sendable {
    public let index: UInt32
    public let commandDigest: StableDigest
    public let senderRunID: AgentRunID
    public let graph: WorkflowTaskGraph
    public let feedback: String?
    public let observation: JSONValue?
    public let pendingInputs: AgentSessionPendingInputs?

    public init(index: UInt32, commandDigest: StableDigest, senderRunID: AgentRunID,
                graph: WorkflowTaskGraph, feedback: String? = nil, observation: JSONValue? = nil,
                pendingInputs: AgentSessionPendingInputs? = nil) {
        self.index = index; self.commandDigest = commandDigest; self.senderRunID = senderRunID
        self.graph = graph; self.feedback = feedback
        self.observation = observation
        self.pendingInputs = pendingInputs
    }
}
