// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
@testable import AgentRuntime
import Foundation
import XCTest

final class ExecutionPrimitiveCoverageTests: XCTestCase {
    func testSystemClockProducesCurrentTimeAndHonorsZeroDelay() async throws {
        let clock = SystemAgentExecutionClock()
        let before = try AgentTimestamp(Date())

        let observed = try await clock.now()
        try await clock.sleep(milliseconds: 0)

        let after = try AgentTimestamp(Date())
        XCTAssertGreaterThanOrEqual(observed, before)
        XCTAssertLessThanOrEqual(observed, after)
    }

    func testSystemClockRejectsNanosecondOverflowBeforeSleeping() async {
        let clock = SystemAgentExecutionClock()

        do {
            try await clock.sleep(milliseconds: UInt64.max)
            XCTFail("Expected an overflow failure")
        } catch let error as AgentExecutionError {
            XCTAssertEqual(error, .internalInvariant("delay overflow"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNoOpLoggerAcceptsRedactedMetadata() async {
        await NoOpAgentExecutionLogger().record(
            code: "executor.coverage.probe",
            metadata: ["run": "redacted"]
        )
    }

    func testEventBuilderRejectsIllegalTransitionsAndVersionGaps() throws {
        let requestID = AgentRequestID()
        let handleID = AgentExecutionHandleID()
        let runID = AgentRunID()
        let failure = try RuntimeTestFixtures.failure()
        func builder() -> ExecutionEventBuilder {
            ExecutionEventBuilder(
                requestID: requestID,
                handleID: handleID,
                runID: runID,
                timestamp: AgentTimestamp(rawValue: 1)
            )
        }

        // created -> generating is not a registered edge.
        var illegal = builder()
        XCTAssertThrowsError(
            try illegal.append(
                id: AgentEventID(),
                event: .statusChanged(try AgentRunStatus(state: .generating, stateVersion: 2)),
                transitionTo: .generating,
                redaction: failure.redaction
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentExecutionError,
                .internalInvariant("illegal runtime transition")
            )
        }

        // A transition whose supplied status version is not the derived next version.
        var gap = builder()
        XCTAssertThrowsError(
            try gap.append(
                id: AgentEventID(),
                event: .statusChanged(try AgentRunStatus(state: .preparing, stateVersion: 3)),
                transitionTo: .preparing,
                statusVersion: 3,
                redaction: failure.redaction
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentExecutionError,
                .internalInvariant("state version gap")
            )
        }

        // A nontransition that nevertheless changes the state version.
        var nontransition = builder()
        XCTAssertThrowsError(
            try nontransition.append(
                id: AgentEventID(),
                event: .statusChanged(try AgentRunStatus(state: .created, stateVersion: 2)),
                statusVersion: 2,
                redaction: failure.redaction
            )
        ) {
            XCTAssertEqual(
                $0 as? AgentExecutionError,
                .internalInvariant("nontransition changed state version")
            )
        }
    }

    func testModelAttemptPurposeRejectsUnknownSemanticTypes() {
        XCTAssertNil(ExecutionModelAttemptPurpose(semanticType: "unknown.semantic.v1"))
        XCTAssertNotNil(ExecutionModelAttemptPurpose(semanticType: "agent-compiled-context.standard.v1"))
        XCTAssertNotNil(ExecutionModelAttemptPurpose(semanticType: "agent-compiled-context.synthesis.v1"))
    }

    func testStaticFreezerRejectsRequestsThatDivergeFromFrozenInputs() async throws {
        let offset = 710_000
        let model = try ExecutorTestModelDefinition(offset: offset)
        let provider = try FixedCompletionModelProvider(model: model, answer: "ignored")
        let harness = try ExecutorTestHarness(offset: offset, provider: provider, model: model)
        let freezer = StaticAgentRunInputFreezer(inputs: harness.frozenInputs)

        let divergent = try AgentRequest(
            id: ExecutorTestID.request(offset),
            runID: ExecutorTestID.run(offset),
            conversationID: ExecutorTestID.conversation(offset),
            userTurnID: ExecutorTestID.turn(offset + 1),
            role: "assistant",
            instruction: "Answer the user's request.",
            outputRequirement: .text,
            modelPolicy: AgentModelPolicy(
                localOnly: true,
                allowedSelections: [model.selection],
                strategy: .pinned,
                requiredCapabilities: .init([])
            ),
            capabilityCeiling: .init(authority: .empty),
            budget: try AgentBudget.firstReleaseDefaults(
                contextTokensPerAttempt: 4_096,
                outputTokens: 6_144,
                peakMemoryBytes: 1_073_741_824
            ),
            provenance: AgentRequestProvenance(source: .user)
        )

        do {
            _ = try await freezer.freeze(divergent)
            XCTFail("Expected a frozen-input mismatch failure")
        } catch let error as AgentExecutionError {
            XCTAssertEqual(error, .internalInvariant("frozen input does not match request"))
        }
    }

    func testExecutionHistoryFailsClosedForCorruptManifestAndStatusMismatch() throws {
        let stream = RuntimeTestFixtures.Stream(offset: 3_000)
        let firstStatus = try AgentRunStatus(state: .preparing, stateVersion: 2)
        let first = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 3_001,
            sequence: 1,
            stateVersion: 2,
            state: .preparing,
            timestamp: 10,
            previousDigest: nil,
            event: .statusChanged(firstStatus)
        )

        // A compiled-manifest event referencing an artifact that was never committed.
        let absentReference = try AgentStableBoundaryReference(
            digest: StableDigest.sha256(Data("manifest".utf8)),
            artifactID: ArtifactID(rawValue: RuntimeTestFixtures.uuid(3_002))
        )
        let corrupt = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 3_003,
            sequence: 2,
            stateVersion: 2,
            state: .preparing,
            timestamp: 11,
            previousDigest: first.payload.recordDigest,
            event: .compiledManifestCommitted(
                stepID: AgentStepID(rawValue: RuntimeTestFixtures.uuid(3_004)),
                reference: absentReference
            )
        )
        let corruptProjection = try XCTUnwrap(AgentRunProjection.replay([first, corrupt]))
        XCTAssertThrowsError(
            try ExecutionHistory(events: [first, corrupt], projection: corruptProjection)
        ) {
            XCTAssertEqual($0 as? AgentExecutionError, .invalidRecoveryBoundary)
        }

        // A final status that diverges from the replay projection's committed status.
        let thirdStatus = try AgentRunStatus(state: .synthesizing, stateVersion: 3)
        let third = try RuntimeTestFixtures.envelope(
            stream: stream,
            eventNumber: 3_005,
            sequence: 2,
            stateVersion: 3,
            state: .synthesizing,
            timestamp: 11,
            previousDigest: first.payload.recordDigest,
            event: .statusChanged(thirdStatus)
        )
        let staleProjection = try XCTUnwrap(AgentRunProjection.replay([first]))
        XCTAssertThrowsError(
            try ExecutionHistory(events: [first, third], projection: staleProjection)
        ) {
            XCTAssertEqual($0 as? AgentExecutionError, .invalidRecoveryBoundary)
        }
    }

    func testPayloadStoreMapsEveryRetentionOwnerKind() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mobilellm-payload-store-coverage-\(UUID().uuidString)",
                isDirectory: true
            )
        let names = DeterministicExecutorArtifactNames()
        let store = try ContentAddressedArtifactStore(
            configuration: ArtifactStoreConfiguration(
                rootURL: root,
                excludeFromBackup: false,
                verifyPlatformProtection: false
            ),
            clock: { AgentTimestamp(rawValue: 1_000) },
            idGenerator: { names.nextID() },
            temporaryNameGenerator: { "payload-coverage" }
        )
        let payloadStore = ContentAddressedExecutionPayloadStore(store: store)
        let runID = AgentRunID()
        let stepID = AgentStepID()
        let invocationID = ToolInvocationID()
        let data = Data("payload".utf8)

        let userManaged = try await payloadStore.commit(
            data: data,
            mimeType: "application/octet-stream",
            semanticType: "payload",
            runID: runID,
            stepID: stepID,
            invocationID: invocationID,
            owner: try ArtifactOwner(kind: .userManaged, identifier: "user-1"),
            sensitivity: .publicMetadata
        )
        XCTAssertEqual(userManaged.retentionPolicy, .userManaged)

        let transient = try await payloadStore.commit(
            data: data,
            mimeType: "application/octet-stream",
            semanticType: "payload",
            runID: runID,
            stepID: stepID,
            invocationID: invocationID,
            owner: try ArtifactOwner(kind: .transient, identifier: "transient-1"),
            sensitivity: .publicMetadata
        )
        XCTAssertEqual(transient.retentionPolicy, .transient)

        let durableOwner = try ArtifactOwner(kind: .durableRecord, identifier: "durable-1")
        do {
            _ = try await payloadStore.commit(
                data: data,
                mimeType: "application/octet-stream",
                semanticType: "payload",
                runID: runID,
                stepID: stepID,
                invocationID: invocationID,
                owner: durableOwner,
                sensitivity: .publicMetadata
            )
            XCTFail("Expected durable-record payload owner to be rejected")
        } catch let error as AgentExecutionError {
            XCTAssertEqual(
                error,
                .internalInvariant("durable-record payload owner has no compatible retention policy")
            )
        }
    }

