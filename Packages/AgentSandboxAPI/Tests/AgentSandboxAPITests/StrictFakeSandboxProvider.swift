// SPDX-License-Identifier: MIT

import Foundation
@_spi(AgentRuntime) import AgentContracts
import AgentSandboxAPI

/// Contract test double only. No sandbox provider implementation exists in production sources.
actor StrictFakeSandboxProvider: AgentSandboxProvider {
    nonisolated let descriptor: AgentSandboxProviderDescriptor
    private nonisolated let report: SandboxCapabilities
    private let policy: RegisteredSandboxProviderPolicy

    private struct StartLedgerEntry: Sendable {
        let requestFingerprint: StableDigest
        let handleID: SandboxExecutionHandleID
    }

    private struct CommandLedgerEntry: Sendable {
        let commandFingerprint: StableDigest
        let receipt: SandboxCommandReceipt
    }

    private struct Execution {
        let request: SandboxExecutionRequest
        var status: SandboxExecutionStatus
        var result: SandboxExecutionResult?
        var events: [SandboxEventEnvelope]
        var commandLedger: [SandboxCommandID: CommandLedgerEntry]
        var observers: [UUID: AsyncThrowingStream<SandboxEventEnvelope, Error>.Continuation]
    }

    private var starts: [String: StartLedgerEntry] = [:]
    private var executions: [SandboxExecutionHandleID: Execution] = [:]
    private var clock: Int64 = 1_000

    init(
        descriptor: AgentSandboxProviderDescriptor,
        report: SandboxCapabilities,
        policy: RegisteredSandboxProviderPolicy
    ) {
        self.descriptor = descriptor
        self.report = report
        self.policy = policy
    }

    func capabilities() async throws -> SandboxCapabilities { report }

    func start(
        _ request: SandboxExecutionRequest,
        idempotencyKey: String
    ) async throws -> SandboxExecutionHandleID {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              idempotencyKey.utf8.count <= 256,
              idempotencyKey.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else { throw AgentSandboxAPIError.invalidValue("start idempotency key") }
        try request.negotiatedCapabilities.validate(
            against: policy,
            descriptor: descriptor,
            capabilities: report
        )
        guard request.protocolVersion == request.negotiatedCapabilities.selectedProtocolVersion else {
            throw AgentSandboxAPIError.incompatibleProtocol
        }
        if let prior = starts[idempotencyKey] {
            guard prior.requestFingerprint == request.fingerprint else {
                throw AgentSandboxAPIError.idempotencyConflict
            }
            return prior.handleID
        }

        let handleID = SandboxExecutionHandleID()
        let now = tick()
        let status = try SandboxExecutionStatus(
            handleID: handleID,
            stateVersion: 1,
            state: .accepted,
            acceptedAt: now,
            updatedAt: now,
            protocolVersion: request.protocolVersion
        )
        let event = try SandboxEventRecord(
            eventID: SandboxEventID(),
            handleID: handleID,
            sequence: 1,
            timestamp: now,
            status: status,
            event: .accepted(requestFingerprint: request.fingerprint),
            previousRecordDigest: nil
        )
        executions[handleID] = Execution(
            request: request,
            status: status,
            result: nil,
            events: [try eventEnvelope(event)],
            commandLedger: [:],
            observers: [:]
        )
        starts[idempotencyKey] = StartLedgerEntry(
            requestFingerprint: request.fingerprint,
            handleID: handleID
        )
        return handleID
    }

    func attach(to id: SandboxExecutionHandleID) async throws -> any SandboxExecutionHandle {
        guard executions[id] != nil else { throw AgentSandboxAPIError.executionNotFound }
        return StrictFakeSandboxHandle(id: id, provider: self)
    }

    func begin(_ id: SandboxExecutionHandleID) async throws {
        let current = try execution(id).status
        guard current.state == .accepted else { throw AgentSandboxAPIError.invalidValue("begin state") }
        let next = try SandboxExecutionStatus(
            handleID: id,
            stateVersion: current.stateVersion + 1,
            state: .running,
            acceptedAt: current.acceptedAt,
            updatedAt: tick(),
            protocolVersion: current.protocolVersion
        )
        try update(id, status: next, event: .started)
    }

    func emitProgress(
        _ progress: AgentExecutionProgress,
        for id: SandboxExecutionHandleID
    ) async throws {
        let current = try execution(id).status
        guard current.state == .running else { throw AgentSandboxAPIError.invalidValue("progress state") }
        let next = try SandboxExecutionStatus(
            handleID: id,
            stateVersion: current.stateVersion + 1,
            state: .running,
            progress: progress,
            acceptedAt: current.acceptedAt,
            updatedAt: tick(),
            protocolVersion: current.protocolVersion
        )
        try update(id, status: next, event: .progress(progress))
    }

    func complete(
        _ id: SandboxExecutionHandleID,
        output: CanonicalJSON? = nil,
        artifacts: [ArtifactReference] = []
    ) async throws {
        let current = try execution(id).status
        guard !current.state.isTerminal else { throw AgentSandboxAPIError.terminalExecution }
        let terminal = try SandboxExecutionStatus(
            handleID: id,
            stateVersion: current.stateVersion + 1,
            state: .completed,
            acceptedAt: current.acceptedAt,
            updatedAt: tick(),
            protocolVersion: current.protocolVersion
        )
        let request = try execution(id).request
        let result = try SandboxExecutionResult(
            requestID: request.requestID,
            handleID: id,
            terminalStatus: terminal,
            structuredOutput: output,
            artifacts: artifacts
        )
        try setTerminal(id, result: result)
    }

    func fail(_ id: SandboxExecutionHandleID, failure: AgentFailure) async throws {
        let current = try execution(id).status
        guard !current.state.isTerminal, failure.classification != .cancelled else {
            throw AgentSandboxAPIError.terminalExecution
        }
        let terminal = try SandboxExecutionStatus(
            handleID: id,
            stateVersion: current.stateVersion + 1,
            state: .failed,
            failure: failure,
            acceptedAt: current.acceptedAt,
            updatedAt: tick(),
            protocolVersion: current.protocolVersion
        )
        let request = try execution(id).request
        try setTerminal(
            id,
            result: SandboxExecutionResult(
                requestID: request.requestID,
                handleID: id,
                terminalStatus: terminal
            )
        )
    }

    func observerCount(for id: SandboxExecutionHandleID) -> Int {
        executions[id]?.observers.count ?? 0
    }

    fileprivate func status(for id: SandboxExecutionHandleID) throws -> SandboxExecutionStatus {
        try execution(id).status
    }

    fileprivate func result(for id: SandboxExecutionHandleID) throws -> SandboxExecutionResult? {
        try execution(id).result
    }

    fileprivate func subscribe(
        id: SandboxExecutionHandleID,
        after cursor: AgentEventCursor?,
        observerID: UUID,
        continuation: AsyncThrowingStream<SandboxEventEnvelope, Error>.Continuation
    ) {
        guard var execution = executions[id] else {
            continuation.finish(throwing: AgentSandboxAPIError.executionNotFound)
            return
        }
        let startIndex: Int
        if let cursor {
            guard cursor.executionHandleID.rawValue == id.rawValue,
                  let index = execution.events.firstIndex(where: {
                      (try? $0.payload.cursor) == cursor
                  })
            else {
                continuation.finish(throwing: AgentSandboxAPIError.invalidCursor)
                return
            }
            startIndex = index + 1
        } else {
            startIndex = 0
        }
        if startIndex < execution.events.count {
            for event in execution.events[startIndex...] { continuation.yield(event) }
        }
        if execution.status.state.isTerminal {
            continuation.finish()
        } else {
            execution.observers[observerID] = continuation
            executions[id] = execution
        }
    }

    fileprivate func detach(id: SandboxExecutionHandleID, observerID: UUID) {
        guard var execution = executions[id] else { return }
        execution.observers.removeValue(forKey: observerID)
        executions[id] = execution
    }

    fileprivate func send(
        _ command: SandboxCommandEnvelope,
        to id: SandboxExecutionHandleID
    ) throws -> SandboxCommandReceipt {
        guard command.payload.handleID == id else {
            throw AgentSandboxAPIError.requestBindingMismatch
        }
        var execution = try execution(id)
        guard command.protocolVersion == execution.request.protocolVersion
        else { throw AgentSandboxAPIError.incompatibleProtocol }
        if let prior = execution.commandLedger[command.payload.commandID] {
            guard prior.commandFingerprint == command.payload.fingerprint else {
                throw AgentSandboxAPIError.idempotencyConflict
            }
            return prior.receipt
        }
        if command.payload.expectedStateVersion != execution.status.stateVersion {
            let receipt = try rejectionReceipt(
                command: command.payload,
                status: execution.status,
                disposition: .stale,
                code: "sandbox.command.stale",
                message: "Command targeted a stale execution state"
            )
            execution.commandLedger[command.payload.commandID] = CommandLedgerEntry(
                commandFingerprint: command.payload.fingerprint,
                receipt: receipt
            )
            executions[id] = execution
            return receipt
        }
        if execution.status.state.isTerminal {
            let receipt = try rejectionReceipt(
                command: command.payload,
                status: execution.status,
                disposition: .rejected,
                code: "sandbox.command.terminal",
                message: "Execution is terminal"
            )
            execution.commandLedger[command.payload.commandID] = CommandLedgerEntry(
                commandFingerprint: command.payload.fingerprint,
                receipt: receipt
            )
            executions[id] = execution
            return receipt
        }

        switch command.payload.action {
        case .cancel:
            let current = execution.status
            let cancellation = try SandboxExecutionStatus(
                handleID: id,
                stateVersion: current.stateVersion + 1,
                state: .cancellationRequested,
                progress: current.progress,
                acceptedAt: current.acceptedAt,
                updatedAt: tick(),
                protocolVersion: current.protocolVersion
            )
            let receipt = try SandboxCommandReceipt(
                commandID: command.payload.commandID,
                commandFingerprint: command.payload.fingerprint,
                handleID: id,
                disposition: .accepted,
                currentStatus: cancellation
            )
            execution.commandLedger[command.payload.commandID] = CommandLedgerEntry(
                commandFingerprint: command.payload.fingerprint,
                receipt: receipt
            )
            executions[id] = execution
            try update(id, status: cancellation, event: .commandProcessed(receipt))

            let cancelled = try SandboxExecutionStatus(
                handleID: id,
                stateVersion: cancellation.stateVersion + 1,
                state: .cancelled,
                failure: SandboxTestValues.failure(.cancelled),
                acceptedAt: cancellation.acceptedAt,
                updatedAt: tick(),
                protocolVersion: cancellation.protocolVersion
            )
            let request = try self.execution(id).request
            try setTerminal(
                id,
                result: SandboxExecutionResult(
                    requestID: request.requestID,
                    handleID: id,
                    terminalStatus: cancelled
                )
            )
            return receipt
        }
    }

    private func execution(_ id: SandboxExecutionHandleID) throws -> Execution {
        guard let execution = executions[id] else { throw AgentSandboxAPIError.executionNotFound }
        return execution
    }

    private func tick() -> AgentTimestamp {
        let value = AgentTimestamp(rawValue: clock)
        clock += 1
        return value
    }

    private func update(
        _ id: SandboxExecutionHandleID,
        status: SandboxExecutionStatus,
        event: SandboxEvent
    ) throws {
        var execution = try execution(id)
        let record = try SandboxEventRecord(
            eventID: SandboxEventID(),
            handleID: id,
            sequence: UInt64(execution.events.count + 1),
            timestamp: status.updatedAt,
            status: status,
            event: event,
            previousRecordDigest: execution.events.last?.payload.recordDigest
        )
        let envelope = try eventEnvelope(record)
        execution.status = status
        execution.events.append(envelope)
        for observer in execution.observers.values { observer.yield(envelope) }
        executions[id] = execution
    }

    private func setTerminal(
        _ id: SandboxExecutionHandleID,
        result: SandboxExecutionResult
    ) throws {
        try update(id, status: result.terminalStatus, event: .terminal(result))
        var execution = try execution(id)
        execution.result = result
        for observer in execution.observers.values { observer.finish() }
        execution.observers.removeAll()
        executions[id] = execution
    }

    private func rejectionReceipt(
        command: SandboxCommand,
        status: SandboxExecutionStatus,
        disposition: SandboxCommandDisposition,
        code: String,
        message: String
    ) throws -> SandboxCommandReceipt {
        let failure = try AgentFailure(
            code: code,
            classification: .permanent,
            safeMessage: message,
            retryAdvice: .never,
            externalEffect: .confirmedNone,
            requiredUserAction: .none,
            redaction: RedactionMetadata(classification: .publicMetadata, policyVersion: 1)
        )
        return try SandboxCommandReceipt(
            commandID: command.commandID,
            commandFingerprint: command.fingerprint,
            handleID: command.handleID,
            disposition: disposition,
            currentStatus: status,
            failure: failure
        )
    }

    private func eventEnvelope(_ record: SandboxEventRecord) throws -> SandboxEventEnvelope {
        try AgentEnvelope(
            protocolVersion: record.status.protocolVersion,
            payloadVersion: SandboxEventRecord.currentPayloadVersion,
            payload: record
        )
    }
}

private struct StrictFakeSandboxHandle: SandboxExecutionHandle {
    let id: SandboxExecutionHandleID
    let provider: StrictFakeSandboxProvider

    func events(after cursor: AgentEventCursor?) -> AsyncThrowingStream<SandboxEventEnvelope, Error> {
        let observerID = UUID()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in
                Task { await provider.detach(id: id, observerID: observerID) }
            }
            Task {
                await provider.subscribe(
                    id: id,
                    after: cursor,
                    observerID: observerID,
                    continuation: continuation
                )
            }
        }
    }

    func status() async throws -> SandboxExecutionStatus {
        try await provider.status(for: id)
    }

    func result() async throws -> SandboxExecutionResult? {
        try await provider.result(for: id)
    }

    func send(_ command: SandboxCommandEnvelope) async throws -> SandboxCommandReceipt {
        try await provider.send(command, to: id)
    }
}
