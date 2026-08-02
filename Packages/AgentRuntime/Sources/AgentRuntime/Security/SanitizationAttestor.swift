// SPDX-License-Identifier: MIT

@_spi(AgentRuntime) import AgentContracts
import CryptoKit
import Foundation

/// Trusted local verification for the keyed attestation carried by sanitized durable JSON.
///
/// Decoding `SanitizedCanonicalJSON` proves only structural validity. Every executable boundary
/// must additionally verify this attestation with a key that is never persisted in the journal.
public protocol SanitizationAttestationValidating: Sendable {
    func validate(_ value: SanitizedCanonicalJSON) throws
}

public enum SanitizationAttestationError: Error, Hashable, Sendable {
    case invalidKey
    case invalidPolicyRevision
    case policyRevisionMismatch
    case invalidAttestation
}

/// HMAC-SHA256 attestor whose key is supplied by the app's protected secret store.
///
/// The implementation intentionally uses only Foundation plus AgentContracts so AgentRuntime stays
/// MLX- and platform-framework-free. The key is retained only in memory and is never exposed by a
/// public property, encoded, logged, or included in equality/hash behavior.
public struct LocalSanitizationAttestor: SanitizationAttestationValidating, Sendable {
    public let policyRevision: UInt64
    private let key: Data

    public init(key: Data, policyRevision: UInt64) throws {
        guard (32 ... 4_096).contains(key.count) else {
            throw SanitizationAttestationError.invalidKey
        }
        guard policyRevision > 0 else {
            throw SanitizationAttestationError.invalidPolicyRevision
        }
        self.key = key
        self.policyRevision = policyRevision
    }

    /// Creates trusted sanitizer output after the caller has removed or substituted secret values.
    /// Secret references remain opaque identifiers; plaintext secret material must never be passed.
    public func attest(
        value: CanonicalJSON,
        referencedSecretIDs: some Sequence<SecretReferenceID> = [],
        redaction: RedactionMetadata
    ) throws -> SanitizedCanonicalJSON {
        let provisional = try SanitizedCanonicalJSON(
            value: value,
            referencedSecretIDs: referencedSecretIDs,
            redaction: redaction,
            policyRevision: policyRevision,
            attestationDigest: StableDigest.sha256(Data("unissued".utf8))
        )
        return try SanitizedCanonicalJSON(
            value: provisional.value,
            referencedSecretIDs: provisional.referencedSecretIDs,
            redaction: provisional.redaction,
            policyRevision: provisional.policyRevision,
            attestationDigest: digest(for: provisional)
        )
    }

    public func validate(_ value: SanitizedCanonicalJSON) throws {
        guard value.policyRevision == policyRevision else {
            throw SanitizationAttestationError.policyRevisionMismatch
        }
        guard constantTimeEqual(value.attestationDigest, digest(for: value)) else {
            throw SanitizationAttestationError.invalidAttestation
        }
    }

    private func digest(for value: SanitizedCanonicalJSON) -> StableDigest {
        var message = Data()
        appendComponent(Data("mobilellm.sanitized-json-attestation.v1".utf8), to: &message)
        appendComponent(value.value.data, to: &message)
        appendComponent(Data(String(value.policyRevision).utf8), to: &message)
        for secretID in value.referencedSecretIDs {
            appendComponent(Data("secret:\(secretID.description)".utf8), to: &message)
        }
        appendComponent(Data(value.redaction.classification.rawValue.utf8), to: &message)
        appendComponent(Data(String(value.redaction.policyVersion).utf8), to: &message)
        for path in value.redaction.redactedFieldPaths {
            appendComponent(Data("path:\(path)".utf8), to: &message)
        }
        appendComponent(
            Data((value.redaction.omittedByteCount.map { String($0) } ?? "none").utf8),
            to: &message
        )
        appendComponent(
            Data((value.redaction.omittedContentDigest?.rawValue ?? "none").utf8),
            to: &message
        )
        return hmacSHA256(message)
    }

    private func appendComponent(_ component: Data, to destination: inout Data) {
        var length = UInt64(component.count).bigEndian
        withUnsafeBytes(of: &length) { destination.append(contentsOf: $0) }
        destination.append(component)
    }

    private func hmacSHA256(_ message: Data) -> StableDigest {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        let hexadecimal = authenticationCode.map { String(format: "%02x", $0) }.joined()
        return try! StableDigest(rawValue: hexadecimal)
    }

    private func constantTimeEqual(_ lhs: StableDigest, _ rhs: StableDigest) -> Bool {
        let left = Self.bytes(of: lhs)
        let right = Self.bytes(of: rhs)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func bytes(of digest: StableDigest) -> [UInt8] {
        let scalars = Array(digest.rawValue.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            result.append((nibble(scalars[index]) << 4) | nibble(scalars[index + 1]))
            index += 2
        }
        return result
    }

    private static func nibble(_ value: UInt8) -> UInt8 {
        value <= 57 ? value - 48 : value - 87
    }
}
