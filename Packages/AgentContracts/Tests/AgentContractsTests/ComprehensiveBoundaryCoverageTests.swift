// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

final class ComprehensiveBoundaryCoverageTests: XCTestCase {
    func testAllContractErrorsExposeStableSafeDescriptions() throws {
        let version = try XCTUnwrap(SemanticVersion("2.0.0"))
        let reservation = TestValues.id(BudgetReservationIDDomain.self, 1)
        let errors: [AgentContractError] = [
            .invalidTimestamp,
            .invalidRedactionMetadata,
            .invalidSchemaDeclaration("bad"),
            .invalidSemanticVersion,
            .unsupportedProtocolVersion(received: version, supportedMajor: 1),
            .unsupportedPayloadVersion(received: 2, supported: 1 ... 1),
            .schemaMismatch(expected: "a", received: "b"),
            .invalidDigest("bad"),
            .nonFiniteJSONNumber,
            .integerOutsideIJSONRange,
            .nonCanonicalJSON,
            .wireLimitExceeded("bytes"),
            .invalidName("field"),
            .capabilityEscalation([.localRead]),
            .capabilityNotStrictlyAttenuated,
            .budgetExceeded(dimension: .activeMilliseconds, limit: 1, requested: 2),
            .arithmeticOverflow(dimension: .outputTokens),
            .reservationNotFound(reservation),
            .conflictingReservation(reservation),
            .usageExceedsReservation(reservation),
            .invalidExternalOperationPlan("plan"),
            .authorizationDenied,
            .authorizationExpired,
            .authorizationBindingMismatch("binding"),
            .invalidArtifactReference("artifact"),
            .invalidJSONSchema("schema"),
            .invalidCommand("command"),
            .invalidEventSequence("event"),
            .invalidRunStatus("status"),
        ]

        for error in errors {
            XCTAssertFalse(try XCTUnwrap(error.errorDescription).isEmpty)
        }
    }

    func testPrimitiveCanonicalAndSecretBoundariesRoundTrip() throws {
        let timestamp = try AgentTimestamp(Date(timeIntervalSince1970: 1.25))
        XCTAssertEqual(timestamp.rawValue, 1_250)
        XCTAssertEqual(timestamp.date.timeIntervalSince1970, 1.25, accuracy: 0.000_001)

        let digest = StableDigest.fingerprint(
            domain: "coverage.digest",
            components: [Data("a".utf8), Data("bc".utf8)]
        )
        XCTAssertEqual(digest.description, digest.rawValue)
        try assertContractRoundTrip(digest)

        let encodedScalars: [JSONValue] = [
            .null,
            .bool(true),
            .integer(-4),
            .unsignedInteger(UInt64.max),
            .number(1.25),
            .string("value"),
            .array([.bool(false)]),
            .object(["key": .string("value")]),
        ]
        for value in encodedScalars {
            _ = try AgentWireDecoder.decode(JSONValue.self, from: encodedJSON(value))
        }

        let value = JSONValue.object([
            "array": .array([.null, .bool(true), .integer(-2), .number(0.000_001)]),
            "escaped": .string("\u{0008}\t\n\u{000c}\r\"\\"),
            "unsigned": .unsignedInteger(42),
        ])
        let canonical = try CanonicalJSON(value)
        XCTAssertEqual(try CanonicalJSON(canonicalData: canonical.data), canonical)
        XCTAssertFalse(canonical.string.isEmpty)
        try assertContractRoundTrip(canonical)

        let firstSecret = TestValues.id(SecretReferenceIDDomain.self, 2)
        let secondSecret = TestValues.id(SecretReferenceIDDomain.self, 3)
        let redaction = try RedactionMetadata(
            classification: .secret,
            redactedFieldPaths: ["$.token", "$.password"],
            omittedByteCount: 12,
            policyVersion: 3
        )
        let sanitized = try SanitizedCanonicalJSON(
            value: canonical,
            referencedSecretIDs: [secondSecret, firstSecret],
            redaction: redaction,
            policyRevision: 4,
            attestationDigest: TestValues.digest("d")
        )
        XCTAssertEqual(sanitized.data, canonical.data)
        XCTAssertEqual(sanitized.string, canonical.string)
        XCTAssertEqual(sanitized.fingerprint, canonical.fingerprint)
        try assertContractRoundTrip(sanitized)

        let secret = try SecretReference(
            id: firstSecret,
            purpose: "credential for boundary test",
            providerID: "keychain"
        )
        try assertContractRoundTrip(secret)
    }

