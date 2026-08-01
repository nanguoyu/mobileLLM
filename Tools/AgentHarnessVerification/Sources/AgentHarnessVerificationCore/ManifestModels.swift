// SPDX-License-Identifier: MIT

import Foundation

public enum VerificationMode: String, Sendable {
    case `static`
    case release
}

public struct VerificationConfiguration: Sendable {
    public var mode: VerificationMode
    public var repositoryRoot: URL
    public var requirementsURL: URL
    public var testsURL: URL
    public var quarantineURL: URL
    public var now: Date

    public init(
        mode: VerificationMode,
        repositoryRoot: URL,
        requirementsURL: URL? = nil,
        testsURL: URL? = nil,
        quarantineURL: URL? = nil,
        now: Date = Date()
    ) {
        let root = repositoryRoot.standardizedFileURL
        self.mode = mode
        self.repositoryRoot = root
        self.requirementsURL = requirementsURL
            ?? root.appending(path: "Verification/AgentHarness/requirements.v1.json")
        self.testsURL = testsURL
            ?? root.appending(path: "Verification/AgentHarness/tests.v1.json")
        self.quarantineURL = quarantineURL
            ?? root.appending(path: "Verification/AgentHarness/quarantine.v1.json")
        self.now = now
    }
}

public struct VerificationDiagnostic: Equatable, Sendable, Comparable {
    public let code: String
    public let location: String
    public let message: String

    public init(code: String, location: String, message: String) {
        self.code = code
        self.location = location
        self.message = message
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.location, lhs.code, lhs.message) < (rhs.location, rhs.code, rhs.message)
    }
}

public struct VerificationReport: Sendable {
    public let diagnostics: [VerificationDiagnostic]
    public init(diagnostics: [VerificationDiagnostic]) { self.diagnostics = diagnostics.sorted() }
    public var succeeded: Bool { diagnostics.isEmpty }
}

struct RequirementsDocument: Decodable {
    let schemaVersion: Int
    let documentID: String
    let sourceSpecification: SourceSpecification
    let requirements: [RequirementRecord]
}

struct SourceSpecification: Decodable {
    let path: String
    let sha256: String
    let capturedAtUTC: String
}

struct RequirementRecord: Decodable {
    let id: String
    let area: String
    let status: String
    let riskTier: String
    let specAnchors: [SpecAnchor]
    let platforms: [String]
    let verificationTiers: [String]
    let testIDs: [String]
    let requiredEvidence: [String]
}

struct SpecAnchor: Decodable {
    let section: String
    let heading: String
    let lineStart: Int
    let lineEnd: Int
}

struct TestsDocument: Decodable {
    let schemaVersion: Int
    let documentID: String
    let tests: [TestRecord]
}

struct TestRecord: Decodable {
    let id: String
    let status: String
    let kind: String
    let riskTier: String
    let requirementIDs: [String]
    let selectors: [TestSelector]
    let platforms: [String]
    let verificationTiers: [String]
    let requiredEvidence: [String]
}

struct TestSelector: Decodable, Hashable {
    let kind: String
    let value: String
}

struct QuarantineDocument: Decodable {
    let schemaVersion: Int
    let documentID: String
    let policy: QuarantinePolicy
    let entries: [QuarantineRecord]
}

struct QuarantinePolicy: Decodable {
    let maximumDays: Int
    let forbiddenRiskTiers: [String]
    let forbiddenAreas: [String]
    let expiredEntryFailsVerification: Bool
}

struct QuarantineRecord: Decodable {
    let testID: String
    let owner: String
    let reason: String
    let createdAtUTC: String
    let expiresAtUTC: String
    let replacementCoverageTestIDs: [String]
}

enum VerificationVocabulary {
    static let requirementStatuses: Set<String> = ["active", "planned", "retired"]
    static let testStatuses: Set<String> = ["active", "planned", "retired"]
    static let risks: Set<String> = ["P0", "P1", "P2"]
    static let platforms: Set<String> = ["all", "swiftpm", "ios", "ios-device", "ios-simulator", "macos"]
    static let tiers: Set<String> = ["every-change", "pull-request", "nightly", "release-candidate"]
    static let selectorKinds: Set<String> = [
        "swift-test", "xctest", "ui-test", "script", "device-scenario", "manual-inspection",
    ]
}
