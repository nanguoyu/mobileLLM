// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import AgentContracts
@testable import AgentSandboxAPI

// TEST-ID: AHT-SANDBOX-003
final class ProviderContractTests: XCTestCase {
    func testProviderValuesRoundTripAndUseNamespacedSchemas() throws {
        let values = try SandboxTestValues.negotiated()
        XCTAssertEqual(
            try decoded(AgentSandboxProviderDescriptor.self, from: values.descriptor),
            values.descriptor
        )
        XCTAssertEqual(try decoded(SandboxCapabilities.self, from: values.report), values.report)
        XCTAssertEqual(try decoded(RegisteredSandboxProviderPolicy.self, from: values.policy), values.policy)
        XCTAssertEqual(
            try decoded(NegotiatedSandboxCapabilities.self, from: values.negotiated),
            values.negotiated
        )
        XCTAssertTrue(AgentSandboxProviderDescriptor.schemaID.hasPrefix("com.mobilellm.agent.sandbox."))
        XCTAssertTrue(SandboxCapabilities.schemaID.hasPrefix("com.mobilellm.agent.sandbox."))
        XCTAssertTrue(RegisteredSandboxProviderPolicy.schemaID.hasPrefix("com.mobilellm.agent.sandbox."))
        XCTAssertTrue(NegotiatedSandboxCapabilities.schemaID.hasPrefix("com.mobilellm.agent.sandbox."))
        XCTAssertEqual(values.descriptor.protocolVersion, AgentContractVersion.currentProtocol)
        XCTAssertEqual(values.report.protocolVersion, AgentContractVersion.currentProtocol)
        try values.negotiated.validate(
            against: values.policy,
            descriptor: values.descriptor,
            capabilities: values.report
        )
    }

    func testDisplayOnlyDescriptorChangeDoesNotInvalidateSecurityFingerprint() throws {
        let original = try SandboxTestValues.descriptor(displayName: "English Name")
        let localized = try SandboxTestValues.descriptor(displayName: "本地沙箱")
        XCTAssertNotEqual(original.displayName, localized.displayName)
        XCTAssertEqual(original.fingerprint, localized.fingerprint)

        let changedBinary = try SandboxTestValues.descriptor(
            implementationVersion: SemanticVersion(major: 1, minor: 0, patch: 1)
        )
        XCTAssertNotEqual(original.fingerprint, changedBinary.fingerprint)
    }

