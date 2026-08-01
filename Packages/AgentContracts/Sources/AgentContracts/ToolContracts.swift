// SPDX-License-Identifier: MIT

import Foundation

/// Hard complexity limits for JSON Schema Draft 2020-12 contract documents.
public struct JSONSchemaLimits: Hashable, Codable, Sendable {
    /// Maximum canonical encoded bytes.
    public let maximumEncodedBytes: UInt64
    /// Maximum nested object/array depth.
    public let maximumNestingDepth: UInt16
    /// Maximum structural plus locally resolved schema nodes.
    public let maximumResolvedNodes: UInt32
    /// Maximum local `$ref` traversal depth.
    public let maximumLocalReferenceDepth: UInt16
    /// Maximum Unicode-scalar length of a pattern.
    public let maximumPatternLength: UInt16

    /// Creates nonzero schema limits.
    public init(
        maximumEncodedBytes: UInt64,
        maximumNestingDepth: UInt16,
        maximumResolvedNodes: UInt32,
        maximumLocalReferenceDepth: UInt16,
        maximumPatternLength: UInt16
    ) throws {
        guard maximumEncodedBytes > 0, maximumNestingDepth > 0, maximumResolvedNodes > 0,
              maximumLocalReferenceDepth > 0, maximumPatternLength > 0
        else { throw AgentContractError.invalidJSONSchema("limits must be positive") }
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumResolvedNodes = maximumResolvedNodes
        self.maximumLocalReferenceDepth = maximumLocalReferenceDepth
        self.maximumPatternLength = maximumPatternLength
    }

    /// Required first-release limits from the specification.
    public static let firstRelease = try! Self(
        maximumEncodedBytes: 64 * 1_024,
        maximumNestingDepth: 16,
        maximumResolvedNodes: 1_024,
        maximumLocalReferenceDepth: 16,
        maximumPatternLength: 256
    )

    /// Decodes and revalidates nonzero schema limits.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                maximumEncodedBytes: container.decode(UInt64.self, forKey: .maximumEncodedBytes),
                maximumNestingDepth: container.decode(UInt16.self, forKey: .maximumNestingDepth),
                maximumResolvedNodes: container.decode(UInt32.self, forKey: .maximumResolvedNodes),
                maximumLocalReferenceDepth: container.decode(UInt16.self, forKey: .maximumLocalReferenceDepth),
                maximumPatternLength: container.decode(UInt16.self, forKey: .maximumPatternLength)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case maximumEncodedBytes, maximumNestingDepth, maximumResolvedNodes
        case maximumLocalReferenceDepth, maximumPatternLength
    }
}

/// Whether every keyword in a schema is enforced by the local validator contract.
public enum JSONSchemaEnforcement: String, CaseIterable, Hashable, Codable, Sendable {
    /// Every present keyword is in the locally enforced subset.
    case fullyEnforced
    /// Unknown keywords are preserved but explicitly not locally enforced.
    case partiallyEnforced
}

/// A preserved, bounded JSON Schema Draft 2020-12 document with enforcement metadata.
public struct JSONSchemaDocument: Hashable, Codable, Sendable {
    /// Canonical schema tree, including unknown keywords for round-trip and display.
    public let root: JSONValue
    /// Complexity limits applied when this value was accepted.
    public let limits: JSONSchemaLimits
    /// Local enforcement status.
    public let enforcement: JSONSchemaEnforcement
    /// Unknown keyword names in stable order.
    public let unenforcedKeywords: [String]
    /// Deterministic digest of canonical schema bytes.
    public let digest: StableDigest

    /// Validates a bounded local-reference-only Draft 2020-12 schema document.
    public init(root: JSONValue, limits: JSONSchemaLimits = .firstRelease) throws {
        guard case .object = root else {
            throw AgentContractError.invalidJSONSchema("root must be an object")
        }
        // Bound trusted in-memory values iteratively before recursive canonicalization or schema
        // traversal. This is the same hard inline boundary used for persisted contract values.
        try AgentInlineJSONValidation.validate(root)
        let data = try root.canonicalData()
        guard data.count <= limits.maximumEncodedBytes else {
            throw AgentContractError.invalidJSONSchema("encoded size exceeds limit")
        }
        var inspection = SchemaInspection()
        try inspection.walk(root, depth: 1, context: .schema, limits: limits)
        guard inspection.nodes <= limits.maximumResolvedNodes else {
            throw AgentContractError.invalidJSONSchema("node count exceeds limit")
        }
        try inspection.validateReferences(in: root, limits: limits)
        self.root = root
        self.limits = limits
        unenforcedKeywords = inspection.unknownKeywords.sorted()
        enforcement = unenforcedKeywords.isEmpty ? .fullyEnforced : .partiallyEnforced
        digest = StableDigest.sha256(data)
    }

