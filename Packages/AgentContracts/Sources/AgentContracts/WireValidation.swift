// SPDX-License-Identifier: MIT

import Foundation

enum AgentWireValidation {
    static func isNonblankControlFree(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isLowercaseNamespace(_ value: String, maximumLength: Int) -> Bool {
        guard isNonblankControlFree(value, maximumLength: maximumLength), value.contains(".") else {
            return false
        }
        var previousSeparator = true
        for scalar in value.unicodeScalars {
            let isAlphaNumeric = (0x61 ... 0x7A).contains(scalar.value)
                || (0x30 ... 0x39).contains(scalar.value)
            let isSeparator = scalar.value == 0x2E || scalar.value == 0x2D
            guard isAlphaNumeric || isSeparator, !(isSeparator && previousSeparator) else { return false }
            previousSeparator = isSeparator
        }
        return !previousSeparator
    }

    static func isRFCToken(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        let allowedPunctuation: Set<UInt32> = [
            0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
            0x5E, 0x5F, 0x60, 0x7C, 0x7E,
        ]
        return value.unicodeScalars.allSatisfy { scalar in
            (0x30 ... 0x39).contains(scalar.value)
                || (0x41 ... 0x5A).contains(scalar.value)
                || (0x61 ... 0x7A).contains(scalar.value)
                || allowedPunctuation.contains(scalar.value)
        }
    }

    static func isMIMEType(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return value == normalized
            && value.utf8.count <= 127
            && parts.count == 2
            && isRFCToken(parts[0])
            && isRFCToken(parts[1])
    }
}

/// Resource limits applied before untrusted JSON reaches a typed decoder.
public struct AgentWireDecodingLimits: Hashable, Codable, Sendable {
    /// Maximum complete UTF-8 payload size.
    public let maximumBytes: Int
    /// Maximum JSON object/array nesting depth.
    public let maximumNestingDepth: Int
    /// Maximum aggregate object members and array elements.
    public let maximumCollectionItems: Int
    /// Maximum encoded bytes in one JSON string token.
    public let maximumStringBytes: Int

    /// Creates positive, internally bounded preflight limits.
    public init(
        maximumBytes: Int,
        maximumNestingDepth: Int,
        maximumCollectionItems: Int,
        maximumStringBytes: Int
    ) throws {
        guard maximumBytes > 0, maximumBytes <= 64 * 1_024 * 1_024,
              maximumNestingDepth > 0, maximumNestingDepth <= 512,
              maximumCollectionItems > 0, maximumCollectionItems <= 1_000_000,
              maximumStringBytes > 0, maximumStringBytes <= maximumBytes
        else { throw AgentContractError.wireLimitExceeded("invalid decoder limits") }
        self.maximumBytes = maximumBytes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumCollectionItems = maximumCollectionItems
        self.maximumStringBytes = maximumStringBytes
    }

    /// Conservative defaults for persisted and MCP contract envelopes.
    public static let contractEnvelope = try! Self(
        maximumBytes: 64 * 1_024 * 1_024,
        maximumNestingDepth: 128,
        maximumCollectionItems: 100_000,
        maximumStringBytes: 48 * 1_024 * 1_024
    )

    /// Limits for inline canonical JSON values; larger content must be an artifact.
    public static let inlineValue = try! Self(
        maximumBytes: 8 * 1_024 * 1_024,
        maximumNestingDepth: 64,
        maximumCollectionItems: 32_768,
        maximumStringBytes: 8 * 1_024 * 1_024
    )

    /// Decodes limits only through the validating initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumBytes: container.decode(Int.self, forKey: .maximumBytes),
                maximumNestingDepth: container.decode(Int.self, forKey: .maximumNestingDepth),
                maximumCollectionItems: container.decode(Int.self, forKey: .maximumCollectionItems),
                maximumStringBytes: container.decode(Int.self, forKey: .maximumStringBytes)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumBytes, maximumNestingDepth, maximumCollectionItems, maximumStringBytes
    }
}

