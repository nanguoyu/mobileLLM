// SPDX-License-Identifier: MIT

// TEST-ID: AHT-CONTEXT-APP-001
import Foundation
import XCTest
@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
@testable import mobileLLM
@testable import MobileLLMUI
@testable import LLMCore
import AppRuntime

final class ProductionRegressionTests: XCTestCase, @unchecked Sendable {
    private let attestor = try! LocalSanitizationAttestor(key: Data(repeating: 0x3d, count: 32), policyRevision: 1)

    @MainActor
    private func makeContainer() -> (AppContainer, URL, String) {
        let directory = FileManager.default.temporaryDirectory.appending(component: "mobilellm-audit-\(UUID().uuidString)")
        let suite = "mobilellm-audit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.contextLength = 8192
        let container = AppContainer(
            engine: MockLLMEngine(script: .init()), downloadBase: directory,
            downloader: { _, _, _, _ in }, settings: settings,
            conversationStore: ConversationStore(directory: directory),
            openAICredentials: EphemeralOpenAICredentialStore(),
            mcpDiscovery: MCPDiscoveryCache(defaults: defaults)
        )
        return (container, directory, suite)
    }

    @MainActor
    private func frozen(_ container: AppContainer, directory: URL, query: String) throws -> FrozenAgentRunInputs {
        let model = LLMCatalog.bonsai8b
        let message = Message(role: .user, answer: query)
        let memoryTools = try ["remember", "recall"].map { try AgentToolLogicalID(providerID: "builtin", name: $0) }
        let policy = try ConversationToolPolicy(masterEnabled: true, allowedToolIDs: memoryTools,
                                                pinnedToolIDs: [], selectionPolicyVersion: 1, materializedFromGlobalTemplate: false)
        let conversation = Conversation(modelID: model.id, variantID: model.defaultVariantValue.id,
                                        messages: [message], toolPolicy: policy)
        container.chat.conversations = [conversation]
        container.chat.activeID = conversation.id
        let config = OpenAIOnlineConfigurationBox(baseURL: "https://unused.invalid/v1", modelID: nil, credentials: container.openAICredentials)
        let snapshot = try XCTUnwrap(makeAgentSnapshot(container: container, conversationID: conversation.id, userTurnID: message.id, text: query, imageRefs: [], downloadBase: directory, onlineConfigBox: config))
        return try AppFrozenInputBuilder(capabilityVersion: SemanticVersion("1.0.0")!).frozenInputs(snapshot: snapshot, artifactReferences: [])
    }

    @MainActor
    func testMemoryOffExcludesSavedFactsFromProductionFrozenInput() async throws {
        let (container, directory, suite) = makeContainer()
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await container.memory.add("The user has a secret preference named MEMORY_OFF_SENTINEL.")
        container.settings.memoryEnabled = false
        let result = try frozen(container, directory: directory, query: "Hello")
        XCTAssertTrue(result.memories.isEmpty, "Memory is OFF, but frozen input contains: \(result.memories.map { $0.frozen.content })")
        XCTAssertFalse(result.toolCatalog.descriptors.contains { ["remember", "recall"].contains($0.id.logicalID.name) },
                       "Disabling Memory also revokes the previously selected memory tools")
    }

