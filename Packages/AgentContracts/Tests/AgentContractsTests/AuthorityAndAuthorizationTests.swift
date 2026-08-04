// SPDX-License-Identifier: MIT

import XCTest
@_spi(AgentRuntime) @testable import AgentContracts

// TEST-ID: AHT-SUBAGENT-001
final class AuthorityAndAuthorizationTests: XCTestCase {
    func testHTTPSWildcardDestinationCoversConcreteHTTPSOnly() throws {
        let wildcard = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: ExternalDestination.anyHTTPSNetworkEndpoint
        )
        let https = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://example.com"
        )
        let http = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "http://example.com"
        )
        XCTAssertTrue(wildcard.covers(https))
        XCTAssertFalse(wildcard.covers(http))
        XCTAssertTrue(https.covers(https))
        XCTAssertFalse(https.covers(wildcard), "the wildcard is not a concrete host")

        let wildcardScope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [wildcard],
            dataCategories: [try AgentDataCategory(rawValue: "web.page")]
        )
        let concreteScope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [https],
            dataCategories: [try AgentDataCategory(rawValue: "web.page")]
        )
        XCTAssertTrue(concreteScope.isSubset(of: wildcardScope))
        let httpOnly = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [http],
            dataCategories: [try AgentDataCategory(rawValue: "web.page")]
        )
        XCTAssertFalse(httpOnly.isSubset(of: wildcardScope), "http must never be covered by https://*")
    }

    func testPlanIsWithinWildcardHTTPSAuthority() throws {
        let concrete = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://docs.example.com"
        )
        let prepared = try TestValues.preparedRead(destination: concrete)
        let wildcardScope = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [
                try ExternalDestination(
                    kind: .networkEndpoint,
                    normalizedIdentity: ExternalDestination.anyHTTPSNetworkEndpoint
                ),
            ],
            dataCategories: [TestValues.category()]
        )
        XCTAssertTrue(prepared.plan.isWithin(wildcardScope),
                      "a concrete https plan must fit under the https wildcard ceiling")
        let httpDest = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "http://docs.example.com"
        )
        let httpPrepared = try TestValues.preparedRead(destination: httpDest)
        XCTAssertFalse(httpPrepared.plan.isWithin(wildcardScope),
                       "http plans must never fit under the https-only wildcard")
    }

    func testEveryAuthorityDimensionAttenuatesAndFingerprints() throws {
        let destination = TestValues.destination()
        let artifact = TestValues.id(ArtifactIDDomain.self, 10)
        let secret = TestValues.id(SecretReferenceIDDomain.self, 11)
        let workspace = TestValues.id(SandboxWorkspaceHandleIDDomain.self, 12)
        let checkpoint = TestValues.id(SandboxCheckpointHandleIDDomain.self, 13)
        let constraint = try AgentAuthorityConstraint(
            key: "filesystem.paths",
            allowedValues: ["docs", "tmp"]
        )
        let parent = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead, .localRead]),
            destinations: [destination],
            dataCategories: [TestValues.category()],
            artifactIDs: [artifact],
            secretReferenceIDs: [secret],
            workspaceIDs: [workspace],
            checkpointIDs: [checkpoint],
            constraints: [constraint]
        )
        let child = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            destinations: [destination],
            dataCategories: [TestValues.category()],
            secretReferenceIDs: [secret],
            constraints: [AgentAuthorityConstraint(key: "filesystem.paths", allowedValues: ["docs"])]
        )
        XCTAssertTrue(child.isStrictSubset(of: parent))
        XCTAssertNotEqual(child.fingerprint, parent.fingerprint)
        XCTAssertThrowsError(
            try RunCapabilityCeiling(authority: child).attenuating(to: parent, requireStrict: true)
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: parent),
            authority: child
        )
        XCTAssertNotEqual(grant.fingerprint, grant.runCeiling.fingerprint)
    }

    func testPreparedPayloadAndSecretAreFullyFingerprintBound() throws {
        let firstSecret = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 20),
            purpose: "weather read",
            providerID: "provider-a"
        )
        let changedPurpose = try SecretReference(
            id: firstSecret.id,
            purpose: "mail send",
            providerID: "provider-a"
        )
        let first = try TestValues.preparedRead(secret: firstSecret)
        let second = try TestValues.preparedRead(secret: changedPurpose)
        XCTAssertNotEqual(first.plan.fingerprint, second.plan.fingerprint)

        let substituted = try CanonicalJSON(.object(["query": .string("private replacement")]))
        XCTAssertThrowsError(
            try PreparedExternalOperationRequest(
                requestID: first.requestID,
                runID: first.runID,
                conversationID: first.conversationID,
                stepID: first.stepID,
                invocationID: first.invocationID,
                plan: first.plan,
                payload: TestValues.sanitized(substituted),
                capabilityGrant: first.capabilityGrant
            )
        )
    }

    func testConversationReceiptReusesOnlyIdenticalBoundedReadPlan() throws {
        let original = try TestValues.preparedRead()
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 30),
            prepared: original,
            decision: .approved,
            scope: .conversation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )
        let laterRun = try TestValues.preparedRead(
            requestID: TestValues.id(AgentRequestIDDomain.self, 31),
            runID: TestValues.id(AgentRunIDDomain.self, 32),
            conversationID: original.conversationID,
            stepID: TestValues.id(AgentStepIDDomain.self, 33),
            invocationID: TestValues.id(ToolInvocationIDDomain.self, 34)
        )
        XCTAssertNoThrow(
            try AuthorizedExternalOperationRequest(
                prepared: laterRun,
                authorization: receipt,
                trustedRunAuthority: trustedAuthority(for: laterRun)
            )
        )

        let otherConversation = try TestValues.preparedRead(
            requestID: TestValues.id(AgentRequestIDDomain.self, 35),
            runID: TestValues.id(AgentRunIDDomain.self, 36),
            conversationID: TestValues.id(ConversationIDDomain.self, 37),
            stepID: TestValues.id(AgentStepIDDomain.self, 38)
        )
        XCTAssertThrowsError(
            try AuthorizedExternalOperationRequest(
                prepared: otherConversation,
                authorization: receipt,
                trustedRunAuthority: trustedAuthority(for: otherConversation)
            )
        )

        XCTAssertFalse(receipt.isUsable(at: AgentTimestamp(rawValue: 99)))
        XCTAssertTrue(receipt.isUsable(at: AgentTimestamp(rawValue: 100)))
        XCTAssertTrue(receipt.isUsable(at: AgentTimestamp(rawValue: 200)))
        XCTAssertFalse(receipt.isUsable(at: AgentTimestamp(rawValue: 201)))
    }

    func testExactReceiptBindsPreparedRequestAndGrantFingerprints() throws {
        let original = try TestValues.preparedRead()
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 40),
            prepared: original,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1)
        )
        XCTAssertNoThrow(
            try AuthorizedExternalOperationRequest(
                prepared: original,
                authorization: receipt,
                trustedRunAuthority: trustedAuthority(for: original)
            )
        )
        let replacement = try TestValues.preparedRead(
            requestID: original.requestID,
            runID: original.runID,
            conversationID: original.conversationID,
            stepID: original.stepID,
            invocationID: original.invocationID,
            grantAuthority: try AgentAuthorityScope(
                capabilities: AgentCapabilitySet([.networkRead]),
                destinations: [TestValues.destination(), TestValues.destination("unused")],
                dataCategories: [TestValues.category()]
            )
        )
        XCTAssertThrowsError(
            try AuthorizedExternalOperationRequest(
                prepared: replacement,
                authorization: receipt,
                trustedRunAuthority: trustedAuthority(for: replacement)
            )
        )
    }

    func testRetryableWriteRequiresAndCarriesExactIdempotencyKey() throws {
        let payload = try CanonicalJSON(.object(["message": .string("send once")]))
        let destination = TestValues.destination("write")
        let authority = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.externalWrite]),
            destinations: [destination],
            dataCategories: [TestValues.category()]
        )
        let grant = try StepCapabilityGrant(
            runCeiling: RunCapabilityCeiling(authority: authority),
            authority: authority
        )
        let retry = try ExternalRetryPolicy(
            kind: .boundedExponential,
            maximumAttempts: 2,
            baseDelayMilliseconds: 10,
            maximumDelayMilliseconds: 20
        )
        XCTAssertThrowsError(
            try ExternalOperationPlan(
                kind: .tool,
                subjectID: "test.write",
                destination: destination,
                dataCategories: [TestValues.category()],
                payloadDigest: payload.fingerprint,
                effects: [AgentEffect.externalWrite],
                requiredCapabilities: AgentCapabilitySet([.externalWrite]),
                maximumRequestBytes: 1_024,
                maximumResponseBytes: 1_024,
                timeoutMilliseconds: 1_000,
                retryPolicy: retry,
                idempotency: .reconciliationAvailable,
                userPreview: "Write once"
            )
        )
        let key = ExternalIdempotencyKey.derive(components: [Data("write-1".utf8)])
        let plan = try ExternalOperationPlan(
            kind: .tool,
            subjectID: "test.write",
            destination: destination,
            dataCategories: [TestValues.category()],
            payloadDigest: payload.fingerprint,
            effects: [AgentEffect.externalWrite],
            requiredCapabilities: AgentCapabilitySet([.externalWrite]),
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 1_024,
            timeoutMilliseconds: 1_000,
            retryPolicy: retry,
            idempotency: .idempotencyKeyRequired,
            idempotencyKey: key,
            userPreview: "Write once"
        )
        let prepared = try PreparedExternalOperationRequest(
            requestID: TestValues.id(AgentRequestIDDomain.self, 50),
            runID: TestValues.id(AgentRunIDDomain.self, 51),
            conversationID: TestValues.id(ConversationIDDomain.self, 52),
            stepID: TestValues.id(AgentStepIDDomain.self, 53),
            plan: plan,
            payload: TestValues.sanitized(payload),
            capabilityGrant: grant
        )
        let secondAttempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 2)
        XCTAssertEqual(secondAttempt.idempotencyKey, key)
        XCTAssertThrowsError(try ExternalOperationAttempt(prepared: prepared, attemptNumber: 3))
    }

    func testExecutionGateRechecksTimeDigestCredentialAndDestination() async throws {
        let secret = try SecretReference(
            id: TestValues.id(SecretReferenceIDDomain.self, 60),
            purpose: "read token",
            providerID: "provider-a"
        )
        let prepared = try TestValues.preparedRead(
            redirects: [TestValues.destination("redirect")],
            secret: secret
        )
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 61),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 100),
            expiresAt: AgentTimestamp(rawValue: 200)
        )
        let authorized = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedAuthority(for: prepared)
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let clock = MutableAuthorizationClock(AgentTimestamp(rawValue: 100))
        let gate = authorized.executionGate(
            clock: clock,
            policyValidator: AcceptingPolicyValidator(),
            attemptLedger: InMemoryAttemptLedger()
        )
        let counter = Counter()
        let firstHop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        _ = try await gate.perform(
            observation: TestValues.observation(for: prepared),
            attempt: attempt,
            hop: firstHop
        ) { control in
            await counter.increment()
            try await control.consumeResponseBytes(42)
            return eagerBoundaryCompletion()
        }
        let count = await counter.value
        XCTAssertEqual(count, 1)

        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(for: prepared),
                attempt: attempt,
                hop: firstHop
            ) { _ in eagerBoundaryCompletion() }
        }

        await clock.set(AgentTimestamp(rawValue: 201))
        let redirectHop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: TestValues.destination("redirect")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(for: prepared),
                attempt: attempt,
                hop: redirectHop
            ) { _ in eagerBoundaryCompletion() }
        }
        await clock.set(AgentTimestamp(rawValue: 150))
        let missingDigest = try ExternalOperationObservation(
            destination: TestValues.destination("redirect"),
            dataCategories: prepared.plan.dataCategories,
            effects: prepared.plan.effects,
            requestBytes: UInt64(prepared.payload.data.count),
            responseBytesLimit: prepared.plan.maximumResponseBytes,
            payloadDigest: nil,
            descriptorID: prepared.plan.descriptorID,
            schemaDigest: prepared.plan.schemaDigest,
            trustRevision: prepared.plan.trustRevision,
            credentialReference: secret,
            resolvedSecretReferenceIDs: [secret.id]
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: missingDigest,
                attempt: attempt,
                hop: redirectHop
            ) { _ in eagerBoundaryCompletion() }
        }
        let wrongSecret = try SecretReference(id: secret.id, purpose: "other", providerID: "provider-a")
        let wrongCredential = try TestValues.observation(
            for: prepared,
            destination: TestValues.destination("redirect"),
            credentialReference: wrongSecret
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: wrongCredential,
                attempt: attempt,
                hop: redirectHop
            ) { _ in eagerBoundaryCompletion() }
        }
    }

    func testTrustedAuthorityPolicyAndDurableClaimCannotBeForgedOrReplayed() async throws {
        let prepared = try TestValues.preparedRead(redirects: [TestValues.destination("redirect")])
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 70),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1),
            expiresAt: AgentTimestamp(rawValue: 1_000)
        )
        let wrongAuthority = try TrustedRunAuthority(
            runID: prepared.runID,
            ceiling: RunCapabilityCeiling(authority: .empty),
            policyRevision: 1
        )
        XCTAssertThrowsError(
            try AuthorizedExternalOperationRequest(
                prepared: prepared,
                authorization: receipt,
                trustedRunAuthority: wrongAuthority
            )
        )

        let authorized = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedAuthority(for: prepared)
        )
        let clock = MutableAuthorizationClock(AgentTimestamp(rawValue: 10))
        let policy = MutablePolicyValidator()
        let ledger = ThrowOnceAttemptLedger()
        let gate = authorized.executionGate(
            clock: clock,
            policyValidator: policy,
            attemptLedger: ledger
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let firstHop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(for: prepared),
                attempt: attempt,
                hop: firstHop
            ) { _ in eagerBoundaryCompletion() }
        }
        let result = try await gate.perform(
            observation: TestValues.observation(for: prepared),
            attempt: attempt,
            hop: firstHop
        ) { control in
            try await control.consumeResponseBytes(8)
            return eagerBoundaryCompletion()
        }
        XCTAssertEqual(result.value, .none)
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(for: prepared),
                attempt: attempt,
                hop: firstHop
            ) { _ in eagerBoundaryCompletion() }
        }

        await policy.revoke()
        let secondHop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: TestValues.destination("redirect")
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(
                    for: prepared,
                    destination: TestValues.destination("redirect")
                ),
                attempt: attempt,
                hop: secondHop
            ) { _ in eagerBoundaryCompletion() }
        }
    }

    func testBoundaryHopBindsCanonicalItineraryPositionAndDestination() async throws {
        let redirects = [TestValues.destination("redirect-b"), TestValues.destination("redirect-a")]
        let prepared = try TestValues.preparedRead(redirects: redirects)
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let primary = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        XCTAssertEqual(primary.kind, .primary)
        XCTAssertEqual(primary.hopNumber, 1)

        for (index, destination) in prepared.plan.allowedRedirects.enumerated() {
            let redirect = try ExternalOperationBoundaryHop(
                prepared: prepared,
                attempt: attempt,
                destination: destination
            )
            XCTAssertEqual(redirect.kind, .redirect)
            XCTAssertEqual(redirect.hopNumber, UInt16(index + 2))
            try assertContractRoundTrip(redirect)
        }
        XCTAssertThrowsError(try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: TestValues.destination("not-planned")
        ))

        var forgedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedJSON(primary)) as? [String: Any]
        )
        forgedObject["hopNumber"] = 2
        forgedObject["fingerprint"] = StableDigest.fingerprint(
            domain: "external-operation-boundary-hop.v1",
            components: [
                Data(attempt.fingerprint.rawValue.utf8),
                Data(ExternalOperationBoundaryHopKind.primary.rawValue.utf8),
                Data((prepared.plan.destination?.kind.rawValue ?? "").utf8),
                Data((prepared.plan.destination?.normalizedIdentity ?? "").utf8),
                Data("2".utf8),
            ]
        ).rawValue
        let forged = try AgentWireDecoder.decode(
            ExternalOperationBoundaryHop.self,
            from: JSONSerialization.data(withJSONObject: forgedObject, options: [.sortedKeys])
        )
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 80),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1)
        )
        let authorized = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedAuthority(for: prepared)
        )
        let gate = authorized.executionGate(
            clock: MutableAuthorizationClock(AgentTimestamp(rawValue: 2)),
            policyValidator: AcceptingPolicyValidator(),
            attemptLedger: InMemoryAttemptLedger()
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await gate.perform(
                observation: TestValues.observation(for: prepared),
                attempt: attempt,
                hop: forged
            ) { _ in eagerBoundaryCompletion() }
        }
    }

    func testBoundaryControlCannotEscapeGateLifetime() async throws {
        let prepared = try TestValues.preparedRead()
        let receipt = try ApprovalReceipt(
            id: TestValues.id(ApprovalIDDomain.self, 81),
            prepared: prepared,
            decision: .approved,
            scope: .exactInvocation,
            policyVersion: 1,
            decidedAt: AgentTimestamp(rawValue: 1)
        )
        let authorized = try AuthorizedExternalOperationRequest(
            prepared: prepared,
            authorization: receipt,
            trustedRunAuthority: trustedAuthority(for: prepared)
        )
        let attempt = try ExternalOperationAttempt(prepared: prepared, attemptNumber: 1)
        let hop = try ExternalOperationBoundaryHop(
            prepared: prepared,
            attempt: attempt,
            destination: prepared.plan.destination
        )
        let capture = BoundaryControlCapture()
        let result = try await authorized.executionGate(
            clock: MutableAuthorizationClock(AgentTimestamp(rawValue: 2)),
            policyValidator: AcceptingPolicyValidator(),
            attemptLedger: InMemoryAttemptLedger()
        ).perform(
            observation: TestValues.observation(for: prepared),
            attempt: attempt,
            hop: hop
        ) { control in
            await capture.store(control)
            try await control.consumeResponseBytes(3)
            return ExternalOperationBoundaryCompletion(
                value: .canonicalJSON(try CanonicalJSON(.object(["ok": .bool(true)]))),
                responseDigest: TestValues.digest("7")
            )
        }
        XCTAssertEqual(result.responseBytes, 3)
        XCTAssertEqual(result.responseDigest, TestValues.digest("7"))
        guard let escaped = await capture.value() else {
            return XCTFail("Expected captured boundary control")
        }
        await XCTAssertThrowsErrorAsync {
            try await escaped.consumeResponseBytes(1)
        }
    }

    func testConstraintValidationSortingAndScopeDuplicateKeysFailClosed() throws {
        XCTAssertThrowsError(
            try AgentAuthorityConstraint(key: "Not Lowercase", allowedValues: ["x"])
        )
        XCTAssertThrowsError(
            try AgentAuthorityConstraint(key: "valid.key", allowedValues: [])
        )
        XCTAssertThrowsError(
            try AgentAuthorityConstraint(
                key: "valid.key",
                allowedValues: ["bad\u{01}value"]
            )
        )

        let first = try AgentAuthorityConstraint(key: "a.key", allowedValues: ["z"])
        let second = try AgentAuthorityConstraint(key: "b.key", allowedValues: ["a"])
        XCTAssertEqual([second, first].sorted().map(\.key), ["a.key", "b.key"])

        XCTAssertThrowsError(
            try AgentAuthorityScope(
                capabilities: AgentCapabilitySet([]),
                constraints: [
                    try AgentAuthorityConstraint(key: "same.key", allowedValues: ["one"]),
                    try AgentAuthorityConstraint(key: "same.key", allowedValues: ["two"]),
                ]
            )
        )
    }

    func testScopeSubsetRequiresEveryParentConstraintAndTrustRevisionIsPositive() throws {
        let parent = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            constraints: [
                try AgentAuthorityConstraint(key: "filesystem.paths", allowedValues: ["docs"]),
            ]
        )
        let childWithUnknownConstraint = try AgentAuthorityScope(
            capabilities: AgentCapabilitySet([.networkRead]),
            constraints: [
                try AgentAuthorityConstraint(key: "unrelated.key", allowedValues: ["value"]),
            ]
        )
        XCTAssertFalse(childWithUnknownConstraint.isSubset(of: parent))

        XCTAssertThrowsError(
            try TrustedRunAuthority(
                runID: AgentRunID(),
                ceiling: RunCapabilityCeiling(authority: parent),
                policyRevision: 0
            )
        ) {
            XCTAssertEqual($0 as? AgentContractError, .authorizationDenied)
        }
    }
}

