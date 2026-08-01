// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// A deterministic timestamp represented as milliseconds since the Unix epoch.
public struct AgentTimestamp: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    /// Milliseconds since 1970-01-01T00:00:00Z.
    public let rawValue: Int64

    /// Creates a timestamp from a deterministic millisecond value.
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Creates a timestamp from a Foundation date, rounding toward zero to milliseconds.
    ///
    /// Foundation can represent non-finite and extremely distant dates. Those values are
    /// rejected instead of relying on a trapping floating-point-to-integer conversion.
    public init(_ date: Date) throws {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max)
        else { throw AgentContractError.invalidTimestamp }
        rawValue = Int64(milliseconds)
    }

    /// Converts this value to a Foundation date.
    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(rawValue) / 1_000)
    }

    /// Orders timestamps by their millisecond value.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A validated SHA-256 digest encoded as 64 lowercase hexadecimal characters.
public struct StableDigest: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The canonical lowercase hexadecimal digest.
    public let rawValue: String

    /// Creates a digest after validating its canonical representation.
    public init(rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({
                  (0x30 ... 0x39).contains($0.value) || (0x61 ... 0x66).contains($0.value)
              })
        else {
            throw AgentContractError.invalidDigest(rawValue)
        }
        self.rawValue = rawValue
    }

    /// Computes a SHA-256 digest over the supplied bytes.
    public static func sha256(_ data: Data) -> Self {
        let value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try! Self(rawValue: value)
    }

    /// Computes a collision-resistant digest over length-delimited components.
    public static func fingerprint(domain: String, components: [Data]) -> Self {
        var bytes = Data("mobileLLM.AgentContracts.fingerprint.v1\0".utf8)
        appendLengthDelimited(Data(domain.utf8), to: &bytes)
        for component in components {
            appendLengthDelimited(component, to: &bytes)
        }
        return sha256(bytes)
    }

    /// The canonical lowercase hexadecimal digest.
    public var description: String { rawValue }

    /// Decodes and validates one lowercase hexadecimal digest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(rawValue: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a canonical SHA-256 digest"
            )
        }
    }

    /// Encodes one lowercase hexadecimal digest.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func appendLengthDelimited(_ component: Data, to result: inout Data) {
        var length = UInt64(component.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(component)
    }
}

