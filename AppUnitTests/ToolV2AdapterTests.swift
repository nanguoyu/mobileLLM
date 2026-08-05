// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
@testable import mobileLLM
@testable import LLMCore
import AppRuntime
import Foundation
import XCTest

// TEST-ID: AHT-TOOL-005
final class ToolV2AdapterTests: XCTestCase {
    private let attestor = try! LocalSanitizationAttestor(
        key: Data(repeating: 0x3d, count: 32),
        policyRevision: 1
    )

    // MARK: - Web search

    func testWebSearchAdapterPreparesPlanAndExecutesInsideBoundary() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedHTTPProtocol.self]
        CannedHTTPProtocol.routes = [
            "www.bing.com": .rss(
                title: "Example Result",
                link: "https://example.com/result",
                snippet: "A snippet"
            ),
        ]
        let tool = WebSearchTool(
            engines: [.bing],
            session: URLSession(configuration: configuration),
            dnsResolver: { _ in ["93.184.216.34"] }
        )
        let adapter = try AppWebSearchToolAdapter(tool: tool, trustRevision: "builtin.v1")
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: [
            "query": .string("mobileLLM"),
        ])
        let preparation = try makePreparationContext(
            destinations: [try AppWebSearchToolAdapter.destination(engine: .bing)],
            dataCategories: [try AgentDataCategory(rawValue: "web.search")],
            capabilities: AgentCapabilitySet([.networkRead])
        )

        let prepared = try await adapter.prepare(request: request, context: preparation)
        XCTAssertEqual(prepared.externalOperation.plan.effects, [.networkRead])
        XCTAssertEqual(
            prepared.externalOperation.plan.destination,
            try AppWebSearchToolAdapter.destination(engine: .bing)
        )

        let outcome = try await execute(adapter, prepared: prepared)
        guard case .completed(let results) = outcome,
              case .text(let text) = results.first
        else { return XCTFail("expected completed text, got \(outcome)") }
        XCTAssertTrue(text.value.contains("Example Result"))
    }

    // MARK: - Wikipedia

    func testWikipediaAdapterPreparesLanguageHostAndExecutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedHTTPProtocol.self]
        CannedHTTPProtocol.routes = [
            "en.wikipedia.org/w/api.php": .json(#"{"query":{"search":[{"title":"Alan Turing"}]}}"#),
            "en.wikipedia.org/api/rest_v1": .json(#"{"extract":"Alan Turing was a British mathematician."}"#),
        ]
        let adapter = try AppWikipediaToolAdapter(
            tool: WikipediaTool(session: URLSession(configuration: configuration)),
            trustRevision: "builtin.v1"
        )
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: [
            "query": .string("Alan Turing"),
        ])
        let preparation = try makePreparationContext(
            destinations: [try AppWikipediaToolAdapter.destination(lang: "en")],
            dataCategories: [try AgentDataCategory(rawValue: "web.wikipedia")],
            capabilities: AgentCapabilitySet([.networkRead])
        )

        let prepared = try await adapter.prepare(request: request, context: preparation)
        XCTAssertEqual(
            prepared.externalOperation.plan.destination,
            try AppWikipediaToolAdapter.destination(lang: "en")
        )
        XCTAssertTrue(prepared.externalOperation.plan.userPreview.contains("Alan Turing"))

        let outcome = try await execute(adapter, prepared: prepared)
        guard case .completed(let results) = outcome,
              case .text(let text) = results.first
        else { return XCTFail("expected completed text, got \(outcome)") }
        XCTAssertTrue(text.value.contains("Alan Turing was a British mathematician."))
    }

    // MARK: - Webpage reader

    func testWebScraperAdapterPreparesHttpsDestinationAndExecutes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedHTTPProtocol.self]
        CannedHTTPProtocol.routes = [
            "example.com/article": .html(
                "<html><head><title>Doc Title</title></head><body><article>"
                    + "<h1>Hello</h1><p>First paragraph text.</p></article></body></html>"
            ),
        ]
        let tool = WebScraperTool(
            session: URLSession(configuration: configuration),
            dnsResolver: { _ in ["93.184.216.34"] }
        )
        let adapter = try AppWebScraperToolAdapter(tool: tool, trustRevision: "builtin.v1")
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: [
            "url": .string(pageURL.absoluteString),
        ])
        let preparation = try makePreparationContext(
            destinations: [try AppWebScraperToolAdapter.destination(url: pageURL)],
            dataCategories: [try AgentDataCategory(rawValue: "web.page")],
            capabilities: AgentCapabilitySet([.networkRead])
        )

        let prepared = try await adapter.prepare(request: request, context: preparation)
        XCTAssertEqual(
            prepared.externalOperation.plan.destination,
            try AppWebScraperToolAdapter.destination(url: pageURL)
        )

        let outcome = try await execute(adapter, prepared: prepared)
        guard case .completed(let results) = outcome,
              case .text(let text) = results.first
        else { return XCTFail("expected completed text, got \(outcome)") }
        XCTAssertTrue(text.value.contains("Doc Title"))
        XCTAssertTrue(text.value.contains("First paragraph text."))
    }

    // MARK: - System data (calendar / reminders / location)

    func testSystemDataAdaptersPrepareAndExecuteAllFourTools() async throws {
        let store = FakeEventStore()
        let location = FakeLocationProvider()
        let cases: [(tool: any LLMCore.Tool, effects: [AgentEffect], destination: String, category: String,
                     arguments: [String: JSONValue], expected: String)] = [
            (
                CreateCalendarEventTool(store: store),
                [.localWrite],
                "mobilellm.calendar",
                "user.calendar",
                ["title": .string("Review"),
                 "start": .string("2026-08-10T10:00:00")],
                "Added"
            ),
            (
                ListCalendarEventsTool(store: store),
                [.localRead],
                "mobilellm.calendar",
                "user.calendar",
                ["daysAhead": .integer(7)],
                "Events in the next"
            ),
            (
                CreateReminderTool(store: store),
                [.localWrite],
                "mobilellm.reminders",
                "user.reminders",
                ["title": .string("Water plants"),
                 "due": .string("2026-08-10T09:00:00")],
                "Reminder set"
            ),
            (
                CurrentLocationTool(provider: location),
                [.localRead],
                "mobilellm.location",
                "user.location",
                [:],
                "Vienna"
            ),
        ]

        for item in cases {
            let adapter = try AppSystemDataToolAdapter(
                tool: item.tool,
                effects: item.effects,
                destinationIdentity: item.destination,
                dataCategory: item.category,
                userPreview: "preview",
                trustRevision: "builtin.v1"
            )
            let request = try makeRequest(descriptor: adapter.descriptor, arguments: item.arguments)
            let preparation = try makePreparationContext(
                destinations: [try ExternalDestination(
                    kind: .privateDataStore,
                    normalizedIdentity: item.destination
                )],
                dataCategories: [try AgentDataCategory(rawValue: item.category)],
                capabilities: AgentCapabilitySet(item.effects.compactMap(\.minimumCapability))
            )
            let prepared = try await adapter.prepare(request: request, context: preparation)
            XCTAssertEqual(
                prepared.externalOperation.plan.destination,
                try ExternalDestination(kind: .privateDataStore, normalizedIdentity: item.destination)
            )
            XCTAssertEqual(prepared.externalOperation.plan.effects, item.effects)

            let outcome = try await execute(adapter, prepared: prepared)
            guard case .completed(let results) = outcome,
                  case .text(let text) = results.first
            else { return XCTFail("expected completed text, got \(outcome)") }
            XCTAssertTrue(text.value.contains(item.expected), "\(text.value) should contain \(item.expected)")
        }
    }

    // MARK: - Memory (remember / recall)

    func testMemoryAdaptersPrepareAndExecuteRememberAndRecall() async throws {
        let store = FakeMemoryStore()
        let rememberAdapter = try AppMemoryToolAdapter(
            tool: RememberTool(store: store),
            effects: [.localWrite],
            trustRevision: "builtin.v1"
        )
        let rememberRequest = try makeRequest(descriptor: rememberAdapter.descriptor, arguments: [
            "text": .string("The user is named Dong"),
        ])
        let memoryPreparation = try makePreparationContext(
            destinations: [try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.memory"
            )],
            dataCategories: [try AgentDataCategory(rawValue: "user.memory")],
            capabilities: AgentCapabilitySet([.localWrite])
        )
        let rememberPrepared = try await rememberAdapter.prepare(
            request: rememberRequest,
            context: memoryPreparation
        )
        let rememberOutcome = try await execute(rememberAdapter, prepared: rememberPrepared)
        guard case .completed(let rememberResults) = rememberOutcome,
              case .text(let rememberText) = rememberResults.first
        else { return XCTFail("expected completed remember, got \(rememberOutcome)") }
        XCTAssertTrue(rememberText.value.contains("Saved to memory."))

        let recallAdapter = try AppMemoryToolAdapter(
            tool: RecallTool(store: store),
            effects: [.localRead],
            trustRevision: "builtin.v1"
        )
        let recallRequest = try makeRequest(descriptor: recallAdapter.descriptor, arguments: [
            "query": .string("name"),
        ])
        let recallPreparation = try makePreparationContext(
            destinations: [try ExternalDestination(
                kind: .privateDataStore,
                normalizedIdentity: "mobilellm.memory"
            )],
            dataCategories: [try AgentDataCategory(rawValue: "user.memory")],
            capabilities: AgentCapabilitySet([.localRead])
        )
        let recallPrepared = try await recallAdapter.prepare(
            request: recallRequest,
            context: recallPreparation
        )
        let recallOutcome = try await execute(recallAdapter, prepared: recallPrepared)
        guard case .completed(let recallResults) = recallOutcome,
              case .text(let recallText) = recallResults.first
        else { return XCTFail("expected completed recall, got \(recallOutcome)") }
        XCTAssertTrue(recallText.value.contains("The user is named Dong"))
    }

    // MARK: - Fixtures

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