    /// Decodes and recomputes enforcement metadata and digest, rejecting forged values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let root = try container.decode(JSONValue.self, forKey: .root)
        let limits = try container.decode(JSONSchemaLimits.self, forKey: .limits)
        let encodedEnforcement = try container.decode(JSONSchemaEnforcement.self, forKey: .enforcement)
        let encodedKeywords = try container.decode([String].self, forKey: .unenforcedKeywords)
        let encodedDigest = try container.decode(StableDigest.self, forKey: .digest)
        do {
            try self.init(root: root, limits: limits)
            guard enforcement == encodedEnforcement,
                  unenforcedKeywords == encodedKeywords,
                  digest == encodedDigest
            else { throw AgentContractError.invalidJSONSchema("forged schema metadata") }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case root, limits, enforcement, unenforcedKeywords, digest
    }

    /// Validates one instance against the fully enforced local JSON Schema subset.
    public func validates(instance: JSONValue) throws -> Bool {
        guard enforcement == .fullyEnforced else {
            throw AgentContractError.invalidJSONSchema("cannot prove a partially enforced schema")
        }
        return try JSONSchemaInstanceValidator(root: root).validate(instance, against: root, depth: 1)
    }
}

private struct JSONSchemaInstanceValidator {
    let root: JSONValue

    func validate(_ instance: JSONValue, against schema: JSONValue, depth: UInt16) throws -> Bool {
        guard depth <= 64 else { throw AgentContractError.invalidJSONSchema("instance validation depth") }
        if case .bool(let allowed) = schema { return allowed }
        guard case .object(let keywords) = schema else { return false }

        if let reference = keywords["$ref"] {
            guard case .string(let pointer) = reference,
                  let target = value(at: pointer, in: root),
                  try validate(instance, against: target, depth: depth + 1)
            else { return false }
        }
        if let type = keywords["type"], !matchesType(instance, declaration: type) { return false }
        if case .array(let allowed)? = keywords["enum"], !allowed.contains(instance) { return false }
        if let constant = keywords["const"], constant != instance { return false }

        if case .object(let object) = instance {
            if let minimum = nonnegativeInteger(keywords["minProperties"]), object.count < minimum {
                return false
            }
            if let maximum = nonnegativeInteger(keywords["maxProperties"]), object.count > maximum {
                return false
            }
            if case .array(let required)? = keywords["required"] {
                for item in required {
                    guard case .string(let key) = item, object[key] != nil else { return false }
                }
            }
            let properties: [String: JSONValue]
            if case .object(let declared)? = keywords["properties"] { properties = declared }
            else { properties = [:] }
            for (key, value) in object {
                if let propertySchema = properties[key] {
                    guard try validate(value, against: propertySchema, depth: depth + 1) else {
                        return false
                    }
                } else if let additional = keywords["additionalProperties"] {
                    guard try validate(value, against: additional, depth: depth + 1) else { return false }
                }
            }
        }

        if case .array(let array) = instance {
            if let minimum = nonnegativeInteger(keywords["minItems"]), array.count < minimum { return false }
            if let maximum = nonnegativeInteger(keywords["maxItems"]), array.count > maximum { return false }
            if case .bool(true)? = keywords["uniqueItems"], Set(array).count != array.count { return false }
            var prefixCount = 0
            if case .array(let prefixes)? = keywords["prefixItems"] {
                prefixCount = prefixes.count
                for (index, itemSchema) in prefixes.enumerated() where index < array.count {
                    guard try validate(array[index], against: itemSchema, depth: depth + 1) else {
                        return false
                    }
                }
            }
            if let itemSchema = keywords["items"] {
                for item in array.dropFirst(prefixCount) {
                    guard try validate(item, against: itemSchema, depth: depth + 1) else { return false }
                }
            }
        }

        if case .string(let string) = instance {
            let length = string.unicodeScalars.count
            if let minimum = nonnegativeInteger(keywords["minLength"]), length < minimum { return false }
            if let maximum = nonnegativeInteger(keywords["maxLength"]), length > maximum { return false }
        }

        if let number = numericValue(instance) {
            if let minimum = numericValue(keywords["minimum"]), number < minimum { return false }
            if let maximum = numericValue(keywords["maximum"]), number > maximum { return false }
            if let minimum = numericValue(keywords["exclusiveMinimum"]), number <= minimum { return false }
            if let maximum = numericValue(keywords["exclusiveMaximum"]), number >= maximum { return false }
            if let divisor = numericValue(keywords["multipleOf"]) {
                let quotient = number / divisor
                guard quotient.isFinite,
                      abs(quotient - quotient.rounded()) <= max(1, abs(quotient)) * 1e-12
                else { return false }
            }
        }

        if case .array(let schemas)? = keywords["allOf"] {
            for child in schemas where try !validate(instance, against: child, depth: depth + 1) {
                return false
            }
        }
        if case .array(let schemas)? = keywords["anyOf"] {
            var matched = false
            for child in schemas where try validate(instance, against: child, depth: depth + 1) {
                matched = true
            }
            if !matched { return false }
        }
        if case .array(let schemas)? = keywords["oneOf"] {
            var matches = 0
            for child in schemas where try validate(instance, against: child, depth: depth + 1) {
                matches += 1
            }
            if matches != 1 { return false }
        }
        if let negated = keywords["not"], try validate(instance, against: negated, depth: depth + 1) {
            return false
        }
        return true
    }

