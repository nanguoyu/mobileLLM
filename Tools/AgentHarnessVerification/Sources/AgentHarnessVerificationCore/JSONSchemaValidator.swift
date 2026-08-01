// SPDX-License-Identifier: MIT

import CoreFoundation
import Foundation

/// A deliberately small, offline JSON Schema Draft 2020-12 validator for the repository-owned
/// verification documents. It implements every assertion keyword used by the checked-in schemas and
/// rejects unknown validation keywords so a schema change cannot silently weaken the gate.
enum RepositoryJSONSchemaValidator {
    struct Issue: Equatable, Comparable {
        let location: String
        let message: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.location, lhs.message) < (rhs.location, rhs.message)
        }
    }

    private static let annotationKeywords: Set<String> = [
        "$schema", "$id", "title", "description", "default", "examples", "deprecated",
        "readOnly", "writeOnly", "$comment",
    ]
    private static let assertionKeywords: Set<String> = [
        "$ref", "$defs", "type", "enum", "const", "properties", "required",
        "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "contains",
        "minProperties", "minLength", "maxLength", "pattern", "minimum", "maximum",
        "oneOf", "allOf", "if", "then", "format",
    ]

    static func validateSchema(_ schema: Any, label: String) -> [Issue] {
        var issues: [Issue] = []
        validateSchemaNode(schema, at: label, issues: &issues)
        return issues.sorted()
    }

    static func validate(instance: Any, against schema: Any, label: String) -> [Issue] {
        var issues: [Issue] = []
        validate(instance, schema: schema, rootSchema: schema, at: label,
                 referenceStack: [], issues: &issues)
        return issues.sorted()
    }

    private static func validateSchemaNode(_ value: Any, at location: String,
                                           issues: inout [Issue]) {
        if value is Bool { return }
        guard let schema = value as? [String: Any] else {
            issues.append(.init(location: location, message: "schema must be an object or boolean"))
            return
        }
        let known = annotationKeywords.union(assertionKeywords)
        for keyword in schema.keys.sorted() where !known.contains(keyword) {
            issues.append(.init(location: location,
                                message: "unsupported schema keyword '\(keyword)'"))
        }

        if let definitions = schema["$defs"] as? [String: Any] {
            for key in definitions.keys.sorted() {
                validateSchemaNode(definitions[key] as Any,
                                   at: "\(location).$defs.\(key)", issues: &issues)
            }
        } else if schema["$defs"] != nil {
            issues.append(.init(location: "\(location).$defs", message: "must be an object"))
        }
        if let properties = schema["properties"] as? [String: Any] {
            for key in properties.keys.sorted() {
                validateSchemaNode(properties[key] as Any,
                                   at: "\(location).properties.\(key)", issues: &issues)
            }
        } else if schema["properties"] != nil {
            issues.append(.init(location: "\(location).properties", message: "must be an object"))
        }
        if let additional = schema["additionalProperties"], !(additional is Bool) {
            validateSchemaNode(additional, at: "\(location).additionalProperties", issues: &issues)
        }
        for keyword in ["items", "contains", "if", "then"] {
            if let child = schema[keyword] {
                validateSchemaNode(child, at: "\(location).\(keyword)", issues: &issues)
            }
        }
        for keyword in ["oneOf", "allOf"] {
            guard let value = schema[keyword] else { continue }
            guard let children = value as? [Any], !children.isEmpty else {
                issues.append(.init(location: "\(location).\(keyword)",
                                    message: "must be a non-empty array of schemas"))
                continue
            }
            for (index, child) in children.enumerated() {
                validateSchemaNode(child, at: "\(location).\(keyword)[\(index)]", issues: &issues)
            }
        }
        if let reference = schema["$ref"] as? String,
           !reference.hasPrefix("#/") {
            issues.append(.init(location: "\(location).$ref",
                                message: "only local JSON Pointer references are supported"))
        } else if schema["$ref"] != nil, !(schema["$ref"] is String) {
            issues.append(.init(location: "\(location).$ref", message: "must be a string"))
        }
    }

    private static func validate(
        _ instance: Any,
        schema: Any,
        rootSchema: Any,
        at location: String,
        referenceStack: [String],
        issues: inout [Issue]
    ) {
        if let allowed = schema as? Bool {
            if !allowed { issues.append(.init(location: location, message: "value is forbidden")) }
            return
        }
        guard let schema = schema as? [String: Any] else {
            issues.append(.init(location: location, message: "invalid schema node"))
            return
        }

        if let reference = schema["$ref"] as? String {
            guard !referenceStack.contains(reference) else {
                issues.append(.init(location: location, message: "cyclic schema reference \(reference)"))
                return
            }
            guard let resolved = resolve(reference, in: rootSchema) else {
                issues.append(.init(location: location, message: "unresolved schema reference \(reference)"))
                return
            }
            validate(instance, schema: resolved, rootSchema: rootSchema, at: location,
                     referenceStack: referenceStack + [reference], issues: &issues)
        }

        if let type = schema["type"], !matchesType(instance, declaration: type) {
            issues.append(.init(location: location,
                                message: "value does not match declared type \(display(type))"))
            return
        }
        if let constant = schema["const"], !jsonEqual(instance, constant) {
            issues.append(.init(location: location, message: "value does not match const"))
        }
        if let values = schema["enum"] as? [Any], !values.contains(where: { jsonEqual(instance, $0) }) {
            issues.append(.init(location: location, message: "value is not in enum"))
        }

        if let alternatives = schema["oneOf"] as? [Any] {
            let matches = alternatives.filter {
                var candidate: [Issue] = []
                validate(instance, schema: $0, rootSchema: rootSchema, at: location,
                         referenceStack: referenceStack, issues: &candidate)
                return candidate.isEmpty
            }.count
            if matches != 1 {
                issues.append(.init(location: location,
                                    message: "oneOf matched \(matches) schemas; expected exactly one"))
            }
        }
        if let conjunctions = schema["allOf"] as? [Any] {
            for child in conjunctions {
                validate(instance, schema: child, rootSchema: rootSchema, at: location,
                         referenceStack: referenceStack, issues: &issues)
            }
        }
        if let condition = schema["if"] {
            var conditionIssues: [Issue] = []
            validate(instance, schema: condition, rootSchema: rootSchema, at: location,
                     referenceStack: referenceStack, issues: &conditionIssues)
            if conditionIssues.isEmpty, let consequence = schema["then"] {
                validate(instance, schema: consequence, rootSchema: rootSchema, at: location,
                         referenceStack: referenceStack, issues: &issues)
            }
        }

        if let object = instance as? [String: Any] {
            validateObject(object, schema: schema, rootSchema: rootSchema, at: location,
                           referenceStack: referenceStack, issues: &issues)
        }
        if let array = instance as? [Any] {
            validateArray(array, schema: schema, rootSchema: rootSchema, at: location,
                          referenceStack: referenceStack, issues: &issues)
        }
        if let string = instance as? String {
            validateString(string, schema: schema, at: location, issues: &issues)
        }
        if isNumber(instance), let number = numericValue(instance) {
            if let minimum = numericValue(schema["minimum"]), number < minimum {
                issues.append(.init(location: location, message: "number is below minimum \(minimum)"))
            }
            if let maximum = numericValue(schema["maximum"]), number > maximum {
                issues.append(.init(location: location, message: "number exceeds maximum \(maximum)"))
            }
        }
    }

    private static func validateObject(
        _ object: [String: Any], schema: [String: Any], rootSchema: Any, at location: String,
        referenceStack: [String], issues: inout [Issue]
    ) {
        if let minimum = integerValue(schema["minProperties"]), object.count < minimum {
            issues.append(.init(location: location, message: "object has fewer than \(minimum) properties"))
        }
        if let required = schema["required"] as? [String] {
            for key in required.sorted() where object[key] == nil {
                issues.append(.init(location: "\(location).\(key)", message: "required property is missing"))
            }
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for key in properties.keys.sorted() {
            guard let value = object[key], let child = properties[key] else { continue }
            validate(value, schema: child, rootSchema: rootSchema,
                     at: "\(location).\(key)", referenceStack: referenceStack, issues: &issues)
        }
        let extras = Set(object.keys).subtracting(properties.keys).sorted()
        if let additional = schema["additionalProperties"] as? Bool, !additional {
            for key in extras {
                issues.append(.init(location: "\(location).\(key)",
                                    message: "additional property is not allowed"))
            }
        } else if let additional = schema["additionalProperties"], !(additional is Bool) {
            for key in extras {
                validate(object[key] as Any, schema: additional, rootSchema: rootSchema,
                         at: "\(location).\(key)", referenceStack: referenceStack, issues: &issues)
            }
        }
    }

    private static func validateArray(
        _ array: [Any], schema: [String: Any], rootSchema: Any, at location: String,
        referenceStack: [String], issues: inout [Issue]
    ) {
        if let minimum = integerValue(schema["minItems"]), array.count < minimum {
            issues.append(.init(location: location, message: "array has fewer than \(minimum) items"))
        }
        if let maximum = integerValue(schema["maxItems"]), array.count > maximum {
            issues.append(.init(location: location, message: "array has more than \(maximum) items"))
        }
        if schema["uniqueItems"] as? Bool == true {
            var seen: Set<Data> = []
            for (index, value) in array.enumerated() {
                guard let encoded = try? JSONSerialization.data(withJSONObject: value,
                                                                options: [.sortedKeys, .fragmentsAllowed]) else {
                    issues.append(.init(location: "\(location)[\(index)]",
                                        message: "value cannot be canonicalized"))
                    continue
                }
                if !seen.insert(encoded).inserted {
                    issues.append(.init(location: "\(location)[\(index)]", message: "item is duplicated"))
                }
            }
        }
        if let itemSchema = schema["items"] {
            for (index, value) in array.enumerated() {
                validate(value, schema: itemSchema, rootSchema: rootSchema,
                         at: "\(location)[\(index)]", referenceStack: referenceStack, issues: &issues)
            }
        }
        if let contains = schema["contains"] {
            let matched = array.contains { value in
                var candidate: [Issue] = []
                validate(value, schema: contains, rootSchema: rootSchema, at: location,
                         referenceStack: referenceStack, issues: &candidate)
                return candidate.isEmpty
            }
            if !matched { issues.append(.init(location: location, message: "contains matched no item")) }
        }
    }

    private static func validateString(_ string: String, schema: [String: Any], at location: String,
                                       issues: inout [Issue]) {
        if let minimum = integerValue(schema["minLength"]), string.count < minimum {
            issues.append(.init(location: location, message: "string is shorter than \(minimum) characters"))
        }
        if let maximum = integerValue(schema["maxLength"]), string.count > maximum {
            issues.append(.init(location: location, message: "string is longer than \(maximum) characters"))
        }
        if let pattern = schema["pattern"] as? String {
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            if (try? NSRegularExpression(pattern: pattern).firstMatch(in: string, range: range)) == nil {
                issues.append(.init(location: location, message: "string does not match pattern \(pattern)"))
            }
        }
        if let format = schema["format"] as? String {
            let valid: Bool
            switch format {
            case "date-time": valid = ISO8601DateFormatter().date(from: string) != nil
            case "uuid": valid = UUID(uuidString: string) != nil
            default: valid = false
            }
            if !valid { issues.append(.init(location: location, message: "invalid \(format) format")) }
        }
    }

    private static func resolve(_ reference: String, in root: Any) -> Any? {
        guard reference.hasPrefix("#/") else { return nil }
        var current: Any = root
        for raw in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = raw.replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let object = current as? [String: Any], let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    private static func matchesType(_ value: Any, declaration: Any) -> Bool {
        let names: [String]
        if let single = declaration as? String { names = [single] }
        else if let several = declaration as? [String] { names = several }
        else { return false }
        return names.contains { name in
            switch name {
            case "object": return value is [String: Any]
            case "array": return value is [Any]
            case "string": return value is String
            case "boolean": return isBoolean(value)
            case "integer": return isInteger(value)
            case "number": return isNumber(value)
            case "null": return value is NSNull
            default: return false
            }
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isNumber(_ value: Any) -> Bool {
        value is NSNumber && !isBoolean(value)
    }

    private static func isInteger(_ value: Any) -> Bool {
        guard isNumber(value), let number = numericValue(value), number.isFinite else { return false }
        return number.rounded(.towardZero) == number
    }

    private static func numericValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func integerValue(_ value: Any?) -> Int? {
        guard let number = numericValue(value), number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull, rhs is NSNull { return true }
        if isBoolean(lhs) || isBoolean(rhs) {
            return isBoolean(lhs) && isBoolean(rhs)
                && (lhs as? NSNumber)?.boolValue == (rhs as? NSNumber)?.boolValue
        }
        if isNumber(lhs), isNumber(rhs) { return numericValue(lhs) == numericValue(rhs) }
        return (lhs as AnyObject).isEqual(rhs)
    }

    private static func display(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let strings = value as? [String] { return strings.joined(separator: "|") }
        return String(describing: value)
    }
}
