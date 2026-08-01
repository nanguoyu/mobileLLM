// SPDX-License-Identifier: MIT

import Foundation

/// A Semantic Versioning 2.0.0 value used for protocol capability negotiation.
public struct SemanticVersion: Hashable, Codable, Sendable, Comparable, CustomStringConvertible,
    LosslessStringConvertible
{
    /// The breaking-change component.
    public let major: UInt

    /// The backward-compatible feature component.
    public let minor: UInt

    /// The backward-compatible fix component.
    public let patch: UInt

    /// Dot-separated prerelease identifiers, empty for a normal release.
    public let prereleaseIdentifiers: [String]

    /// Dot-separated build identifiers, ignored for precedence.
    public let buildMetadataIdentifiers: [String]

    /// Creates a validated semantic version.
    public init(
        major: UInt,
        minor: UInt,
        patch: UInt,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
    ) throws {
        guard Self.valid(identifiers: prereleaseIdentifiers, forbidNumericLeadingZeros: true),
              Self.valid(identifiers: buildMetadataIdentifiers, forbidNumericLeadingZeros: false)
        else {
            throw AgentContractError.invalidSemanticVersion
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }

    /// Parses a Semantic Versioning 2.0.0 string.
    public init?(_ description: String) {
        let buildSplit = description.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildSplit.count <= 2 else { return nil }
        let coreAndPrerelease = buildSplit[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard coreAndPrerelease.count <= 2 else { return nil }
        let core = coreAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ !$0.isEmpty && ($0 == "0" || !$0.hasPrefix("0")) }),
              let major = UInt(core[0]),
              let minor = UInt(core[1]),
              let patch = UInt(core[2])
        else { return nil }

        let prerelease = coreAndPrerelease.count == 2
            ? coreAndPrerelease[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        let build = buildSplit.count == 2
            ? buildSplit[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
        guard let parsed = try? Self(
            major: major,
            minor: minor,
            patch: patch,
            prereleaseIdentifiers: prerelease,
            buildMetadataIdentifiers: build
        ) else { return nil }
        self = parsed
    }

    /// The canonical semantic-version string.
    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            value += "-" + prereleaseIdentifiers.joined(separator: ".")
        }
        if !buildMetadataIdentifiers.isEmpty {
            value += "+" + buildMetadataIdentifiers.joined(separator: ".")
        }
        return value
    }

    /// Decodes one semantic-version string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let parsed = Self(encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid semantic version"
            )
        }
        self = parsed
    }

    /// Encodes the canonical semantic-version string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Returns whether this value has lower SemVer precedence, ignoring build metadata.
    public func hasLowerSemanticPrecedence(than other: Self) -> Bool {
        Self.compareSemanticPrecedence(self, other) < 0
    }

    /// Provides a stable total wire order: SemVer precedence followed by build metadata.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let precedence = compareSemanticPrecedence(lhs, rhs)
        if precedence != 0 { return precedence < 0 }
        return lhs.buildMetadataIdentifiers.lexicographicallyPrecedes(rhs.buildMetadataIdentifiers)
    }

    private static func compareSemanticPrecedence(_ lhs: Self, _ rhs: Self) -> Int {
        if lhs.major != rhs.major { return lhs.major < rhs.major ? -1 : 1 }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor ? -1 : 1 }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch ? -1 : 1 }
        if lhs.prereleaseIdentifiers.isEmpty { return rhs.prereleaseIdentifiers.isEmpty ? 0 : 1 }
        if rhs.prereleaseIdentifiers.isEmpty { return -1 }

        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
            if left == right { continue }
            let leftNumeric = left.unicodeScalars.allSatisfy { (0x30 ... 0x39).contains($0.value) }
            let rightNumeric = right.unicodeScalars.allSatisfy { (0x30 ... 0x39).contains($0.value) }
            switch (leftNumeric, rightNumeric) {
            case (true, true):
                if left.utf8.count != right.utf8.count {
                    return left.utf8.count < right.utf8.count ? -1 : 1
                }
                return left < right ? -1 : 1
            case (true, false): return -1
            case (false, true): return 1
            case (false, false): return left < right ? -1 : 1
            }
        }
        if lhs.prereleaseIdentifiers.count == rhs.prereleaseIdentifiers.count { return 0 }
        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count ? -1 : 1
    }

    private static func valid(identifiers: [String], forbidNumericLeadingZeros: Bool) -> Bool {
        identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({
                      (0x30 ... 0x39).contains($0.value)
                          || (0x41 ... 0x5A).contains($0.value)
                          || (0x61 ... 0x7A).contains($0.value)
                          || $0.value == 0x2D
                  })
            else { return false }
            if forbidNumericLeadingZeros,
               identifier.allSatisfy(\.isNumber),
               identifier.count > 1,
               identifier.first == "0"
            {
                return false
            }
            return true
        }
    }
}

/// The protocol and payload versions supported by this package release.
public enum AgentContractVersion {
    /// The semantic protocol version emitted by this package.
    public static let currentProtocol = try! SemanticVersion(major: 1, minor: 0, patch: 0)

    /// The current wire payload version for first-generation contract payloads.
    public static let currentPayload: UInt16 = 1