    private func matchesType(_ value: JSONValue, declaration: JSONValue) -> Bool {
        let names: [String]
        switch declaration {
        case .string(let name): names = [name]
        case .array(let values):
            var decodedNames: [String] = []
            for value in values {
                guard case .string(let name) = value else { return false }
                decodedNames.append(name)
            }
            names = decodedNames
        default: return false
        }
        for name in names {
            switch (name, value) {
            case ("null", .null), ("boolean", .bool), ("object", .object), ("array", .array),
                 ("string", .string), ("integer", .integer), ("integer", .unsignedInteger),
                 ("number", .integer), ("number", .unsignedInteger), ("number", .number):
                return true
            case ("integer", .number(let number)):
                if number.isFinite, number.rounded() == number { return true }
            default:
                break
            }
        }
        return false
    }

    private func nonnegativeInteger(_ value: JSONValue?) -> Int? {
        switch value {
        case .integer(let number) where number >= 0 && number <= Int64(Int.max): Int(number)
        case .unsignedInteger(let number) where number <= UInt64(Int.max): Int(number)
        default: nil
        }
    }

    private func numericValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let number): Double(number)
        case .unsignedInteger(let number): Double(number)
        case .number(let number): number
        default: nil
        }
    }

    private func value(at reference: String, in document: JSONValue) -> JSONValue? {
        guard reference.hasPrefix("#/") else { return nil }
        var current = document
        for raw in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw.replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }
}

private struct SchemaInspection {
    enum Context {
        case schema
        case propertyMap
        case definitionMap
        case ordinaryValue
    }

    var nodes: UInt32 = 0
    var references: [String] = []
    var unknownKeywords: Set<String> = []

    private static let supportedKeywords: Set<String> = [
        "$schema", "$id", "$defs", "$ref", "$comment", "type", "title", "description",
        "default", "examples", "enum", "const", "properties", "required", "additionalProperties",
        "items", "prefixItems", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength",
        "minimum", "maximum",
        "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minProperties", "maxProperties",
        "allOf", "anyOf", "oneOf", "not",
    ]

    mutating func walk(
        _ value: JSONValue,
        depth: UInt16,
        context: Context,
        limits: JSONSchemaLimits
    ) throws {
        guard depth <= limits.maximumNestingDepth else {
            throw AgentContractError.invalidJSONSchema("nesting depth exceeds limit")
        }
        nodes += 1
        guard nodes <= limits.maximumResolvedNodes else {
            throw AgentContractError.invalidJSONSchema("node count exceeds limit")
        }
        switch value {
        case .array(let values):
            for child in values { try walk(child, depth: depth + 1, context: context, limits: limits) }
        case .object(let object):
            if context == .schema { try Self.validateSupportedKeywordShapes(object) }
            for (key, child) in object {
                if context == .schema, !Self.supportedKeywords.contains(key) { unknownKeywords.insert(key) }
                if context == .schema, key == "$ref" {
                    guard case .string(let reference) = child,
                          reference.hasPrefix("#/$defs/")
                    else { throw AgentContractError.invalidJSONSchema("remote or malformed reference") }
                    references.append(reference)
                }
                if context == .schema, key == "pattern", case .string(let pattern) = child,
                   pattern.unicodeScalars.count > limits.maximumPatternLength
                {
                    throw AgentContractError.invalidJSONSchema("pattern exceeds preservation limit")
                }
                let childContext: Context
                if context == .schema, key == "properties" {
                    childContext = .propertyMap
                } else if context == .schema, key == "$defs" {
                    childContext = .definitionMap
                } else if context == .propertyMap || context == .definitionMap {
                    childContext = .schema
                } else if context == .schema, Self.schemaValuedKeywords.contains(key) {
                    childContext = .schema
                } else {
                    childContext = .ordinaryValue
                }
                try walk(child, depth: depth + 1, context: childContext, limits: limits)
            }
        default:
            break
        }
    }

    mutating func validateReferences(in root: JSONValue, limits: JSONSchemaLimits) throws {
        var expandedNodes = nodes
        for reference in references {
            var seen: Set<String> = []
            try resolve(
                reference,
                in: root,
                depth: 1,
                seen: &seen,
                expandedNodes: &expandedNodes,
                limits: limits
            )
        }
        nodes = expandedNodes
    }

