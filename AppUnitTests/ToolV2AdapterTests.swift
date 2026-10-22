// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
@testable import mobileLLM
@testable import LLMCore
@testable import MobileLLMUI
import AppRuntime
import Foundation
import XCTest

// TEST-ID: AHT-TOOL-005
// TEST-ID: AHT-OUTBOX-001
final class ToolV2AdapterTests: XCTestCase {
    private let attestor = try! LocalSanitizationAttestor(
        key: Data(repeating: 0x3d, count: 32),
        policyRevision: 1
    )

    @MainActor
    func testAppRequestBindsExistingChatMessageIdentitiesForOutboxReconciliation() throws {
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let snapshot = makeSnapshot(userMessageID: userMessageID)
        let builder = AppFrozenInputBuilder(capabilityVersion: SemanticVersion("1.0.0")!)

        let request = try builder.request(
            snapshot: snapshot,
            artifactReferences: [],
            responseMessageID: assistantMessageID
        )

        XCTAssertEqual(request.provenance.sourceMessageID?.rawValue, userMessageID)
        XCTAssertEqual(request.provenance.responseMessageID?.rawValue, assistantMessageID)
    }

    @MainActor
    func testSnapshotUsesRequestedConversationInsteadOfVisibleConversationState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "agent-snapshot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "agent-snapshot-test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.temperature = 0.91
        settings.topP = 0.92
        settings.maxTokens = 999
        settings.contextLength = 4_096
        let credentials = EphemeralOpenAICredentialStore()
        let container = AppContainer(
            engine: MockLLMEngine(script: .init()),
            downloadBase: directory,
            downloader: { _, _, _, _ in },
            settings: settings,
            conversationStore: ConversationStore(directory: directory),
            openAICredentials: credentials
        )
        let targetModel = LLMCatalog.bonsai8b
        let targetVariant = targetModel.defaultVariantValue
        let visibleModel = LLMCatalog.gemma4E2B
        let visibleVariant = visibleModel.defaultVariantValue
        let calculator = try AgentToolLogicalID(providerID: "builtin", name: "calculator")
        let target = Conversation(
            modelID: targetModel.id,
            variantID: targetVariant.id,
            messages: [Message(role: .user, answer: "target")],
            toolPolicy: try ConversationToolPolicy(
                masterEnabled: true,
                allowedToolIDs: [calculator],
                pinnedToolIDs: [],
                selectionPolicyVersion: 1,
                materializedFromGlobalTemplate: false
            ),
            contextLength: 12_345,
            sampling: ConversationSampling(temperature: 0.12, topP: 0.34, maxTokens: 222),
            approvalMode: .fullAccess,
            reasoningEffort: .high
        )
        let visible = Conversation(
            modelID: visibleModel.id,
            variantID: visibleVariant.id,
            messages: [Message(role: .user, answer: "visible")],
            contextLength: 65_536,
            sampling: ConversationSampling(temperature: 0.8, topP: 0.9, maxTokens: 888),
            approvalMode: .ask,
            reasoningEffort: .low
        )
        container.chat.conversations = [target, visible]
        container.chat.activeID = visible.id
        container.chat.synchronizeActiveModel(
            LoadedModel(model: visibleModel, variant: visibleVariant),
            reseedEmptyConversation: false
        )
        let config = OpenAIOnlineConfigurationBox(
            baseURL: "https://example.com/v1",
            modelID: nil,
            credentials: credentials
        )

        let snapshot = try XCTUnwrap(makeAgentSnapshot(
            container: container,
            conversationID: target.id,
            userTurnID: target.messages[0].id,
            text: "target",
            imageRefs: [],
            downloadBase: directory,
            onlineConfigBox: config
        ))