    func testNegotiationIsExactLocalAndReportedIntersection() throws {
        let destinationA = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://a.example"
        )
        let destinationB = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://b.example"
        )
        let destinationC = try ExternalDestination(
            kind: .networkEndpoint,
            normalizedIdentity: "https://c.example"
        )
        let dataA = try AgentDataCategory(rawValue: "data.alpha")
        let dataB = try AgentDataCategory(rawValue: "data.beta")
        let dataC = try AgentDataCategory(rawValue: "data.gamma")
        let artifactA = SandboxTestValues.id(ArtifactIDDomain.self, 1)
        let artifactB = SandboxTestValues.id(ArtifactIDDomain.self, 2)
        let artifactC = SandboxTestValues.id(ArtifactIDDomain.self, 3)
        let secretA = SandboxTestValues.id(SecretReferenceIDDomain.self, 4)
        let secretB = SandboxTestValues.id(SecretReferenceIDDomain.self, 5)
        let secretC = SandboxTestValues.id(SecretReferenceIDDomain.self, 6)
        let workspaceA = SandboxTestValues.id(SandboxWorkspaceHandleIDDomain.self, 7)
        let workspaceB = SandboxTestValues.id(SandboxWorkspaceHandleIDDomain.self, 8)
        let workspaceC = SandboxTestValues.id(SandboxWorkspaceHandleIDDomain.self, 9)
        let checkpointA = SandboxTestValues.id(SandboxCheckpointHandleIDDomain.self, 10)
        let checkpointB = SandboxTestValues.id(SandboxCheckpointHandleIDDomain.self, 11)
        let checkpointC = SandboxTestValues.id(SandboxCheckpointHandleIDDomain.self, 12)
        let localConstraint = try AgentAuthorityConstraint(
            key: "runtime.family",
            allowedValues: ["swift", "python"]
        )
        let reportedConstraint = try AgentAuthorityConstraint(
            key: "runtime.family",
            allowedValues: ["python", "javascript"]
        )
        let localAuthority = SandboxTestValues.authority(
            capabilities: [.codeExecution, .localRead],
            destinations: [destinationA, destinationB],
            dataCategories: [dataA, dataB],
            artifactIDs: [artifactA, artifactB],
            secretIDs: [secretA, secretB],
            workspaceIDs: [workspaceA, workspaceB],
            checkpointIDs: [checkpointA, checkpointB],
            constraints: [localConstraint]
        )
        let reportedAuthority = SandboxTestValues.authority(
            capabilities: [.codeExecution, .networkRead],
            destinations: [destinationB, destinationC],
            dataCategories: [dataB, dataC],
            artifactIDs: [artifactB, artifactC],
            secretIDs: [secretB, secretC],
            workspaceIDs: [workspaceB, workspaceC],
            checkpointIDs: [checkpointB, checkpointC],
            constraints: [reportedConstraint]
        )
        let localLimits = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.enumerated().map {
            ($0.element, UInt64(10_000 + $0.offset))
        })
        let reportedLimits = Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.enumerated().map {
            ($0.element, UInt64(10_014 - $0.offset))
        })
        let localBudget = try AgentBudget(
            limits: BudgetQuantities(localLimits),
            maximumThermalState: .serious,
            memoryPressureResponse: .pause
        )
        let reportedBudget = try AgentBudget(
            limits: BudgetQuantities(reportedLimits),
            maximumThermalState: .fair,
            memoryPressureResponse: .pause
        )
        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            features: [.cancellation, .networkAccess, .progressEvents],
            authority: reportedAuthority,
            budget: reportedBudget,
            maximumConcurrentExecutions: 8
        )
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            features: [.cancellation, .codeExecution, .progressEvents],
            authority: localAuthority,
            budget: localBudget,
            maximumConcurrentExecutions: 2
        )
        let negotiated = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )

        XCTAssertEqual(negotiated.features, [.cancellation, .progressEvents])
        XCTAssertEqual(negotiated.maximumConcurrentExecutions, 2)
        XCTAssertEqual(negotiated.maximumAuthority.capabilities.values, [.codeExecution])
        XCTAssertEqual(negotiated.maximumAuthority.destinations, [destinationB])
        XCTAssertEqual(negotiated.maximumAuthority.dataCategories, [dataB])
        XCTAssertEqual(negotiated.maximumAuthority.artifactIDs, [artifactB])
        XCTAssertEqual(negotiated.maximumAuthority.secretReferenceIDs, [secretB])
        XCTAssertEqual(negotiated.maximumAuthority.workspaceIDs, [workspaceB])
        XCTAssertEqual(negotiated.maximumAuthority.checkpointIDs, [checkpointB])
        XCTAssertEqual(negotiated.maximumAuthority.constraints.count, 1)
        XCTAssertEqual(negotiated.maximumAuthority.constraints[0].allowedValues, ["python"])
        XCTAssertTrue(negotiated.maximumAuthority.isSubset(of: localAuthority))
        XCTAssertTrue(negotiated.maximumAuthority.isSubset(of: reportedAuthority))
        for dimension in BudgetDimension.allCases {
            XCTAssertEqual(
                negotiated.maximumBudget.limits[dimension],
                min(localLimits[dimension]!, reportedLimits[dimension]!),
                "Budget intersection widened \(dimension.rawValue)"
            )
        }
        XCTAssertEqual(negotiated.maximumBudget.maximumThermalState, .fair)
        XCTAssertNoThrow(try policy.maximumBudget.attenuating(to: negotiated.maximumBudget))
        XCTAssertNoThrow(try report.maximumBudget.attenuating(to: negotiated.maximumBudget))
    }

    func testMissingConstraintKeyProducesNoAuthorityForThatDimension() throws {
        let constrained = SandboxTestValues.authority(
            constraints: [try AgentAuthorityConstraint(key: "runtime.family", allowedValues: ["swift"])]
        )
        let unconstrainedClaim = SandboxTestValues.authority()
        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            authority: unconstrainedClaim
        )
        let policy = try SandboxTestValues.policy(descriptor: descriptor, authority: constrained)
        let negotiated = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )

        XCTAssertTrue(negotiated.maximumAuthority.constraints.isEmpty)
        XCTAssertTrue(negotiated.maximumAuthority.isSubset(of: constrained))
        XCTAssertTrue(negotiated.maximumAuthority.isSubset(of: unconstrainedClaim))
    }

    func testProviderCanDowngradeButCannotExpandLocalPolicy() throws {
        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            features: [.cancellation],
            authority: SandboxTestValues.authority(
                capabilities: [.codeExecution, .networkRead, .externalWrite]
            ),
            budget: SandboxTestValues.budget(limit: 9_000_000),
            maximumConcurrentExecutions: 50
        )
        let policyAuthority = SandboxTestValues.authority(capabilities: [.codeExecution])
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            features: [.cancellation, .codeExecution],
            authority: policyAuthority,
            budget: SandboxTestValues.budget(limit: 1_000),
            maximumConcurrentExecutions: 1
        )
        let negotiated = try policy.negotiate(
            descriptor: descriptor,
            capabilities: report
        )

        XCTAssertEqual(negotiated.features, [.cancellation])
        XCTAssertEqual(negotiated.maximumAuthority.capabilities.values, [.codeExecution])
        XCTAssertEqual(negotiated.maximumBudget.limits[.peakMemoryBytes], 1_000)
        XCTAssertEqual(negotiated.maximumConcurrentExecutions, 1)
    }

    func testIdentityFingerprintTrustAndProtocolTamperingFailClosed() throws {
        let descriptor = try SandboxTestValues.descriptor()
        let report = try SandboxTestValues.capabilities(descriptor: descriptor)

        let wrongIDPolicy = try RegisteredSandboxProviderPolicy(
            providerID: "other.sandbox",
            descriptorFingerprint: descriptor.fingerprint,
            trustRevision: descriptor.trustRevision,
            allowedProtocolVersions: [AgentContractVersion.currentProtocol],
            allowedFeatures: SandboxFeature.allCases,
            maximumAuthority: SandboxTestValues.authority(),
            maximumBudget: SandboxTestValues.budget(),
            maximumConcurrentExecutions: 1,
            policyRevision: 1
        )
        XCTAssertThrowsError(
            try wrongIDPolicy.negotiate(descriptor: descriptor, capabilities: report)
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .providerIdentityMismatch) }

        let wrongFingerprintPolicy = try RegisteredSandboxProviderPolicy(
            providerID: descriptor.providerID,
            descriptorFingerprint: SandboxTestValues.digest("9"),
            trustRevision: descriptor.trustRevision,
            allowedProtocolVersions: [AgentContractVersion.currentProtocol],
            allowedFeatures: SandboxFeature.allCases,
            maximumAuthority: SandboxTestValues.authority(),
            maximumBudget: SandboxTestValues.budget(),
            maximumConcurrentExecutions: 1,
            policyRevision: 1
        )
        XCTAssertThrowsError(
            try wrongFingerprintPolicy.negotiate(descriptor: descriptor, capabilities: report)
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .descriptorFingerprintMismatch) }

        let wrongTrustPolicy = try RegisteredSandboxProviderPolicy(
            providerID: descriptor.providerID,
            descriptorFingerprint: descriptor.fingerprint,
            trustRevision: descriptor.trustRevision + 1,
            allowedProtocolVersions: [AgentContractVersion.currentProtocol],
            allowedFeatures: SandboxFeature.allCases,
            maximumAuthority: SandboxTestValues.authority(),
            maximumBudget: SandboxTestValues.budget(),
            maximumConcurrentExecutions: 1,
            policyRevision: 1
        )
        XCTAssertThrowsError(
            try wrongTrustPolicy.negotiate(descriptor: descriptor, capabilities: report)
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .trustRevisionMismatch) }

        let incompatible = try SemanticVersion(major: 1, minor: 1, patch: 0)
        let incompatiblePolicy = try SandboxTestValues.policy(
            descriptor: descriptor,
            versions: [incompatible]
        )
        XCTAssertThrowsError(
            try incompatiblePolicy.negotiate(descriptor: descriptor, capabilities: report)
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .incompatibleProtocol) }

        let forgedEnvelopeData = try replacingJSONField(
            in: encodedJSON(descriptor),
            path: ["protocolVersion"],
            with: "2.0.0"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentSandboxProviderDescriptor.self, from: forgedEnvelopeData)
        )

        let forgedDescriptorData = try replacingJSONField(
            in: encodedJSON(descriptor),
            path: ["fingerprint"],
            with: SandboxTestValues.digest("8").rawValue
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            AgentSandboxProviderDescriptor.self,
            from: forgedDescriptorData
        ))

        let fingerprintTamperingCases: [(Data, (Data) throws -> Void)] = [
            (
                try replacingJSONField(
                    in: encodedJSON(report),
                    path: ["fingerprint"],
                    with: SandboxTestValues.digest("7").rawValue
                ),
                { _ = try JSONDecoder().decode(SandboxCapabilities.self, from: $0) }
            ),
            (
                try replacingJSONField(
                    in: encodedJSON(try SandboxTestValues.policy(descriptor: descriptor)),
                    path: ["fingerprint"],
                    with: SandboxTestValues.digest("6").rawValue
                ),
                { _ = try JSONDecoder().decode(RegisteredSandboxProviderPolicy.self, from: $0) }
            ),
            (
                try replacingJSONField(
                    in: encodedJSON(try SandboxTestValues.negotiated().negotiated),
                    path: ["fingerprint"],
                    with: SandboxTestValues.digest("5").rawValue
                ),
                { _ = try JSONDecoder().decode(NegotiatedSandboxCapabilities.self, from: $0) }
            ),
        ]
        for (data, decode) in fingerprintTamperingCases {
            XCTAssertThrowsError(try decode(data))
        }

        let duplicateVersion = try replacingJSONField(
            in: encodedJSON(descriptor),
            path: ["supportedProtocolVersions"],
            with: ["1.0.0", "1.0.0"]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentSandboxProviderDescriptor.self, from: duplicateVersion)
        )
    }

    func testMemoryPressureBehaviorMustBeSupportedByBothPolicyAndProvider() throws {
        let descriptor = try SandboxTestValues.descriptor()
        let incompatibleBudget = try AgentBudget(
            limits: BudgetQuantities(
                Dictionary(uniqueKeysWithValues: BudgetDimension.allCases.map { ($0, UInt64(100)) })
            ),
            maximumThermalState: .fair,
            memoryPressureResponse: .failRun
        )
        let report = try SandboxTestValues.capabilities(
            descriptor: descriptor,
            budget: incompatibleBudget
        )
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            budget: SandboxTestValues.budget(limit: 100)
        )
        XCTAssertThrowsError(
            try policy.negotiate(
                descriptor: descriptor,
                capabilities: report
            )
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .negotiatedCapabilityMismatch) }
    }

    func testDescriptorAndCapabilityReportMustUseTheSameProtocol() throws {
        let alternate = try SemanticVersion(major: 1, minor: 0, patch: 1)
        let descriptor = try SandboxTestValues.descriptor(
            versions: [AgentContractVersion.currentProtocol, alternate]
        )
        let report = try SandboxCapabilities(
            providerID: descriptor.providerID,
            descriptorFingerprint: descriptor.fingerprint,
            supportedProtocolVersions: [AgentContractVersion.currentProtocol, alternate],
            features: SandboxFeature.allCases,
            maximumAuthority: SandboxTestValues.authority(),
            maximumBudget: SandboxTestValues.budget(),
            maximumConcurrentExecutions: 1,
            reportRevision: 1,
            protocolVersion: alternate
        )
        let policy = try SandboxTestValues.policy(
            descriptor: descriptor,
            versions: [AgentContractVersion.currentProtocol, alternate]
        )
        XCTAssertThrowsError(
            try policy.negotiate(descriptor: descriptor, capabilities: report)
        ) { XCTAssertEqual($0 as? AgentSandboxAPIError, .incompatibleProtocol) }
    }

    func testFingerprintEncodingFailurePropagatesWithoutTrap() {
        struct Expected: Error {}
        struct ThrowingValue: Encodable {
            func encode(to encoder: Encoder) throws { throw Expected() }
        }
        XCTAssertThrowsError(
            try SandboxContractValidation.fingerprint(domain: "test.throw", value: ThrowingValue())
        ) { XCTAssertTrue($0 is Expected) }
    }

    func testFingerprintUsesCanonicalJSONAcrossInsertionAndNumberRepresentations() throws {
        var forward: [String: JSONValue] = [:]
        forward["beta"] = .string("value")
        forward["alpha"] = .integer(1)
        var reverse: [String: JSONValue] = [:]
        reverse["alpha"] = .number(1.0)
        reverse["beta"] = .string("value")

        let forwardDigest = try SandboxContractValidation.fingerprint(
            domain: "test.canonical",
            value: forward
        )
        let reverseDigest = try SandboxContractValidation.fingerprint(
            domain: "test.canonical",
            value: reverse
        )
        XCTAssertEqual(forwardDigest, reverseDigest)
    }

    func testFingerprintRejectsBoundedNonFiniteAndNonIJSONInputs() {
        struct DeeplyNested: Encodable {
            let remainingDepth: Int

            func encode(to encoder: Encoder) throws {
                if remainingDepth == 0 {
                    var container = encoder.singleValueContainer()
                    try container.encode(0)
                } else {
                    var container = encoder.unkeyedContainer()
                    try container.encode(Self(remainingDepth: remainingDepth - 1))
                }
            }
        }

        struct NonFinite: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(Double.infinity)
            }
        }

        XCTAssertThrowsError(
            try SandboxContractValidation.fingerprint(
                domain: "test.too-deep",
                value: DeeplyNested(remainingDepth: 129)
            )
        )
        XCTAssertThrowsError(
            try SandboxContractValidation.fingerprint(
                domain: "test.non-finite",
                value: NonFinite()
            )
        )
        XCTAssertThrowsError(
            try SandboxContractValidation.fingerprint(
                domain: "test.non-ijson-integer",
                value: ["value": UInt64(9_007_199_254_740_992)]
            )
        )
    }

    func testAllPublicProviderEnumsAndErrorsRemainExhaustivelyRepresentable() throws {
        XCTAssertEqual(
            try decoded([SandboxFeature].self, from: SandboxFeature.allCases),
            SandboxFeature.allCases
        )
        let errors: [AgentSandboxAPIError] = [
            .invalidValue("x"), .providerIdentityMismatch, .descriptorFingerprintMismatch,
            .trustRevisionMismatch, .incompatibleProtocol, .capabilityReportBindingMismatch,
            .negotiatedCapabilityMismatch, .authorityOrBudgetExpansion, .requestBindingMismatch,
            .idempotencyConflict, .executionNotFound, .staleCommand, .invalidCursor,
            .invalidEventChain, .terminalExecution,
        ]
        XCTAssertEqual(Set(errors).count, 15)
        XCTAssertTrue(errors.allSatisfy { $0.localizedDescription.isEmpty == false })
    }
}