    private func resolve(
        _ reference: String,
        in root: JSONValue,
        depth: UInt16,
        seen: inout Set<String>,
        expandedNodes: inout UInt32,
        limits: JSONSchemaLimits
    ) throws {
        guard depth <= limits.maximumLocalReferenceDepth else {
            throw AgentContractError.invalidJSONSchema("local reference depth exceeds limit")
        }
        guard seen.insert(reference).inserted else {
            throw AgentContractError.invalidJSONSchema("cyclic local reference")
        }
        guard let target = Self.value(at: reference, in: root) else {
            throw AgentContractError.invalidJSONSchema("unresolved local reference")
        }
        try Self.countExpandedNodes(target, total: &expandedNodes, limit: limits.maximumResolvedNodes)
        for nested in Self.references(in: target) {
            try resolve(
                nested,
                in: root,
                depth: depth + 1,
                seen: &seen,
                expandedNodes: &expandedNodes,
                limits: limits
            )
        }
        seen.remove(reference)
    }

    private static let schemaValuedKeywords: Set<String> = [
        "additionalProperties", "items", "contains", "not", "if", "then", "else",
        "allOf", "anyOf", "oneOf", "prefixItems",
    ]

    private static let validTypes: Set<String> = [
        "null", "boolean", "object", "array", "number", "integer", "string",
    ]

    private static func validateSupportedKeywordShapes(_ object: [String: JSONValue]) throws {
        func fail(_ keyword: String) throws -> Never {
            throw AgentContractError.invalidJSONSchema("malformed supported keyword \(keyword)")
        }
        func isSchema(_ value: JSONValue) -> Bool {
            if case .object = value { return true }
            if case .bool = value { return true }
            return false
        }
        func isNonnegativeInteger(_ value: JSONValue) -> Bool {
            switch value {
            case .unsignedInteger: true
            case .integer(let number): number >= 0
            default: false
            }
        }
        func isNumber(_ value: JSONValue) -> Bool {
            switch value {
            case .integer, .unsignedInteger, .number: true
            default: false
            }
        }

        for (keyword, value) in object where supportedKeywords.contains(keyword) {
            switch keyword {
            case "$schema", "$id", "$comment", "title", "description":
                guard case .string = value else { try fail(keyword) }
            case "$ref":
                guard case .string(let reference) = value, reference.hasPrefix("#/$defs/") else {
                    try fail(keyword)
                }
            case "$defs", "properties":
                guard case .object(let map) = value, map.values.allSatisfy(isSchema) else {
                    try fail(keyword)
                }
            case "type":
                switch value {
                case .string(let type):
                    guard validTypes.contains(type) else { try fail(keyword) }
                case .array(let types):
                    var names: [String] = []
                    for item in types {
                        guard case .string(let name) = item else { try fail(keyword) }
                        names.append(name)
                    }
                    guard !names.isEmpty, names.count == types.count,
                          Set(names).count == names.count
                    else { try fail(keyword) }
                    for name in names where !validTypes.contains(name) { try fail(keyword) }
                default:
                    try fail(keyword)
                }
            case "required":
                guard case .array(let values) = value else { try fail(keyword) }
                let names = values.compactMap { item -> String? in
                    if case .string(let name) = item { return name }
                    return nil
                }
                guard names.count == values.count, Set(names).count == names.count else { try fail(keyword) }
            case "additionalProperties", "items", "not":
                guard isSchema(value) else { try fail(keyword) }
            case "prefixItems", "allOf", "anyOf", "oneOf":
                guard case .array(let schemas) = value,
                      !schemas.isEmpty,
                      schemas.allSatisfy(isSchema)
                else { try fail(keyword) }
            case "examples":
                guard case .array = value else { try fail(keyword) }
            case "enum":
                guard case .array(let values) = value, !values.isEmpty else { try fail(keyword) }
            case "uniqueItems":
                guard case .bool = value else { try fail(keyword) }
            case "minItems", "maxItems", "minLength", "maxLength", "minProperties", "maxProperties":
                guard isNonnegativeInteger(value) else { try fail(keyword) }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                guard isNumber(value) else { try fail(keyword) }
            case "multipleOf":
                let positive: Bool
                switch value {
                case .unsignedInteger(let number):
                    positive = number > 0
                case .integer(let number):
                    positive = number > 0
                case .number(let number):
                    positive = number > 0 && number.isFinite
                default:
                    positive = false
                }
                guard positive else { try fail(keyword) }
            case "default", "const":
                break
            default:
                break
            }
        }
        try validateOrderedBounds(object, lower: "minItems", upper: "maxItems")
        try validateOrderedBounds(object, lower: "minLength", upper: "maxLength")
        try validateOrderedBounds(object, lower: "minProperties", upper: "maxProperties")
    }

