// SPDX-License-Identifier: MIT

import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class ToolSelectorTests: XCTestCase {
    func testConversationPolicyCanonicalizesAndRejectsPinnedExpansion() throws {
        let web = try logical("builtin", "web_search")
        let clock = try logical("builtin", "clock")
        let policy = try ConversationToolPolicy(
            masterEnabled: true,
            allowedToolIDs: [web, clock, web],
            pinnedToolIDs: [clock, clock],
            selectionPolicyVersion: 2,
            materializedFromGlobalTemplate: true
        )
        XCTAssertEqual(policy.allowedToolIDs, [clock, web])
        XCTAssertEqual(policy.pinnedToolIDs, [clock])
        XCTAssertThrowsError(
            try ConversationToolPolicy(
                masterEnabled: true,
                allowedToolIDs: [clock],
                pinnedToolIDs: [web],
                selectionPolicyVersion: 1,
                materializedFromGlobalTemplate: false
            )
        )
        XCTAssertThrowsError(
            try ConversationToolPolicy(
                masterEnabled: true,
                allowedToolIDs: [],
                selectionPolicyVersion: 0,
                materializedFromGlobalTemplate: false
            )
        )
    }

    func testPolicyAndCatalogDecodeRejectNoncanonicalOrAmbiguousValues() throws {
        let clock = try descriptor(provider: "builtin", name: "clock", effects: [.localPure])
        let web = try descriptor(provider: "builtin", name: "web", effects: [.networkRead])
        let policy = try policy(allowed: [clock.id.logicalID, web.id.logicalID])
        let encodedPolicy = try jsonObject(policy)
        var reversedPolicy = encodedPolicy
        reversedPolicy["allowedToolIDs"] = Array(
            (encodedPolicy["allowedToolIDs"] as! [Any]).reversed()
        )
        XCTAssertThrowsError(try decode(ConversationToolPolicy.self, object: reversedPolicy))

        XCTAssertThrowsError(try ToolCatalogSnapshot(revision: 1, descriptors: [clock, clock]))
        XCTAssertThrowsError(
            try ToolCatalogSnapshot(
                revision: 1,
                descriptors: [clock],
                unavailable: [UnavailableTool(logicalID: clock.id.logicalID, reason: .providerUnavailable)]
            )
        )
        XCTAssertThrowsError(try ToolCatalogSnapshot(revision: 0, descriptors: []))

        let catalog = try ToolCatalogSnapshot(revision: 1, descriptors: [web, clock])
        let encodedCatalog = try jsonObject(catalog)
        var reversedCatalog = encodedCatalog
        reversedCatalog["descriptors"] = Array(
            (encodedCatalog["descriptors"] as! [Any]).reversed()
        )
        XCTAssertThrowsError(try decode(ToolCatalogSnapshot.self, object: reversedCatalog))
        XCTAssertEqual(try decode(ToolCatalogSnapshot.self, object: encodedCatalog), catalog)
    }

    func testStaticCatalogReturnsExactLocalSnapshotWithoutMutation() async throws {
        let value = try ToolCatalogSnapshot(
            revision: 7,
            descriptors: [try descriptor(provider: "builtin", name: "clock", effects: [.localPure])]
        )
        let catalog = StaticToolCatalog(snapshot: value)
        let loaded = try await catalog.localSnapshot()
        XCTAssertEqual(loaded, value)
        XCTAssertEqual(value.descriptor(for: value.descriptors[0].id.logicalID), value.descriptors[0])
        XCTAssertNil(value.descriptor(for: try logical("missing", "tool")))
    }

    func testMasterDisabledNeverAdvertisesButRetainsUnavailableEvidence() throws {
        let clock = try descriptor(provider: "builtin", name: "clock", effects: [.localPure])
        let missing = try logical("mcp.server-1", "missing")
        let input = try ToolSelectionInput(
            policy: policy(
                masterEnabled: false,
                allowed: [clock.id.logicalID, missing],
                pinned: [clock.id.logicalID]
            ),
            catalog: ToolCatalogSnapshot(revision: 1, descriptors: [clock]),
            availableCapabilities: AgentCapabilitySet([]),
            latestUserRequest: "clock"
        )
        let result = try DeterministicToolSelector().select(input)
        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertTrue(result.snapshot.decisions.isEmpty)
        XCTAssertEqual(result.unavailable, [UnavailableTool(logicalID: missing, reason: .descriptorMissing)])
    }

    func testSelectionCanOnlyNarrowAllowedSetAndPinnedToolWins() throws {
        let clock = try descriptor(provider: "builtin", name: "clock", effects: [.localPure])
        let calculator = try descriptor(provider: "builtin", name: "calculator", effects: [.localPure])
        let forbidden = try descriptor(provider: "builtin", name: "weather", effects: [.networkRead])
        let input = try ToolSelectionInput(
            policy: policy(
                allowed: [clock.id.logicalID, calculator.id.logicalID],
                pinned: [calculator.id.logicalID]
            ),
            catalog: ToolCatalogSnapshot(revision: 1, descriptors: [forbidden, clock, calculator]),
            availableCapabilities: AgentCapabilitySet([.networkRead]),
            latestUserRequest: "Search the web and tell me the clock",
            explicitlyRequestedToolIDs: [forbidden.id.logicalID],
            maximumAdvertisedTools: 2
        )
        let result = try DeterministicToolSelector().select(input)
        XCTAssertEqual(result.descriptors.map(\.id.logicalID), [calculator.id.logicalID, clock.id.logicalID])
        XCTAssertFalse(result.descriptors.map(\.id.logicalID).contains(forbidden.id.logicalID))
        XCTAssertEqual(result.snapshot.decisions[0].rationaleCodes, ["user.pinned"])
    }

    func testImageAndGenericWhatsThisNeverSelectWebByThemselves() throws {
        let web = try descriptor(
            provider: "builtin",
            name: "web_search",
            title: "Web Search",
            summary: "Search current information on the web",
            effects: [.networkRead]
        )
        let input = try ToolSelectionInput(
            policy: policy(allowed: [web.id.logicalID]),
            catalog: ToolCatalogSnapshot(revision: 1, descriptors: [web]),
            availableCapabilities: AgentCapabilitySet([.networkRead]),
            latestUserRequest: "what's this?",
            attachmentMIMETypes: ["image/jpeg"]
        )
        let result = try DeterministicToolSelector().select(input)
        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertTrue(result.snapshot.decisions.isEmpty)
    }

    func testExplicitNetworkIntentSelectsAllowedWebTool() throws {
        let web = try descriptor(
            provider: "builtin",
            name: "web_search",
            title: "Web Search",
            summary: "Search current information on the web",
            effects: [.networkRead]
        )
        let input = try ToolSelectionInput(
            policy: policy(allowed: [web.id.logicalID]),
            catalog: ToolCatalogSnapshot(revision: 1, descriptors: [web]),
            availableCapabilities: AgentCapabilitySet([.networkRead]),
            latestUserRequest: "Please use Web Search for today's news"
        )
        let result = try DeterministicToolSelector().select(input)
        XCTAssertEqual(result.descriptors, [web])
        XCTAssertTrue(result.snapshot.decisions[0].rationaleCodes.contains("request.explicit"))
    }

    func testCapabilityAndCatalogAvailabilityFailuresAreVisible() throws {
        let web = try descriptor(provider: "builtin", name: "web_search", effects: [.networkRead])
        let remote = try logical("mcp.server-7", "remote")
        let absentSandbox = try logical("sandbox", "execute")
        let input = try ToolSelectionInput(
            policy: policy(allowed: [web.id.logicalID, remote, absentSandbox]),
            catalog: ToolCatalogSnapshot(
                revision: 3,
                descriptors: [web],
                unavailable: [
                    UnavailableTool(logicalID: remote, reason: .providerUnavailable),
                    UnavailableTool(logicalID: absentSandbox, reason: .sandboxProviderAbsent),
                ]
            ),
            availableCapabilities: AgentCapabilitySet([]),
            latestUserRequest: "search web"
        )
        let result = try DeterministicToolSelector().select(input)
        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertEqual(
            Set(result.unavailable),
            Set([
                UnavailableTool(logicalID: web.id.logicalID, reason: .capabilityUnavailable),
                UnavailableTool(logicalID: remote, reason: .providerUnavailable),
                UnavailableTool(logicalID: absentSandbox, reason: .sandboxProviderAbsent),
            ])
        )
    }

    func testSkillRecentAndLexicalSignalsHaveDeterministicOrderingAndCap() throws {
        let clock = try descriptor(provider: "builtin", name: "clock", effects: [.localPure])
        let calc = try descriptor(provider: "builtin", name: "calculator", effects: [.localPure])
        let notes = try descriptor(provider: "builtin", name: "notes", effects: [.localRead])
        let input = try ToolSelectionInput(
            policy: policy(allowed: [clock.id.logicalID, calc.id.logicalID, notes.id.logicalID]),
            catalog: ToolCatalogSnapshot(revision: 2, descriptors: [notes, clock, calc]),
            availableCapabilities: AgentCapabilitySet([.localRead]),
            latestUserRequest: "calculate a clock offset",
            activeSkillToolHints: [notes.id.logicalID],
            recentSuccessfulToolChain: [clock.id.logicalID, calc.id.logicalID],
            maximumAdvertisedTools: 2
        )
        let selector = DeterministicToolSelector()
        let first = try selector.select(input)
        let second = try selector.select(input)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.descriptors.map(\.id.logicalID), [clock.id.logicalID, notes.id.logicalID])
        XCTAssertEqual(first.snapshot.inputDigest, second.snapshot.inputDigest)

        let changed = try ToolSelectionInput(
            policy: input.policy,
            catalog: input.catalog,
            availableCapabilities: input.availableCapabilities,
            latestUserRequest: "calculate",
            activeSkillToolHints: input.activeSkillToolHints,
            recentSuccessfulToolChain: input.recentSuccessfulToolChain,
            maximumAdvertisedTools: 2
        )
        XCTAssertNotEqual(try selector.select(changed).snapshot.inputDigest, first.snapshot.inputDigest)
    }

    func testSelectionInputAndResultFailClosedOnMalformedValues() throws {
        let clock = try descriptor(provider: "builtin", name: "clock", effects: [.localPure])
        let basePolicy = try policy(allowed: [clock.id.logicalID])
        let catalog = try ToolCatalogSnapshot(revision: 1, descriptors: [clock])
        XCTAssertThrowsError(
            try ToolSelectionInput(
                policy: basePolicy,
                catalog: catalog,
                availableCapabilities: AgentCapabilitySet([]),
                latestUserRequest: "clock",
                attachmentMIMETypes: ["IMAGE/JPEG"]
            )
        )
        XCTAssertThrowsError(
            try ToolSelectionInput(
                policy: basePolicy,
                catalog: catalog,
                availableCapabilities: AgentCapabilitySet([]),
                latestUserRequest: "clock",
                maximumAdvertisedTools: 0
            )
        )
        XCTAssertThrowsError(
            try ToolSelectionInput(
                policy: basePolicy,
                catalog: catalog,
                availableCapabilities: AgentCapabilitySet([]),
                latestUserRequest: "clock",
                recentSuccessfulToolChain: Array(repeating: clock.id.logicalID, count: 65)
            )
        )
        let selected = try DeterministicToolSelector().select(
            ToolSelectionInput(
                policy: basePolicy,
                catalog: catalog,
                availableCapabilities: AgentCapabilitySet([]),
                latestUserRequest: "clock"
            )
        )
        XCTAssertThrowsError(
            try ToolSelectionResult(
                snapshot: selected.snapshot,
                descriptors: [],
                unavailable: []
            )
        )
    }

    // MARK: - Fixtures

    private func policy(
        masterEnabled: Bool = true,
        allowed: [AgentToolLogicalID],
        pinned: [AgentToolLogicalID] = []
    ) throws -> ConversationToolPolicy {
        try ConversationToolPolicy(
            masterEnabled: masterEnabled,
            allowedToolIDs: allowed,
            pinnedToolIDs: pinned,
            selectionPolicyVersion: 1,
            materializedFromGlobalTemplate: false
        )
    }

    private func logical(_ provider: String, _ name: String) throws -> AgentToolLogicalID {
        try AgentToolLogicalID(providerID: provider, name: name)
    }

    private func descriptor(
        provider: String,
        name: String,
        title: String? = nil,
        summary: String? = nil,
        effects: [AgentEffect]
    ) throws -> AgentToolDescriptor {
        let schema = try JSONSchemaDocument(
            root: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ])
        )
        let logicalID = try logical(provider, name)
        let id = try AgentToolDescriptorID(
            logicalID: logicalID,
            version: SemanticVersion("1.0.0")!,
            schemaDigest: schema.digest,
            trustRevision: "local-1"
        )
        return try AgentToolDescriptor(
            id: id,
            title: title ?? name,
            summary: summary ?? "Use \(name)",
            inputSchema: schema,
            effects: effects,
            requiredCapabilities: AgentCapabilitySet(effects.compactMap(\.minimumCapability)),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 5_000),
            retryPolicy: .never,
            idempotency: .pureRead,
            supportsProgress: false,
            supportsCancellation: true
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        object: [String: Any]
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }
}