/// A provider-neutral JSON value used in typed requests, results, and schema documents.
public indirect enum JSONValue: Hashable, Codable, Sendable {
    /// The JSON null value.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A signed integral JSON number.
    case integer(Int64)
    /// An unsigned integral JSON number.
    case unsignedInteger(UInt64)
    /// A finite binary64 JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])

    /// Decodes exactly one JSON value without coercing strings or booleans to numbers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// Encodes exactly one JSON value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "JSON numbers must be finite")
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    /// Produces deterministic UTF-8 JSON with UTF-16 key ordering and normalized finite numbers.
    public func canonicalData() throws -> Data {
        Data(try canonicalString().utf8)
    }

    /// Produces a deterministic SHA-256 fingerprint of the canonical JSON value.
    public func fingerprint() throws -> StableDigest {
        StableDigest.sha256(try canonicalData())
    }

    fileprivate func canonicalString() throws -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .integer(let value):
            guard (-9_007_199_254_740_991 ... 9_007_199_254_740_991).contains(value) else {
                throw AgentContractError.integerOutsideIJSONRange
            }
            return String(value)
        case .unsignedInteger(let value):
            guard value <= 9_007_199_254_740_991 else {
                throw AgentContractError.integerOutsideIJSONRange
            }
            return String(value)
        case .number(let value):
            return try Self.canonicalNumber(value)
        case .string(let value):
            return Self.escaped(value)
        case .array(let values):
            return "[" + (try values.map { try $0.canonicalString() }.joined(separator: ",")) + "]"
        case .object(let object):
            let keys = object.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            let members = try keys.map { key in
                Self.escaped(key) + ":" + (try object[key]!.canonicalString())
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }

    private static func escaped(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0 ... 0x1F: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private static func canonicalNumber(_ value: Double) throws -> String {
        guard value.isFinite else { throw AgentContractError.nonFiniteJSONNumber }
        if value == 0 { return "0" }

        // Preserve JCS's shortest integer spelling for binary64 values such as `1.0`.
        // `.number` deliberately represents IEEE-754 binary64, whose full finite range is
        // required by RFC 8785; exact interoperable integers use the separately guarded cases.
        if value.rounded(.towardZero) == value,
           abs(value) < Double(UInt64.max)
        {
            return value < 0 ? "-" + String(UInt64(-value)) : String(UInt64(value))
        }

        var raw = String(value).lowercased()
        guard let exponentIndex = raw.firstIndex(of: "e") else { return raw }
        let mantissa = String(raw[..<exponentIndex])
        let exponentText = String(raw[raw.index(after: exponentIndex)...])
        guard let exponent = Int(exponentText) else { throw AgentContractError.nonFiniteJSONNumber }

        let magnitude = abs(value)
        if magnitude >= 1e-6, magnitude < 1e21 {
            let negative = mantissa.hasPrefix("-")
            let unsignedMantissa = negative ? String(mantissa.dropFirst()) : mantissa
            let pieces = unsignedMantissa.split(separator: ".", omittingEmptySubsequences: false)
            let integerDigits = pieces.isEmpty ? "0" : String(pieces[0])
            let fractionDigits = pieces.count == 2 ? String(pieces[1]) : ""
            let digits = integerDigits + fractionDigits
            let decimalIndex = integerDigits.count + exponent
            let expanded: String
            if decimalIndex <= 0 {
                expanded = "0." + String(repeating: "0", count: -decimalIndex) + digits
            } else if decimalIndex >= digits.count {
                expanded = digits + String(repeating: "0", count: decimalIndex - digits.count)
            } else {
                let split = digits.index(digits.startIndex, offsetBy: decimalIndex)
                expanded = String(digits[..<split]) + "." + String(digits[split...])
            }
            return negative ? "-" + expanded : expanded
        }

        let sign = exponent >= 0 ? "+" : "-"
        raw = mantissa + "e" + sign + String(abs(exponent))
        return raw
    }
}

/// Canonical JSON bytes suitable for stable argument and payload fingerprints.
public struct CanonicalJSON: Hashable, Codable, Sendable {
    /// Maximum canonical inline bytes; larger bodies must be represented by artifacts.
    public static let maximumBytes = 8 * 1_024 * 1_024
    /// The canonical UTF-8 bytes.
    public let data: Data

    /// Creates a canonical representation from a typed JSON value.
    public init(_ value: JSONValue) throws {
        try AgentInlineJSONValidation.validate(value)
        let canonical = try value.canonicalData()
        guard canonical.count <= Self.maximumBytes else {
            throw AgentContractError.wireLimitExceeded("canonical inline JSON bytes")
        }
        data = canonical
    }

    /// Accepts bytes only when they are valid and already in canonical form.
    public init(canonicalData: Data) throws {
        guard canonicalData.count <= Self.maximumBytes else {
            throw AgentContractError.wireLimitExceeded("canonical inline JSON bytes")
        }
        let decoded = try AgentWireDecoder.decode(
            JSONValue.self,
            from: canonicalData,
            limits: .inlineValue
        )
        let canonical = try decoded.canonicalData()
        guard canonical == canonicalData else { throw AgentContractError.nonCanonicalJSON }
        data = canonical
    }

    /// The canonical UTF-8 representation as a string.
    public var string: String {
        String(decoding: data, as: UTF8.self)
    }

    /// The deterministic SHA-256 digest of the canonical JSON bytes.
    public var fingerprint: StableDigest {
        StableDigest.sha256(data)
    }

    /// Decodes a canonical JSON representation stored as one UTF-8 string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(canonicalData: Data(encoded.utf8))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected canonical JSON: \(error)"
            )
        }
    }

    /// Encodes the canonical JSON representation as one UTF-8 string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// Canonical JSON plus a locally keyed sanitization attestation for durable prepared requests.
///
/// Decoding restores audit data only. An executable gate always asks the trusted policy validator
/// to verify `attestationDigest` against its local key and current sanitization policy.
public struct SanitizedCanonicalJSON: Hashable, Codable, Sendable {
    /// Canonical secret-free body.
    public let value: CanonicalJSON
    /// Secret-store references substituted for plaintext values in the body.
    public let referencedSecretIDs: [SecretReferenceID]
    /// Redaction evidence produced by the trusted sanitizer.
    public let redaction: RedactionMetadata
    /// Positive local sanitization policy revision.
    public let policyRevision: UInt64
    /// Opaque locally keyed attestation over body, references, redaction, and policy revision.
    public let attestationDigest: StableDigest

    /// Creates sanitizer output. Only trusted runtime/compiler code imports this SPI.
    @_spi(AgentRuntime)
    public init(
        value: CanonicalJSON,
        referencedSecretIDs: some Sequence<SecretReferenceID> = [],
        redaction: RedactionMetadata,
        policyRevision: UInt64,
        attestationDigest: StableDigest
    ) throws {
        let secrets = Array(Set(referencedSecretIDs)).sorted { $0.description < $1.description }
        guard policyRevision > 0,
              secrets.isEmpty || redaction.classification == .secret
        else {
            throw AgentContractError.invalidRedactionMetadata
        }
        self.value = value
        self.referencedSecretIDs = secrets
        self.redaction = redaction
        self.policyRevision = policyRevision
        self.attestationDigest = attestationDigest
    }

    /// Canonical payload bytes.
    public var data: Data { value.data }
    /// Canonical payload text.
    public var string: String { value.string }
    /// Digest of the exact sanitized body.
    public var fingerprint: StableDigest { value.fingerprint }