    private static func validateOrderedBounds(
        _ object: [String: JSONValue],
        lower: String,
        upper: String
    ) throws {
        func integer(_ value: JSONValue?) -> UInt64? {
            switch value {
            case .unsignedInteger(let number): number
            case .integer(let number) where number >= 0: UInt64(number)
            default: nil
            }
        }
        if let minimum = integer(object[lower]), let maximum = integer(object[upper]), minimum > maximum {
            throw AgentContractError.invalidJSONSchema("\(lower) exceeds \(upper)")
        }
    }

    private static func value(at reference: String, in root: JSONValue) -> JSONValue? {
        guard reference.hasPrefix("#/") else { return nil }
        var current = root
        for raw in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard case .object(let object) = current, let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    private static func references(in value: JSONValue) -> [String] {
        switch value {
        case .array(let values):
            var result: [String] = []
            for child in values { result.append(contentsOf: references(in: child)) }
            return result
        case .object(let object):
            var result: [String] = []
            for (key, child) in object {
                if key == "$ref", case .string(let reference) = child {
                    result.append(reference)
                } else {
                    result.append(contentsOf: references(in: child))
                }
            }
            return result
        default: return []
        }
    }

    private static func countExpandedNodes(
        _ value: JSONValue,
        total: inout UInt32,
        limit: UInt32
    ) throws {
        guard total < limit else {
            throw AgentContractError.invalidJSONSchema("resolved node count exceeds limit")
        }
        total += 1
        switch value {
        case .array(let values):
            for child in values { try countExpandedNodes(child, total: &total, limit: limit) }
        case .object(let object):
            for child in object.values { try countExpandedNodes(child, total: &total, limit: limit) }
        default:
            break
        }
    }
}

/// Stable namespaced identity of a tool independent of compatible descriptor revisions.
public struct AgentToolLogicalID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Stable provider namespace.
    public let providerID: String
    /// Stable tool name within the provider.
    public let name: String

    /// Creates a validated logical tool identity.
    public init(providerID: String, name: String) throws {
        guard AgentWireValidation.isNonblankControlFree(providerID, maximumLength: 256),
              AgentWireValidation.isNonblankControlFree(name, maximumLength: 256)
        else { throw AgentContractError.invalidName("tool logical identity") }
        self.providerID = providerID
        self.name = name
    }

    /// Namespaced display-independent wire identity.
    public var description: String {
        "\(providerID.utf8.count):\(providerID)\(name.utf8.count):\(name)"
    }

    /// Orders logical IDs by provider then name.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.providerID == rhs.providerID ? lhs.name < rhs.name : lhs.providerID < rhs.providerID
    }

    /// Decodes and revalidates a logical tool identity.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                providerID: container.decode(String.self, forKey: .providerID),
                name: container.decode(String.self, forKey: .name)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case providerID, name }
}

/// Immutable identity of one exact tool descriptor and trust assignment.
public struct AgentToolDescriptorID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Compatible logical identity.
    public let logicalID: AgentToolLogicalID
    /// Descriptor semantic version.
    public let version: SemanticVersion
    /// Exact input-schema digest.
    public let schemaDigest: StableDigest
    /// Locally assigned trust revision.
    public let trustRevision: String

    /// Creates an exact descriptor identity.
    public init(
        logicalID: AgentToolLogicalID,
        version: SemanticVersion,
        schemaDigest: StableDigest,
        trustRevision: String
    ) throws {
        guard AgentWireValidation.isNonblankControlFree(trustRevision, maximumLength: 128) else {
            throw AgentContractError.invalidName("tool trust revision")
        }
        self.logicalID = logicalID
        self.version = version
        self.schemaDigest = schemaDigest
        self.trustRevision = trustRevision
    }

    /// Stable exact descriptor identity.
    public var description: String {
        "\(logicalID.description)\(version.description.utf8.count):\(version)"
            + "\(schemaDigest.rawValue.utf8.count):\(schemaDigest.rawValue)"
            + "\(trustRevision.utf8.count):\(trustRevision)"
    }

    /// Orders exact descriptors by stable identity.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.logicalID != rhs.logicalID { return lhs.logicalID < rhs.logicalID }
        if lhs.version != rhs.version { return lhs.version < rhs.version }
        if lhs.schemaDigest != rhs.schemaDigest { return lhs.schemaDigest.rawValue < rhs.schemaDigest.rawValue }
        return lhs.trustRevision < rhs.trustRevision
    }

    /// Decodes and revalidates an exact descriptor identity.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                logicalID: container.decode(AgentToolLogicalID.self, forKey: .logicalID),
                version: container.decode(SemanticVersion.self, forKey: .version),
                schemaDigest: container.decode(StableDigest.self, forKey: .schemaDigest),
                trustRevision: container.decode(String.self, forKey: .trustRevision)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case logicalID, version, schemaDigest, trustRevision }
}