    func testMaximalAuthorityScopesRoundTripAndAttenuateEveryDimension() throws {
        let capabilities = AgentCapabilitySet([
            .networkRead, .localRead, .localWrite, .privateDataRead, .externalWrite,
            .externalCommunication, .destructive, .financial, .codeExecution,
        ])
        XCTAssertTrue(capabilities.isStrictSubset(of: AgentCapabilitySet(capabilities.values + [.unknownExternal])))
        XCTAssertFalse(capabilities.fingerprint.rawValue.isEmpty)
        XCTAssertEqual(AgentCapability.localRead.description, "local.read")
        try assertContractRoundTrip(AgentCapability.localRead)
        try assertContractRoundTrip(capabilities)

        let firstConstraint = try AgentAuthorityConstraint(
            key: "filesystem.paths",
            allowedValues: ["tmp", "docs"]
        )
        let secondConstraint = try AgentAuthorityConstraint(
            key: "process.runtimes",
            allowedValues: ["swift", "python"]
        )
        XCTAssertTrue(
            try AgentAuthorityConstraint(key: "filesystem.paths", allowedValues: ["docs"])
                .isSubset(of: firstConstraint)
        )
        XCTAssertNotEqual(firstConstraint < secondConstraint, secondConstraint < firstConstraint)
        try assertContractRoundTrip(firstConstraint)

        let destinations = [
            try ExternalDestination(kind: .networkEndpoint, normalizedIdentity: "https://b.invalid"),
            try ExternalDestination(kind: .fileReference, normalizedIdentity: "bookmark:a"),
        ]
        let categories = [
            try AgentDataCategory(rawValue: "user.private"),
            try AgentDataCategory(rawValue: "user.query"),
        ]
        let artifacts = [
            TestValues.id(ArtifactIDDomain.self, 12),
            TestValues.id(ArtifactIDDomain.self, 11),
        ]
        let secrets = [
            TestValues.id(SecretReferenceIDDomain.self, 14),
            TestValues.id(SecretReferenceIDDomain.self, 13),
        ]
        let workspaces = [
            TestValues.id(SandboxWorkspaceHandleIDDomain.self, 16),
            TestValues.id(SandboxWorkspaceHandleIDDomain.self, 15),
        ]
        let checkpoints = [
            TestValues.id(SandboxCheckpointHandleIDDomain.self, 18),
            TestValues.id(SandboxCheckpointHandleIDDomain.self, 17),
        ]
        let scope = try AgentAuthorityScope(
            capabilities: capabilities,
            destinations: destinations.reversed(),
            dataCategories: categories.reversed(),
            artifactIDs: artifacts,
            secretReferenceIDs: secrets,
            workspaceIDs: workspaces,
            checkpointIDs: checkpoints,
            constraints: [secondConstraint, firstConstraint]
        )
        XCTAssertFalse(scope.fingerprint.rawValue.isEmpty)
        try assertContractRoundTrip(scope)

        let localCeiling = RunCapabilityCeiling(capabilities: AgentCapabilitySet([.localRead]))
        let localGrant = try StepCapabilityGrant(
            runCeiling: localCeiling,
            capabilities: AgentCapabilitySet([.localRead])
        )
        XCTAssertEqual(localGrant.capabilities, AgentCapabilitySet([.localRead]))
        try assertContractRoundTrip(localGrant)

        let ceiling = RunCapabilityCeiling(authority: scope)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: scope)
        try assertContractRoundTrip(grant)
        let trusted = try TrustedRunAuthority(
            runID: TestValues.id(AgentRunIDDomain.self, 19),
            ceiling: ceiling,
            policyRevision: 1
        )
        XCTAssertTrue(trusted.validates(runID: trusted.runID, grant: grant))
        XCTAssertFalse(trusted.validates(runID: TestValues.id(AgentRunIDDomain.self, 20), grant: grant))

