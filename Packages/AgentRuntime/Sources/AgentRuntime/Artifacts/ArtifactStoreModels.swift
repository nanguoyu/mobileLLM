// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// A durable record that owns an artifact reference.
///
/// Owner values are deliberately opaque to the artifact store. The canonical identifiers are
/// supplied by the journal or projection that owns the reference; artifact bodies never become
/// part of the owner key.
public struct ArtifactOwner: Hashable, Codable, Sendable, Comparable {
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        case run
        case conversation
        case message
        case durableRecord
        case userManaged
        case transient
    }

    public let kind: Kind
    public let identifier: String

    public init(kind: Kind, identifier: String) throws {
        let scalars = identifier.unicodeScalars
        guard !identifier.isEmpty, identifier.count <= 256,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              scalars.allSatisfy({ scalar in
                  !((0 ... 31).contains(scalar.value) || (127 ... 159).contains(scalar.value))
              })
        else { throw ArtifactStoreError.invalidOwner }
        self.kind = kind
        self.identifier = identifier
    }

    public static func run(_ id: AgentRunID) -> Self {
        try! Self(kind: .run, identifier: id.description)
    }

    public static func conversation(_ id: ConversationID) -> Self {
        try! Self(kind: .conversation, identifier: id.description)
    }

    public static func message(_ id: MessageID) -> Self {
        try! Self(kind: .message, identifier: id.description)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.identifier < rhs.identifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                kind: container.decode(Kind.self, forKey: .kind),
                identifier: container.decode(String.self, forKey: .identifier)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid artifact owner")
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, identifier }
}

/// Validated input to an atomic artifact commit.
public struct ArtifactCommitRequest: Hashable, Sendable {
    public let artifactID: ArtifactID?
    public let data: Data
    public let expectedDigest: StableDigest?
    public let expectedByteCount: UInt64?
    public let mimeType: String
    public let semanticType: String?
    public let provenance: ArtifactProvenance
    public let retentionPolicy: ArtifactRetentionPolicy
    public let sensitivity: RedactionClassification
    public let initialOwner: ArtifactOwner

    public init(
        artifactID: ArtifactID? = nil,
        data: Data,
        expectedDigest: StableDigest? = nil,
        expectedByteCount: UInt64? = nil,
        mimeType: String,
        semanticType: String? = nil,
        provenance: ArtifactProvenance,
        retentionPolicy: ArtifactRetentionPolicy,
        sensitivity: RedactionClassification,
        initialOwner: ArtifactOwner
    ) {
        self.artifactID = artifactID
        self.data = data
        self.expectedDigest = expectedDigest
        self.expectedByteCount = expectedByteCount
        self.mimeType = mimeType
        self.semanticType = semanticType
        self.provenance = provenance
        self.retentionPolicy = retentionPolicy
        self.sensitivity = sensitivity
        self.initialOwner = initialOwner
    }
}

/// Store-wide hard limits and platform storage requirements.
public struct ArtifactStoreConfiguration: Hashable, Sendable {
    public static let defaultMaximumArtifactBytes: UInt64 = 32 * 1_024 * 1_024

    public let rootURL: URL
    public let maximumArtifactBytes: UInt64
    public let excludeFromBackup: Bool
    public let verifyPlatformProtection: Bool

    public init(
        rootURL: URL,
        maximumArtifactBytes: UInt64 = Self.defaultMaximumArtifactBytes,
        excludeFromBackup: Bool = true,
        verifyPlatformProtection: Bool = true
    ) throws {
        guard rootURL.isFileURL, !rootURL.path.isEmpty, rootURL.path != "/",
              maximumArtifactBytes > 0
        else { throw ArtifactStoreError.invalidConfiguration }
        self.rootURL = rootURL
        self.maximumArtifactBytes = maximumArtifactBytes
        self.excludeFromBackup = excludeFromBackup
        self.verifyPlatformProtection = verifyPlatformProtection
    }
}

/// Stable fault registry covering each artifact durability boundary.
public enum ArtifactStoreFaultPoint: String, CaseIterable, Hashable, Codable, Sendable {
    public static let registryVersion = 1

    case beforeStagingWrite
    case afterStagingSync
    case afterObjectPublish
    case beforeIndexReplace
    case afterIndexReplace
    case beforeObjectRead
    case afterObjectRead
    case beforeObjectDelete
    case afterObjectDelete
}

public typealias ArtifactStoreClock = @Sendable () -> AgentTimestamp
public typealias ArtifactStoreIDGenerator = @Sendable () -> ArtifactID
public typealias ArtifactStoreTemporaryNameGenerator = @Sendable () -> String
public typealias ArtifactStoreFaultInjector = @Sendable (ArtifactStoreFaultPoint) throws -> Void

/// Typed failures. No error embeds artifact bytes, bearer tokens, or absolute external paths.
public enum ArtifactStoreError: Error, Hashable, Sendable {
    case invalidConfiguration
    case invalidOwner
    case retentionOwnerMismatch
    case secretContentProhibited
    case artifactTooLarge(limit: UInt64, actual: UInt64)
    case expectedDigestMismatch
    case expectedByteCountMismatch
    case invalidArtifactMetadata
    case artifactIDCollision(ArtifactID)
    case artifactNotFound(ArtifactID)
    case artifactStillReferenced(ArtifactID)
    case userManagedArtifactRequiresExplicitDeletion(ArtifactID)
    case staleReference(ArtifactID)
    case missingContent(ArtifactID)
    case integrityMismatch(ArtifactID)
    case unconfinedPath
    case symbolicLinkEncountered
    case metadataCorrupt
    case unsupportedMetadataVersion(Int)
    case storeAlreadyOpen
    case dataProtectionUnavailable
    case ioFailure(operation: String, code: Int32)
    case injected(ArtifactStoreFaultPoint)
}

/// Why an unreferenced artifact record may be removed.
public enum ArtifactDeletionReason: String, CaseIterable, Hashable, Codable, Sendable {
    case garbageCollection
    case explicitUserRequest
}

/// Deterministic cleanup accounting without exposing root paths.
public struct ArtifactCleanupReport: Hashable, Codable, Sendable {
    public let removedArtifactIDs: [ArtifactID]
    public let removedObjectDigests: [StableDigest]
    public let removedStagingFileCount: Int
    public let removedMetadataTemporaryFileCount: Int

    public init(
        removedArtifactIDs: [ArtifactID] = [],
        removedObjectDigests: [StableDigest] = [],
        removedStagingFileCount: Int = 0,
        removedMetadataTemporaryFileCount: Int = 0
    ) {
        self.removedArtifactIDs = removedArtifactIDs.sorted { $0.description < $1.description }
        self.removedObjectDigests = removedObjectDigests.sorted { $0.rawValue < $1.rawValue }
        self.removedStagingFileCount = removedStagingFileCount
        self.removedMetadataTemporaryFileCount = removedMetadataTemporaryFileCount
    }
}

/// Redacted diagnostic state for tests and local observability.
public struct ArtifactStoreSnapshot: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let reference: ArtifactReference
        public let owners: [ArtifactOwner]

        public init(reference: ArtifactReference, owners: [ArtifactOwner]) {
            self.reference = reference
            self.owners = owners.sorted()
        }
    }

    public let entries: [Entry]
    public let physicalObjectCount: Int

    public init(entries: [Entry], physicalObjectCount: Int) {
        self.entries = entries.sorted { $0.reference.id.description < $1.reference.id.description }
        self.physicalObjectCount = physicalObjectCount
    }
}
