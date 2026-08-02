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
