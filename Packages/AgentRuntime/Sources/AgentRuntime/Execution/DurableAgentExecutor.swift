// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import Foundation

/// Empty executable catalog for deployments that have not registered Tool V2 adapters.
public struct EmptyExecutableToolCatalog: ExecutableToolCatalog, Sendable {
    public init() {}

    public func localSnapshot() async throws -> ToolCatalogSnapshot {
        try ToolCatalogSnapshot(revision: 1, descriptors: [])
    }

    public func tool(for descriptorID: AgentToolDescriptorID) async throws -> (any ToolV2)? {
        nil
    }
}

/// Production durable executor. The value is intentionally small; all ownership, command,
/// subscription, and recovery coordination lives in one actor shared by every attached handle.
public struct DurableAgentExecutor: AgentExecutor, Sendable {
    public let controller: AgentRunController

    public init(
        repository: any RuntimeRepository,
        payloadStore: any AgentExecutionPayloadStoring,
        inputFreezer: any AgentRunInputFreezing,
        modelProviders: StaticAgentModelProviderCatalog,
        tools: any ExecutableToolCatalog = EmptyExecutableToolCatalog(),
        policyEngine: any ApprovalPolicyEngine,
        sanitizer: any AgentExecutionPayloadSanitizing,
        residencyDriver: any ModelResidencyDriver,
        reusableApprovals: any AgentReusableApprovalProviding = EmptyReusableApprovalProvider(),
        clock: any AgentExecutionClock = SystemAgentExecutionClock(),
        logger: any AgentExecutionLogging = NoOpAgentExecutionLogger(),
        interactionContext: ApprovalInteractionContext = .foregroundInteractive
    ) {
        controller = AgentRunController(
            repository: repository,
            payloadStore: payloadStore,
            inputFreezer: inputFreezer,
            modelProviders: modelProviders,
            tools: tools,
            policyEngine: policyEngine,
            sanitizer: sanitizer,
            residencyDriver: residencyDriver,
            reusableApprovals: reusableApprovals,
            clock: clock,
            logger: logger,
            interactionContext: interactionContext
        )
    }

    public func submit(
        _ request: AgentRequest,
        commandID: AgentCommandID
    ) async throws -> AgentExecutionHandleID {
        try await controller.submit(request, commandID: commandID)
    }

    public func attach(to id: AgentExecutionHandleID) async throws -> any AgentExecutionHandle {
        try await controller.attach(to: id)
    }
}

private struct DurableAgentExecutionHandle: AgentExecutionHandle, Sendable {
    let id: AgentExecutionHandleID
    let controller: AgentRunController

    func events(
        after cursor: AgentEventCursor?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        controller.eventStream(for: id, after: cursor)
    }

    func ephemeralEvents() async -> AsyncThrowingStream<AgentEphemeralEventEnvelope, Error> {
        await controller.ephemeralEventStream(for: id)
    }

    func status() async throws -> AgentRunStatus {
        try await controller.status(for: id)
    }

    func result() async throws -> AgentResult? {
        try await controller.result(for: id)
    }

    func send(_ command: AgentCommandEnvelope) async throws -> AgentCommandReceipt {
        try await controller.send(command, through: id)
    }
}

