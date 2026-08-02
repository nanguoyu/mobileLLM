// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@_spi(AgentRuntime) @testable import AgentRuntime
import Foundation
import XCTest

final class AgentModelProviderTests: XCTestCase {
    func testDescriptorContextCatalogAndLocalPreparationAreDeterministic() async throws {
        let fixture = try ModelFixture()
        let provider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities
        )
        let descriptorData = try JSONEncoder().encode(fixture.descriptor)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentModelProviderDescriptor.self, from: descriptorData),
            fixture.descriptor
        )
        let contextData = try JSONEncoder().encode(fixture.context)
        XCTAssertEqual(
            try JSONDecoder().decode(ModelPreparationContext.self, from: contextData),
            fixture.context
        )

        let catalog = try StaticAgentModelProviderCatalog(providers: [provider])
        XCTAssertEqual(
            try catalog.provider(for: fixture.request.selection).descriptor,
            fixture.descriptor
        )
        XCTAssertThrowsError(
            try StaticAgentModelProviderCatalog(providers: [provider, provider])
        ) { error in
            XCTAssertEqual(
                error as? AgentModelRuntimeError,
                .duplicateProvider(fixture.descriptor.id)
            )
        }

        let missing = try ModelFixture(offset: 1)
        XCTAssertThrowsError(try catalog.provider(for: missing.request.selection)) { error in
            XCTAssertEqual(
                error as? AgentModelRuntimeError,
                .providerNotFound(missing.descriptor.id)
            )
        }

        let prepared = try await AgentModelRequestPreparer().prepare(
            provider: provider,
            request: fixture.request,
            context: fixture.context
        )
        XCTAssertEqual(prepared.providerDescriptor, fixture.descriptor)
        XCTAssertEqual(prepared.capabilities, fixture.capabilities)
        XCTAssertEqual(prepared.preparedRequest.request, fixture.request)
        XCTAssertEqual(prepared.preparedRequest.externalOperation.plan.kind, .localPure)
        XCTAssertEqual(
            prepared.preparedRequest.externalOperation.plan.subjectID,
            fixture.descriptor.id.rawValue
        )
        XCTAssertEqual(
            prepared.preparedRequest.externalOperation.payload,
            fixture.context.authorizationPayload
        )
    }

    func testPreparationLimitsFailClosed() throws {
        let fixture = try ModelFixture()
        let values: [(UInt64, UInt64, UInt64)] = [
            (1, 1, 1),
            (fixture.context.maximumRequestBytes, 0, 1),
            (fixture.context.maximumRequestBytes, 1, 0),
        ]
        for (requestBytes, responseBytes, timeout) in values {
            XCTAssertThrowsError(
                try ModelPreparationContext(
                    conversationID: fixture.context.conversationID,
                    modelPolicy: fixture.context.modelPolicy,
                    capabilityGrant: fixture.context.capabilityGrant,
                    authorizationPayload: fixture.context.authorizationPayload,
                    maximumRequestBytes: requestBytes,
                    maximumResponseBytes: responseBytes,
                    timeoutMilliseconds: timeout
                )
            ) { error in
                XCTAssertEqual(error as? AgentModelRuntimeError, .invalidPreparationLimits)
            }
        }
    }

    func testPreparationRejectsRemoteProviderWrongProviderAndCapabilityRevision() async throws {
        let fixture = try ModelFixture()
        let remote = try ModelFixture(location: .remote)
        await assertModelError(.onlineProviderForbidden) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: ScriptedModelProvider(
                    descriptor: remote.descriptor,
                    capabilities: remote.capabilities
                ),
                request: remote.request,
                context: remote.context
            )
        }

        let other = try ModelFixture(offset: 2)
        await assertModelError(.providerSelectionMismatch) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: ScriptedModelProvider(
                    descriptor: other.descriptor,
                    capabilities: fixture.capabilities
                ),
                request: fixture.request,
                context: fixture.context
            )
        }

        let changedRevision = AgentModelProviderDescriptor(
            id: fixture.descriptor.id,
            adapterVersion: fixture.descriptor.adapterVersion,
            capabilityVersion: SemanticVersion("2.0.0")!,
            location: .onDevice
        )
        await assertModelError(.capabilityVersionMismatch) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: ScriptedModelProvider(
                    descriptor: changedRevision,
                    capabilities: fixture.capabilities
                ),
                request: fixture.request,
                context: fixture.context
            )
        }
    }

    func testPreparationRejectsPolicyAndAuthorizationPayloadMismatch() async throws {
        let fixture = try ModelFixture()
        let other = try ModelFixture(offset: 3)
        let disallowedPolicy = try AgentModelPolicy(
            localOnly: true,
            allowedSelections: [other.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let disallowedContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: disallowedPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        let provider = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities
        )
        await assertModelError(.selectionNotAllowed) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: disallowedContext
            )
        }

        let cloudPolicy = try AgentModelPolicy(
            localOnly: false,
            allowedSelections: [fixture.request.selection],
            strategy: .pinned,
            requiredCapabilities: AgentModelCapabilitySet([])
        )
        let cloudContext = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: cloudPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: fixture.context.authorizationPayload,
            maximumRequestBytes: fixture.context.maximumRequestBytes,
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        await assertModelError(.onlineProviderForbidden) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: cloudContext
            )
        }

        let mismatchedPayload = try ModelPreparationContext(
            conversationID: fixture.context.conversationID,
            modelPolicy: fixture.context.modelPolicy,
            capabilityGrant: fixture.context.capabilityGrant,
            authorizationPayload: other.context.authorizationPayload,
            maximumRequestBytes: max(
                fixture.context.maximumRequestBytes,
                other.context.maximumRequestBytes
            ),
            maximumResponseBytes: fixture.context.maximumResponseBytes,
            timeoutMilliseconds: fixture.context.timeoutMilliseconds
        )
        await assertModelError(.preparedRequestMismatch) {
            _ = try await AgentModelRequestPreparer().prepare(
                provider: provider,
                request: fixture.request,
                context: mismatchedPayload
            )
        }
    }

    func testCapabilityNegotiationRejectsEveryUnsupportedRequestShape() async throws {
        let required = try ModelFixture(requiredCapabilities: AgentModelCapabilitySet([.vision]))
        await assertModelError(
            .missingCapabilities(AgentModelCapabilitySet([.vision]))
        ) {
            _ = try await required.prepared()
        }

        let enabledThinking = try ModelFixture(
            features: AgentModelCapabilitySet([]),
            thinkingMode: .enabled
        )
        await assertModelError(
            .missingCapabilities(AgentModelCapabilitySet([.reasoning]))
        ) {
            _ = try await enabledThinking.prepared()
        }

        let fixture = try ModelFixture()
        let smaller = try AgentModelCapabilities(
            maximumContextTokens: 4_096,
            maximumOutputTokens: 512,
            features: fixture.capabilities.features,
            toolCallingMode: .unavailable,
            cancellationGranularity: .batch,
            resourceConstraints: fixture.capabilities.resourceConstraints,
            reportsTokenUsage: true,
            reportsCost: false
        )
        await assertModelError(.modelTokenLimitExceeded) {
            _ = try await fixture.prepared(
                provider: ScriptedModelProvider(
                    descriptor: fixture.descriptor,
                    capabilities: smaller
                )
            )
        }

        let inconsistent = try ModelFixture(
            features: AgentModelCapabilitySet([]),
            toolCallingMode: .textDialect
        )
        await assertModelError(.inconsistentCapabilities) {
            _ = try await inconsistent.prepared()
        }

        let tool = try ModelFixture.tool()
        let noTools = try ModelFixture(advertisedTools: [tool])
        await assertModelError(.toolCallingUnavailable) {
            _ = try await noTools.prepared()
        }

        let image = try ModelFixture.imageArtifact()
        let noVision = try ModelFixture(messageArtifacts: [image], offset: 7)
        await assertModelError(
            .missingCapabilities(AgentModelCapabilitySet([.vision]))
        ) {
            _ = try await noVision.prepared()
        }
        let vision = try ModelFixture(
            features: AgentModelCapabilitySet([.reasoning, .vision]),
            messageArtifacts: [image],
            offset: 8
        )
        _ = try await vision.prepared()
    }

    func testPreparedPlanCannotWidenOrChangeProviderIdentity() async throws {
        let fixture = try ModelFixture()
        let malformed = ScriptedModelProvider(
            descriptor: fixture.descriptor,
            capabilities: fixture.capabilities,
            preparationMode: .wrongSubject
        )
        await assertModelError(.preparedRequestMismatch) {
            _ = try await fixture.prepared(provider: malformed)
        }

        let remoteDescriptor = AgentModelProviderDescriptor(
            id: fixture.descriptor.id,
            adapterVersion: fixture.descriptor.adapterVersion,
            capabilityVersion: fixture.descriptor.capabilityVersion,
            location: .remote
        )
        XCTAssertThrowsError(
            try LocalAgentModelPreparation.prepare(
                request: fixture.request,
                context: fixture.context,
                provider: remoteDescriptor
            )
        ) { error in
            XCTAssertEqual(error as? AgentModelRuntimeError, .preparedRequestMismatch)
        }
    }
}

private func assertModelError(
    _ expected: AgentModelRuntimeError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)")
    } catch {
        XCTAssertEqual(error as? AgentModelRuntimeError, expected)
    }
}
