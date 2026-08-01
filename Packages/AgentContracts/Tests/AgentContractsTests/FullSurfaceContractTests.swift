// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class FullSurfaceContractTests: XCTestCase {
    func testCompleteAgentRequestAndResultSurfacesRoundTrip() throws {
        let fixture = try sandboxFixture()
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"),
            "properties": .object([
                "answer": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("answer")]),
            "additionalProperties": .bool(false),
        ]))
        let contexts = try AgentContextReference.Kind.allCases.enumerated().map { index, kind in
            try AgentContextReference(
                kind: kind,
                sourceID: "source-\(index)",
                revisionDigest: TestValues.digest(Character(String(index)))
            )
        }
        for context in contexts { try assertContractRoundTrip(context) }

        let firstLabel = try AgentRequestLabel(key: "request.priority", value: "high")
        let secondLabel = try AgentRequestLabel(key: "request.route", value: "local")
        XCTAssertTrue(firstLabel < secondLabel)
        try assertContractRoundTrip(firstLabel)

        let provenance = AgentRequestProvenance(
            source: .user,
            sourceMessageID: TestValues.id(MessageIDDomain.self, 510),
            evidenceDigests: [TestValues.digest("c"), TestValues.digest("b")]
        )
        try assertContractRoundTrip(provenance)
        let request = try AgentRequest(
            id: TestValues.id(AgentRequestIDDomain.self, 511),
            runID: TestValues.id(AgentRunIDDomain.self, 512),
            conversationID: TestValues.id(ConversationIDDomain.self, 513),
            userTurnID: TestValues.id(UserTurnIDDomain.self, 514),
            role: "primary",
            instruction: "Return one structured answer.",
            outputRequirement: .structured(schema),
            modelPolicy: try modelPolicy(),
            capabilityCeiling: RunCapabilityCeiling(authority: fixture.authority),
            budget: fixture.parentBudget,
            contextReferences: contexts,
            artifactReferences: [fixture.artifact],
            sandboxRequirement: fixture.requirement,
            labels: [secondLabel, firstLabel],
            provenance: provenance
        )
        try assertContractRoundTrip(request)

        let childAuthority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.localRead]),
            artifactIDs: [fixture.artifact.id]
        )
        let parent = ParentAgentContext(
            runID: request.runID,
            requestingStepID: TestValues.id(AgentStepIDDomain.self, 515),
            capabilityCeiling: request.capabilityCeiling
        )
        let child = try AgentRequest(
            id: TestValues.id(AgentRequestIDDomain.self, 516),
            runID: TestValues.id(AgentRunIDDomain.self, 517),
            conversationID: request.conversationID,
            userTurnID: request.userTurnID,
            parent: parent,
            role: "subagent",
            instruction: "Inspect the supplied artifact without mutation.",
            outputRequirement: .text,
            modelPolicy: try modelPolicy(),
            capabilityCeiling: RunCapabilityCeiling(authority: childAuthority),
            budget: TestValues.budget(limit: 100),
            artifactReferences: [fixture.artifact],
            provenance: AgentRequestProvenance(
                source: .parentAgent,
                parentRequestID: request.id,
                evidenceDigests: [TestValues.digest("d")]
            )
        )
        try assertContractRoundTrip(child)

        let input = try UserInputRequest(
            id: TestValues.id(InteractionRequestIDDomain.self, 518),
            runID: request.runID,
            prompt: "Which format should be used?",
            responseSchema: schema,
            creationStateVersion: 4
        )
        try assertContractRoundTrip(input)

        let answer = try AgentAnswer(
            text: "Done",
            structuredOutput: .object(["answer": .string("yes")]),
            artifacts: [fixture.artifact]
        )
        try assertContractRoundTrip(answer)
        let evidence = try [
            AgentEvidence(kind: "verification.alpha", digest: TestValues.digest("1")),
            AgentEvidence(kind: "verification.alpha", digest: TestValues.digest("2")),
            AgentEvidence(
                kind: "verification.alpha",
                digest: TestValues.digest("2"),
                artifactID: fixture.artifact.id
            ),
            AgentEvidence(kind: "verification.beta", digest: TestValues.digest("1")),
        ].sorted()
        for item in evidence { try assertContractRoundTrip(item) }
        let result = try AgentResult(
            requestID: request.id,
            executionHandleID: TestValues.id(AgentExecutionHandleIDDomain.self, 519),
            runID: request.runID,
            status: AgentRunStatus(
                state: .completed,
                stateVersion: 9,
                terminalReason: .completed
            ),
            answer: answer,
            usage: AgentUsage(quantities: BudgetQuantities([.outputTokens: 7])),
            evidence: evidence.reversed()
        )
        try assertContractRoundTrip(result)
    }

    func testCompleteSandboxSurfaceRoundTripsAndRejectsWidening() throws {
        let fixture = try sandboxFixture()
        try assertContractRoundTrip(fixture.filesystem)
        try assertContractRoundTrip(fixture.process)
        try assertContractRoundTrip(fixture.requirement)
        XCTAssertFalse(fixture.requirement.fingerprint.rawValue.isEmpty)

        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: fixture.authority),
            authority: fixture.authority
        )
        let runID = TestValues.id(AgentRunIDDomain.self, 520)
        let trusted = try TrustedRunAuthority(
            runID: runID,
            ceiling: grant.runCeiling,
            policyRevision: 1
        )
        XCTAssertNoThrow(try fixture.requirement.validateForExecution(
            runID: runID,
            stepGrant: grant,
            parentBudget: fixture.parentBudget,
            trustedRunAuthority: trusted
        ))

        let progress = try AgentExecutionProgress(
            phase: "sandbox.executing",
            completedUnits: 2,
            totalUnits: 4,
            safeMessage: "Running"
        )
        try assertContractRoundTrip(progress)
        XCTAssertThrowsError(try AgentExecutionProgress(
            phase: "sandbox.executing",
            completedUnits: 5,
            totalUnits: 4
        ))
        XCTAssertThrowsError(try AgentExecutionProgress(
            phase: "sandbox.executing",
            completedUnits: 1,
            safeMessage: "\n"
        ))
    }

    func testIdentifierCursorAndExplicitVersionSurfacesRoundTrip() throws {
        _ = AgentRunID()
        let firstSandbox = try SandboxEventCursor(
            executionHandleID: TestValues.id(SandboxExecutionHandleIDDomain.self, 530),
            eventID: TestValues.id(SandboxEventIDDomain.self, 531),
            sequence: 1
        )
        let secondSandbox = try SandboxEventCursor(
            executionHandleID: firstSandbox.executionHandleID,
            eventID: TestValues.id(SandboxEventIDDomain.self, 532),
            sequence: 2
        )
        XCTAssertEqual([secondSandbox, firstSandbox].sorted(), [firstSandbox, secondSandbox])
        try assertContractRoundTrip(firstSandbox)

        let firstEvent = try AgentEventCursor(
            executionHandleID: TestValues.id(AgentExecutionHandleIDDomain.self, 533),
            eventID: TestValues.id(AgentEventIDDomain.self, 534),
            sequence: 1,
            runStateVersion: 1,
            runState: .preparing,
            timestamp: AgentTimestamp(rawValue: 100),
            cumulativeUsage: .zero,
            recordDigest: TestValues.digest("4"),
            isTerminal: false
        )
        let secondEvent = try AgentEventCursor(
            executionHandleID: firstEvent.executionHandleID,
            eventID: TestValues.id(AgentEventIDDomain.self, 535),
            sequence: 2,
            runStateVersion: 2,
            runState: .generating,
            timestamp: AgentTimestamp(rawValue: 101),
            cumulativeUsage: .zero,
            recordDigest: TestValues.digest("5"),
            isTerminal: false
        )
        XCTAssertEqual([secondEvent, firstEvent].sorted(), [firstEvent, secondEvent])
        try assertContractRoundTrip(firstEvent)

        try AgentContractVersion.validate(
            protocolVersion: AgentContractVersion.currentProtocol,
            payloadVersion: AgentContractVersion.currentPayload
        )
        let reference = try AgentStableBoundaryReference(digest: TestValues.digest("6"))
        let explicit = try AgentEnvelope(
            protocolVersion: AgentContractVersion.currentProtocol,
            payloadVersion: AgentContractVersion.currentPayload,
            payload: reference,
            redaction: TestValues.redaction()
        )
        XCTAssertEqual(
            try AgentWireDecoder.decode(type(of: explicit), from: encodedJSON(explicit)).payload,
            reference
        )
    }
}