// MARK: - Canned HTTP fixture

private final class CannedHTTPProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: CannedResponse] = [:]

    enum CannedResponse {
        case json(String)
        case html(String)
        case rss(title: String, link: String, snippet: String)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        guard let entry = Self.routes.first(where: { url.contains($0.key) }) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        let body: String
        switch entry.value {
        case .json(let json):
            body = json
        case .html(let html):
            body = html
        case .rss(let title, let link, let snippet):
            body = """
            <rss><channel><item><title>\(title)</title><link>\(link)</link>\
            <description>\(snippet)</description></item></channel></rss>
            """
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Fake seams

private actor FakeEventStore: EventStoring {
    func createEvent(_ draft: CalendarEventDraft) async throws -> String {
        "created"
    }

    func events(daysAhead: Int) async throws -> [CalendarEventInfo] {
        [CalendarEventInfo(title: "Review", start: Date().addingTimeInterval(86_400))]
    }

    func createReminder(_ draft: ReminderDraft) async throws -> String {
        "created"
    }
}

private struct FakeLocationProvider: LocationProviding {
    func currentLocation() async throws -> LocationFix {
        LocationFix(latitude: 48.2082, longitude: 16.3738, accuracy: 100, locality: "Vienna")
    }
}

private actor FakeMemoryStore: MemoryStoring {
    private var facts: [MemoryFact] = []

    func save(_ text: String, source: MemoryFact.Source) async throws -> MemoryFact {
        let fact = MemoryFact(text: text, source: source)
        facts.append(fact)
        return fact
    }

    func saveIfAbsent(_ text: String, source: MemoryFact.Source) async throws -> MemorySaveResult {
        if facts.contains(where: { $0.text == text }) {
            return .duplicate(MemoryFact(text: text, source: source))
        }
        return .saved(try await save(text, source: source))
    }

    func saveIfAbsent(_ text: String, source: MemoryFact.Source, sourceText: String?) async throws
        -> MemorySaveResult {
        try await saveIfAbsent(text, source: source)
    }

    func list() async -> [MemoryFact] { facts }

    func update(id: String, text: String) async throws {}
    func delete(id: String) async throws {}
    func deleteAll() async throws {}

    func search(_ query: String, limit: Int) async -> [MemoryFact] {
        Array(facts.prefix(max(1, limit)))
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
