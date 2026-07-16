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

/// Evaluate an arithmetic expression on-device (+, −, ×, ÷, %, parentheses, powers).
///
/// The evaluation is a pure-Swift recursive-descent parser (`ExpressionEvaluator`), NOT
/// `NSExpression(format:)`: `NSExpression` raises an ObjC `NSException` on malformed input — a bare `%`,
/// unbalanced parens, an operator run — and an ObjC exception is UNCATCHABLE from Swift, so one bad
/// model-generated expression crashed the whole app. The evaluator instead throws a Swift error we turn
/// into a result STRING the model can read and recover from.
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
        // Normalize common unicode operators the model might emit (`^` → `**` power).
        let expr = raw.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                      .replacingOccurrences(of: "^", with: "**").replacingOccurrences(of: " ", with: "")
        guard Self.isSafe(expr) else { return "Error: unsupported characters in expression." }
        do {
            let value = try ExpressionEvaluator.evaluate(expr)
            // Overflow / divide-by-zero produce ±inf or NaN — report rather than print "inf".
            guard value.isFinite else { return "Error: couldn’t evaluate “\(raw)”." }
            return numberString(value)
        } catch {
            return "Error: couldn’t evaluate “\(raw)”."
        }
    }
    /// A cheap first-line filter: digits, operators, dots and parentheses only, so obvious junk (letters,
    /// unicode digits, `@`) is rejected before parsing. Structural cases it lets through — a bare `%`,
    /// unbalanced parens — are caught safely by `ExpressionEvaluator`, which never traps.
    static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { "0123456789.+-*/()% ".contains($0) }
    }
    private func numberString(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
}

/// A tiny pure-Swift arithmetic evaluator (tokenizer + recursive-descent parser). Float semantics
/// throughout (`10/4 == 2.5`); `%` is `truncatingRemainder`; `**` is right-associative power that binds
/// tighter than unary `-` on the left (`-2**2 == -4`, Python-style). Every malformed input throws
/// `EvalError` — it never calls `fatalError`/traps — so the calculator can turn it into a result string.
enum ExpressionEvaluator {
    enum EvalError: Error { case malformed }

    static func evaluate(_ s: String) throws -> Double {
        var parser = Parser(tokens: try tokenize(s))
        let value = try parser.parseExpression()
        guard parser.isAtEnd else { throw EvalError.malformed }   // trailing junk, e.g. "2)" or "2 3"
        return value
    }

    // MARK: Tokens

    enum Token: Equatable { case number(Double), plus, minus, star, slash, percent, power, lparen, rparen }

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "0"..."9", ".":
                var lit = ""
                while i < chars.count, ("0"..."9").contains(chars[i]) || chars[i] == "." { lit.append(chars[i]); i += 1 }
                guard let d = Double(lit) else { throw EvalError.malformed }   // e.g. ".", "1.2.3"
                tokens.append(.number(d))
                continue
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" { tokens.append(.power); i += 2; continue }
                tokens.append(.star)
            case "/": tokens.append(.slash)
            case "%": tokens.append(.percent)
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: throw EvalError.malformed
            }
            i += 1
        }
        return tokens
    }

    // MARK: Parser — precedence: (+ −) < (* / %) < unary < (**)

    struct Parser {
        let tokens: [Token]
        var pos = 0
        var isAtEnd: Bool { pos >= tokens.count }
        private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while let t = peek(), t == .plus || t == .minus {
                pos += 1
                let rhs = try parseTerm()
                value = (t == .plus) ? value + rhs : value - rhs
            }
            return value
        }
        // term := unary (('*' | '/' | '%') unary)*
        mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while let t = peek(), t == .star || t == .slash || t == .percent {
                pos += 1
                let rhs = try parseUnary()
                switch t {
                case .star:    value *= rhs
                case .slash:   value /= rhs
                case .percent: value = value.truncatingRemainder(dividingBy: rhs)
                default:       break
                }
            }
            return value
        }
        // unary := ('+' | '-') unary | power   — power binds tighter, so "-2**2" is -(2**2).
        mutating func parseUnary() throws -> Double {
            if let t = peek(), t == .plus || t == .minus {
                pos += 1
                let v = try parseUnary()
                return t == .minus ? -v : v
            }
            return try parsePower()
        }
        // power := primary ('**' unary)?   — right-associative (the exponent recurses through unary).
        mutating func parsePower() throws -> Double {
            let base = try parsePrimary()
            if peek() == .power {
                pos += 1
                let exp = try parseUnary()
                return pow(base, exp)
            }
            return base
        }
        // primary := number | '(' expression ')'
        mutating func parsePrimary() throws -> Double {
            guard let t = peek() else { throw EvalError.malformed }
            switch t {
            case .number(let d): pos += 1; return d
            case .lparen:
                pos += 1
                let v = try parseExpression()
                guard peek() == .rparen else { throw EvalError.malformed }   // unbalanced "(2+3"
                pos += 1
                return v
            default: throw EvalError.malformed   // bare operator, e.g. "%" or "*3"
            }
        }
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
