// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import LLMCore
import XCTest

// TEST-ID: AHT-MCP-001
final class MCPToolV2AdapterTests: XCTestCase {
    private let attestor = try! LocalSanitizationAttestor(
        key: Data(repeating: 0x3d, count: 32),
        policyRevision: 1
    )

    func testDescriptorAndPlanCarryConservativeRemotePosture() async throws {
        let stableID = UUID()
        let server = MCPServer(name: "stub", url: "https://mcp.test/mcp")
        let spec = MCPToolSpec(
            name: "remote_lookup",
            description: "Look up remotely",
            inputSchemaJSON: #"{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}"#
        )
        let adapter = try MCPToolV2Adapter(
            client: MCPClient(server: server),
            spec: spec,
            serverStableID: stableID,
            trustRevision: "mcp.v1"
        )

        XCTAssertEqual(adapter.descriptor.effects, [.unknownExternal])
        XCTAssertEqual(adapter.descriptor.retryPolicy, .never)
        XCTAssertEqual(adapter.descriptor.idempotency, .nonIdempotent)
        XCTAssertEqual(adapter.descriptor.id.logicalID.providerID, "mcp.\(stableID.uuidString)")
        XCTAssertEqual(adapter.descriptor.id.logicalID.name, "remote_lookup")

        let prepared = try await adapter.prepare(
            request: try makeRequest(descriptor: adapter.descriptor),
            context: try makePreparationContext(serverStableID: stableID)
        )
        let plan = prepared.externalOperation.plan
        XCTAssertEqual(plan.kind, .mcp)
        XCTAssertEqual(
            plan.destination,
            try ExternalDestination(kind: .mcpServer, normalizedIdentity: stableID.uuidString)
        )
        XCTAssertEqual(plan.effects, [.unknownExternal])
        XCTAssertEqual(plan.retryPolicy, .never)
        XCTAssertEqual(plan.idempotency, .nonIdempotent)
        XCTAssertTrue(plan.userPreview.contains("remote_lookup"))
        XCTAssertEqual(plan.descriptorID, adapter.descriptor.id.description)
    }

