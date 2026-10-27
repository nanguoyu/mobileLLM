// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import AgentSandboxAPI
import Foundation

/// Secrets stay in the app's credential resolver; this value is never encoded into a run.
public struct OpenSandboxCredentials: Sendable {
    public let connection: OpenSandboxConnection
    public let apiKey: String
    public init(connection: OpenSandboxConnection, apiKey: String) { self.connection = connection; self.apiKey = apiKey }
}

public enum OpenSandboxToolOperation: String, CaseIterable, Sendable {
    case write = "sandbox_write_files", read = "sandbox_read_file", list = "sandbox_list_files"
    case run = "sandbox_run", start = "sandbox_start", process = "sandbox_process", stop = "sandbox_stop"
    case browser = "sandbox_browser", export = "sandbox_export"
    var action: String { self == .run ? "exec" : String(describing: self) }
}

public actor OpenSandboxToolService {
    private let repository: any RuntimeRepository
    private let directory: URL
    private let resolve: @Sendable (String) -> OpenSandboxCredentials?
    private let sanitizer: LocalSanitizationAttestor
    private var providers: [String: OpenSandboxProvider] = [:]

    public init(repository: any RuntimeRepository, directory: URL, sanitizer: LocalSanitizationAttestor,
                credentials: @escaping @Sendable (String) -> OpenSandboxCredentials?) {
        self.repository = repository; self.directory = directory; self.sanitizer = sanitizer; resolve = credentials
    }

    public func adapter(for descriptor: AgentToolDescriptorID) throws -> (any ToolV2)? {
        guard descriptor.logicalID.providerID == "sandbox", let operation = OpenSandboxToolOperation(rawValue: descriptor.logicalID.name),
              let credentials = resolve(descriptor.trustRevision) else { return nil }
        let result = try OpenSandboxTool(operation: operation, connection: credentials.connection, service: self)
        return result.descriptor.id == descriptor ? result : nil
    }

    func binding(request: ToolExecutionRequest, context: ToolPreparationContext,
                 operation: OpenSandboxToolOperation, connection: OpenSandboxConnection) async throws -> Binding {
        guard resolve(connection.fingerprint.rawValue)?.connection == connection,
              let owner = try await repository.loadRunFacts(for: context.runID)?.submission?.request.payload,
              owner.id == context.requestID, owner.conversationID == context.conversationID,
              owner.capabilityCeiling == context.capabilityGrant.runCeiling,
              context.capabilityGrant.authority.workspaceIDs.count == 1,
              let workspace = context.capabilityGrant.authority.workspaceIDs.first else { throw OpenSandboxError.unavailable }
        let key = connection.fingerprint.rawValue + ":" + workspace.description
        let provider: OpenSandboxProvider
        if let cached = providers[key] { provider = cached }
        else {
            let resolver = resolve
            provider = try OpenSandboxProvider(connection: connection, scopeID: workspace.rawValue,
                directory: directory.appendingPathComponent(connection.id.uuidString),
                apiKey: { resolver(connection.fingerprint.rawValue)?.apiKey })
            providers[key] = provider
        }
        let negotiated = try await provider.negotiate()
        let values = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map {
            ($0, min(owner.budget.limits[$0], provider.maximumBudget.limits[$0]))
        })
        let budget = try AgentBudget(limits: BudgetQuantities(values), maximumThermalState: owner.budget.maximumThermalState,
            memoryPressureResponse: owner.budget.memoryPressureResponse)
        let authority = provider.maximumAuthority
        guard authority.isSubset(of: context.capabilityGrant.authority) else { throw AgentSandboxAPIError.authorityOrBudgetExpansion }
        var roots: [SandboxFilesystemRequirement] = []
        if [.write, .read, .list, .export].contains(operation) {
            roots = [try SandboxFilesystemRequirement(logicalRoot: "sandbox.workspace", access: operation == .write ? .readWrite : .readOnly,
                maximumWrittenBytes: operation == .write ? min(262_144, budget.limits[.generatedArtifactBytes]) : 0)]
        }
        let requirement = try SandboxRequirement(minimumProtocolVersion: AgentContractVersion.currentProtocol,
            workspaceID: workspace, authority: authority, budget: budget, filesystem: roots,
            networkDestinations: connection.networkDestinations)
        guard case .object(var payload) = try JSONDecoder().decode(JSONValue.self, from: request.sanitizedArguments.value.data) else {
            throw ToolV2ContractError.invalidArguments
        }
        payload["action"] = .string(operation.action)
        let sanitized = try sanitizer.sanitize(CanonicalJSON(.object(payload)), referencedSecretIDs: [],
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1))
        return Binding(provider: provider, requirement: requirement, parentBudget: owner.budget,
            negotiated: negotiated, payload: sanitized)
    }

    public func close(workspaceID: UUID) async throws {
        try restoreOwnedProviders(workspaceID: workspaceID)
        for provider in providers.values where provider.workspaceID.rawValue == workspaceID { try await provider.closeWorkspace() }
    }

    public func closeAll() async throws {
        try restoreOwnedProviders(workspaceID: nil)
        for provider in providers.values { try await provider.closeWorkspace() }
    }

    /// Reconstruct only scopes with this app's durable execution records. Never enumerate or close
    /// all workspaces on a shared server. A removed credential produces an explicit cleanup error.
    private func restoreOwnedProviders(workspaceID: UUID?) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        struct Header: Decodable { let connectionFingerprint: StableDigest }
        func children(_ path: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isSymbolicLinkKey])
                .filter { try $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true }
        }
        for server in try children(directory) {
            guard let serverID = UUID(uuidString: server.lastPathComponent) else { continue }
            for scope in try children(server) {
                guard let id = UUID(uuidString: scope.lastPathComponent), workspaceID == nil || workspaceID == id else { continue }
                if FileManager.default.fileExists(atPath: scope.appendingPathComponent(".closed").path) { continue }
                guard let file = try children(scope).first(where: { $0.pathExtension == "json" }) else { continue }
                let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: file))
                let key = header.connectionFingerprint.rawValue + ":" + SandboxWorkspaceHandleID(rawValue: id).description
                if providers[key] != nil { continue }
                guard let credentials = resolve(header.connectionFingerprint.rawValue), credentials.connection.id == serverID else {
                    throw OpenSandboxError.unavailable
                }
                let resolver = resolve, fingerprint = header.connectionFingerprint.rawValue
                providers[key] = try OpenSandboxProvider(connection: credentials.connection, scopeID: id, directory: server,
                    apiKey: { resolver(fingerprint)?.apiKey })
            }
        }
    }

    struct Binding: Sendable {
        let provider: OpenSandboxProvider
        let requirement: SandboxRequirement
        let parentBudget: AgentBudget
        let negotiated: NegotiatedSandboxCapabilities
        let payload: SanitizedCanonicalJSON
    }
}

