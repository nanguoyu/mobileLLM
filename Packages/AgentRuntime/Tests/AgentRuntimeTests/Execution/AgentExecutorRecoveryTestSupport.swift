// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) @testable import AgentContracts
@testable import AgentRuntime
import Foundation

/// A crash-test barrier that pauses the caller only after the selected state is durably visible.
/// Cancelling that caller simulates process loss after commit but before its receipt can drive the
/// next in-memory step. The durable SQLite journal remains the sole recovery input.
actor ExecutorPostCommitCrashGate {
    let targetState: AgentRunState?
    let targetEventID: AgentEventID?
    let targetOccurrence: Int
    private var intercepted = false
    private var matchingCommitCount = 0

    init(targetState: AgentRunState, targetOccurrence: Int = 1) {
        precondition(targetOccurrence > 0)
        self.targetState = targetState
        targetEventID = nil
        self.targetOccurrence = targetOccurrence
    }

    init(targetEventID: AgentEventID, targetOccurrence: Int = 1) {
        precondition(targetOccurrence > 0)
        targetState = nil
        self.targetEventID = targetEventID
        self.targetOccurrence = targetOccurrence
    }

    func waitUntilIntercepted() async throws {
        for _ in 0 ..< 5_000 {
            if intercepted { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ExecutorIntegrationTestError.timeout
    }

    func suspendIfNeeded(after events: [AgentEventEnvelope]) async throws {
        guard !intercepted else { return }
        let matches = if let targetEventID {
            events.contains { $0.payload.eventID == targetEventID }
        } else {
            events.last?.payload.runState == targetState
        }
        guard matches else { return }
        matchingCommitCount += 1
        guard matchingCommitCount == targetOccurrence else { return }
        intercepted = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

actor ExecutorBoundaryClaimProbe {
    struct Claim: Sendable {
        let attempt: ExternalOperationAttempt
        let hop: ExternalOperationBoundaryHop
    }

    private var claims: [Claim] = []

    func record(attempt: ExternalOperationAttempt, hop: ExternalOperationBoundaryHop) {
        claims.append(Claim(attempt: attempt, hop: hop))
    }

    func snapshot() -> [Claim] { claims }
}

enum ExecutorSimulatedProcessLoss: Error {
    case afterBoundaryClaim
    case beforeCommandCompletion
}

actor ExecutorCommandCompletionFault {
    let commandID: AgentCommandID
    private var injected = false

    init(commandID: AgentCommandID) {
        self.commandID = commandID
    }

    func shouldInject(for candidate: AgentCommandID) -> Bool {
        guard candidate == commandID, !injected else { return false }
        injected = true
        return true
    }
}

actor ExecutorMutationReplayInjector {
    let target: RunJournalMutationIdentity
    private var committedEventIDs: [AgentEventID]?

    init(target: RunJournalMutationIdentity) {
        self.target = target
    }

    func replayEventIDs(for candidate: RunJournalMutationIdentity) -> [AgentEventID]? {
        guard candidate == target else { return nil }
        return committedEventIDs
    }

    func record(_ receipt: RuntimeJournalMutationReceipt, for candidate: RunJournalMutationIdentity) {
        guard candidate == target,
              receipt.appendReceipt.disposition == .appended,
              committedEventIDs == nil
        else { return }
        committedEventIDs = receipt.appendReceipt.eventIDs
    }
}

/// Suspends after SQLite has atomically persisted an exact tool-boundary claim but before the
/// provider closure can begin. Closing the old repository and aborting the suspension models a
/// process disappearing at that precise durable boundary without giving cleanup code a writable
/// store in which to manufacture an outcome.
actor ExecutorBoundaryClaimCrashGate {
    private var intercepted = false
    private var continuation: CheckedContinuation<Void, any Error>?

    func waitUntilIntercepted() async throws {
        for _ in 0 ..< 5_000 {
            if intercepted { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ExecutorIntegrationTestError.timeout
    }

    func suspendAfterDurableClaim() async throws {
        guard !intercepted else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            intercepted = true
        }
    }

    func abortAsProcessLoss() {
        continuation?.resume(throwing: ExecutorSimulatedProcessLoss.afterBoundaryClaim)
        continuation = nil
    }

    func releaseAfterDurableClaim() {
        continuation?.resume()
        continuation = nil
    }
}

/// A cancellation-insensitive barrier immediately before the scoped SQLite boundary claim. It
/// makes the lifecycle CAS and boundary claim race deterministic: a pause/cancel command can win
/// the state transition while the suspended claimant remains unable to perform boundary I/O.
actor ExecutorBeforeBoundaryClaimGate {
    private var intercepted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilIntercepted() async throws {
        for _ in 0 ..< 5_000 {
            if intercepted { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ExecutorIntegrationTestError.timeout
    }

    func suspendBeforeClaim() async {
        guard !intercepted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            intercepted = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Suspends the first event-page read so tests can deterministically commit live events while a
/// durable subscription is hydrating. Releasing the gate then verifies buffered replay ordering.
actor ExecutorReadEventsGate {
    private var intercepted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilIntercepted() async throws {
        for _ in 0 ..< 5_000 {
            if intercepted { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ExecutorIntegrationTestError.timeout
    }

    func suspendFirstRead() async {
        guard !intercepted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            intercepted = true
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// Delegates every production repository operation to SQLite and gates only successful append
/// receipts. It introduces no alternate recovery facts and cannot mutate event payloads.
actor ExecutorPostCommitGatedRepository: RuntimeRepository {
    let underlying: SQLiteRunJournal
    let gate: ExecutorPostCommitCrashGate?
    let claimProbe: ExecutorBoundaryClaimProbe?
    let boundaryClaimCrashGate: ExecutorBoundaryClaimCrashGate?
    let commandCompletionFault: ExecutorCommandCompletionFault?
    let mutationReplayInjector: ExecutorMutationReplayInjector?
    let beforeBoundaryClaimGate: ExecutorBeforeBoundaryClaimGate?
    let readEventsGate: ExecutorReadEventsGate?
    let loadRunFactsFailure: AgentExecutionError?
    private var mayInjectLoadRunFactsFailure = false

    init(
        underlying: SQLiteRunJournal,
        gate: ExecutorPostCommitCrashGate? = nil,
        claimProbe: ExecutorBoundaryClaimProbe? = nil,
        boundaryClaimCrashGate: ExecutorBoundaryClaimCrashGate? = nil,
        commandCompletionFault: ExecutorCommandCompletionFault? = nil,
        mutationReplayInjector: ExecutorMutationReplayInjector? = nil,
        beforeBoundaryClaimGate: ExecutorBeforeBoundaryClaimGate? = nil,
        readEventsGate: ExecutorReadEventsGate? = nil,
        loadRunFactsFailure: AgentExecutionError? = nil
    ) {
        self.underlying = underlying
        self.gate = gate
        self.claimProbe = claimProbe
        self.boundaryClaimCrashGate = boundaryClaimCrashGate
        self.commandCompletionFault = commandCompletionFault
        self.mutationReplayInjector = mutationReplayInjector
        self.beforeBoundaryClaimGate = beforeBoundaryClaimGate
        self.readEventsGate = readEventsGate
        self.loadRunFactsFailure = loadRunFactsFailure
    }

    func loadProjection(for runID: AgentRunID) async throws -> AgentRunProjection? {
        try await underlying.loadProjection(for: runID)
    }

    func append(_ request: RunJournalAppendRequest) async throws -> RunJournalAppendReceipt {
        let receipt = try await underlying.append(request)
        if receipt.disposition == .appended {
            try await gate?.suspendIfNeeded(after: request.events)
        }
        return receipt
    }

    func readEvents(_ request: RunJournalReadRequest) async throws -> RunJournalEventPage {
        await readEventsGate?.suspendFirstRead()
        return try await underlying.readEvents(request)
    }

    func commitSubmission(
        _ submission: RuntimeSubmissionCommit
    ) async throws -> RuntimeSubmissionReceipt {
        let receipt = try await underlying.commitSubmission(submission)
        if receipt.appendReceipt.disposition == .appended {
            try await gate?.suspendIfNeeded(after: submission.initialAppend.events)
        }
        mayInjectLoadRunFactsFailure = true
        return receipt
    }

    func commit(_ mutation: RuntimeJournalMutation) async throws -> RuntimeJournalMutationReceipt {
        if let eventIDs = await mutationReplayInjector?.replayEventIDs(
            for: mutation.append.mutationIdentity
        ) {
            guard let projection = try await underlying.loadProjection(for: mutation.append.runID),
                  let ledger = try await underlying.loadBudgetLedger(for: mutation.append.runID)
            else { throw AgentExecutionError.invalidRecoveryBoundary }
            return RuntimeJournalMutationReceipt(
                appendReceipt: try RunJournalAppendReceipt(
                    mutationIdentity: mutation.append.mutationIdentity,
                    disposition: .replayed,
                    projection: projection,
                    eventIDs: eventIDs
                ),
                budgetLedger: ledger
            )
        }
        let receipt = try await underlying.commit(mutation)
        await mutationReplayInjector?.record(
            receipt,
            for: mutation.append.mutationIdentity
        )
        if receipt.appendReceipt.disposition == .appended {
            try await gate?.suspendIfNeeded(after: mutation.append.events)
        }
        return receipt
    }

    func commitFinalization(
        _ finalization: RuntimeFinalizationCommit
    ) async throws -> RuntimeJournalMutationReceipt {
        let receipt = try await underlying.commitFinalization(finalization)
        if receipt.appendReceipt.disposition == .appended {
            try await gate?.suspendIfNeeded(after: finalization.mutation.append.events)
        }
        return receipt
    }

    func enqueueCommand(
        _ envelope: AgentCommandEnvelope
    ) async throws -> AgentCommandAdmission {
        try await underlying.enqueueCommand(envelope)
    }

    func claimCommands(
        owner: String,
        now: AgentTimestamp,
        leaseUntil: AgentTimestamp,
        limit: Int
    ) async throws -> AgentCommandClaim {
        try await underlying.claimCommands(
            owner: owner,
            now: now,
            leaseUntil: leaseUntil,
            limit: limit
        )
    }

    func completeCommand(
        commandID: AgentCommandID,
        lease: AgentCommandLeaseIdentity,
        receipt: AgentCommandReceiptEnvelope,
        completedAt: AgentTimestamp
    ) async throws -> DurableAgentCommand {
        if await commandCompletionFault?.shouldInject(for: commandID) == true {
            throw ExecutorSimulatedProcessLoss.beforeCommandCompletion
        }
        return try await underlying.completeCommand(
            commandID: commandID,
            lease: lease,
            receipt: receipt,
            completedAt: completedAt
        )
    }

    func loadCommand(_ commandID: AgentCommandID) async throws -> DurableAgentCommand? {
        try await underlying.loadCommand(commandID)
    }

    func loadRunFacts(for runID: AgentRunID) async throws -> RuntimeRunFacts? {
        if mayInjectLoadRunFactsFailure, let loadRunFactsFailure { throw loadRunFactsFailure }
        return try await underlying.loadRunFacts(for: runID)
    }

    func loadRunFacts(
        for executionHandleID: AgentExecutionHandleID
    ) async throws -> RuntimeRunFacts? {
        try await underlying.loadRunFacts(for: executionHandleID)
    }

    func loadRunSnapshot(for runID: AgentRunID) async throws -> RuntimeRunSnapshot? {
        try await underlying.loadRunSnapshot(for: runID)
    }

    func loadRunSnapshot(
        for executionHandleID: AgentExecutionHandleID
    ) async throws -> RuntimeRunSnapshot? {
        try await underlying.loadRunSnapshot(for: executionHandleID)
    }

    func boundaryClaimEvidence(
        approvalID: ApprovalID,
        prepared: PreparedExternalOperationRequest,
        attempt: ExternalOperationAttempt
    ) async throws -> RuntimeBoundaryClaimEvidence {
        try await underlying.boundaryClaimEvidence(
            approvalID: approvalID,
            prepared: prepared,
            attempt: attempt
        )
    }

    func loadBudgetLedger(for runID: AgentRunID) async throws -> BudgetLedgerSnapshot? {
        try await underlying.loadBudgetLedger(for: runID)
    }

    func loadCompiledManifests(
        for runID: AgentRunID
    ) async throws -> [DurableCompiledManifest] {
        try await underlying.loadCompiledManifests(for: runID)
    }

    func loadApprovals(for runID: AgentRunID) async throws -> [DurableApproval] {
        try await underlying.loadApprovals(for: runID)
    }

    func loadInteractions(for runID: AgentRunID) async throws -> [DurableInteraction] {
        try await underlying.loadInteractions(for: runID)
    }

    func loadToolInvocations(for runID: AgentRunID) async throws -> [DurableToolInvocation] {
        try await underlying.loadToolInvocations(for: runID)
    }

    func loadRecoveryFacts(for runID: AgentRunID) async throws -> RuntimeRecoveryFacts? {
        try await underlying.loadRecoveryFacts(for: runID)
    }

    func recoveryDirective(for runID: AgentRunID) async throws -> RecoveryDirective? {
        try await underlying.recoveryDirective(for: runID)
    }

    func claimBoundaryHop(
        scope: RuntimeBoundaryClaimScope,
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool {
        await claimProbe?.record(attempt: attempt, hop: hop)
        if hop.destination?.kind == .networkEndpoint {
            await beforeBoundaryClaimGate?.suspendBeforeClaim()
        }
        let claimed = try await underlying.claimBoundaryHop(
            scope: scope,
            approvalID: approvalID,
            preparedRequestFingerprint: preparedRequestFingerprint,
            attempt: attempt,
            hop: hop
        )
        if claimed, hop.destination?.kind == .networkEndpoint {
            try await boundaryClaimCrashGate?.suspendAfterDurableClaim()
        }
        return claimed
    }
}

func makeReopenedExecutor(
    harness: ExecutorTestHarness,
    repository: any RuntimeRepository,
    provider: any AgentModelProvider,
    tools: any ExecutableToolCatalog = EmptyExecutableToolCatalog(),
    residencyDriver: any ModelResidencyDriver = ScriptedModelResidencyDriver(),
    clock: any AgentExecutionClock = FixedExecutorClock()
) throws -> DurableAgentExecutor {
    DurableAgentExecutor(
        repository: repository,
        payloadStore: harness.payloadStore,
        inputFreezer: StaticAgentRunInputFreezer(inputs: harness.frozenInputs),
        modelProviders: try StaticAgentModelProviderCatalog(providers: [provider]),
        tools: tools,
        policyEngine: try DefaultApprovalPolicyEngine(
            policyVersion: 1,
            sanitizationValidator: harness.attestor
        ),
        sanitizer: harness.attestor,
        residencyDriver: residencyDriver,
        clock: clock
    )
}