/// Single authority for durable root-run ownership. Handles and event streams do not own work.
public actor AgentRunController {
    struct Subscription {
        let continuation: AsyncThrowingStream<AgentEventEnvelope, Error>.Continuation
        var nextSequence: UInt64
        var hydrating: Bool
        var buffered: [AgentEventEnvelope]
    }

    typealias EphemeralContinuation = AsyncThrowingStream<
        AgentEphemeralEventEnvelope,
        Error
    >.Continuation

    let repository: any RuntimeRepository
    let payloadStore: any AgentExecutionPayloadStoring
    let inputFreezer: any AgentRunInputFreezing
    let modelProviders: StaticAgentModelProviderCatalog
    let tools: any ExecutableToolCatalog
    let policyEngine: any ApprovalPolicyEngine
    let sanitizer: any AgentExecutionPayloadSanitizing
    let reusableApprovals: any AgentReusableApprovalProviding
    let clock: any AgentExecutionClock
    let logger: any AgentExecutionLogging
    let interactionContext: ApprovalInteractionContext
    let arbiter: ResourceArbiter

    var workers: [AgentRunID: Task<Void, Never>] = [:]
    var activeToolCancellations: [AgentRunID: (
        invocationID: ToolInvocationID,
        token: ExecutionCancellationToken
    )] = [:]
    private var subscriptions: [AgentExecutionHandleID: [UUID: Subscription]] = [:]
    var ephemeralSubscriptions: [AgentExecutionHandleID: [UUID: EphemeralContinuation]] = [:]
    let commandOwner = "mobilellm.agent-run-controller.v1"

    public init(
        repository: any RuntimeRepository,
        payloadStore: any AgentExecutionPayloadStoring,
        inputFreezer: any AgentRunInputFreezing,
        modelProviders: StaticAgentModelProviderCatalog,
        tools: any ExecutableToolCatalog,
        policyEngine: any ApprovalPolicyEngine,
        sanitizer: any AgentExecutionPayloadSanitizing,
        residencyDriver: any ModelResidencyDriver,
        reusableApprovals: any AgentReusableApprovalProviding,
        clock: any AgentExecutionClock,
        logger: any AgentExecutionLogging,
        interactionContext: ApprovalInteractionContext
    ) {
        self.repository = repository
        self.payloadStore = payloadStore
        self.inputFreezer = inputFreezer
        self.modelProviders = modelProviders
        self.tools = tools
        self.policyEngine = policyEngine
        self.sanitizer = sanitizer
        self.reusableApprovals = reusableApprovals
        self.clock = clock
        self.logger = logger
        self.interactionContext = interactionContext
        arbiter = ResourceArbiter(driver: residencyDriver)
    }

    public func submit(
        _ request: AgentRequest,
        commandID: AgentCommandID
    ) async throws -> AgentExecutionHandleID {
        if let existing = try await repository.loadRunFacts(for: request.runID),
           let submission = existing.submission
        {
            guard submission.commandID == commandID,
                  submission.request.payload == request
            else {
                if submission.commandID == commandID {
                    throw AgentExecutionError.submissionCommandConflict(commandID)
                }
                throw AgentExecutionError.requestRunAlreadyExists(request.runID)
            }
            return submission.executionHandleID
        }

        let frozen = try await inputFreezer.freeze(request)
        let frozenData = try ExecutionEncoding.encode(frozen)
        let inputArtifact = try await payloadStore.commit(
            data: frozenData,
            mimeType: "application/json",
            semanticType: "agent-run-input.v1",
            runID: request.runID,
            stepID: nil,
            invocationID: nil,
            owner: .run(request.runID),
            sensitivity: .personalData
        )
        let inputReference = try AgentStableBoundaryReference(
            digest: StableDigest.sha256(frozenData),
            artifactID: inputArtifact.id
        )
        let handleID = ExecutionStableID.handle(request: request, commandID: commandID)
        let messageID = request.provenance.sourceMessageID
            ?? ExecutionStableID.message(runID: request.runID, role: .user)
        let userBody = Data(frozen.currentUser.frozen.content.utf8)
        let userArtifact = try await payloadStore.commit(
            data: userBody,
            mimeType: "text/plain",
            semanticType: "agent-user-message.v1",
            runID: request.runID,
            stepID: nil,
            invocationID: nil,
            owner: .message(messageID),
            sensitivity: .personalData
        )
        let timestamp = try await clock.now()
        var builder = ExecutionEventBuilder(
            requestID: request.id,
            handleID: handleID,
            runID: request.runID,
            timestamp: timestamp
        )
        let initialEvent = try builder.append(
            id: ExecutionStableID.event(runID: request.runID, key: "run-input"),
            event: .runInputSnapshotCommitted(inputReference),
            at: timestamp,
            redaction: Self.publicRedaction
        )
        let append = try RunJournalAppendRequest(
            mutationIdentity: .command(commandID),
            runID: request.runID,
            expectedRunStateVersion: 1,
            events: [initialEvent]
        )
        let message = JournalMessageReference(
            messageID: messageID,
            conversationID: request.conversationID,
            runID: request.runID,
            role: .user,
            bodyDigest: StableDigest.sha256(userBody),
            bodyArtifactID: userArtifact.id,
            createdAt: timestamp
        )
        let outbox = ProjectionOutboxItem(
            idempotencyKey: "accepted:\(messageID.description)",
            conversationID: request.conversationID,
            runID: request.runID,
            messageID: messageID,
            kind: .acceptedUserMessage,
            payloadDigest: message.bodyDigest,
            payloadArtifactID: message.bodyArtifactID
        )
        do {
            let receipt = try await repository.commitSubmission(
                RuntimeSubmissionCommit(
                    commandID: commandID,
                    request: try AgentRequestEnvelope(payload: request),
                    executionHandleID: handleID,
                    userMessage: message,
                    inputSnapshot: inputReference,
                    initialAppend: append,
                    initialLedger: try BudgetLedgerSnapshot(budget: request.budget),
                    outbox: outbox
                )
            )
            guard receipt.executionHandleID == handleID else {
                throw AgentExecutionError.corruptExecutionBinding
            }
            broadcast([initialEvent], handleID: handleID)
            schedule(runID: request.runID)
            return handleID
        } catch RuntimeRepositoryError.commandConflict {
            if let facts = try await repository.loadRunFacts(for: request.runID),
               let submission = facts.submission,
               submission.commandID == commandID,
               submission.request.payload == request
            {
                return submission.executionHandleID
            }
            throw AgentExecutionError.submissionCommandConflict(commandID)
        }
    }

    public func attach(to id: AgentExecutionHandleID) async throws -> any AgentExecutionHandle {
        guard let facts = try await repository.loadRunFacts(for: id) else {
            throw AgentExecutionError.executionNotFound(id)
        }
        guard facts.projection.executionHandleID == id,
              facts.submission?.executionHandleID == id
        else { throw AgentExecutionError.corruptExecutionBinding }
        return DurableAgentExecutionHandle(id: id, controller: self)
    }

    nonisolated public func eventStream(
        for handleID: AgentExecutionHandleID,
        after cursor: AgentEventCursor?
    ) -> AsyncThrowingStream<AgentEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let subscriptionID = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.detach(subscriptionID, from: handleID) }
            }
            Task {
                await self.hydrate(
                    subscriptionID,
                    handleID: handleID,
                    after: cursor,
                    continuation: continuation
                )
            }
        }
    }

    public func status(for handleID: AgentExecutionHandleID) async throws -> AgentRunStatus {
        let (_, history) = try await loadExecution(handleID)
        return history.status
    }

    public func result(for handleID: AgentExecutionHandleID) async throws -> AgentResult? {
        let (_, history) = try await loadExecution(handleID)
        return history.result
    }

    private func hydrate(
        _ subscriptionID: UUID,
        handleID: AgentExecutionHandleID,
        after cursor: AgentEventCursor?,
        continuation: AsyncThrowingStream<AgentEventEnvelope, Error>.Continuation
    ) async {
        do {
            guard let facts = try await repository.loadRunFacts(for: handleID) else {
                throw AgentExecutionError.executionNotFound(handleID)
            }
            guard facts.projection.executionHandleID == handleID else {
                throw AgentExecutionError.corruptExecutionBinding
            }
            let trusted = try await validate(cursor, for: facts)
            let start = trusted?.cursor.sequence ?? 0
            subscriptions[handleID, default: [:]][subscriptionID] = Subscription(
                continuation: continuation,
                nextSequence: start + 1,
                hydrating: true,
                buffered: []
            )
            var readCursor = cursor
            var reachedEnd = false
            while !reachedEnd {
                let page = try await repository.readEvents(
                    RunJournalReadRequest(runID: facts.projection.runID, after: readCursor)
                )
                for event in page.events {
                    deliver(event, to: subscriptionID, handleID: handleID)
                }
                readCursor = page.nextCursor ?? readCursor
                reachedEnd = page.reachedEnd
            }
            guard var subscription = subscriptions[handleID]?[subscriptionID] else { return }
            subscription.hydrating = false
            let pending = subscription.buffered.sorted {
                $0.payload.sequence < $1.payload.sequence
            }
            subscription.buffered.removeAll(keepingCapacity: false)
            subscriptions[handleID]?[subscriptionID] = subscription
            for event in pending {
                deliver(event, to: subscriptionID, handleID: handleID)
            }
            let nextSequence: UInt64
            if let stored = subscriptions[handleID]?[subscriptionID]?.nextSequence {
                nextSequence = stored
            } else {
                nextSequence = 0
            }
            if facts.projection.isTerminal, nextSequence > facts.projection.eventCount {
                finish(subscriptionID, handleID: handleID)
            }
        } catch {
            continuation.finish(throwing: error)
            detach(subscriptionID, from: handleID)
        }
    }

    private func validate(
        _ cursor: AgentEventCursor?,
        for facts: RuntimeRunFacts
    ) async throws -> TrustedAgentEventCursor? {
        guard let cursor else { return nil }
        guard cursor.executionHandleID == facts.projection.executionHandleID else {
            throw AgentExecutionError.cursorBelongsToAnotherExecution
        }
        var readCursor: AgentEventCursor?
        while true {
            let page = try await repository.readEvents(
                RunJournalReadRequest(runID: facts.projection.runID, after: readCursor)
            )
            if let record = page.events.first(where: { $0.payload.sequence == cursor.sequence })?.payload {
                guard record.cursor == cursor else {
                    throw AgentExecutionError.cursorIntegrityMismatch
                }
                return TrustedAgentEventCursor(cursor: cursor)
            }
            guard !page.reachedEnd else { throw AgentExecutionError.cursorNotFound }
            readCursor = page.nextCursor
        }
    }

    private func loadExecution(
        _ handleID: AgentExecutionHandleID
    ) async throws -> (RuntimeRunFacts, ExecutionHistory) {
        guard let snapshot = try await repository.loadRunSnapshot(for: handleID) else {
            throw AgentExecutionError.executionNotFound(handleID)
        }
        return (
            snapshot.facts,
            try ExecutionHistory(events: snapshot.events, projection: snapshot.facts.projection)
        )
    }

    func allEvents(runID: AgentRunID) async throws -> [AgentEventEnvelope] {
        var result: [AgentEventEnvelope] = []
        var cursor: AgentEventCursor?
        while true {
            let page = try await repository.readEvents(
                RunJournalReadRequest(runID: runID, after: cursor, limit: 1_024)
            )
            result.append(contentsOf: page.events)
            guard !page.reachedEnd else { return result }
            cursor = page.nextCursor
        }
    }

    func broadcast(_ events: [AgentEventEnvelope], handleID: AgentExecutionHandleID) {
        let ids = subscriptions[handleID]?.keys.map({ $0 }) ?? []
        for id in ids {
            for event in events {
                guard var subscription = subscriptions[handleID]?[id] else { continue }
                if subscription.hydrating {
                    subscription.buffered.append(event)
                    subscriptions[handleID]?[id] = subscription
                } else {
                    deliver(event, to: id, handleID: handleID)
                }
            }
        }
        if events.contains(where: { $0.payload.event.isRunTerminal }) {
            finishEphemeral(handleID: handleID)
        }
    }

    private func deliver(
        _ event: AgentEventEnvelope,
        to subscriptionID: UUID,
        handleID: AgentExecutionHandleID
    ) {
        guard var subscription = subscriptions[handleID]?[subscriptionID],
              event.payload.sequence >= subscription.nextSequence
        else { return }
        guard event.payload.sequence == subscription.nextSequence else {
            subscription.continuation.finish(
                throwing: AgentExecutionError.invalidRecoveryBoundary
            )
            subscriptions[handleID]?[subscriptionID] = nil
            return
        }
        subscription.continuation.yield(event)
        subscription.nextSequence += 1
        subscriptions[handleID]?[subscriptionID] = subscription
        if event.payload.event.isRunTerminal { finish(subscriptionID, handleID: handleID) }
    }

    private func finish(_ subscriptionID: UUID, handleID: AgentExecutionHandleID) {
        subscriptions[handleID]?[subscriptionID]?.continuation.finish()
        subscriptions[handleID]?[subscriptionID] = nil
        if subscriptions[handleID]?.isEmpty == true { subscriptions[handleID] = nil }
    }

    private func detach(_ subscriptionID: UUID, from handleID: AgentExecutionHandleID) {
        subscriptions[handleID]?[subscriptionID] = nil
        if subscriptions[handleID]?.isEmpty == true { subscriptions[handleID] = nil }
    }

    func schedule(runID: AgentRunID) {
        guard workers[runID] == nil else { return }
        workers[runID] = Task { [weak self] in
            guard let self else { return }
            await self.drive(runID: runID)
            await self.workerFinished(runID: runID)
        }
    }

    private func workerFinished(runID: AgentRunID) {
        workers[runID] = nil
    }

    func registerToolCancellation(
        _ token: ExecutionCancellationToken,
        runID: AgentRunID,
        invocationID: ToolInvocationID
    ) throws {
        guard activeToolCancellations[runID] == nil else {
            throw AgentExecutionError.internalInvariant("run already owns a live tool cancellation")
        }
        activeToolCancellations[runID] = (invocationID, token)
    }

    func clearToolCancellation(runID: AgentRunID, invocationID: ToolInvocationID) {
        guard activeToolCancellations[runID]?.invocationID == invocationID else { return }
        activeToolCancellations[runID] = nil
    }

    func cancelActiveTool(runID: AgentRunID) async {
        guard let active = activeToolCancellations[runID] else { return }
        await active.token.cancel()
    }

    static let publicRedaction = try! RedactionMetadata(
        classification: .publicMetadata,
        policyVersion: 1
    )
}