/// Timeout policy advertised by one exact tool descriptor.
public struct ToolTimeoutPolicy: Hashable, Codable, Sendable {
    /// Maximum execution duration in milliseconds.
    public let maximumMilliseconds: UInt64

    /// Creates a positive timeout policy.
    public init(maximumMilliseconds: UInt64) throws {
        guard maximumMilliseconds > 0 else {
            throw AgentContractError.invalidName("tool timeout")
        }
        self.maximumMilliseconds = maximumMilliseconds
    }

    /// Decodes and revalidates a timeout policy.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(maximumMilliseconds: container.decode(UInt64.self)) }
        catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    /// Encodes the maximum milliseconds as one integer.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(maximumMilliseconds)
    }
}

/// Complete provider-neutral descriptor for one exact tool revision.
public struct AgentToolDescriptor: Hashable, Codable, Sendable {
    /// Exact descriptor identity.
    public let id: AgentToolDescriptorID
    /// Localized display title.
    public let title: String
    /// Bounded model-facing summary.
    public let summary: String
    /// Complete input schema.
    public let inputSchema: JSONSchemaDocument
    /// Optional complete structured output schema.
    public let outputSchema: JSONSchemaDocument?
    /// Maximum locally assigned effects.
    public let effects: [AgentEffect]
    /// Minimum authority required by the effects and local policy.
    public let requiredCapabilities: AgentCapabilitySet
    /// Timeout policy.
    public let timeoutPolicy: ToolTimeoutPolicy
    /// Retry policy that remote metadata cannot widen.
    public let retryPolicy: ExternalRetryPolicy
    /// Idempotency semantics that remote metadata cannot upgrade.
    public let idempotency: ExternalIdempotency
    /// Whether progress events may be emitted.
    public let supportsProgress: Bool
    /// Whether cooperative cancellation is implemented.
    public let supportsCancellation: Bool

    /// Creates a complete exact tool descriptor.
    public init(
        id: AgentToolDescriptorID,
        title: String,
        summary: String,
        inputSchema: JSONSchemaDocument,
        outputSchema: JSONSchemaDocument? = nil,
        effects: some Sequence<AgentEffect>,
        requiredCapabilities: AgentCapabilitySet,
        timeoutPolicy: ToolTimeoutPolicy,
        retryPolicy: ExternalRetryPolicy,
        idempotency: ExternalIdempotency,
        supportsProgress: Bool,
        supportsCancellation: Bool
    ) throws {
        let normalizedEffects = Array(Set(effects)).sorted()
        guard AgentWireValidation.isNonblankControlFree(title, maximumLength: 256),
              AgentWireValidation.isNonblankControlFree(summary, maximumLength: 4_096),
              id.schemaDigest == inputSchema.digest,
              !normalizedEffects.isEmpty
        else { throw AgentContractError.invalidName("tool descriptor") }
        try AgentOperationSemantics.validate(
            effects: normalizedEffects,
            capabilities: requiredCapabilities,
            retryPolicy: retryPolicy,
            idempotency: idempotency,
            idempotencyKey: nil,
            requiresBoundIdempotencyKey: false
        )
        let writeEffects: Set<AgentEffect> = [
            .localWrite, .externalWrite, .externalCommunication, .destructive, .financial,
        ]
        if retryPolicy.kind != .never,
           !Set(normalizedEffects).isDisjoint(with: writeEffects),
           idempotency != .idempotencyKeyRequired
        {
            throw AgentContractError.invalidExternalOperationPlan(
                "retryable write tool must require a per-request idempotency key"
            )
        }
        self.id = id
        self.title = title
        self.summary = summary
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.effects = normalizedEffects
        self.requiredCapabilities = requiredCapabilities
        self.timeoutPolicy = timeoutPolicy
        self.retryPolicy = retryPolicy
        self.idempotency = idempotency
        self.supportsProgress = supportsProgress
        self.supportsCancellation = supportsCancellation
    }

    /// Decodes and revalidates schema, effect, retry, and capability invariants.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let effects = try container.decode([AgentEffect].self, forKey: .effects)
        do {
            try self.init(
                id: container.decode(AgentToolDescriptorID.self, forKey: .id),
                title: container.decode(String.self, forKey: .title),
                summary: container.decode(String.self, forKey: .summary),
                inputSchema: container.decode(JSONSchemaDocument.self, forKey: .inputSchema),
                outputSchema: container.decodeIfPresent(JSONSchemaDocument.self, forKey: .outputSchema),
                effects: effects,
                requiredCapabilities: container.decode(
                    AgentCapabilitySet.self,
                    forKey: .requiredCapabilities
                ),
                timeoutPolicy: container.decode(ToolTimeoutPolicy.self, forKey: .timeoutPolicy),
                retryPolicy: container.decode(ExternalRetryPolicy.self, forKey: .retryPolicy),
                idempotency: container.decode(ExternalIdempotency.self, forKey: .idempotency),
                supportsProgress: container.decode(Bool.self, forKey: .supportsProgress),
                supportsCancellation: container.decode(Bool.self, forKey: .supportsCancellation)
            )
            guard self.effects == effects else {
                throw AgentContractError.invalidName("noncanonical tool effects")
            }
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, inputSchema, outputSchema, effects, requiredCapabilities
        case timeoutPolicy, retryPolicy, idempotency, supportsProgress, supportsCancellation
    }
}