private extension FullSurfaceContractTests {
    struct SandboxFixture {
        let artifact: ArtifactReference
        let authority: AgentAuthorityScope
        let parentBudget: AgentBudget
        let filesystem: SandboxFilesystemRequirement
        let process: SandboxProcessRequirement
        let requirement: SandboxRequirement
    }

    func modelPolicy() throws -> AgentModelPolicy {
        let first = AgentModelSelection(
            providerID: try AgentModelProviderID("local.prism"),
            modelID: try AgentModelID("bonsai"),
            variantID: try AgentModelVariantID("8b-1bit"),
            capabilityVersion: SemanticVersion("1.0.0")!
        )
        let second = AgentModelSelection(
            providerID: try AgentModelProviderID("local.mlx"),
            modelID: try AgentModelID("gemma"),
            variantID: try AgentModelVariantID("e2b"),
            capabilityVersion: SemanticVersion("1.1.0")!
        )
        return try AgentModelPolicy(
            localOnly: true,
            allowedSelections: [first, second],
            strategy: .deterministicLocalPolicy,
            requiredCapabilities: AgentModelCapabilitySet([.reasoning, .jsonSchemaConstraint])
        )
    }

    func sandboxFixture() throws -> SandboxFixture {
        let artifact = TestValues.artifact()
        let destination = TestValues.destination("sandbox")
        let workspaceID = TestValues.id(SandboxWorkspaceHandleIDDomain.self, 540)
        let checkpointID = TestValues.id(SandboxCheckpointHandleIDDomain.self, 541)
        let secretID = TestValues.id(SecretReferenceIDDomain.self, 542)
        let secret = try SecretReference(
            id: secretID,
            purpose: "sandbox credential",
            providerID: "keychain.local"
        )
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.localRead, .localWrite, .networkRead, .codeExecution]),
            destinations: [destination],
            artifactIDs: [artifact.id],
            secretReferenceIDs: [secretID],
            workspaceIDs: [workspaceID],
            checkpointIDs: [checkpointID],
            constraints: [try AgentAuthorityConstraint(
                key: "sandbox.runtime",
                allowedValues: ["swift.native", "python.local"]
            )]
        )
        let parentBudget = TestValues.budget(limit: 1_000)
        let filesystem = try SandboxFilesystemRequirement(
            logicalRoot: "workspace.output",
            access: .readWrite,
            artifactIDs: [artifact.id],
            maximumWrittenBytes: 100
        )
        let process = try SandboxProcessRequirement(
            maximumConcurrentProcesses: 2,
            maximumProcessLaunches: 4,
            allowedRuntimeIDs: ["swift.native", "python.local"]
        )
        let requirement = try SandboxRequirement(
            minimumProtocolVersion: SemanticVersion("1.0.0")!,
            workspaceID: workspaceID,
            checkpointID: checkpointID,
            authority: authority,
            budget: TestValues.budget(limit: 500),
            filesystem: [filesystem],
            networkDestinations: [destination],
            process: process,
            secretReferences: [secret]
        )
        return SandboxFixture(
            artifact: artifact,
            authority: authority,
            parentBudget: parentBudget,
            filesystem: filesystem,
            process: process,
            requirement: requirement
        )
    }
}