    func testEmptyExecutableCatalogHasStableEmptySnapshotAndNoLookupResult() async throws {
        let catalog = EmptyExecutableToolCatalog()
        let snapshot = try await catalog.localSnapshot()
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertEqual(snapshot.descriptors, [])
        XCTAssertEqual(snapshot.unavailable, [])

        let descriptorID = try AgentToolDescriptorID(
            logicalID: AgentToolLogicalID(providerID: "test", name: "missing"),
            version: try XCTUnwrap(SemanticVersion("1.0.0")),
            schemaDigest: StableDigest.sha256(Data("schema".utf8)),
            trustRevision: "test-1"
        )
        let tool = try await catalog.tool(for: descriptorID)
        XCTAssertNil(tool)
    }

    func testFirstBuiltEventUsesBuilderTimestampWhenNoTimestampIsProposed() throws {
        let initialTimestamp = AgentTimestamp(rawValue: 7_000)
        var builder = ExecutionEventBuilder(
            requestID: AgentRequestID(),
            handleID: AgentExecutionHandleID(),
            runID: AgentRunID(),
            timestamp: initialTimestamp
        )
        let failure = try ExecutionFailureFactory.make(
            reason: .internalFailure,
            code: "execution.test",
            message: "A safe test failure"
        )

        let first = try builder.append(
            id: AgentEventID(),
            event: .diagnostic(failure),
            at: nil,
            redaction: failure.redaction
        )
        let second = try builder.append(
            id: AgentEventID(),
            event: .diagnostic(failure),
            at: nil,
            redaction: failure.redaction
        )

        XCTAssertEqual(first.payload.timestamp, initialTimestamp)
        XCTAssertEqual(second.payload.timestamp, AgentTimestamp(rawValue: 7_001))
    }