        XCTAssertEqual(snapshot.model.id, targetModel.id)
        XCTAssertEqual(snapshot.variant.id, targetVariant.id)
        XCTAssertEqual(snapshot.messages.map(\.answer), ["target"])
        XCTAssertEqual(snapshot.contextLength, 12_345)
        XCTAssertEqual(snapshot.maxTokens, 222)
        XCTAssertEqual(snapshot.temperature, 0.12)
        XCTAssertEqual(snapshot.topP, 0.34)
        XCTAssertEqual(snapshot.localToolNames, ["calculator"])
        XCTAssertEqual(snapshot.approvalMode, .fullAccess)
        XCTAssertEqual(snapshot.onlineReasoningEffort, .high)
    }

    func testOnlineConfigurationRemainsBoundToAcceptedSelectionAfterSettingsEdit() throws {
        let credentials = EphemeralOpenAICredentialStore()
        try credentials.saveAPIKey("secret", serviceID: "service-a")
        let box = OpenAIOnlineConfigurationBox(
            baseURL: "https://unused.example/v1",
            modelID: nil,
            credentials: credentials
        )
        let firstID = box.update(
            serviceID: "service-a",
            baseURL: "https://first.example/v1",
            modelID: "model-a",
            reasoningEffort: .low,
            maximumOutputTokens: 4_096
        )
        let secondID = box.update(
            serviceID: "service-a",
            baseURL: "https://second.example/v1",
            modelID: "model-a",
            reasoningEffort: .high,
            maximumOutputTokens: 8_192
        )
        let version = SemanticVersion("1.0.0")!
        func selection(_ configurationID: String) throws -> AgentModelSelection {
            try AgentModelSelection(
                providerID: AgentModelProviderID(AppFrozenInputBuilder.onlineProviderID),
                modelID: AgentModelID("model-a"),
                variantID: AgentModelVariantID(
                    AppFrozenInputBuilder.onlineVariantID(configurationID: configurationID)
                ),
                capabilityVersion: version
            )
        }

        let first = try XCTUnwrap(box.configuration(for: selection(firstID)))
        let second = try XCTUnwrap(box.configuration(for: selection(secondID)))
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(first.baseURL, "https://first.example/v1")
        XCTAssertEqual(first.reasoningEffort, .low)
        XCTAssertEqual(first.maximumOutputTokens, 4_096)
        XCTAssertEqual(second.baseURL, "https://second.example/v1")
        XCTAssertEqual(second.reasoningEffort, .high)
        XCTAssertEqual(second.maximumOutputTokens, 8_192)

        let relaunched = OpenAIOnlineConfigurationBox(
            baseURL: "https://unused.example/v1",
            modelID: nil,
            credentials: credentials
        )
        let rehydratedID = relaunched.update(
            serviceID: "service-a",
            baseURL: "https://first.example/v1",
            modelID: "model-a",
            reasoningEffort: .low,
            maximumOutputTokens: 4_096
        )
        XCTAssertEqual(rehydratedID, firstID)
        XCTAssertEqual(
            try XCTUnwrap(relaunched.configuration(for: selection(firstID))).baseURL,
            "https://first.example/v1"
        )
    }

    @MainActor
    func testLocalFrozenInputAdvertisesOnlyTheRelevantBoundedToolSubset() throws {
        let snapshot = makeSnapshot(userMessageID: UUID())
        let builder = AppFrozenInputBuilder(capabilityVersion: SemanticVersion("1.0.0")!)

        let frozen = try builder.frozenInputs(snapshot: snapshot, artifactReferences: [])
        let selected = try frozen.selectedTools(latestUserRequest: snapshot.text)
        let compiled = try ContextCompiler().compile(
            FrozenContextSnapshot(
                runID: AgentRunID(rawValue: UUID()),
                requestID: AgentRequestID(rawValue: UUID()),
                stepID: AgentStepID(rawValue: UUID()),
                baseSystem: frozen.baseSystem,
                skills: frozen.skills,
                memories: frozen.memories,
                conversation: frozen.conversation,
                currentUser: frozen.currentUser,
                advertisedTools: selected.descriptors,
                selectorID: selected.snapshot.selectorID,
                selectorPolicyVersion: selected.snapshot.policyVersion,
                contextPolicyVersion: frozen.contextPolicyVersion,
                approvalPolicyVersion: frozen.approvalPolicyVersion
            ),
            budget: frozen.contextBudget
        )

        XCTAssertEqual(frozen.maximumAdvertisedTools, 8)
        XCTAssertEqual(frozen.contextBudget.maximumToolSchemaTokens, 4_096)
        XCTAssertGreaterThan(frozen.toolCatalog.descriptors.count, 8)
        XCTAssertLessThan(selected.descriptors.count, frozen.toolCatalog.descriptors.count)
        XCTAssertLessThanOrEqual(selected.descriptors.count, 8)
        XCTAssertFalse(selected.descriptors.contains { $0.id.logicalID.name == "web_search" })
        XCTAssertEqual(compiled.advertisedTools.count, selected.descriptors.count)

        let explicitSearch = try frozen.selectedTools(
            latestUserRequest: "Search the web for the current Swift release notes."
        )
        XCTAssertTrue(explicitSearch.descriptors.contains { $0.id.logicalID.name == "web_search" })
        XCTAssertLessThanOrEqual(explicitSearch.descriptors.count, 8)
    }

    @MainActor
    private func makeSnapshot(userMessageID: UUID, deepSeekWebServiceID: String? = nil) -> AgentRunRequestSnapshot {
        let model = LLMCatalog.bonsai8b
        let variant = model.defaultVariantValue
        return AgentRunRequestSnapshot(
            conversationID: UUID(),
            userTurnID: userMessageID,
            text: "What's this?",
            imageRefs: [],
            messages: [Message(id: userMessageID, role: .user, answer: "What's this?")],
            systemPrompt: "You are helpful.",
            memoryFacts: [],
            activeSkill: nil,
            model: model,
            variant: variant,
            weightsDirectory: FileManager.default.temporaryDirectory,
            thinkingEnabled: false,
            contextLength: 8_192,
            maxTokens: 512,
            temperature: 0.2,
            topP: 0.9,
            topK: 40,
            repetitionPenalty: 1.0,
            toolsEnabled: true,
            localToolNames: AppLocalToolIDs.names,
            memorySeamAvailable: true,
            eventSeamAvailable: true,
            locationSeamAvailable: true,
            mcpToolDescriptors: [],
            webSearchDestinations: deepSeekWebServiceID == nil ? [] : [try! AppDeepSeekWebToolAdapter.destination()],
            toolPolicy: nil,
            onlineModelEnabled: false,
            onlineModelID: nil,
            onlineServiceID: nil,
            onlineConfigurationID: nil,
            onlineReasoningEnabled: false,
            onlineContextLength: 128_000,
            onlineOutputBudgetAuto: true,
            onlineMaximumOutputTokens: nil,
            approvalMode: .safePreset,
            onlineReasoningEffort: nil,
            deepSeekWebServiceID: deepSeekWebServiceID
        )
    }

    // MARK: - Web search

    // TEST-ID: AHT-DYNAMIC-001
    @MainActor
    func testWorkflowGeneratorSuppressesItsOwnToolsWithoutErasingDelegatedPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try AgentRuntimeAssembly(engine: MockLLMEngine(script: .init()), downloadBase: root,
            conversationDirectory: root, models: [LLMCatalog.bonsai8b], snapshot: { _, _, _, _ in nil })
        let snapshot = makeSnapshot(userMessageID: UUID(), deepSeekWebServiceID: "account-A")
        let expected = try assembly.frozenBuilder.frozenInputs(snapshot: snapshot, artifactReferences: [])
        let generator = try assembly.makeDynamicWorkflowGenerator(snapshot: snapshot)
        let frozen = try await assembly.inputFreezer.freeze(generator)
        XCTAssertTrue(try frozen.selectedTools(latestUserRequest: "Search and read official webpages").descriptors.isEmpty)
        XCTAssertEqual(frozen.toolCatalog, expected.toolCatalog)
        XCTAssertEqual(frozen.toolPolicy, expected.toolPolicy)
        XCTAssertTrue(frozen.toolPolicy.masterEnabled)
        let recovered = try JSONDecoder().decode(FrozenAgentRunInputs.self, from: JSONEncoder().encode(frozen))
        XCTAssertEqual(recovered.toolCatalog, expected.toolCatalog, "Recovery must preserve the delegated tools")
        XCTAssertTrue(try recovered.selectedTools(latestUserRequest: "Search the web").descriptors.isEmpty)
        let ordinaryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        XCTAssertNil(ordinaryJSON["suppressModelTools"], "Ordinary/legacy input encoding stays unchanged")
        let ordinary = try JSONDecoder().decode(FrozenAgentRunInputs.self, from: JSONEncoder().encode(expected))
        XCTAssertFalse(try ordinary.selectedTools(latestUserRequest: "Search the web").descriptors.isEmpty)
        let disabledGenerator = try assembly.makeDynamicWorkflowGenerator(snapshot: snapshot.withText("Research", toolsEnabled: false))
        let disabled = try await assembly.inputFreezer.freeze(disabledGenerator)
        XCTAssertFalse(disabled.toolPolicy.masterEnabled)
        XCTAssertTrue(disabled.toolCatalog.descriptors.isEmpty, "Suppression cannot re-enable user-disabled tools")
    }

    // TEST-ID: AHT-DYNAMIC-001
    @MainActor
    func testResearchChildCanFinishItsAdmittedModelPassesButCannotExceedTheirBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assembly = try AgentRuntimeAssembly(engine: MockLLMEngine(script: .init()), downloadBase: root,
            conversationDirectory: root, models: [LLMCatalog.bonsai8b], snapshot: { _, _, _, _ in nil })
        let generator = try assembly.makeDynamicWorkflowGenerator(snapshot: makeSnapshot(userMessageID: UUID()))
        let frozen = try await assembly.inputFreezer.freeze(generator)
        let child = try generator.budget.attenuating(to: AgentBudget(
            limits: generator.budget.limits.sharingCumulativeCapacity(among: 4),
            maximumThermalState: generator.budget.maximumThermalState,
            memoryPressureResponse: generator.budget.memoryPressureResponse), requireStrict: true)
        var ledger = try BudgetLedgerSnapshot(budget: child)
        let pass = AgentUsage(quantities: BudgetQuantities([
            .modelAttempts: 1, .inputTokens: child.limits[.contextTokensPerAttempt],
            .outputTokens: frozen.generationParameters.maximumOutputTokens
        ]))
        for _ in 0 ..< child.limits[.modelAttempts] {
            let reservation = try BudgetReservation(id: BudgetReservationID(), maximumUsage: pass, reason: "research-model-pass")
            ledger = try ledger.reserving(reservation)
            ledger = try ledger.settling(reservationID: reservation.id, actualUsage: pass)
        }
        let excess = try BudgetReservation(id: BudgetReservationID(), maximumUsage: pass, reason: "excess-pass")
        XCTAssertThrowsError(try ledger.reserving(excess), "The fixed model/token ceiling must still be enforced")
    }

    @MainActor
    func testDeepSeekSelectionIsFrozenAndReconstructsWithoutDuplicatePublicTools() async throws {
        let snapshot = makeSnapshot(userMessageID: UUID(), deepSeekWebServiceID: "account-A")
        let builder = AppFrozenInputBuilder(capabilityVersion: SemanticVersion("1.0.0")!)
        let frozen = try builder.frozenInputs(snapshot: snapshot.withText("Search and read a webpage"), artifactReferences: [])
        let request = try builder.request(snapshot: snapshot, artifactReferences: [])
        XCTAssertTrue(request.capabilityCeiling.authority.destinations.contains(try AppDeepSeekWebToolAdapter.destination()))
        XCTAssertFalse(request.capabilityCeiling.authority.destinations.contains {
            $0.normalizedIdentity == ExternalDestination.anyHTTPSNetworkEndpoint
        })
        let catalog = try AppToolCatalog(enabledToolNames: AppLocalToolIDs.names, memoryStore: nil,
            eventStore: nil, locationProvider: nil, mcpCache: MCPDiscoveryCache())
        for operation in [DeepSeekWebOperation.search, .fetch] {
            let descriptors = frozen.toolCatalog.descriptors.filter { $0.id.logicalID.name == operation.toolName }
            XCTAssertEqual(descriptors.count, 1, "One capability must not advertise competing implementations")
            let descriptor = try XCTUnwrap(descriptors.first)
            XCTAssertEqual(AppDeepSeekWebToolAdapter.serviceID(from: descriptor.id), "account-A")
            let restored = try await catalog.tool(for: descriptor.id)
            XCTAssertEqual(restored?.descriptor, descriptor, "Recovery reconstructs the exact account-bound adapter")
            let other = try AppDeepSeekWebToolAdapter.makeDescriptor(operation: operation, serviceID: "account-B")
            XCTAssertNotEqual(descriptor.id, other.id, "Changing account invalidates descriptor-bound approval")
        }
        let disabled = try builder.frozenInputs(snapshot: snapshot.withText("Hello", toolsEnabled: false), artifactReferences: [])
        XCTAssertFalse(disabled.toolCatalog.descriptors.contains { ["web_search", "fetch_webpage"].contains($0.id.logicalID.name) })
    }

    func testDeepSeekReadsCredentialsOnlyAfterAuthorizationAndFailsWithoutFallback() async throws {
        let reads = DeepSeekCredentialReadProbe()
        let adapter = try AppDeepSeekWebToolAdapter(operation: .search, serviceID: "account-A") { serviceID in
            await reads.record(serviceID)
            return nil
        }
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: ["query": .string("Swift documentation")])
        let preparation = try makePreparationContext(destinations: [AppDeepSeekWebToolAdapter.destination()],
            dataCategories: [AgentDataCategory(rawValue: "web.search")], capabilities: AgentCapabilitySet([.networkRead]))
        let prepared = try await adapter.prepare(request: request, context: preparation)
        let before = await reads.ids
        XCTAssertTrue(before.isEmpty, "Preparation must not access credentials or the network")
        XCTAssertTrue(prepared.externalOperation.plan.allowedFallbacks.isEmpty)
        let outcome = try await execute(adapter, prepared: prepared)
        guard case .failed(let failure) = outcome else { return XCTFail("Missing key must not look like a successful or public-engine search") }
        XCTAssertTrue(failure.safeMessage.contains("API key"))
        let after = await reads.ids
        XCTAssertEqual(after, ["account-A"])
    }

    func testDeepSeekInvalidPageBecomesAToolFailureWithoutReadingCredentials() async throws {
        let reads = DeepSeekCredentialReadProbe()
        let adapter = try AppDeepSeekWebToolAdapter(operation: .fetch, serviceID: "account-A") { serviceID in
            await reads.record(serviceID)
            return nil
        }
        let request = try makeRequest(descriptor: adapter.descriptor,
            arguments: ["url": .string("http://mlsys.cst.cam.ac.uk/")])
        let context = try makePreparationContext(destinations: [AppDeepSeekWebToolAdapter.destination()],
            dataCategories: [AgentDataCategory(rawValue: "web.page")], capabilities: AgentCapabilitySet([.networkRead]))
        let prepared = try await adapter.prepare(request: request, context: context)
        let outcome = try await execute(adapter, prepared: prepared)
        guard case .failed(let failure) = outcome else { return XCTFail("HTTP input must remain rejected") }
        XCTAssertTrue(failure.safeMessage.contains("HTTPS"))
        let ids = await reads.ids
        XCTAssertTrue(ids.isEmpty, "An invalid page must make no authenticated API request")
    }

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

    /// Regression for the device matrix (test24): the default five-engine web_search plan reserves
    /// `maximumResponseBytes × (1 + fallbacks)`. With the old 2 MiB per-hop cap that worst case was
    /// 10 MiB, which blew the default 8 MiB `networkResponseBytesTotal` run budget before any network
    /// hop. The adapter must clamp its per-hop cap so the full default fallback itinerary fits.
    func testWebSearchDefaultPlanFitsRunNetworkBudget() async throws {
        let tool = WebSearchTool(
            engines: SearchEngine.allCases,
            session: URLSession(configuration: .ephemeral)
        )
        let adapter = try AppWebSearchToolAdapter(tool: tool, trustRevision: "builtin.v1")
        let request = try makeRequest(descriptor: adapter.descriptor, arguments: [
            "query": .string("mobileLLM"),
        ])
        let destinations = try SearchEngine.allCases.map {
            try AppWebSearchToolAdapter.destination(engine: $0)
        }
        let preparation = try makePreparationContext(
            destinations: destinations,
            dataCategories: [try AgentDataCategory(rawValue: "web.search")],
            capabilities: AgentCapabilitySet([.networkRead])
        )

        let prepared = try await adapter.prepare(request: request, context: preparation)
        let hops = 1 + prepared.externalOperation.plan.allowedFallbacks.count
        let worstCase = prepared.externalOperation.plan.maximumResponseBytes * UInt64(hops)
        XCTAssertEqual(
            prepared.externalOperation.plan.maximumResponseBytes,
            1 * 1_024 * 1_024,
            "web_search per-hop cap must stay at 1 MiB so the default itinerary fits the run budget"
        )
        XCTAssertLessThanOrEqual(
            worstCase,
            8 * 1_024 * 1_024,
            "default five-engine web_search worst-case reservation \(worstCase) "
                + "must fit networkResponseBytesTotal"
        )
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
        ], userSourceText: "我的名字是 Dong，请记住。")
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
        let saved = await store.list()
        XCTAssertEqual(saved.first?.sourceText, "我的名字是 Dong，请记住。")
        XCTAssertEqual(rememberPrepared.externalOperation.plan.executionConstraintDigest,
                       rememberRequest.userSourceTextDigest)

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
        arguments: [String: JSONValue],
        userSourceText: String? = nil
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
            sanitizedArguments: sanitized,
            userSourceText: userSourceText
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
        if let fact = facts.first(where: { $0.text == text }) { return .duplicate(fact) }
        let fact = MemoryFact(text: text, source: source, sourceText: sourceText)
        facts.append(fact)
        return .saved(fact)
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

private actor DeepSeekCredentialReadProbe {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private struct TestAlwaysClaimableAttemptLedger: ExternalOperationAttemptClaiming {
    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool { true }
}