    func testDiscoveryCacheGatesDescriptorsByExplicitDiscoveryAndSettings() throws {
        let defaults = UserDefaults(suiteName: "mcp-discovery-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "") }
        let cache = MCPDiscoveryCache(defaults: defaults)
        let stableID = UUID()
        let server = MCPServer(name: "stub", url: "https://mcp.test/mcp", stableID: stableID)
        let specA = MCPToolSpec(name: "alpha", description: "a", inputSchemaJSON: "{}")
        let specB = MCPToolSpec(name: "beta", description: "b", inputSchemaJSON: "{}")

        XCTAssertTrue(cache.descriptors(for: [server]).isEmpty,
                      "never-discovered servers must not advertise tools during prompt compilation")

        cache.update(server: server, specs: [specA, specB])
        let names = cache.descriptors(for: [server]).map(\.id.logicalID.name)
        XCTAssertEqual(Set(names), Set(["alpha", "beta"]))

        var muted = server
        muted.disabledTools = ["beta"]
        XCTAssertEqual(cache.descriptors(for: [muted]).map(\.id.logicalID.name), ["alpha"])

        var disabled = server
        disabled.isEnabled = false
        XCTAssertTrue(cache.descriptors(for: [disabled]).isEmpty, "disabled servers are not advertised")

        cache.upsert(server: disabled)
        XCTAssertEqual(cache.specs(serverStableID: stableID).count, 2,
                       "upsert must preserve discovered specs across setting changes")
        cache.remove(serverStableID: stableID)
        XCTAssertTrue(cache.descriptors(for: [server]).isEmpty)

        // Discovery results survive relaunch: a fresh cache over the same defaults restores them.
        cache.update(server: server, specs: [specA])
        let reloaded = MCPDiscoveryCache(defaults: defaults)
        XCTAssertEqual(
            reloaded.descriptors(for: [server]).map(\.id.logicalID.name),
            ["alpha"],
            "explicit discovery must persist across app relaunches without reconnecting"
        )
    }

    func testExecuteSuccessConsumesBoundaryAndReturnsText() async throws {
        let (adapter, prepared, authorized, context) = try await makeExecutableAdapter(
            transcript: MCPCannedTranscript.success
        )
        let outcome = try await ToolExecutor().execute(
            tool: adapter,
            authorized: authorized,
            context: context
        )
        guard case .completed(let results) = outcome,
              case .text(let text) = results.first
        else { return XCTFail("expected completed text, got \(outcome)") }
        XCTAssertEqual(text.value, "MCP_RESULT_OK")
        XCTAssertNotNil(prepared)
    }

    func testTransportLossAfterIntentBecomesUncertainReconciliation() async throws {
        let (adapter, _, authorized, context) = try await makeExecutableAdapter(
            transcript: MCPCannedTranscript.http500
        )
        let outcome = try await ToolExecutor().execute(
            tool: adapter,
            authorized: authorized,
            context: context
        )
        guard case .uncertain(let failure) = outcome else {
            return XCTFail("expected uncertain outcome, got \(outcome)")
        }
        XCTAssertEqual(failure.code, "tool.mcp.transport-uncertain")
        XCTAssertEqual(failure.externalEffect, .uncertain)
        XCTAssertEqual(failure.classification, .potentiallySideEffecting)
    }

    func testBadURLIsConfirmedFailureWithoutUncertainty() async throws {
        let badServer = MCPServer(name: "bad", url: "not a url")
        let stableID = UUID()
        let spec = MCPToolSpec(name: "remote_lookup", description: "d", inputSchemaJSON: "{}")
        let adapter = try MCPToolV2Adapter(
            client: MCPClient(server: badServer),
            spec: spec,
            serverStableID: stableID,
            trustRevision: "mcp.v1"
        )
        let prepared = try await adapter.prepare(
            request: try makeRequest(descriptor: adapter.descriptor),
            context: try makePreparationContext(serverStableID: stableID)
        )
        let (authorized, context) = try makeAuthorized(prepared: prepared)
        let outcome = try await ToolExecutor().execute(tool: adapter, authorized: authorized, context: context)
        guard case .failed(let failure) = outcome else {
            return XCTFail("expected failed outcome, got \(outcome)")
        }
        XCTAssertEqual(failure.code, "tool.mcp.invalid-url")
        XCTAssertEqual(failure.externalEffect, .confirmedNone)
    }

    // MARK: - Fixtures

    private func makeExecutableAdapter(
        transcript: MCPCannedTranscript
    ) async throws -> (
        MCPToolV2Adapter,
        PreparedToolInvocation,
        AuthorizedToolInvocation,
        ToolExecutionContext
    ) {
        let stableID = UUID()
        let server = MCPServer(name: "stub", url: "https://mcp.test/mcp", stableID: stableID)
        let spec = MCPToolSpec(
            name: "remote_lookup",
            description: "Look up remotely",
            inputSchemaJSON: #"{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}"#
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPCannedProtocol.self]
        MCPCannedProtocol.transcript = transcript
        let session = URLSession(configuration: configuration)
        let adapter = try MCPToolV2Adapter(
            client: MCPClient(server: server, session: session),
            spec: spec,
            serverStableID: stableID,
            trustRevision: "mcp.v1"
        )
        let prepared = try await adapter.prepare(
            request: try makeRequest(descriptor: adapter.descriptor),
            context: try makePreparationContext(serverStableID: stableID)
        )
        let (authorized, context) = try makeAuthorized(prepared: prepared)
        return (adapter, prepared, authorized, context)
    }

    private func makeAuthorized(
        prepared: PreparedToolInvocation
    ) throws -> (AuthorizedToolInvocation, ToolExecutionContext) {
        let plan = prepared.externalOperation.plan
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.unknownExternal]),
            destinations: [plan.destination].compactMap { $0 } + plan.allowedFallbacks,
            dataCategories: plan.dataCategories
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        let trusted = try TrustedRunAuthority(
            runID: prepared.externalOperation.runID,
            ceiling: ceiling,
            policyRevision: 1
        )
        let receipt = try ApprovalReceipt(
            id: ApprovalID(),
            prepared: prepared.externalOperation,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1_000)
        )
        let authorization = try AuthorizedExternalOperationRequest(
            prepared: prepared.externalOperation,
            authorization: receipt,
            trustedRunAuthority: trusted
        )
        let authorized = try AuthorizedToolInvocation(
            prepared: prepared,
            authorization: authorization
        )
        let context = try ToolExecutionContext(
            authorized: authorized,
            deadline: AgentTimestamp(rawValue: 60_000),
            attemptNumber: 1,
            budgetReservationID: BudgetReservationID(),
            cancellation: TestNeverCancelled(),
            artifactWriter: TestRejectingArtifactWriter(),
            logger: TestRecordingLogger(),
            authorizationClock: TestFixedAuthorizationClock(),
            authorizationPolicyValidator: try DefaultApprovalPolicyEngine(
                policyVersion: 1,
                sanitizationValidator: attestor
            ),
            attemptLedger: TestAlwaysClaimableAttemptLedger()
        )
        return (authorized, context)
    }

    private func makeRequest(descriptor: AgentToolDescriptor) throws -> ToolExecutionRequest {
        let arguments = try CanonicalJSON(.object(["q": .string("hello")]))
        let sanitized = try attestor.attest(
            value: arguments,
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        return try ToolExecutionRequest(
            proposedCall: ProposedToolCall(
                invocationID: ToolInvocationID(rawValue: UUID()),
                toolID: descriptor.id.logicalID,
                arguments: arguments
            ),
            descriptor: descriptor,
            sanitizedArguments: sanitized
        )
    }

    private func makePreparationContext(serverStableID: UUID) throws -> ToolPreparationContext {
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.unknownExternal]),
            destinations: [try ExternalDestination(
                kind: .mcpServer,
                normalizedIdentity: serverStableID.uuidString
            )],
            dataCategories: [try AgentDataCategory(rawValue: "mcp.call")]
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        return ToolPreparationContext(
            requestID: AgentRequestID(rawValue: UUID()),
            runID: AgentRunID(rawValue: UUID()),
            conversationID: ConversationID(rawValue: UUID()),
            stepID: AgentStepID(rawValue: UUID()),
            capabilityGrant: try StepCapabilityGrant(runCeiling: ceiling, authority: authority)
        )
    }
}