        for effect in AgentEffect.allCases {
            _ = effect.minimumCapability
        }
        XCTAssertEqual(AgentEffect.allCases.sorted().count, AgentEffect.allCases.count)
    }

    func testBudgetArithmeticAndMaximumAccountingSuccessPaths() throws {
        let lhs = BudgetQuantities([.activeMilliseconds: 2, .peakMemoryBytes: 7])
        let rhs = BudgetQuantities([.activeMilliseconds: 3, .peakMemoryBytes: 5])
        let sum = try lhs.adding(rhs)
        XCTAssertEqual(sum[.activeMilliseconds], 5)
        XCTAssertEqual(sum[.peakMemoryBytes], 12)
        let maximum = lhs.componentwiseMaximum(rhs)
        XCTAssertEqual(maximum[.activeMilliseconds], 3)
        XCTAssertEqual(maximum[.peakMemoryBytes], 7)
        try assertContractRoundTrip(lhs)
        try assertContractRoundTrip(TestValues.budget(limit: 50))
    }

    func testMaximalExternalOperationRoundTripsWithoutLosingAuthorizationScope() throws {
        let fixture = try maximalExternalFixture()
        XCTAssertTrue(fixture.plan.isWithin(fixture.authority))
        XCTAssertTrue(fixture.observation.isWithin(fixture.plan))
        XCTAssertEqual(fixture.key.description, fixture.key.digest.rawValue)

        try assertContractRoundTrip(fixture.plan.destination!)
        try assertContractRoundTrip(fixture.plan.dataCategories[0])
        try assertContractRoundTrip(fixture.plan.retryPolicy)
        try assertContractRoundTrip(fixture.plan)
        try assertContractRoundTrip(fixture.prepared)
        try assertContractRoundTrip(fixture.receipt)
        try assertContractRoundTrip(fixture.attempt)
        try assertContractRoundTrip(fixture.hop)
        try assertContractRoundTrip(fixture.observation)
        XCTAssertTrue(fixture.receipt.isUsable(at: AgentTimestamp(rawValue: 100)))
        XCTAssertFalse(fixture.receipt.isUsable(at: AgentTimestamp(rawValue: 201)))
    }

    func testExternalOperationSemanticsRejectEveryUnsafeCombination() throws {
        let destination = TestValues.destination("semantics")
        let retry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 1,
            maximumDelayMilliseconds: 2,
            allowsJitter: true
        )
        try assertContractRoundTrip(retry)

        XCTAssertThrowsError(
            try basePlan(destination: destination, effects: [], capabilities: .init([]))
        )
        XCTAssertThrowsError(
            try basePlan(
                destination: destination,
                effects: [.externalWrite],
                capabilities: .init([.externalWrite]),
                idempotency: .pureRead
            )
        )
        XCTAssertThrowsError(
            try basePlan(destination: destination, effects: [.networkRead], capabilities: .init([]))
        )
        XCTAssertThrowsError(
            try basePlan(
                destination: destination,
                effects: [.externalWrite],
                capabilities: .init([.externalWrite]),
                retry: retry,
                idempotency: .nonIdempotent
            )
        )
        XCTAssertThrowsError(
            try basePlan(
                destination: destination,
                effects: [.externalWrite],
                capabilities: .init([.externalWrite]),
                retry: retry,
                idempotency: .reconciliationAvailable
            )
        )
        XCTAssertThrowsError(
            try basePlan(
                destination: destination,
                effects: [.unknownExternal],
                capabilities: .init([.unknownExternal]),
                retry: retry,
                idempotency: .reconciliationAvailable
            )
        )
    }

    func testToolDescriptorResultsProgressAndTerminalStreamsRoundTrip() throws {
        let descriptor = try maximalToolDescriptor()
        XCTAssertFalse(descriptor.id.description.isEmpty)
        XCTAssertFalse(descriptor.id.logicalID.description.isEmpty)
        XCTAssertEqual([descriptor.id.logicalID, descriptor.id.logicalID].sorted().count, 2)
        try assertContractRoundTrip(descriptor.id.logicalID)
        try assertContractRoundTrip(descriptor.id)
        try assertContractRoundTrip(descriptor.timeoutPolicy)
        try assertContractRoundTrip(descriptor)

        let call = ProposedToolCall(
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 80),
            toolID: descriptor.id.logicalID,
            arguments: try CanonicalJSON(.object(["query": .string("hello")]))
        )
        XCTAssertFalse(call.baseFingerprint.rawValue.isEmpty)

        let structured = try ToolStructuredResult(
            CanonicalJSON(.object(["ok": .bool(true)]))
        )
        let resource = try ToolResourceLink(
            url: "https://example.invalid/result",
            mimeType: "application/json"
        )
        let image = TestValues.artifact(mimeType: "image/png")
        let collection = try ToolResultCollection([
            .text(ToolTextResult("done")),
            .structured(structured),
            .resourceLink(resource),
            .image(image),
            .artifact(TestValues.artifact()),
        ])
        XCTAssertEqual(collection.startIndex, 0)
        XCTAssertEqual(collection.endIndex, 5)
        _ = collection[0]
        try assertContractRoundTrip(structured)
        try assertContractRoundTrip(resource)
        try assertContractRoundTrip(collection)

        let progress = try ToolExecutionProgress(
            completedUnits: 1,
            totalUnits: 2,
            message: "working"
        )
        try assertContractRoundTrip(progress)
        let progressEvent = ToolExecutionEvent.progress(progress)
        let completedEvent = ToolExecutionEvent.completed(collection)
        XCTAssertFalse(progressEvent.isTerminal)
        XCTAssertTrue(completedEvent.isTerminal)
        XCTAssertTrue(ToolExecutionEvent.failed(TestValues.failure()).isTerminal)
        try ToolExecutionStreamValidator.validate([progressEvent, completedEvent])
        try ToolExecutionStreamValidator.validate([progressEvent], requireTerminal: false)
        XCTAssertThrowsError(try ToolExecutionStreamValidator.validate([progressEvent]))
        XCTAssertThrowsError(
            try ToolExecutionStreamValidator.validate([completedEvent, progressEvent])
        )

        try AgentToolInvocationOutcome.completed(collection).validate()
        try AgentToolInvocationOutcome.failed(TestValues.failure()).validate()
        let uncertain = TestValues.failure(
            classification: .potentiallySideEffecting,
            externalEffect: .uncertain,
            action: .reconcile
        )
        try AgentToolInvocationOutcome.uncertain(uncertain).validate()
        XCTAssertThrowsError(try AgentToolInvocationOutcome.failed(uncertain).validate())
        XCTAssertThrowsError(
            try AgentToolInvocationOutcome.uncertain(TestValues.failure()).validate()
        )
    }

    func testSystemAuthorizationClockProducesFiniteTimestamp() async throws {
        let timestamp = try await SystemAgentAuthorizationClock().now()
        XCTAssertGreaterThan(timestamp.rawValue, 0)
    }
}

