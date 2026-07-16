// SPDX-License-Identifier: MIT

import Foundation

/// A function the model can call (DESIGN §7 — tool calling). Kept minimal: a JSON-schema-ish declaration
/// the prompt advertises, plus a local `execute`. Built-in tools run entirely on-device (no server); an
/// MCP-backed or web tool conforms to the same protocol later.
public protocol Tool: Sendable {
    var schema: ToolSchema { get }
    /// Run the call. `argumentsJSON` is the raw JSON object the model emitted; return a short text result
    /// (or an error message — the model reads it and recovers).
    func execute(argumentsJSON: String) async -> String
}

/// A tool's advertised signature — name, one-line purpose, and typed parameters.
public struct ToolSchema: Sendable, Hashable, Codable {
    public let name: String
    public let description: String
    public let parameters: [ToolParam]
    public init(name: String, description: String, parameters: [ToolParam]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct ToolParam: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case string, number, boolean }
    public let name: String
    public let kind: Kind
    public let description: String
    public let required: Bool
    public init(name: String, kind: Kind, description: String, required: Bool = true) {
        self.name = name; self.kind = kind; self.description = description; self.required = required
    }
}

/// A parsed request from the model to invoke a tool.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let argumentsJSON: String        // raw JSON object, e.g. `{"expression":"17+25"}`
    public var id: String { "\(name)(\(argumentsJSON))" }
    public init(name: String, argumentsJSON: String) { self.name = name; self.argumentsJSON = argumentsJSON }

    /// Decode a named string/number argument (numbers are stringified) — a lenient helper for tools.
    public func arg(_ key: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // A JSON boolean bridges to NSNumber too — distinguish it so `true` isn't stringified as "1".
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return nil
    }
}

/// The tools available to a turn. Registration order = advertise order.
public struct ToolRegistry: Sendable {
    public private(set) var tools: [Tool]
    public init(_ tools: [Tool] = []) { self.tools = tools }
    public func tool(named name: String) -> Tool? { tools.first { $0.schema.name == name } }
    public var schemas: [ToolSchema] { tools.map(\.schema) }
    public var isEmpty: Bool { tools.isEmpty }

    /// The built-in, on-device tools (no network / no server) — enough to exercise the whole agent loop.
    public static let builtIn = ToolRegistry([CalculatorTool(), DateTimeTool()])

    /// The on-device tools plus the network-backed Wikipedia lookup — the default set when tools are on.
    public static let standard = ToolRegistry([CalculatorTool(), DateTimeTool(), WebSearchTool()])
}

// MARK: - Built-in local tools

/// Evaluate an arithmetic expression on-device via `NSExpression` (+, −, ×, ÷, %, parentheses, powers).
public struct CalculatorTool: Tool {
    public init() {}
    public var schema: ToolSchema {
        ToolSchema(name: "calculator",
                   description: "Evaluate an arithmetic expression and return the numeric result.",
                   parameters: [ToolParam(name: "expression", kind: .string,
                                          description: "The expression, e.g. \"17 + 25 * 2\"")])
    }
    public func execute(argumentsJSON: String) async -> String {
        guard let raw = ToolCall(name: "calculator", argumentsJSON: argumentsJSON).arg("expression") else {
            return "Error: missing 'expression'."
        }
        // Normalize common unicode operators the model might emit.
        let expr = raw.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                      .replacingOccurrences(of: "^", with: "**").replacingOccurrences(of: " ", with: "")
        guard Self.isSafe(expr) else { return "Error: unsupported characters in expression." }
        // NSExpression does INTEGER division on integer literals ("10/4" → 2), so promote every integer
        // to a double first — otherwise the model gets a silently wrong answer.
        let ns = NSExpression(format: Self.floatify(expr))
        guard let value = ns.expressionValue(with: nil, context: nil) as? NSNumber else {
            return "Error: couldn't evaluate \"\(raw)\"."
        }
        return numberString(value)
    }
    /// Only digits, operators, dots and parentheses — never let `NSExpression` reach a function/keypath.
    static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { "0123456789.+-*/()% ".contains($0) }
    }
    /// "10/4" → "10.0/4.0" so the arithmetic is floating-point.
    static func floatify(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\d.])(\d+)(?![\d.])"#) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1.0")
    }
    private func numberString(_ n: NSNumber) -> String {
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
}

/// The current date and time (on-device clock). No arguments.
public struct DateTimeTool: Tool {
    public init() {}
    public var schema: ToolSchema {
        ToolSchema(name: "current_datetime",
                   description: "Get the current local date and time. Use when the user asks what time or day it is.",
                   parameters: [])
    }
    public func execute(argumentsJSON: String) async -> String {
        let f = DateFormatter()
        f.dateStyle = .full; f.timeStyle = .short
        return f.string(from: Date())
    }
}