// MARK: - Canned MCP transcript protocol

private enum MCPCannedTranscript {
    case success
    case http500
}

private final class MCPCannedProtocol: URLProtocol {
    nonisolated(unsafe) static var transcript: MCPCannedTranscript = .success

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(request)
        let method = body["method"] as? String ?? ""
        let id = body["id"] as? Int
        let status: Int
        let headers: [String: String]
        let payload: Data
        switch method {
        case "initialize":
            status = 200
            headers = ["Content-Type": "application/json"]
            payload = Self.result(id: id, [
                "protocolVersion": "2025-11-25",
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "1"],
            ])
        case "notifications/initialized":
            status = 202
            headers = ["Content-Type": "application/json"]
            payload = Data()
        case "tools/call":
            switch Self.transcript {
            case .success:
                status = 200
                headers = ["Content-Type": "application/json"]
                payload = Self.result(id: id, [
                    "content": [["type": "text", "text": "MCP_RESULT_OK"]],
                ])
            case .http500:
                status = 500
                headers = ["Content-Type": "application/json"]
                payload = Data()
            }
        default:
            status = 400
            headers = ["Content-Type": "application/json"]
            payload = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func result(id: Int?, _ result: [String: Any]) -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { object["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func readBody(_ request: URLRequest) -> [String: Any] {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            let size = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        } else if let body = request.httpBody {
            data = body
        }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

// MARK: - Minimal execution helpers

private struct TestNeverCancelled: ToolCancellationChecking {
    func isCancelled() async -> Bool { false }
}

private struct TestRejectingArtifactWriter: ToolArtifactWriting {
    func commit(
        data: Data,
        mimeType: String,
        semanticType: String?,
        retention: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification
    ) async throws -> ArtifactReference {
        throw AgentContractError.authorizationDenied
    }
}

private actor TestRecordingLogger: ToolRedactedLogging {
    private var storage: [String] = []
    func record(code: String, metadata: [String: String]) async {
        storage.append(code)
    }
}

private struct TestFixedAuthorizationClock: AgentAuthorizationClock {
    func now() async throws -> AgentTimestamp { AgentTimestamp(rawValue: 1_000) }
}

private struct TestAlwaysClaimableAttemptLedger: ExternalOperationAttemptClaiming {
    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool { true }
}