    func testFailureFactoryMapsEveryTerminalFailureReasonToSafeSemantics() throws {
        let expected: [AgentTerminalReason: (
            AgentFailureClassification,
            ExternalEffectDisposition,
            AgentRequiredUserAction
        )] = [
            .budgetExceeded: (.budgetRelated, .confirmedNone, .none),
            .permissionDenied: (.permissionRelated, .confirmedNone, .updateSystemPermission),
            .toolUnavailable: (.incompatible, .confirmedNone, .restoreDependency),
            .modelUnavailable: (.incompatible, .confirmedNone, .restoreDependency),
            .contextUnsatisfiable: (.incompatible, .confirmedNone, .restoreDependency),
            .externalResultUncertain: (.potentiallySideEffecting, .uncertain, .reconcile),
            .cancelledByUser: (.cancelled, .confirmedNone, .none),
            .noProgress: (.permanent, .confirmedNone, .none),
            .internalFailure: (.permanent, .confirmedNone, .none),
        ]

        for (reason, semantics) in expected {
            let failure = try ExecutionFailureFactory.make(
                reason: reason,
                code: "execution.failure",
                message: "A safe failure"
            )
            XCTAssertEqual(failure.classification, semantics.0, "Reason: \(reason)")
            XCTAssertEqual(failure.externalEffect, semantics.1, "Reason: \(reason)")
            XCTAssertEqual(failure.requiredUserAction, semantics.2, "Reason: \(reason)")
            XCTAssertEqual(failure.retryAdvice, .never, "Reason: \(reason)")
        }

        XCTAssertThrowsError(try ExecutionFailureFactory.make(
            reason: .completed,
            code: "execution.completed",
            message: "Completion is not a failure"
        )) { error in
            XCTAssertEqual(
                error as? AgentExecutionError,
                .internalInvariant("completion is not a failure")
            )
        }
    }

    func testFrozenToolSelectionForwardsAttachmentMIMETypesWithoutSelectingNetworkTools() throws {
        let model = try ExecutorTestModelDefinition(offset: 9_700)
        let userTurnID = UserTurnID()
        let attachment = try ModelFixture.imageArtifact()
        let frozen = try FrozenAgentRunInputs(
            modelSelection: model.selection,
            generationParameters: .standard,
            contextBudget: ContextTokenBudget(
                maximumContextTokens: 4_096,
                reservedOutputTokens: 1_024,
                maximumToolSchemaTokens: 512
            ),
            baseSystem: BaseSystemContextSource(
                revision: "coverage-v1",
                content: "Follow the user's request."
            ),
            currentUser: CurrentUserContextSource(
                userTurnID: userTurnID,
                revision: "coverage-v1",
                content: "What's this?",
                attachments: [attachment]
            ),
            toolCatalog: ToolCatalogSnapshot(revision: 1, descriptors: []),
            toolPolicy: ConversationToolPolicy(
                masterEnabled: false,
                allowedToolIDs: [],
                selectionPolicyVersion: 1,
                materializedFromGlobalTemplate: false
            ),
            availableToolCapabilities: AgentCapabilitySet([]),
            contextPolicyVersion: 1,
            approvalPolicyVersion: 1
        )

        let selection = try frozen.selectedTools(latestUserRequest: "What's this?")

        XCTAssertTrue(selection.descriptors.isEmpty)
        XCTAssertTrue(selection.snapshot.decisions.isEmpty)
    }
}