public struct OpenSandboxTool: ToolV2 {
    public let descriptor: AgentToolDescriptor
    private let operation: OpenSandboxToolOperation
    private let connection: OpenSandboxConnection
    private let service: OpenSandboxToolService

    public static func descriptors(connection: OpenSandboxConnection) throws -> [AgentToolDescriptor] {
        try OpenSandboxToolOperation.allCases.filter {
            connection.capabilities.contains(.codeExecution)
                && (![.write, .read, .list, .export].contains($0) || connection.capabilities.contains(.workspaceFiles))
                && ($0 != .browser || connection.capabilities.contains(.applicationInspection))
        }.map { try descriptor($0, connection: connection) }
    }

    private static func descriptor(_ operation: OpenSandboxToolOperation, connection: OpenSandboxConnection) throws -> AgentToolDescriptor {
        func string(_ max: Int) -> JSONValue { .object(["type": .string("string"), "maxLength": .integer(Int64(max))]) }
        func integer(_ min: Int, _ max: Int) -> JSONValue { .object(["type": .string("integer"), "minimum": .integer(Int64(min)), "maximum": .integer(Int64(max))]) }
        func object(_ fields: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(fields),
                "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        let fields: [String: JSONValue]
        let summary: String
        switch operation {
        case .write:
            fields = ["files": .object(["type": .string("array"), "minItems": .integer(1), "maxItems": .integer(8),
                "items": object(["path": string(512), "content": string(131_072),
                    "expectedSHA256": .object(["anyOf": .array([string(64), .object(["type": .string("null")])])])])])]
            summary = "Write up to eight project files in this goal's isolated workspace. Paths are relative. For a new file use expectedSHA256=null; to replace an existing file, first read its current SHA256. Batch limit 128 KiB."
        case .read:
            fields = ["path": string(512), "offset": integer(0, 8_388_608)]
            summary = "Read original workspace text and its SHA256. offset is a UTF-8 byte boundary; start at 0, then use nextOffset for a truncated file."
        case .list:
            fields = ["path": string(512)]; summary = "List this goal's project files. Use '.' for the project root."
        case .run:
            fields = ["command": string(131_072), "timeoutSeconds": integer(1, 120)]
            summary = "Execute a real shell command in /workspace/project. Node, npm, Python, SQLite and Playwright are available. Keep runtime data in MOBILELLM_DATA_DIR (/workspace/data), outside source files. Nonzero exit is a real failure. Output is bounded."
        case .start:
            fields = ["command": string(32_768), "port": integer(1024, 32767)]
            summary = "Start a long-running application server in this workspace and check its HTTP port. Returns an actual process identity; this does not mean the application passed its tests."
        case .process, .stop:
            fields = ["processID": string(36)]
            summary = operation == .stop ? "Stop a previously started process in this goal's workspace." : "Read the actual running/exit state of a process started in this workspace."
        case .browser:
            fields = ["script": string(32_768), "port": integer(1024, 32767)]
            summary = "Run async Python Playwright checks on a started app port. page, context, browser, base_url, expect, json and asyncio.sleep/gather are provided; imports/introspection are not allowed. Use assertions. Exceptions fail the check. Return JSON findings; a screenshot is retained."
        case .export:
            fields = [:]; summary = "Export the current project source as an immutable ZIP artifact, excluding dependency caches and internal logs. The compressed archive is limited to 512 KiB."
        }
        let schema = try JSONSchemaDocument(root: object(fields))
        return try AgentToolDescriptor(id: AgentToolDescriptorID(logicalID: AgentToolLogicalID(providerID: "sandbox", name: operation.rawValue),
            version: SemanticVersion("1.0.0")!, schemaDigest: schema.digest, trustRevision: connection.fingerprint.rawValue),
            title: operation.rawValue, summary: summary, inputSchema: schema, outputSchema: nil,
            effects: [.codeExecution], requiredCapabilities: AgentCapabilitySet([.codeExecution, .localRead, .localWrite, .networkRead]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 180_000), retryPolicy: .never,
            idempotency: .idempotencyKeyRequired, supportsProgress: true, supportsCancellation: true)
    }

    public init(operation: OpenSandboxToolOperation, connection: OpenSandboxConnection, service: OpenSandboxToolService) throws {
        self.operation = operation; self.connection = connection; self.service = service
        descriptor = try Self.descriptor(operation, connection: connection)
    }

    public func prepare(request: ToolExecutionRequest, context: ToolPreparationContext) async throws -> PreparedToolInvocation {
        guard request.descriptor == descriptor else { throw ToolV2ContractError.descriptorMismatch }
        let binding = try await service.binding(request: request, context: context, operation: operation, connection: connection)
        let key = ExternalIdempotencyKey.derive(components: [Data(context.runID.description.utf8), Data(request.proposedCall.invocationID.description.utf8)])
        let plan = try ExternalOperationPlan(kind: .sandbox, subjectID: descriptor.id.logicalID.description,
            canonicalArguments: request.sanitizedArguments, destination: connection.destination,
            dataCategories: [OpenSandboxConnection.dataCategory], payloadDigest: request.sanitizedArguments.fingerprint,
            executionConstraintDigest: binding.requirement.fingerprint,
            effects: descriptor.effects, requiredCapabilities: descriptor.requiredCapabilities,
            maximumRequestBytes: 300_000, maximumResponseBytes: 1_048_576,
            timeoutMilliseconds: 180_000, retryPolicy: .never, idempotency: .idempotencyKeyRequired, idempotencyKey: key,
            userPreview: "Run \(operation.rawValue) in the configured OpenSandbox workspace",
            descriptorID: descriptor.id.description, schemaDigest: descriptor.id.schemaDigest,
            trustRevision: descriptor.id.trustRevision)
        return try PreparedToolInvocation(request: request, context: context, plan: plan)
    }

    public func execute(prepared: AuthorizedToolInvocation, context: ToolExecutionContext) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard prepared.prepared.request.descriptor == descriptor else { throw ToolV2ContractError.executingWrongDescriptor }
                    let external = prepared.prepared.externalOperation, plan = external.plan
                    let binding = try await service.binding(request: prepared.prepared.request,
                        context: ToolPreparationContext(requestID: external.requestID, runID: external.runID,
                            conversationID: external.conversationID, stepID: external.stepID, capabilityGrant: external.capabilityGrant),
                        operation: operation, connection: connection)
                    guard plan.executionConstraintDigest == binding.requirement.fingerprint else { throw AgentSandboxAPIError.requestBindingMismatch }
                    let request = try SandboxExecutionRequest(requestID: external.requestID, runID: external.runID, stepID: external.stepID,
                        requirement: binding.requirement, stepGrant: external.capabilityGrant, parentBudget: binding.parentBudget,
                        negotiatedCapabilities: binding.negotiated, requiredFeatures: [.codeExecution, .structuredOutput, .cancellation],
                        sanitizedPayload: binding.payload, authorization: SandboxAuthorizationReference(
                            approvalID: prepared.authorization.authorization.id, requestID: external.requestID,
                            runID: external.runID, stepID: external.stepID, sanitizedPayloadFingerprint: binding.payload.fingerprint,
                            externalPlanFingerprint: plan.fingerprint, executionConstraintDigest: binding.requirement.fingerprint,
                            negotiatedCapabilitiesFingerprint: binding.negotiated.fingerprint))
                    let boundary = try await context.performBoundary(observation: ExternalOperationObservation(
                        destination: connection.destination, dataCategories: [OpenSandboxConnection.dataCategory], effects: descriptor.effects,
                        requestBytes: UInt64(binding.payload.value.data.count), responseBytesLimit: plan.maximumResponseBytes,
                        payloadDigest: prepared.prepared.request.sanitizedArguments.fingerprint,
                        executionConstraintDigest: binding.requirement.fingerprint, descriptorID: descriptor.id.description,
                        schemaDigest: descriptor.id.schemaDigest, trustRevision: descriptor.id.trustRevision,
                        idempotencyKey: plan.idempotencyKey), operation: { control in
                        let id = try await binding.provider.start(request, idempotencyKey: context.invocationID.description)
                        let handle = try await binding.provider.attach(to: id)
                        let result: SandboxExecutionResult
                        do {
                            var version: UInt64 = 0
                            while true {
                                try Task.checkCancellation()
                                if await context.cancellation.isCancelled() { throw CancellationError() }
                                let status = try await handle.status()
                                if status.stateVersion != version {
                                    version = status.stateVersion
                                    continuation.yield(.progress(try ToolExecutionProgress(completedUnits: version,
                                        message: status.state == .accepted ? "Preparing the execution environment" : "Sandbox: " + status.state.rawValue)))
                                }
                                if status.state.isTerminal, let terminal = try await handle.result() { result = terminal; break }
                                try await Task.sleep(nanoseconds: 250_000_000)
                            }
                        } catch is CancellationError {
                            result = try await Task.detached { try await Self.cancelAndCollect(handle) }.value
                        }
                        let encoded = try CanonicalJSON(JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result)))
                        try await control.consumeResponseBytes(UInt64(encoded.data.count))
                        return try ExternalOperationBoundaryCompletion(value: .canonicalJSON(encoded))
                    })
                    guard case .canonicalJSON(let raw) = boundary.value else { throw OpenSandboxError.invalidResponse }
                    let result = try JSONDecoder().decode(SandboxExecutionResult.self, from: raw.data)
                    if let failure = result.terminalStatus.failure {
                        continuation.yield(.failed(failure)); continuation.finish(); return
                    }
                    guard let output = result.structuredOutput,
                          case .object(var value) = try JSONDecoder().decode(JSONValue.self, from: output.data) else { throw OpenSandboxError.invalidResponse }
                    value["operationID"] = .string(result.handleID.description)
                    value["workspaceID"] = .string(binding.provider.workspaceID.description)
                    value["operation"] = .string(operation.rawValue)
                    var contents: [ToolResultContent] = []
                    if case .string(let encoded)? = value.removeValue(forKey: "screenshotBase64"), let bytes = Data(base64Encoded: encoded) {
                        guard value["screenshotSHA256"] == .string(StableDigest.sha256(bytes).rawValue) else { throw OpenSandboxError.invalidResponse }
                        let artifact = try await context.artifactWriter.commit(data: bytes, mimeType: "image/jpeg",
                            semanticType: "sandbox.browser-screenshot", retention: .run, sensitivity: .sensitive)
                        value["screenshotArtifactID"] = .string(artifact.id.description)
                        contents.append(.image(artifact))
                    }
                    if case .string(let encoded)? = value.removeValue(forKey: "dataBase64"), let bytes = Data(base64Encoded: encoded) {
                        guard value["sha256"] == .string(StableDigest.sha256(bytes).rawValue) else { throw OpenSandboxError.invalidResponse }
                        let artifact = try await context.artifactWriter.commit(data: bytes, mimeType: "application/zip",
                            semanticType: "sandbox.project-source", retention: .run, sensitivity: .sensitive)
                        value["artifactID"] = .string(artifact.id.description)
                        contents.append(.artifact(artifact))
                    }
                    contents.insert(.structured(try ToolStructuredResult(CanonicalJSON(.object(value)))), at: 0)
                    continuation.yield(.completed(try ToolResultCollection(contents)))
                    continuation.finish()
                } catch let error as OpenSandboxToolFailure {
                    continuation.yield(.failed(error.failure)); continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func cancelAndCollect(_ handle: any SandboxExecutionHandle) async throws -> SandboxExecutionResult {
        for _ in 0..<2 {
            let status = try await handle.status()
            if status.state.isTerminal, let result = try await handle.result() { return result }
            let command = try SandboxCommand(commandID: SandboxCommandID(), handleID: handle.id,
                expectedStateVersion: status.stateVersion, action: .cancel, issuedAt: AgentTimestamp(Date()))
            do { _ = try await handle.send(SandboxCommandEnvelope(payload: command)); break }
            catch AgentSandboxAPIError.staleCommand { continue }
        }
        for _ in 0..<20 {
            if let result = try await handle.result() { return result }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OpenSandboxToolFailure(failure: try OpenSandboxProvider.failure("Cancellation was requested but the final execution state is not confirmed.", uncertain: true))
    }
}

private struct OpenSandboxToolFailure: Error, Sendable { let failure: AgentFailure }
