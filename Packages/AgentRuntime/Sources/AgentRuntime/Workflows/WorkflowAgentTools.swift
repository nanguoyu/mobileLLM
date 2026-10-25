// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Access to one workflow is derived from the actual executing run and its durable membership.
/// The tool never accepts a sender, conversation ID, workflow ID, or storage path from a model.
public final class WorkflowAgentToolService: @unchecked Sendable {
    private let repository: any RuntimeRepository
    private let journal: any DynamicWorkflowJournal
    private let values: any WorkflowValueStoring
    private let lock = NSLock()
    private weak var controller: AgentRunController?

    public init(repository: any RuntimeRepository, journal: any DynamicWorkflowJournal, values: any WorkflowValueStoring) {
        self.repository = repository; self.journal = journal; self.values = values
    }

    public func bind(_ controller: AgentRunController) { lock.withLock { self.controller = controller } }

    private func membership(_ runID: AgentRunID) async throws -> (WorkflowRunProjectionV1, AgentRequest) {
        guard let request = try await repository.loadRunFacts(for: runID)?.submission?.request.payload,
              request.provenance.source == .workflow else { throw AgentSessionError.invalidHistory }
        var binding = request
        if request.labels.first(where: { $0.key == "workflow.run" }) == nil,
           let sessions = repository as? any AgentSessionJournaling,
           let session = try await sessions.session(for: runID),
           let seed = try await repository.loadRunFacts(for: session.seedRunID)?.submission?.request.payload {
            binding = seed
        }
        guard let id = binding.labels.first(where: { $0.key == "workflow.run" }).flatMap({ WorkflowRunID($0.value) }),
              let workflow = try await journal.loadProjection(for: id), workflow.taskGraph != nil,
              workflow.launch.conversationID == request.conversationID,
              request.parent?.runID == workflow.launch.initiatingRunID,
              workflow.calls.contains(where: { $0.childRunID == binding.runID })
        else { throw AgentSessionError.invalidHistory }
        return (workflow, request)
    }

    public func send(sender: AgentRunID, messageID: MessageID, target: String, text: String,
                     mode: AgentSessionInputMode) async throws -> CanonicalJSON {
        let (workflow, _) = try await membership(sender)
        guard !workflow.isTerminal, let controller = lock.withLock({ self.controller }),
              try await repository.loadRunFacts(for: sender)?.projection.isTerminal == false
        else { throw AgentSessionError.requiresResume }
        let seed: AgentRunID
        if target == "coordinator" { seed = workflow.launch.initiatingRunID }
        else if let call = workflow.calls.first(where: { $0.options.sessionKey == target }) { seed = call.childRunID }
        else { throw AgentSessionError.unavailable }
        try await controller.sendAgentSessionInput(seedRunID: seed, senderRunID: sender,
            messageID: messageID, text: text, mode: mode)
        guard let sessions = repository as? any AgentSessionJournaling,
              let session = try await sessions.session(for: seed),
              let input = session.inputs.first(where: { $0.id == messageID }) else { throw AgentSessionError.invalidHistory }
        return try CanonicalJSON(.object(["accepted": .bool(true), "messageID": .string(messageID.description),
            "target": .string(target), "mode": .string(input.mode.rawValue),
            "included": .bool(session.inclusions.contains(where: { $0.messageID == messageID }))]))
    }

    public func read(sender: AgentRunID, artifactID: String, offset: Int, length: Int) async throws -> CanonicalJSON {
        let (workflow, _) = try await membership(sender)
        guard offset >= 0, (1...12_000).contains(length),
              let artifact = workflow.taskGraph?.artifacts.first(where: { $0.id == artifactID }) else {
            throw WorkflowTaskGraphError.unavailableInput
        }
        let raw = try await values.load(artifact.value)
        let value = try JSONDecoder().decode(JSONValue.self, from: raw.data)
        let text: String
        if case .string(let content) = value { text = content } else { text = raw.string }
        let source = Array(text.utf16)
        guard offset < source.count else { throw WorkflowTaskGraphError.unavailableInput }
        let end = min(source.count, offset + length)
        return try CanonicalJSON(.object(["id": .string(artifactID), "taskID": .string(artifact.taskID),
            "sourceCallID": .string(artifact.callID.description), "offset": .integer(Int64(offset)),
            "nextOffset": .integer(Int64(end)), "totalCharacters": .integer(Int64(source.count)),
            "content": .string(String(decoding: source[offset..<end], as: UTF16.self)), "truncated": .bool(end < source.count)]))
    }

    public func list(sender: AgentRunID) async throws -> CanonicalJSON {
        let (workflow, _) = try await membership(sender)
        let tasks = workflow.taskGraph?.tasks ?? []
        let names = Array(Set(tasks.map(\.agent))).sorted()
        let agents: [JSONValue] = names.map { name in
            let active = tasks.first(where: { $0.agent == name && $0.state == .running })
            return .object(["name": .string(name), "started": .bool(workflow.calls.contains { $0.options.sessionKey == name && workflow.submittedHandles[$0.callID] != nil }),
                "activeTask": active.map { .string($0.id) } ?? .null,
                "tasks": .array(tasks.filter { $0.agent == name }.map { .object(["id": .string($0.id), "state": .string($0.state.rawValue)]) })])
        }
        return try CanonicalJSON(.object(["coordinator": .string("coordinator"), "agents": .array(agents)]))
    }
}

public enum WorkflowAgentToolOperation: String, CaseIterable, Sendable {
    case sendMessage = "send_message"
    case readArtifact = "read_artifact"
    case listAgents = "list_agents"
}