/// The supported entry point for decoding untrusted persisted, MCP, and adapter JSON.
///
/// It performs an allocation-light byte/depth/string/collection preflight before delegating to
/// `JSONDecoder`. Boundary adapters must not call a bare decoder on attacker-controlled bytes.
public enum AgentWireDecoder {
    /// Decodes one typed contract value after deterministic structural preflight.
    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        limits: AgentWireDecodingLimits = .contractEnvelope
    ) throws -> Value {
        try preflight(data, limits: limits)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func preflight(_ data: Data, limits: AgentWireDecodingLimits) throws {
        guard data.count <= limits.maximumBytes else {
            throw AgentContractError.wireLimitExceeded("payload bytes")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw AgentContractError.wireLimitExceeded("invalid UTF-8")
        }

        struct ContainerState {
            let isObject: Bool
            var keys: Set<String> = []
        }

        let bytes = Array(data)
        var containers: [ContainerState] = []
        var items = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x22:
                let start = index
                index += 1
                var encodedStringBytes = 0
                var escaped = false
                while index < bytes.count {
                    let stringByte = bytes[index]
                    if escaped {
                        escaped = false
                        encodedStringBytes += 1
                    } else if stringByte == 0x5C {
                        escaped = true
                        encodedStringBytes += 1
                    } else if stringByte == 0x22 {
                        break
                    } else {
                        guard stringByte >= 0x20 else {
                            throw AgentContractError.wireLimitExceeded("unescaped string control")
                        }
                        encodedStringBytes += 1
                    }
                    guard encodedStringBytes <= limits.maximumStringBytes else {
                        throw AgentContractError.wireLimitExceeded("string bytes")
                    }
                    index += 1
                }
                guard index < bytes.count, bytes[index] == 0x22, !escaped else {
                    throw AgentContractError.wireLimitExceeded("unterminated JSON string")
                }
                var lookahead = index + 1
                while lookahead < bytes.count,
                      bytes[lookahead] == 0x20 || bytes[lookahead] == 0x09
                        || bytes[lookahead] == 0x0A || bytes[lookahead] == 0x0D
                {
                    lookahead += 1
                }
                if lookahead < bytes.count, bytes[lookahead] == 0x3A {
                    guard !containers.isEmpty, containers[containers.count - 1].isObject else {
                        throw AgentContractError.wireLimitExceeded("object key outside object")
                    }
                    let token = Data(bytes[start ... index])
                    let key = try JSONDecoder().decode(String.self, from: token)
                    guard containers[containers.count - 1].keys.insert(key).inserted else {
                        throw AgentContractError.wireLimitExceeded("duplicate object key")
                    }
                }
            case 0x7B:
                containers.append(ContainerState(isObject: true))
                items += 1
                guard containers.count <= limits.maximumNestingDepth else {
                    throw AgentContractError.wireLimitExceeded("nesting depth")
                }
            case 0x5B:
                containers.append(ContainerState(isObject: false))
                items += 1
                guard containers.count <= limits.maximumNestingDepth else {
                    throw AgentContractError.wireLimitExceeded("nesting depth")
                }
            case 0x7D:
                guard containers.last?.isObject == true else {
                    throw AgentContractError.wireLimitExceeded("unbalanced container")
                }
                containers.removeLast()
            case 0x5D:
                guard containers.last?.isObject == false else {
                    throw AgentContractError.wireLimitExceeded("unbalanced container")
                }
                containers.removeLast()
            case 0x2C:
                items += 1
            default:
                break
            }
            guard items <= limits.maximumCollectionItems else {
                throw AgentContractError.wireLimitExceeded("collection items")
            }
            index += 1
        }
        guard containers.isEmpty else {
            throw AgentContractError.wireLimitExceeded("unterminated JSON structure")
        }
    }
}

/// Iterative structural validation for trusted in-memory JSON before recursive canonicalization.
enum AgentInlineJSONValidation {
    static func validate(
        _ value: JSONValue,
        limits: AgentWireDecodingLimits = .inlineValue
    ) throws {
        var stack: [(value: JSONValue, depth: Int)] = [(value, 0)]
        var items = 0
        while let current = stack.popLast() {
            switch current.value {
            case .null, .bool, .integer, .unsignedInteger:
                break
            case .number(let value):
                guard value.isFinite else { throw AgentContractError.nonFiniteJSONNumber }
            case .string(let value):
                guard value.utf8.count <= limits.maximumStringBytes else {
                    throw AgentContractError.wireLimitExceeded("string bytes")
                }
            case .array(let values):
                let depth = current.depth + 1
                guard depth <= limits.maximumNestingDepth,
                      values.count <= limits.maximumCollectionItems - items
                else { throw AgentContractError.wireLimitExceeded("inline JSON structure") }
                items += values.count
                stack.append(contentsOf: values.map { ($0, depth) })
            case .object(let object):
                let depth = current.depth + 1
                guard depth <= limits.maximumNestingDepth,
                      object.count <= limits.maximumCollectionItems - items,
                      object.keys.allSatisfy({ $0.utf8.count <= limits.maximumStringBytes })
                else { throw AgentContractError.wireLimitExceeded("inline JSON structure") }
                items += object.count
                stack.append(contentsOf: object.values.map { ($0, depth) })
            }
        }
    }
}

enum AgentOperationSemantics {
    static func validate(
        effects: [AgentEffect],
        capabilities: AgentCapabilitySet,
        retryPolicy: ExternalRetryPolicy,
        idempotency: ExternalIdempotency,
        idempotencyKey: ExternalIdempotencyKey?,
        requiresBoundIdempotencyKey: Bool = true
    ) throws {
        guard !effects.isEmpty else {
            throw AgentContractError.invalidExternalOperationPlan("at least one effect is required")
        }
        let readOnlyEffects: Set<AgentEffect> = [.localPure, .localRead, .privateDataRead, .networkRead]
        guard !(idempotency == .pureRead && !Set(effects).isSubset(of: readOnlyEffects)) else {
            throw AgentContractError.invalidExternalOperationPlan("non-read operation declared pure read")
        }
        let missingEffectCapabilities = effects.compactMap(\.minimumCapability).filter {
            !capabilities.contains($0)
        }
        guard missingEffectCapabilities.isEmpty else {
            throw AgentContractError.capabilityEscalation(missingEffectCapabilities)
        }
        guard !(idempotency == .nonIdempotent && retryPolicy.kind != .never) else {
            throw AgentContractError.invalidExternalOperationPlan("non-idempotent operation cannot retry")
        }
        guard !requiresBoundIdempotencyKey
                || (idempotency == .idempotencyKeyRequired) == (idempotencyKey != nil)
        else {
            throw AgentContractError.invalidExternalOperationPlan("idempotency key contract mismatch")
        }
        let writeEffects: Set<AgentEffect> = [
            .localWrite, .externalWrite, .externalCommunication, .destructive, .financial,
        ]
        if requiresBoundIdempotencyKey,
           retryPolicy.kind != .never,
           !Set(effects).isDisjoint(with: writeEffects)
        {
            guard idempotency == .idempotencyKeyRequired, idempotencyKey != nil else {
                throw AgentContractError.invalidExternalOperationPlan(
                    "write retry requires a bound idempotency key"
                )
            }
        }
        guard !(effects.contains(.unknownExternal) && retryPolicy.kind != .never) else {
            throw AgentContractError.invalidExternalOperationPlan("unknown external effect cannot retry")
        }
    }
}