    /// Validates a protocol/payload pair and fails closed for incompatible values.
    public static func validate(protocolVersion: SemanticVersion, payloadVersion: UInt16) throws {
        guard protocolVersion.major == currentProtocol.major else {
            throw AgentContractError.unsupportedProtocolVersion(
                received: protocolVersion,
                supportedMajor: currentProtocol.major
            )
        }
        guard payloadVersion == currentPayload else {
            throw AgentContractError.unsupportedPayloadVersion(
                received: payloadVersion,
                supported: currentPayload ... currentPayload
            )
        }
    }
}

/// A payload that can be transported by a validated versioned envelope.
public protocol AgentContractPayload: Codable, Sendable {
    /// The stable wire-schema identifier for this payload family.
    static var schemaID: String { get }

    /// The payload versions this implementation can decode.
    static var supportedPayloadVersions: ClosedRange<UInt16> { get }

    /// The payload version emitted by this implementation.
    static var currentPayloadVersion: UInt16 { get }
}

/// A provider-neutral versioned transport envelope for a contract payload.
public struct AgentEnvelope<Payload: AgentContractPayload>: Codable, Sendable {
    /// Semantic version of the cross-component protocol.
    public let protocolVersion: SemanticVersion

    /// Version of the concrete payload schema.
    public let payloadVersion: UInt16

    /// Stable identifier preventing one payload family from decoding as another.
    public let schemaID: String

    /// Optional metadata describing fields redacted before serialization.
    public let redaction: RedactionMetadata?

    /// The typed payload carried by the envelope.
    public let payload: Payload

    /// Decodes an untrusted envelope through the bounded contract-wire entry point.
    public static func decodeUntrusted(
        from data: Data,
        limits: AgentWireDecodingLimits = .contractEnvelope
    ) throws -> Self {
        try AgentWireDecoder.decode(Self.self, from: data, limits: limits)
    }

    /// Wraps a payload using the current supported wire versions.
    public init(payload: Payload, redaction: RedactionMetadata? = nil) throws {
        try Self.validate(
            protocolVersion: AgentContractVersion.currentProtocol,
            payloadVersion: Payload.currentPayloadVersion,
            schemaID: Payload.schemaID
        )
        protocolVersion = AgentContractVersion.currentProtocol
        payloadVersion = Payload.currentPayloadVersion
        schemaID = Payload.schemaID
        self.redaction = redaction
        self.payload = payload
    }

    /// Wraps a payload with explicit versions after compatibility validation.
    public init(
        protocolVersion: SemanticVersion,
        payloadVersion: UInt16,
        payload: Payload,
        redaction: RedactionMetadata? = nil
    ) throws {
        try Self.validate(
            protocolVersion: protocolVersion,
            payloadVersion: payloadVersion,
            schemaID: Payload.schemaID
        )
        self.protocolVersion = protocolVersion
        self.payloadVersion = payloadVersion
        schemaID = Payload.schemaID
        self.redaction = redaction
        self.payload = payload
    }

    /// Decodes and validates protocol version, payload version, and schema identity.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(SemanticVersion.self, forKey: .protocolVersion)
        let payloadVersion = try container.decode(UInt16.self, forKey: .payloadVersion)
        let schemaID = try container.decode(String.self, forKey: .schemaID)
        do {
            try Self.validate(
                protocolVersion: protocolVersion,
                payloadVersion: payloadVersion,
                schemaID: schemaID
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
        self.protocolVersion = protocolVersion
        self.payloadVersion = payloadVersion
        self.schemaID = schemaID
        redaction = try container.decodeIfPresent(RedactionMetadata.self, forKey: .redaction)
        payload = try container.decode(Payload.self, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case payloadVersion
        case schemaID
        case redaction
        case payload
    }

    private static func validate(
        protocolVersion: SemanticVersion,
        payloadVersion: UInt16,
        schemaID: String
    ) throws {
        guard AgentWireValidation.isLowercaseNamespace(Payload.schemaID, maximumLength: 128),
              Payload.currentPayloadVersion > 0,
              Payload.supportedPayloadVersions.contains(Payload.currentPayloadVersion)
        else { throw AgentContractError.invalidSchemaDeclaration(Payload.schemaID) }
        guard protocolVersion.major == AgentContractVersion.currentProtocol.major else {
            throw AgentContractError.unsupportedProtocolVersion(
                received: protocolVersion,
                supportedMajor: AgentContractVersion.currentProtocol.major
            )
        }
        guard Payload.supportedPayloadVersions.contains(payloadVersion) else {
            throw AgentContractError.unsupportedPayloadVersion(
                received: payloadVersion,
                supported: Payload.supportedPayloadVersions
            )
        }
        guard schemaID == Payload.schemaID else {
            throw AgentContractError.schemaMismatch(expected: Payload.schemaID, received: schemaID)
        }
    }
}

extension AgentEnvelope: Equatable where Payload: Equatable {}
extension AgentEnvelope: Hashable where Payload: Hashable {}

/// Default payload-version declarations for version-one contract payloads.
public extension AgentContractPayload {
    /// The only payload version supported by first-generation contract types.
    static var supportedPayloadVersions: ClosedRange<UInt16> { 1 ... 1 }

    /// The payload version emitted by first-generation contract types.
    static var currentPayloadVersion: UInt16 { 1 }
}