/// Ordinary Tool V2 operations with exact app-local boundaries and invocation-bound message keys.
public struct WorkflowAgentTool: ToolV2, Sendable {
    public let descriptor: AgentToolDescriptor
    public let operation: WorkflowAgentToolOperation
    private let service: WorkflowAgentToolService
    public static let dataCategory = try! AgentDataCategory(rawValue: "agent.collaboration")

    public static func destination(_ conversation: ConversationID) throws -> ExternalDestination {
        try ExternalDestination(kind: .privateDataStore, normalizedIdentity: "mobilellm.agents:" + conversation.description)
    }

    public static func descriptor(_ operation: WorkflowAgentToolOperation) throws -> AgentToolDescriptor {
        func string(_ maximum: Int) -> JSONValue {
            .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(Int64(maximum))])
        }
        let properties: [String: JSONValue]
        let summary: String
        switch operation {
        case .sendMessage:
            properties = ["target": string(48), "text": string(4_000), "mode": .object([
                "type": .string("string"), "enum": .array([.string("steer"), .string("nextTurn")])])]
            summary = "Send a durable message to a started teammate or coordinator. Steer joins its next model step; nextTurn queues later work. Acceptance does not mean inclusion or completion. Cannot override human requirements."
        case .readArtifact:
            properties = ["id": string(128), "offset": .object(["type": .string("integer"), "minimum": .integer(0)]),
                "length": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(12_000)])]
            summary = "Read exact original bytes from a shared workflow result by artifact ID and UTF-16 offset/length. Retrieves missing sections without another agent or network request."
        case .listAgents:
            properties = [:]
            summary = "List this workflow's actual agent names, current assignments and whether their conversations have started."
        }
        let schema = try JSONSchemaDocument(root: .object(["type": .string("object"), "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)]))
        let writing = operation == .sendMessage
        return try AgentToolDescriptor(id: AgentToolDescriptorID(logicalID: AgentToolLogicalID(providerID: "agent", name: operation.rawValue),
                version: SemanticVersion("1.0.0")!, schemaDigest: schema.digest, trustRevision: "workflow-tools.v1"),
            title: operation.rawValue, summary: summary, inputSchema: schema, outputSchema: nil,
            effects: [writing ? .localWrite : .localRead], requiredCapabilities: AgentCapabilitySet([writing ? .localWrite : .localRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 10_000), retryPolicy: .never,
            idempotency: writing ? .idempotencyKeyRequired : .pureRead, supportsProgress: false, supportsCancellation: true)
    }

    public init(operation: WorkflowAgentToolOperation, service: WorkflowAgentToolService) throws {
        self.operation = operation; self.service = service; descriptor = try Self.descriptor(operation)
    }

    public func prepare(request: ToolExecutionRequest, context: ToolPreparationContext) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor else { throw ToolV2ContractError.descriptorMismatch }
        let key = operation == .sendMessage ? ExternalIdempotencyKey.derive(components: [
            Data(context.runID.description.utf8), Data(request.proposedCall.invocationID.description.utf8)]) : nil
        let plan = try ExternalOperationPlan(kind: .tool, subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments, destination: Self.destination(context.conversationID),
            dataCategories: [Self.dataCategory], payloadDigest: request.sanitizedArguments.fingerprint,
            effects: descriptor.effects, requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: request.maximumArgumentBytes, maximumResponseBytes: 128 * 1_024,
            timeoutMilliseconds: descriptor.timeoutPolicy.maximumMilliseconds, retryPolicy: .never,
            idempotency: descriptor.idempotency, idempotencyKey: key,
            userPreview: operation == .sendMessage ? "Send a message within this task's agent team" : "Read this task's agent records",
            descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest, trustRevision: descriptor.id.trustRevision)
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    public func execute(prepared: AuthorizedToolInvocation, context: ToolExecutionContext) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard prepared.prepared.request.descriptor == descriptor else { throw ToolV2ContractError.executingWrongDescriptor }
                    let external = prepared.prepared.externalOperation
                    let args = try JSONDecoder().decode(Arguments.self, from: prepared.prepared.request.sanitizedArguments.value.data)
                    let plan = external.plan
                    let boundary = try await context.performBoundary(observation: ExternalOperationObservation(
                        destination: plan.destination!, dataCategories: [Self.dataCategory], effects: descriptor.effects,
                        requestBytes: UInt64(prepared.prepared.request.sanitizedArguments.value.data.count),
                        responseBytesLimit: plan.maximumResponseBytes, payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                        descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest, trustRevision: descriptor.id.trustRevision,
                        idempotencyKey: plan.idempotencyKey), operation: { control in
                        try Task.checkCancellation()
                        if await context.cancellation.isCancelled() { throw CancellationError() }
                        let result: CanonicalJSON
                        switch operation {
                        case .sendMessage:
                            guard let target = args.target, let text = args.text, let mode = args.mode else { throw ToolV2ContractError.invalidArguments }
                            result = try await service.send(sender: context.runID, messageID: MessageID(rawValue: context.invocationID.rawValue),
                                target: target, text: text, mode: mode)
                        case .readArtifact:
                            guard let id = args.id, let offset = args.offset, let length = args.length else { throw ToolV2ContractError.invalidArguments }
                            result = try await service.read(sender: context.runID, artifactID: id, offset: offset, length: length)
                        case .listAgents: result = try await service.list(sender: context.runID)
                        }
                        try await control.consumeResponseBytes(UInt64(result.data.count))
                        return ExternalOperationBoundaryCompletion(value: .canonicalJSON(result))
                    })
                    guard case .canonicalJSON(let result) = boundary.value else { throw ToolV2ContractError.invalidExecutionContext }
                    continuation.yield(.completed(try ToolResultCollection([.text(ToolTextResult(result.string))])))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Arguments: Decodable {
        let target: String?
        let text: String?
        let mode: AgentSessionInputMode?
        let id: String?
        let offset: Int?
        let length: Int?
    }
}