    /// Decodes audit data and rejects noncanonical references and zero policy revisions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let secrets = try container.decode([SecretReferenceID].self, forKey: .referencedSecretIDs)
        do {
            try self.init(
                value: container.decode(CanonicalJSON.self, forKey: .value),
                referencedSecretIDs: secrets,
                redaction: container.decode(RedactionMetadata.self, forKey: .redaction),
                policyRevision: container.decode(UInt64.self, forKey: .policyRevision),
                attestationDigest: container.decode(StableDigest.self, forKey: .attestationDigest)
            )
            guard referencedSecretIDs == secrets else {
                throw AgentContractError.invalidRedactionMetadata
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case value, referencedSecretIDs, redaction, policyRevision, attestationDigest
    }
}

/// Classification controlling how a field may be displayed or retained.
public enum RedactionClassification: String, CaseIterable, Hashable, Codable, Sendable {
    /// Public non-sensitive metadata.
    case publicMetadata
    /// Internal operational metadata unsuitable for user-visible export by default.
    case internalMetadata
    /// Sensitive content requiring bounded retention and careful display.
    case sensitive
    /// Personal data requiring redaction by policy.
    case personalData
    /// Secret material that must never be persisted in an envelope.
    case secret
}

/// Metadata proving that sensitive fields were removed before serialization or logging.
public struct RedactionMetadata: Hashable, Codable, Sendable {
    /// Highest sensitivity represented by the original value.
    public let classification: RedactionClassification

    /// Stable field paths removed before the value crossed the boundary.
    public let redactedFieldPaths: [String]

    /// Number of original bytes intentionally omitted, when known.
    public let omittedByteCount: UInt64?

    /// Version of the local redaction policy applied.
    public let policyVersion: UInt32

    /// Digest of omitted content for correlation without retaining its body.
    public let omittedContentDigest: StableDigest?

    /// Creates normalized redaction metadata.
    public init(
        classification: RedactionClassification,
        redactedFieldPaths: [String] = [],
        omittedByteCount: UInt64? = nil,
        policyVersion: UInt32,
        omittedContentDigest: StableDigest? = nil
    ) throws {
        let normalizedPaths = Array(Set(redactedFieldPaths)).sorted()
        guard policyVersion > 0,
              normalizedPaths.count <= 128,
              normalizedPaths.allSatisfy({
                  AgentWireValidation.isNonblankControlFree($0, maximumLength: 512)
              }),
              classification != .secret
                || (!normalizedPaths.isEmpty && omittedByteCount.map({ $0 > 0 }) == true),
              classification == .publicMetadata || classification == .internalMetadata
                || omittedContentDigest == nil
        else { throw AgentContractError.invalidRedactionMetadata }
        self.classification = classification
        self.redactedFieldPaths = normalizedPaths
        self.omittedByteCount = omittedByteCount
        self.policyVersion = policyVersion
        self.omittedContentDigest = omittedContentDigest
    }

    /// Decodes and rejects duplicate or noncanonically ordered redacted paths.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let paths = try container.decode([String].self, forKey: .redactedFieldPaths)
        do {
            try self.init(
                classification: container.decode(RedactionClassification.self, forKey: .classification),
                redactedFieldPaths: paths,
                omittedByteCount: container.decodeIfPresent(UInt64.self, forKey: .omittedByteCount),
                policyVersion: container.decode(UInt32.self, forKey: .policyVersion),
                omittedContentDigest: container.decodeIfPresent(
                    StableDigest.self,
                    forKey: .omittedContentDigest
                )
            )
            guard redactedFieldPaths == paths else {
                throw AgentContractError.invalidRedactionMetadata
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case classification, redactedFieldPaths, omittedByteCount, policyVersion, omittedContentDigest
    }
}

/// An opaque reference to secret material held by a platform secret store.
public struct SecretReference: Hashable, Codable, Sendable {
    /// Opaque stable identity; it contains no credential material.
    public let id: SecretReferenceID

    /// Locally understood purpose used to select the correct credential.
    public let purpose: String

    /// Optional provider namespace that owns the reference.
    public let providerID: String?

    /// Creates a plaintext-free secret reference.
    public init(id: SecretReferenceID, purpose: String, providerID: String? = nil) throws {
        guard AgentWireValidation.isNonblankControlFree(purpose, maximumLength: 256) else {
            throw AgentContractError.invalidName("secret purpose")
        }
        if let providerID,
           !AgentWireValidation.isNonblankControlFree(providerID, maximumLength: 256)
        {
            throw AgentContractError.invalidName("secret provider")
        }
        self.id = id
        self.purpose = purpose
        self.providerID = providerID
    }

    /// Decodes and revalidates a plaintext-free secret reference.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(SecretReferenceID.self, forKey: .id),
                purpose: container.decode(String.self, forKey: .purpose),
                providerID: container.decodeIfPresent(String.self, forKey: .providerID)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, purpose, providerID
    }
}