/// One model-proposed call after normalization to a stable logical tool identity.
public struct ProposedToolCall: Hashable, Codable, Sendable {
    /// Stable invocation identity assigned before validation.
    public let invocationID: ToolInvocationID
    /// Logical tool requested by the model.
    public let toolID: AgentToolLogicalID
    /// Canonical arguments to validate against the resolved exact descriptor.
    public let arguments: CanonicalJSON

    /// Creates one normalized proposed tool call.
    public init(invocationID: ToolInvocationID, toolID: AgentToolLogicalID, arguments: CanonicalJSON) {
        self.invocationID = invocationID
        self.toolID = toolID
        self.arguments = arguments
    }

    /// Exact duplicate-suppression input before an effect scope is appended.
    public var baseFingerprint: StableDigest {
        StableDigest.fingerprint(
            domain: "proposed-tool-call.v1",
            components: [
                Data(toolID.providerID.utf8),
                Data(toolID.name.utf8),
                Data(arguments.fingerprint.rawValue.utf8),
            ]
        )
    }
}

/// Provider-neutral content emitted by a successful tool invocation.
public enum ToolResultContent: Hashable, Codable, Sendable {
    /// Bounded plain or Markdown text.
    case text(ToolTextResult)
    /// Structured JSON.
    case structured(ToolStructuredResult)
    /// An image stored as a durable artifact.
    case image(ArtifactReference)
    /// A bounded external resource link and optional MIME type.
    case resourceLink(ToolResourceLink)
    /// Any other durable artifact.
    case artifact(ArtifactReference)
}

/// Bounded textual tool result that cannot bypass persisted-output limits by construction.
public struct ToolTextResult: Hashable, Codable, Sendable {
    /// Text or Markdown body.
    public let value: String

    /// Creates a result no larger than the contract-wide per-item ceiling.
    public init(_ value: String) throws {
        guard value.utf8.count <= 2 * 1_024 * 1_024 else {
            throw AgentContractError.invalidName("tool text result too large")
        }
        self.value = value
    }

    /// Decodes and revalidates the UTF-8 byte limit.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode(String.self)) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    /// Encodes the bounded text body as one string.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Bounded canonical structured tool result; larger values must become artifacts.
public struct ToolStructuredResult: Hashable, Codable, Sendable {
    /// Canonical structured value.
    public let value: CanonicalJSON

    /// Creates a structured result no larger than the per-item ceiling.
    public init(_ value: CanonicalJSON) throws {
        guard value.data.count <= 2 * 1_024 * 1_024 else {
            throw AgentContractError.invalidName("structured tool result too large")
        }
        self.value = value
    }

    /// Decodes and revalidates the encoded-byte ceiling.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode(CanonicalJSON.self)) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    /// Encodes one canonical structured result.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Validated bounded external resource link emitted by a tool.
public struct ToolResourceLink: Hashable, Codable, Sendable {
    /// Absolute HTTP(S) resource URL.
    public let url: String
    /// Optional validated MIME type.
    public let mimeType: String?

    /// Creates a bounded network resource link.
    public init(url: String, mimeType: String? = nil) throws {
        guard AgentWireValidation.isNonblankControlFree(url, maximumLength: 2_048),
              let components = URLComponents(string: url),
              components.host.map({ !$0.isEmpty }) == true,
              components.scheme == "https" || components.scheme == "http",
              components.user == nil,
              components.password == nil,
              mimeType.map(AgentWireValidation.isMIMEType) ?? true
        else { throw AgentContractError.invalidName("tool resource link") }
        self.url = url
        self.mimeType = mimeType
    }

    /// Decodes and revalidates URL and MIME constraints.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                url: container.decode(String.self, forKey: .url),
                mimeType: container.decodeIfPresent(String.self, forKey: .mimeType)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case url, mimeType }
}

/// A bounded nonempty terminal tool result; larger inline bodies must become artifacts.
public struct ToolResultCollection: Hashable, Codable, Sendable, RandomAccessCollection {
    /// Maximum number of content items in one terminal result.
    public static let maximumItemCount = 64
    /// Maximum aggregate inline body bytes in one terminal result.
    public static let maximumInlineBytes = 2 * 1_024 * 1_024

    /// Canonically retained result items.
    public let values: [ToolResultContent]