private extension ComprehensiveBoundaryCoverageTests {
    struct ExternalFixture {
        let authority: AgentAuthorityScope
        let plan: ExternalOperationPlan
        let prepared: PreparedExternalOperationRequest
        let receipt: ApprovalReceipt
        let attempt: ExternalOperationAttempt
        let hop: ExternalOperationBoundaryHop
        let observation: ExternalOperationObservation
        let key: ExternalIdempotencyKey
    }

    func maximalExternalFixture() throws -> ExternalFixture {
        let argumentSecret = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 40),
            purpose: "argument substitution",
            providerID: "keychain"
        )
        let credential = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 41),
            purpose: "boundary credential",
            providerID: "keychain"
        )
        let body = try CanonicalJSON(.object(["query": .string("value")]))
        let sanitized = try SanitizedCanonicalJSON(
            value: body,
            referencedSecretIDs: [argumentSecret.id],
            redaction: RedactionMetadata(
                classification: .secret,
                redactedFieldPaths: ["$.credential"],
                omittedByteCount: 8,
                policyVersion: 2
            ),
            policyRevision: 2,
            attestationDigest: TestValues.digest("8")
        )
        let primary = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://primary.invalid"
        )
        let redirect = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://redirect.invalid"
        )
        let fallback = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://fallback.invalid"
        )
        let categories = [
            try AgentDataCategory(rawValue: "user.private"),
            try AgentDataCategory(rawValue: "user.query"),
        ]
        let artifacts = [
            TestValues.id(ArtifactIDDomain.self, 43),
            TestValues.id(ArtifactIDDomain.self, 42),
        ]
        let workspace = TestValues.id(SandboxWorkspaceHandleIDDomain.self, 44)
        let constraints = [
            try AgentAuthorityConstraint(key: "filesystem.paths", allowedValues: ["tmp", "docs"]),
            try AgentAuthorityConstraint(key: "process.runtimes", allowedValues: ["swift"]),
        ]
        let effects: [AgentEffect] = [
            .localRead, .localWrite, .privateDataRead, .networkRead, .externalWrite,
            .externalCommunication, .destructive, .financial, .codeExecution,
        ]
        let capabilities = AgentCapabilitySet(effects.compactMap(\.minimumCapability))
        let authority = try AgentAuthorityScope(
            capabilities: capabilities,
            destinations: [fallback, redirect, primary],
            dataCategories: categories,
            artifactIDs: artifacts,
            secretReferenceIDs: [argumentSecret.id, credential.id],
            workspaceIDs: [workspace],
            constraints: constraints
        )
        let key = ExternalIdempotencyKey.derive(components: [Data("request-1".utf8)])
        let retry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 3,
            baseDelayMilliseconds: 10,
            maximumDelayMilliseconds: 100,
            allowsJitter: true
        )
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "coverage.maximal-tool",
            canonicalArguments: sanitized,
            destination: primary,
            allowedRedirects: [redirect],
            allowedFallbacks: [fallback],
            dataCategories: categories,
            artifactIDs: artifacts,
            workspaceID: workspace,
            authorityConstraints: constraints,
            payloadDigest: sanitized.fingerprint,
            executionConstraintDigest: TestValues.digest("7"),
            effects: effects,
            requiredCapabilities: capabilities,
            maximumRequestBytes: 4_096,
            maximumResponseBytes: 8_192,
            timeoutMilliseconds: 1_000,
            retryPolicy: retry,
            idempotency: .idempotencyKeyRequired,
            idempotencyKey: key,
            userPreview: "Execute the complete bounded operation",
            descriptorID: "coverage.maximal-tool@1",
            schemaDigest: TestValues.digest("6"),
            trustRevision: "local-2",
            credentialReference: credential
        )
        let ceiling = RunCapabilityCeiling(authority: authority)
        let grant = try StepCapabilityGrant(runCeiling: ceiling, authority: authority)
        let prepared = try PreparedExternalOperationRequest(
            requestID: TestValues.id(AgentRequestIDDomain.self, 45),
            runID: TestValues.id(AgentRunIDDomain.self, 46),
            conversationID: TestValues.id(ConversationIDDomain.self, 47),
            stepID: TestValues.id(AgentStepIDDomain.self, 48),
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 49),
            plan: plan,
            payload: sanitized,
            capabilityGrant: grant
        )
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 50),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 2,
            decidedAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 2)
        let hop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: redirect
        )
        let observation = try ExternalOperationObservation(
            destination: redirect,
            dataCategories: categories,
            effects: effects,
            requestBytes: UInt64(sanitized.data.count),
            responseBytesLimit: 4_096,
            payloadDigest: sanitized.fingerprint,
            executionConstraintDigest: plan.executionConstraintDigest,
            artifactIDs: artifacts,
            workspaceID: workspace,
            descriptorID: plan.descriptorID,
            schemaDigest: plan.schemaDigest,
            trustRevision: plan.trustRevision,
            idempotencyKey: key,
            credentialReference: credential,
            resolvedSecretReferenceIDs: [argumentSecret.id, credential.id]
        )
        return ExternalFixture(
            authority: authority,
            plan: plan,
            prepared: prepared,
            receipt: receipt,
            attempt: attempt,
            hop: hop,
            observation: observation,
            key: key
        )
    }

    func basePlan(
        destination: ExternalDestination,
        effects: [AgentEffect],
        capabilities: AgentCapabilitySet,
        retry: ExternalRetryPolicy = .never,
        idempotency: ExternalIdempotency = .reconciliationAvailable
    ) throws -> ExternalOperationPlan {
        try ExternalOperationPlan(
            kind: .tool,
            subjectID: "coverage.semantics",
            destination: destination,
            effects: effects,
            requiredCapabilities: capabilities,
            maximumRequestBytes: 4,
            maximumResponseBytes: 1,
            timeoutMilliseconds: 1,
            retryPolicy: retry,
            idempotency: idempotency,
            userPreview: "Boundary"
        )
    }

    func maximalToolDescriptor() throws -> AgentToolDescriptor {
        let schema = try JSONSchemaDocument(root: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]))
        let logical = try AgentToolLogicalID(providerID: "coverage", name: "search")
        let descriptorID = try AgentToolDescriptorID(
            logicalID: logical,
            version: XCTUnwrap(SemanticVersion("1.2.3")),
            schemaDigest: schema.digest,
            trustRevision: "local-1"
        )
        return try AgentToolDescriptor(
            id: descriptorID,
            title: "Search",
            summary: "Searches a bounded local index.",
            inputSchema: schema,
            outputSchema: schema,
            effects: [AgentEffect.networkRead, AgentEffect.externalWrite],
            requiredCapabilities: AgentCapabilitySet([.networkRead, .externalWrite]),
            timeoutPolicy: ToolTimeoutPolicy(maximumMilliseconds: 1_000),
            retryPolicy: ExternalRetryPolicy(
                kind: .boundedExponential,
                maximumAttempts: 2,
                baseDelayMilliseconds: 1,
                maximumDelayMilliseconds: 2
            ),
            idempotency: .idempotencyKeyRequired,
            supportsProgress: true,
            supportsCancellation: true
        )
    }
}