    @MainActor
    func testToolSavedFactAppearsOnTheNextProductionSend() async throws {
        let (container, directory, suite) = makeContainer()
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: suite) }
        await container.memory.refresh()
        _ = try await container.memory.store.saveIfAbsent("The user owns a corgi named FRESH_MEMORY_SENTINEL.", source: .model)
        let persisted = await container.memory.store.list()
        XCTAssertEqual(persisted.count, 1, "Control: the durable fact must exist")
        let result = try frozen(container, directory: directory, query: "What is my corgi called?")
        XCTAssertTrue(result.memories.contains { $0.frozen.content.contains("FRESH_MEMORY_SENTINEL") }, "Next send froze stale MemoryBook with \(result.memories.count) facts")
    }

    @MainActor
    func testProductionMemorySelectionOmitsUnrelatedFacts() async throws {
        let (container, directory, suite) = makeContainer()
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await container.memory.add("The user owns a corgi named Momo.")
        try await container.memory.add("The user owns a telescope named IRRELEVANT_SENTINEL.")
        let result = try frozen(container, directory: directory, query: "corgi grooming advice")
        XCTAssertTrue(result.memories.contains { $0.frozen.content.contains("Momo") }, "Relevant control fact")
        XCTAssertFalse(result.memories.contains { $0.frozen.content.contains("IRRELEVANT_SENTINEL") }, "Unrelated fact entered production frozen context")
    }



    func testPageRedirectCannotLeaveThePreparedHTTPSDestination() async throws {
        RedirectAuditProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectAuditProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let adapter = try AppWebScraperToolAdapter(tool: WebScraperTool(session: session), trustRevision: "audit.v1")
        let target = URL(string: "https://1.1.1.1/start")!
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: ["url": .string(target.absoluteString)])
        let preparation = try makePreparationContext(destinations: [try AppWebScraperToolAdapter.destination(url: target)], dataCategories: [try AgentDataCategory(rawValue: "web.page")], capabilities: AgentCapabilitySet([.networkRead]))
        let prepared = try await adapter.prepare(request: request, context: preparation)
        XCTAssertEqual(prepared.externalOperation.plan.allowedFallbacks.count, 0)
        let outcome = try await execute(adapter, prepared: prepared)
        guard case .failed = outcome else { return XCTFail("Unapproved redirect must fail") }
        XCTAssertEqual(RedirectAuditProtocol.snapshot(), [target.absoluteString], "The second request has neither the approved host nor HTTPS")
    }


    private func makeRequest(
        descriptor: AgentToolDescriptor,
        arguments: [String: JSONValue]
    ) throws -> ToolExecutionRequest {
        let json = try CanonicalJSON(.object(arguments))
        let sanitized = try attestor.attest(
            value: json,
            redaction: RedactionMetadata(classification: .sensitive, policyVersion: 1)
        )
        return try ToolExecutionRequest(
            proposedCall: ProposedToolCall(
                invocationID: ToolInvocationID(rawValue: UUID()),
                toolID: descriptor.id.logicalID,
                arguments: json
            ),
            descriptor: descriptor,
            sanitizedArguments: sanitized
        )
    }

    private func makePreparationContext(
        destinations: [ExternalDestination],
        dataCategories: [AgentDataCategory],
        capabilities: AgentCapabilitySet
    ) throws -> ToolPreparationContext {
        let authority = try AgentAuthorityScope(
            capabilities: capabilities,
            destinations: destinations,
            dataCategories: dataCategories
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

    private func execute(
        _ adapter: any ToolV2,
        prepared: PreparedToolInvocation
    ) async throws -> AgentToolInvocationOutcome {
        let plan = prepared.externalOperation.plan
        let authority = try AgentAuthorityScope(
            capabilities: plan.requiredCapabilities,
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
        return try await ToolExecutor().execute(
            tool: adapter,
            authorized: authorized,
            context: context
        )
    }
}

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

private final class RedirectAuditProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    static func reset() { lock.withLock { requests = [] } }
    static func snapshot() -> [String] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.requests.append(url.absoluteString) }
        let first = url.absoluteString == "https://1.1.1.1/start"
        let headers = first ? ["Location": "http://8.8.8.8/unapproved", "Content-Type": "text/html"] : ["Content-Type": "text/html"]
        let response = HTTPURLResponse(url: url, statusCode: first ? 302 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = first ? "" : "<html><title>Audit fixture</title><body><article>A sufficiently long deterministic page used only to check the prepared operation boundary. This content is served by URLProtocol; no network request leaves this process. It should never be fetched after the approved source redirects outside its scope.</article></body></html>"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
