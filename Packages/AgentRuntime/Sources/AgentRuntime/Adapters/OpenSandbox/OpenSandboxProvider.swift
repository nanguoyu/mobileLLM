// SPDX-License-Identifier: MIT

import AgentContracts
import AgentSandboxAPI
import Foundation

/// One trusted goal scope backed by an OpenSandbox workspace. Scope comes from runtime provenance,
/// never from model arguments. The gateway owns command idempotency across client process death.
public actor OpenSandboxProvider: AgentSandboxProvider {
    public nonisolated let descriptor: AgentSandboxProviderDescriptor
    public nonisolated let connection: OpenSandboxConnection
    public nonisolated let workspaceID: SandboxWorkspaceHandleID
    public nonisolated let maximumAuthority: AgentAuthorityScope
    public nonisolated let maximumBudget: AgentBudget
    private let client: OpenSandboxHTTPClient
    private let directory: URL
    private var records: [SandboxExecutionHandleID: Record] = [:]
    private var starting: Set<SandboxExecutionHandleID> = []

    private struct CancelEntry: Codable {
        let fingerprint: StableDigest
        let remoteVersion: UInt64
        var receipt: SandboxCommandReceipt?
    }
    private struct Record: Codable {
        let id: SandboxExecutionHandleID
        let key: String
        let connectionFingerprint: StableDigest
        let request: SandboxExecutionRequest
        var events: [SandboxEventRecord]
        var remote: OpenSandboxJob?
        var cancellations: [String: CancelEntry] = [:]
        var requestBytes: UInt64? = nil
        var responseBytes: UInt64? = nil
        var largestResponse: UInt64? = nil
    }

    private var responseObservers: [String: @Sendable (UInt64) async throws -> Void] = [:]

    func metered<T: Sendable>(idempotencyKey: String, observer: @escaping @Sendable (UInt64) async throws -> Void,
                             operation: @Sendable () async throws -> T) async throws -> T {
        guard responseObservers[idempotencyKey] == nil else { throw AgentSandboxAPIError.idempotencyConflict }
        responseObservers[idempotencyKey] = observer
        defer { responseObservers.removeValue(forKey: idempotencyKey) }
        return try await operation()
    }

    private func exchange(_ method: String, path: String, body: Data? = nil, id: SandboxExecutionHandleID) async throws -> Data {
        var record = try load(id)
        let sent = UInt64(body?.count ?? 0)
        let limit = record.request.requirement.budget.limits
        guard sent <= limit[.networkRequestBytes] - min(limit[.networkRequestBytes], record.requestBytes ?? 0) else {
            throw AgentContractError.budgetExceeded(dimension: .networkRequestBytes, limit: limit[.networkRequestBytes], requested: sent)
        }
        record.requestBytes = (record.requestBytes ?? 0) + sent
        try save(record)
        let bytes = try await client.request(method, path: path, body: body,
            maximumResponseBytes: limit[.networkResponseBytesPerOperation],
            onResponseBytes: { [self] count in try await consumeResponse(count, id: id) })
        record = try load(id)
        record.largestResponse = max(record.largestResponse ?? 0, UInt64(bytes.count))
        try save(record)
        return bytes
    }

    private func consumeResponse(_ count: UInt64, id: SandboxExecutionHandleID) async throws {
        var record = try load(id)
        let limit = record.request.requirement.budget.limits[.networkResponseBytesTotal]
        guard count <= limit - min(limit, record.responseBytes ?? 0) else {
            throw AgentContractError.budgetExceeded(dimension: .networkResponseBytesTotal, limit: limit, requested: count)
        }
        record.responseBytes = (record.responseBytes ?? 0) + count
        try save(record)
        try await responseObservers[record.key]?(count)
    }

    public init(connection: OpenSandboxConnection, scopeID: UUID, directory: URL,
                apiKey: @escaping @Sendable () -> String?, sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        self.connection = connection
        workspaceID = SandboxWorkspaceHandleID(rawValue: scopeID)
        self.directory = directory.appendingPathComponent(scopeID.uuidString, isDirectory: true)
        client = OpenSandboxHTTPClient(connection: connection, apiKey: apiKey, sessionConfiguration: sessionConfiguration)
        descriptor = try AgentSandboxProviderDescriptor(providerID: "opensandbox." + connection.id.uuidString.lowercased(),
            displayName: "OpenSandbox", implementationVersion: SemanticVersion("1.0.0")!,
            supportedProtocolVersions: [AgentContractVersion.currentProtocol], trustRevision: 1)
        maximumAuthority = try AgentAuthorityScope(capabilities: AgentCapabilitySet([.localRead, .localWrite, .codeExecution, .networkRead]),
            destinations: [connection.destination] + connection.networkDestinations,
            dataCategories: [OpenSandboxConnection.dataCategory], workspaceIDs: [workspaceID])
        var limits = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, UInt64(0)) })
        limits.merge([
            .activeMilliseconds: 180_000, .networkRequestBytes: 300_000,
            .networkResponseBytesPerOperation: 1_048_576, .networkResponseBytesTotal: 2_097_152,
            .generatedArtifactBytes: 8_388_608, .persistedOutputBytes: 8_388_608, .peakMemoryBytes: 2_147_483_648
        ], uniquingKeysWith: { _, maximum in maximum })
        maximumBudget = try AgentBudget(limits: BudgetQuantities(limits),
            maximumThermalState: .critical, memoryPressureResponse: .pause)
    }

    public func capabilities() async throws -> SandboxCapabilities { try report() }

    public func negotiate() throws -> NegotiatedSandboxCapabilities {
        let report = try report()
        return try RegisteredSandboxProviderPolicy(providerID: descriptor.providerID, descriptorFingerprint: descriptor.fingerprint,
            trustRevision: 1, allowedProtocolVersions: descriptor.supportedProtocolVersions, allowedFeatures: report.features,
            maximumAuthority: maximumAuthority, maximumBudget: maximumBudget, maximumConcurrentExecutions: 1, policyRevision: 1)
            .negotiate(descriptor: descriptor, capabilities: report)
    }

    private func report() throws -> SandboxCapabilities {
        var features: [SandboxFeature] = [.cancellation, .progressEvents, .structuredOutput, .workspaceReuse]
        if connection.capabilities.contains(.codeExecution) { features.append(.codeExecution) }
        if connection.capabilities.contains(.workspaceFiles) { features += [.filesystemRead, .filesystemWrite] }
        if !connection.allowedHosts.isEmpty { features.append(.networkAccess) }
        // Process checkpointing and arbitrary process-limit negotiation are not advertised.
        return try SandboxCapabilities(providerID: descriptor.providerID, descriptorFingerprint: descriptor.fingerprint,
            supportedProtocolVersions: descriptor.supportedProtocolVersions, features: features, maximumAuthority: maximumAuthority,
            maximumBudget: maximumBudget, maximumConcurrentExecutions: 1, reportRevision: 1)
    }

    public func start(_ request: SandboxExecutionRequest, idempotencyKey: String) async throws -> SandboxExecutionHandleID {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".closed").path) else {
            throw OpenSandboxError.unavailable
        }
        guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256,
              request.negotiatedCapabilities == (try negotiate()), request.requirement.checkpointID == nil,
              request.requirement.workspaceID == nil || request.requirement.workspaceID == workspaceID,
              request.inputArtifacts.isEmpty, request.requirement.secretReferences.isEmpty,
              request.requirement.process == nil,
              request.requirement.filesystem.allSatisfy({ $0.logicalRoot == "sandbox.workspace" })
        else { throw AgentSandboxAPIError.requestBindingMismatch }
        let digest = StableDigest.fingerprint(domain: "opensandbox-operation.v1", components: [
            Data(connection.fingerprint.rawValue.utf8), Data(workspaceID.description.utf8), Data(idempotencyKey.utf8)])
        let hex = digest.rawValue
        let text = Array(hex)
        let uuid = String(text[0..<8]) + "-" + String(text[8..<12]) + "-" + String(text[12..<16]) + "-"
            + String(text[16..<20]) + "-" + String(text[20..<32])
        let id = SandboxExecutionHandleID(rawValue: UUID(uuidString: uuid)!)
        if let existing = try existing(id) {
            guard existing.key == idempotencyKey, existing.request.fingerprint == request.fingerprint else {
                throw AgentSandboxAPIError.idempotencyConflict
            }
            return id
        }
        let accepted = try AgentTimestamp(Date())
        let status = try SandboxExecutionStatus(handleID: id, stateVersion: 1, state: .accepted, acceptedAt: accepted, updatedAt: accepted)
        let first = try SandboxEventRecord(eventID: SandboxEventID(), handleID: id, sequence: 1, timestamp: accepted,
            status: status, event: .accepted(requestFingerprint: request.fingerprint), previousRecordDigest: nil)
        try save(Record(id: id, key: idempotencyKey, connectionFingerprint: connection.fingerprint,
            request: request, events: [first]))
        starting.insert(id)
        defer { starting.remove(id) }
        let payload = try JSONDecoder().decode(JSONValue.self, from: request.sanitizedPayload.value.data)
        let timeout = min(120, max(1, request.requirement.budget.limits[.activeMilliseconds] / 1_000))
        let body = try CanonicalJSON(.object(["workspaceID": .string(workspaceID.description),
            "requestFingerprint": .string(request.fingerprint.rawValue), "payload": payload, "timeoutSeconds": .integer(Int64(timeout))]))
        do {
            let data = try await exchange("POST", path: "v1/operations/" + id.description, body: body.data, id: id)
            try install(JSONDecoder().decode(OpenSandboxJob.self, from: data), for: id)
        } catch {
            // No automatic POST retry. A durable handle survives ambiguous submission and remains inspectable.
            let confirmedRejection: Bool
            if case OpenSandboxError.http(let code) = error { confirmedRejection = [400, 401, 403, 409, 413, 422, 429].contains(code) }
            else { confirmedRejection = false }
            try finishFailure(id, message: error.localizedDescription, uncertain: !confirmedRejection)
        }
        return id
    }

    public func attach(to id: SandboxExecutionHandleID) async throws -> any SandboxExecutionHandle {
        _ = try load(id)
        return OpenSandboxHandle(id: id, provider: self)
    }

    public func closeWorkspace() async throws {
        let marker = directory.appendingPathComponent(".closed")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        _ = try await client.request("DELETE", path: "v1/workspaces/" + workspaceID.description)
        if FileManager.default.fileExists(atPath: directory.path) {
            try Data().write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    func status(_ id: SandboxExecutionHandleID) async throws -> SandboxExecutionStatus {
        try await refresh(id)
        return try load(id).events.last!.status
    }

    func result(_ id: SandboxExecutionHandleID) async throws -> SandboxExecutionResult? {
        try await refresh(id)
        if case .terminal(let value) = try load(id).events.last!.event { return value }
        return nil
    }

    func events(_ id: SandboxExecutionHandleID, after cursor: AgentEventCursor?) async throws -> [SandboxEventRecord] {
        try await refresh(id)
        let record = try load(id)
        if let cursor {
            guard let event = record.events.first(where: { $0.sequence == cursor.sequence }),
                  try event.cursor == cursor else { throw AgentSandboxAPIError.invalidCursor }
        }
        return record.events.filter { $0.sequence > (cursor?.sequence ?? 0) }
    }

    private func refresh(_ id: SandboxExecutionHandleID) async throws {
        let record = try load(id)
        if record.events.last!.status.state.isTerminal || starting.contains(id) { return }
        do {
            let data = try await exchange("GET", path: "v1/operations/" + id.description, id: id)
            try install(JSONDecoder().decode(OpenSandboxJob.self, from: data), for: id)
        } catch OpenSandboxError.http(404) {
            try finishFailure(id, message: "The environment has no matching operation after recovery. Its earlier submission was not replayed.", uncertain: true)
        }
    }

    private func install(_ job: OpenSandboxJob, for id: SandboxExecutionHandleID) throws {
        guard job.operationID == id.rawValue, job.workspaceID == workspaceID.rawValue, job.version > 0 else {
            throw OpenSandboxError.identityMismatch
        }
        var record = try load(id)
        guard !record.events.last!.status.state.isTerminal, job.version >= (record.remote?.version ?? 0) else { return }
        record.remote = job
        if job.submitted, record.events.last!.status.state == .accepted {
            try append(&record, state: .running, event: .started)
        }
        if job.state == "cancelling", record.events.last!.status.state != .cancellationRequested {
            try append(&record, state: .cancellationRequested, event: .audit(try SandboxAuditRecord(category: "execution", action: "cancel-requested")))
        }
        let state: SandboxExecutionState?
        switch job.state {
        case "completed": state = .completed
        case "failed", "uncertain": state = .failed
        case "cancelled": state = .cancelled
        case "accepted", "starting", "running", "cancelling": state = nil
        default: throw OpenSandboxError.invalidResponse
        }
        if let state {
            var details: [String: String] = ["sandbox.workspace": workspaceID.description, "sandbox.operation": id.description]
            if case .object(let value)? = job.output, case .string(let digest)? = value["sourceDigest"],
               (try? StableDigest(rawValue: digest)) != nil { details["sandbox.source"] = digest }
            let failure = state == .completed ? nil : try Self.failure(job.error ?? "Sandbox execution did not complete",
                uncertain: job.state == "uncertain", cancelled: state == .cancelled, occurred: job.submitted, details: details)
            let timestamp = try AgentTimestamp(Date())
            let previous = record.events.last!
            let status = try SandboxExecutionStatus(handleID: id, stateVersion: previous.status.stateVersion + 1,
                state: state, failure: failure, acceptedAt: previous.status.acceptedAt, updatedAt: timestamp)
            let elapsed = job.finishedAtMS.flatMap { end in job.startedAtMS.map { end >= $0 ? end - $0 : 0 } } ?? 0
            let usage = AgentUsage(quantities: BudgetQuantities([.activeMilliseconds: elapsed,
                .networkRequestBytes: record.requestBytes ?? 0, .networkResponseBytesTotal: record.responseBytes ?? 0,
                .networkResponseBytesPerOperation: record.largestResponse ?? 0]))
            let result = try SandboxExecutionResult(requestID: record.request.requestID, handleID: id, terminalStatus: status,
                structuredOutput: state == .completed ? try job.output.map(CanonicalJSON.init) : nil,
                finalWorkspaceID: workspaceID, usage: usage)
            record.events.append(try SandboxEventRecord(eventID: SandboxEventID(), handleID: id,
                sequence: previous.sequence + 1, timestamp: timestamp, status: status, cumulativeUsage: usage,
                event: .terminal(result), previousRecordDigest: previous.recordDigest))
        }
        try save(record)
    }

    private func append(_ record: inout Record, state: SandboxExecutionState, event: SandboxEvent) throws {
        let previous = record.events.last!, timestamp = try AgentTimestamp(Date())
        let status = try SandboxExecutionStatus(handleID: record.id, stateVersion: previous.status.stateVersion + 1,
            state: state, acceptedAt: previous.status.acceptedAt, updatedAt: timestamp)
        record.events.append(try SandboxEventRecord(eventID: SandboxEventID(), handleID: record.id,
            sequence: previous.sequence + 1, timestamp: timestamp, status: status, event: event, previousRecordDigest: previous.recordDigest))
    }

    private func finishFailure(_ id: SandboxExecutionHandleID, message: String, uncertain: Bool) throws {
        var record = try load(id)
        guard !record.events.last!.status.state.isTerminal else { return }
        let previous = record.events.last!, timestamp = try AgentTimestamp(Date())
        let status = try SandboxExecutionStatus(handleID: id, stateVersion: previous.status.stateVersion + 1, state: .failed,
            failure: Self.failure(message, uncertain: uncertain), acceptedAt: previous.status.acceptedAt, updatedAt: timestamp)
        let result = try SandboxExecutionResult(requestID: record.request.requestID, handleID: id, terminalStatus: status, finalWorkspaceID: workspaceID)
        record.events.append(try SandboxEventRecord(eventID: SandboxEventID(), handleID: id, sequence: previous.sequence + 1,
            timestamp: timestamp, status: status, event: .terminal(result), previousRecordDigest: previous.recordDigest))
        try save(record)
    }

    func send(_ envelope: SandboxCommandEnvelope) async throws -> SandboxCommandReceipt {
        let command = envelope.payload
        var record = try load(command.handleID)
        if let old = record.cancellations[command.commandID.description] {
            guard old.fingerprint == command.fingerprint else { throw AgentSandboxAPIError.idempotencyConflict }
            if let receipt = old.receipt { return receipt }
        } else {
            try await refresh(command.handleID)
            record = try load(command.handleID)
            let current = record.events.last!.status
            guard command.expectedStateVersion == current.stateVersion else { throw AgentSandboxAPIError.staleCommand }
            guard !current.state.isTerminal, let remote = record.remote else { throw AgentSandboxAPIError.terminalExecution }
            record.cancellations[command.commandID.description] = CancelEntry(fingerprint: command.fingerprint, remoteVersion: remote.version)
            try save(record)
        }
        let expected = record.cancellations[command.commandID.description]!.remoteVersion
        let body = try CanonicalJSON(.object(["commandID": .string(command.commandID.description), "expectedVersion": .integer(Int64(expected))]))
        let data = try await exchange("POST", path: "v1/operations/" + command.handleID.description + "/cancel",
            body: body.data, id: command.handleID)
        try install(JSONDecoder().decode(OpenSandboxJob.self, from: data), for: command.handleID)
        record = try load(command.handleID)
        let receipt = try SandboxCommandReceipt(commandID: command.commandID, commandFingerprint: command.fingerprint,
            handleID: command.handleID, disposition: .accepted, currentStatus: record.events.last!.status)
        record.cancellations[command.commandID.description]!.receipt = receipt
        if !record.events.last!.status.state.isTerminal {
            let previous = record.events.last!, timestamp = try AgentTimestamp(Date())
            record.events.append(try SandboxEventRecord(eventID: SandboxEventID(), handleID: command.handleID,
                sequence: previous.sequence + 1, timestamp: timestamp, status: previous.status,
                event: .commandProcessed(receipt), previousRecordDigest: previous.recordDigest))
        }
        try save(record)
        return receipt
    }

    static func failure(_ message: String, uncertain: Bool = false, cancelled: Bool = false, occurred: Bool = false,
                        details: [String: String] = [:]) throws -> AgentFailure {
        let safe = String(String.UnicodeScalarView(message.unicodeScalars.prefix(400).map {
            CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return try AgentFailure(code: "sandbox.opensandbox.execution",
            classification: uncertain ? .potentiallySideEffecting : cancelled ? .cancelled : .permanent,
            safeMessage: safe.isEmpty ? "Sandbox execution failed" : safe, retryAdvice: .never,
            externalEffect: uncertain ? .uncertain : occurred ? .confirmedApplied : .confirmedNone,
            requiredUserAction: uncertain ? .reconcile : .none,
            details: details,
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1))
    }

    private func existing(_ id: SandboxExecutionHandleID) throws -> Record? {
        if let value = records[id] { return value }
        let path = directory.appendingPathComponent(id.description + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
        guard value.id == id, value.connectionFingerprint == connection.fingerprint else { throw OpenSandboxError.identityMismatch }
        var previous: StableDigest?
        for (index, event) in value.events.enumerated() {
            guard event.handleID == id, event.sequence == UInt64(index + 1), event.previousRecordDigest == previous else {
                throw AgentSandboxAPIError.invalidEventChain
            }
            previous = event.recordDigest
        }
        guard !value.events.isEmpty else { throw AgentSandboxAPIError.invalidEventChain }
        records[id] = value
        return value
    }
    private func load(_ id: SandboxExecutionHandleID) throws -> Record {
        guard let value = try existing(id) else { throw AgentSandboxAPIError.executionNotFound }
        return value
    }
    private func save(_ value: Record) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var local = directory
        var metadata = URLResourceValues(); metadata.isExcludedFromBackup = true
        try local.setResourceValues(metadata)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let path = directory.appendingPathComponent(value.id.description + ".json")
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
        #endif
        records[value.id] = value
    }
}

private struct OpenSandboxHandle: SandboxExecutionHandle {
    let id: SandboxExecutionHandleID
    let provider: OpenSandboxProvider
    func status() async throws -> SandboxExecutionStatus { try await provider.status(id) }
    func result() async throws -> SandboxExecutionResult? { try await provider.result(id) }
    func send(_ command: SandboxCommandEnvelope) async throws -> SandboxCommandReceipt {
        guard command.payload.handleID == id else { throw AgentSandboxAPIError.requestBindingMismatch }
        return try await provider.send(command)
    }
    func events(after cursor: AgentEventCursor?) -> AsyncThrowingStream<SandboxEventEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cursor = cursor
                    while !Task.isCancelled {
                        let events = try await provider.events(id, after: cursor)
                        for event in events {
                            continuation.yield(try SandboxEventEnvelope(payload: event))
                            cursor = try event.cursor
                            if event.status.state.isTerminal { continuation.finish(); return }
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
