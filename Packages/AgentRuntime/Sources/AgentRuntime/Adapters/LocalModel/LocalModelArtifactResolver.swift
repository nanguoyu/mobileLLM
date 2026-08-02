// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

/// Explicit, authorization-bound seam for resolving an artifact already admitted to a model request.
///
/// Implementations must not discover locators, prompt for access, download content, or widen authority.
/// They receive the complete pre-authorized reference and return only ephemeral bytes for that exact
/// reference. `LocalModelProvider` verifies byte count and SHA-256 before handing bytes to `LLMEngine`.
public protocol LocalModelArtifactBytesResolving: Sendable {
    func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data
}

/// A no-I/O resolver suitable when the caller did not preload any artifact bodies.
public struct UnavailableLocalModelArtifactResolver: LocalModelArtifactBytesResolving {
    public init() {}

    public func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        throw LocalModelAdapterError.artifactUnavailable(reference.id)
    }
}

/// One exact artifact body loaded by the trusted caller before generation authorization is consumed.
public struct PreloadedLocalModelArtifact: Hashable, Sendable {
    public let reference: ArtifactReference
    public let bytes: Data

    public init(reference: ArtifactReference, bytes: Data) throws {
        guard reference.integrityStatus == .verified,
              reference.byteCount == UInt64(bytes.count),
              reference.contentDigest == StableDigest.sha256(bytes)
        else { throw LocalModelAdapterError.artifactIntegrityMismatch(reference.id) }
        self.reference = reference
        self.bytes = bytes
    }
}

/// In-memory resolver that performs no file, photo-library, provider, or network access.
public struct PreloadedLocalModelArtifactResolver: LocalModelArtifactBytesResolving {
    private let entries: [ArtifactID: PreloadedLocalModelArtifact]

    public init(_ artifacts: [PreloadedLocalModelArtifact]) throws {
        var indexed: [ArtifactID: PreloadedLocalModelArtifact] = [:]
        for artifact in artifacts {
            guard indexed.updateValue(artifact, forKey: artifact.reference.id) == nil else {
                throw LocalModelAdapterError.invalidRegistration("duplicate preloaded artifact")
            }
        }
        entries = indexed
    }

    public func preauthorizedBytes(for reference: ArtifactReference) async throws -> Data {
        guard let artifact = entries[reference.id], artifact.reference == reference else {
            throw LocalModelAdapterError.artifactUnavailable(reference.id)
        }
        return artifact.bytes
    }
}