private func trustedAuthority(
    for prepared: PreparedExternalOperationRequest
) throws -> TrustedRunAuthority {
    try TrustedRunAuthority(
        runID: prepared.runID,
        ceiling: prepared.capabilityGrant.runCeiling,
        policyRevision: 1
    )
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor BoundaryControlCapture {
    private var control: ExternalOperationBoundaryControl?
    func store(_ control: ExternalOperationBoundaryControl) { self.control = control }
    func value() -> ExternalOperationBoundaryControl? { control }
}

private actor MutableAuthorizationClock: AgentAuthorizationClock {
    private var timestamp: AgentTimestamp
    init(_ timestamp: AgentTimestamp) { self.timestamp = timestamp }
    func now() async throws -> AgentTimestamp { timestamp }
    func set(_ timestamp: AgentTimestamp) { self.timestamp = timestamp }
}

private struct AcceptingPolicyValidator: AgentAuthorizationPolicyValidating {
    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {}
}

private actor InMemoryAttemptLedger: ExternalOperationAttemptClaiming {
    private var claims: Set<StableDigest> = []
    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool {
        claims.insert(hop.fingerprint).inserted
    }
}

private actor MutablePolicyValidator: AgentAuthorizationPolicyValidating {
    private var revoked = false
    func revoke() { revoked = true }
    func validateCurrentAuthorization(
        receipt: ApprovalReceipt,
        prepared: PreparedExternalOperationRequest,
        trustedRunAuthority: TrustedRunAuthority,
        at timestamp: AgentTimestamp
    ) async throws {
        if revoked { throw AgentContractError.authorizationDenied }
    }
}

private actor ThrowOnceAttemptLedger: ExternalOperationAttemptClaiming {
    private var shouldThrow = true
    private var claims: Set<StableDigest> = []
    func claimBoundaryHop(
        approvalID: ApprovalID,
        preparedRequestFingerprint: StableDigest,
        attempt: ExternalOperationAttempt,
        hop: ExternalOperationBoundaryHop
    ) async throws -> Bool {
        if shouldThrow {
            shouldThrow = false
            throw AgentContractError.authorizationDenied
        }
        return claims.insert(hop.fingerprint).inserted
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private func eagerBoundaryCompletion() -> ExternalOperationBoundaryCompletion {
    ExternalOperationBoundaryCompletion(value: .none)
}