    /// Creates a bounded result collection.
    public init(_ values: some Sequence<ToolResultContent>) throws {
        let values = Array(values)
        var inlineBytes = 0
        for value in values {
            if case .image(let artifact) = value, !artifact.mimeType.hasPrefix("image/") {
                throw AgentContractError.invalidArtifactReference(
                    "image tool result must reference an image MIME type"
                )
            }
            let addition: Int = switch value {
            case .text(let text): text.value.utf8.count
            case .structured(let structured): structured.value.data.count
            case .resourceLink(let link):
                link.url.utf8.count + (link.mimeType == nil ? 0 : link.mimeType!.utf8.count)
            case .image, .artifact: 0
            }
            guard addition <= Self.maximumInlineBytes - inlineBytes else {
                throw AgentContractError.invalidName("tool result inline content too large")
            }
            inlineBytes += addition
        }
        guard !values.isEmpty, values.count <= Self.maximumItemCount else {
            throw AgentContractError.invalidName("tool result item count")
        }
        self.values = values
    }

    /// Decodes and reapplies aggregate bounds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do { try self.init(container.decode([ToolResultContent].self)) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: String(describing: error))
        }
    }

    /// Encodes the bounded values as an array.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// Collection start index.
    public var startIndex: Int { values.startIndex }
    /// Collection end index.
    public var endIndex: Int { values.endIndex }
    /// Accesses one content item.
    public subscript(position: Int) -> ToolResultContent { values[position] }
}

/// Structured progress from an executing tool.
public struct ToolExecutionProgress: Hashable, Codable, Sendable {
    /// Completed work units.
    public let completedUnits: UInt64
    /// Optional total units, which must not be lower than completed units.
    public let totalUnits: UInt64?
    /// Safe progress message.
    public let message: String?

    /// Creates validated progress.
    public init(completedUnits: UInt64, totalUnits: UInt64? = nil, message: String? = nil) throws {
        if let totalUnits, completedUnits > totalUnits {
            throw AgentContractError.invalidName("tool progress total")
        }
        if let message, !AgentWireValidation.isNonblankControlFree(message, maximumLength: 512) {
            throw AgentContractError.invalidName("tool progress message")
        }
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.message = message
    }

    /// Decodes and revalidates progress bounds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                completedUnits: container.decode(UInt64.self, forKey: .completedUnits),
                totalUnits: container.decodeIfPresent(UInt64.self, forKey: .totalUnits),
                message: container.decodeIfPresent(String.self, forKey: .message)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    private enum CodingKeys: String, CodingKey { case completedUnits, totalUnits, message }
}

/// Normalized event emitted by a provider-neutral tool adapter.
public enum ToolExecutionEvent: Hashable, Codable, Sendable {
    /// Nonterminal progress.
    case progress(ToolExecutionProgress)
    /// The single successful terminal result.
    case completed(ToolResultCollection)
    /// The single typed terminal failure.
    case failed(AgentFailure)

    /// Whether this event terminates the tool invocation stream.
    public var isTerminal: Bool {
        switch self {
        case .progress: false
        case .completed, .failed: true
        }
    }
}

/// Stable terminal tool outcome suitable for a durable journal event.
public enum AgentToolInvocationOutcome: Hashable, Codable, Sendable {
    /// Confirmed successful result content.
    case completed(ToolResultCollection)
    /// Confirmed typed failure with no unresolved external outcome.
    case failed(AgentFailure)
    /// Potentially side-effecting result that requires reconciliation.
    case uncertain(AgentFailure)

    /// Rejects durable outcomes whose case disagrees with typed uncertainty semantics.
    public func validate() throws {
        switch self {
        case .completed:
            break
        case .failed(let failure):
            guard failure.externalEffect != .uncertain,
                  failure.classification != .potentiallySideEffecting
            else { throw AgentContractError.invalidEventSequence("uncertain tool result marked failed") }
        case .uncertain(let failure):
            guard failure.externalEffect == .uncertain,
                  failure.classification == .potentiallySideEffecting
            else { throw AgentContractError.invalidEventSequence("confirmed tool result marked uncertain") }
        }
    }
}

/// Pure validator for exactly-one-terminal tool execution streams.
public enum ToolExecutionStreamValidator {
    /// Rejects empty terminal results, duplicate terminals, and events after a terminal.
    public static func validate(_ events: [ToolExecutionEvent], requireTerminal: Bool = true) throws {
        var terminalSeen = false
        for event in events {
            if terminalSeen {
                throw AgentContractError.invalidEventSequence("tool event follows terminal outcome")
            }
            switch event {
            case .completed:
                terminalSeen = true
            case .failed:
                terminalSeen = true
            case .progress:
                break
            }
        }
        if requireTerminal, !terminalSeen {
            throw AgentContractError.invalidEventSequence("tool stream lacks terminal outcome")
        }
    }
}
