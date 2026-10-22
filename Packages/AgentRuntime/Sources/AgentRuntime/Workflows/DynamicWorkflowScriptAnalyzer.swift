// SPDX-License-Identifier: MIT

import AgentContracts
import Foundation

public enum WorkflowScriptAnalysisError: Error, Hashable, Sendable, CustomStringConvertible,
    LocalizedError
{
    case missingMetadata
    case malformedMetadata(String)
    case invalidSyntax(String)
    case forbiddenCapability(String)
    case unsupportedConstruct(String)
    case unsafeLoop(String)
    case sourceLimitExceeded

    public var description: String {
        switch self {
        case .missingMetadata: "The workflow must start with a pure-literal export const meta declaration."
        case .malformedMetadata(let detail): "Invalid workflow metadata: \(detail)"
        case .invalidSyntax(let detail): "Invalid workflow JavaScript: \(detail)"
        case .forbiddenCapability(let name): "Workflow scripts cannot access \(name)."
        case .unsupportedConstruct(let name): "Workflow construct is not supported safely: \(name)."
        case .unsafeLoop(let detail): "Workflow loop cannot be checkpointed safely: \(detail)"
        case .sourceLimitExceeded: "Workflow source exceeds its hard limit."
        }
    }

    public var errorDescription: String? { description }
}

/// Trusted analysis result. Only this value may enter a script runtime provider.
public struct AnalyzedWorkflowScriptV1: Hashable, Sendable {
    public let script: WorkflowScriptV1
    public let metadata: WorkflowScriptMetadataV1
    public let executableSource: String
    public let instrumentedSource: String
    public let analysisDigest: StableDigest
    public let staticAgentCallSites: UInt32
    public let staticPhaseCallSites: UInt32
    public let staticParallelCallSites: UInt32
    public let checkpointSites: UInt32
    public let savedWorkflowNames: [String]

    fileprivate init(
        script: WorkflowScriptV1,
        metadata: WorkflowScriptMetadataV1,
        executableSource: String,
        instrumentedSource: String,
        staticAgentCallSites: UInt32,
        staticPhaseCallSites: UInt32,
        staticParallelCallSites: UInt32,
        checkpointSites: UInt32,
        savedWorkflowNames: [String]
    ) {
        self.script = script
        self.metadata = metadata
        self.executableSource = executableSource
        self.instrumentedSource = instrumentedSource
        self.staticAgentCallSites = staticAgentCallSites
        self.staticPhaseCallSites = staticPhaseCallSites
        self.staticParallelCallSites = staticParallelCallSites
        self.checkpointSites = checkpointSites
        self.savedWorkflowNames = savedWorkflowNames
        analysisDigest = StableDigest.fingerprint(
            domain: "dynamic-workflow-analysis.v1",
            components: [
                Data(script.sourceDigest.rawValue.utf8),
                Data(instrumentedSource.utf8),
                Data(String(staticAgentCallSites).utf8),
                Data(String(checkpointSites).utf8),
                Data(savedWorkflowNames.joined(separator: "\u{1f}").utf8),
            ]
        )
    }
}

/// Conservative source analyzer for the orchestration-only JavaScript subset.
public struct DynamicWorkflowScriptAnalyzer: Sendable {
    public init() {}

    public func analyze(_ script: WorkflowScriptV1) throws -> AnalyzedWorkflowScriptV1 {
        guard script.source.lengthOfBytes(using: .utf8) <= WorkflowScriptV1.maximumSourceBytes else {
            throw WorkflowScriptAnalysisError.sourceLimitExceeded
        }
        let extraction = try MetadataExtractor(source: script.source).extract()
        let body = extraction.body
        var lexer = JavaScriptLexer(source: body)
        let tokens = try lexer.tokens()
        try Self.rejectForbiddenCapabilities(tokens)
        try Self.validateAgentOptions(tokens)
        let savedWorkflowNames = try Self.savedWorkflowNames(in: tokens)
        let instrumentation = try Self.instrument(source: body, tokens: tokens)
        let callSites = tokens.reduce(into: UInt32(0)) { count, token in
            if token.identifier == "agent" { count &+= UInt32(1) }
        }
        func calls(_ name: String) -> UInt32 {
            UInt32(tokens.indices.filter {
                tokens[$0].identifier == name && $0 + 1 < tokens.count && tokens[$0 + 1].symbol == "("
            }.count)
        }
        return AnalyzedWorkflowScriptV1(
            script: script,
            metadata: extraction.metadata,
            executableSource: body,
            instrumentedSource: instrumentation.source,
            staticAgentCallSites: callSites,
            staticPhaseCallSites: calls("phase"),
            staticParallelCallSites: calls("parallel"),
            checkpointSites: UInt32(instrumentation.insertions.count),
            savedWorkflowNames: savedWorkflowNames
        )
    }

    private static func savedWorkflowNames(in tokens: [JSToken]) throws -> [String] {
        var names: [String] = []
        for index in tokens.indices where tokens[index].identifier == "workflow" {
            guard index + 2 < tokens.count,
                  tokens[index + 1].symbol == "(",
                  let name = tokens[index + 2].stringValue,
                  !name.isEmpty
            else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "saved workflow names must be direct string literals"
                )
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted()
    }

    /// `agent` options affect replay identity and host policy, so generated candidates must expose
    /// their complete top-level shape to analysis. Values may still be ordinary bounded
    /// expressions, but the options container and every key must be literal. This catches model-
    /// invented fields before the candidate is saved and lets the app's single repair pass correct
    /// them without ever dispatching a child.
    private static func validateAgentOptions(_ tokens: [JSToken]) throws {
        for callIndex in tokens.indices where tokens[callIndex].identifier == "agent" {
            guard callIndex + 1 < tokens.count, tokens[callIndex + 1].symbol == "(" else {
                continue
            }
            guard let close = matchingClose(
                in: tokens,
                openingAt: callIndex + 1,
                open: "(",
                close: ")"
            ) else {
                throw WorkflowScriptAnalysisError.invalidSyntax("unbalanced agent call")
            }
            guard let separator = topLevelArgumentSeparator(
                in: tokens,
                after: callIndex + 1,
                before: close
            ) else { continue }
            let optionStart = separator + 1
            guard optionStart < close, tokens[optionStart].symbol == "{" else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "agent options must be a direct object literal"
                )
            }
            guard let optionEnd = matchingClose(
                in: tokens,
                openingAt: optionStart,
                open: "{",
                close: "}"
            ), optionEnd < close else {
                throw WorkflowScriptAnalysisError.invalidSyntax("unbalanced agent options")
            }
            let tail = tokens[(optionEnd + 1) ..< close]
            guard tail.isEmpty || (tail.count == 1 && tail.first?.symbol == ",") else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "agent accepts only prompt and options"
                )
            }
            try validateAgentOptionObject(tokens, openingAt: optionStart, closingAt: optionEnd)
        }
    }

    private static func topLevelArgumentSeparator(
        in tokens: [JSToken],
        after opening: Int,
        before closing: Int
    ) -> Int? {
        var parentheses = 0
        var brackets = 0
        var braces = 0
        for index in (opening + 1) ..< closing {
            switch tokens[index].symbol {
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            case "{": braces += 1
            case "}": braces -= 1
            case "," where parentheses == 0 && brackets == 0 && braces == 0: return index
            default: break
            }
        }
        return nil
    }

    private static func validateAgentOptionObject(
        _ tokens: [JSToken],
        openingAt opening: Int,
        closingAt closing: Int
    ) throws {
        var index = opening + 1
        var seen: Set<String> = []
        while index < closing {
            if tokens[index].symbol == "," { // A trailing comma is valid.
                index += 1
                continue
            }
            guard let key = tokens[index].identifier ?? tokens[index].stringValue else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "agent option keys must be direct literals"
                )
            }
            guard WorkflowAgentOptionContract.allowedKeys.contains(key) else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "unknown agent option '\(key)'"
                )
            }
            guard seen.insert(key).inserted else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "duplicate agent option '\(key)'"
                )
            }
            index += 1
            guard index < closing, tokens[index].symbol == ":" else {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "agent options cannot use shorthand or computed properties"
                )
            }
            index += 1
            let valueStart = index
            var parentheses = 0
            var brackets = 0
            var braces = 0
            while index < closing {
                let symbol = tokens[index].symbol
                if symbol == ",", parentheses == 0, brackets == 0, braces == 0 { break }
                switch symbol {
                case "(": parentheses += 1
                case ")": parentheses -= 1
                case "[": brackets += 1
                case "]": brackets -= 1
                case "{": braces += 1
                case "}": braces -= 1
                default: break
                }
                guard parentheses >= 0, brackets >= 0, braces >= 0 else {
                    throw WorkflowScriptAnalysisError.invalidSyntax("unbalanced agent option value")
                }
                index += 1
            }
            guard index > valueStart, parentheses == 0, brackets == 0, braces == 0 else {
                throw WorkflowScriptAnalysisError.invalidSyntax("invalid agent option value")
            }
            if key == "isolation", index == valueStart + 1,
               let literal = tokens[valueStart].stringValue,
               !WorkflowAgentOptionContract.supportedIsolationValues.contains(literal)
            {
                throw WorkflowScriptAnalysisError.unsupportedConstruct(
                    "agent isolation must be 'worktree' or 'sandbox', not '\(literal)'"
                )
            }
            if index < closing { index += 1 }
        }
    }

    private static let forbiddenIdentifiers: Set<String> = [
        "import", "require", "eval", "Function", "AsyncFunction", "GeneratorFunction",
        "WebAssembly", "RegExp", "fetch", "XMLHttpRequest", "process", "Deno", "Bun", "globalThis",
        "window", "document", "navigator", "location", "Worker", "SharedWorker", "Atomics",
        "SharedArrayBuffer", "ArrayBuffer", "setTimeout", "setInterval", "setImmediate",
        "queueMicrotask", "Date", "Temporal", "performance", "crypto", "Reflect", "Proxy",
        "constructor", "prototype", "__proto__", "BigInt", "Symbol", "WeakRef", "FinalizationRegistry",
        "class", "debugger", "with", "yield", "this", "get", "set", "switch",
        "Uint8Array", "Uint8ClampedArray", "Int8Array", "Uint16Array", "Int16Array",
        "Uint32Array", "Int32Array", "Float16Array", "Float32Array", "Float64Array",
        "BigInt64Array", "BigUint64Array", "DataView",
    ]

    /// JavaScriptCore cannot preempt one native builtin. These operations can amplify a small,
    /// analyzed program into unbounded CPU or memory work before the cooperative watchdog gets a
    /// checkpoint. The logical-realm provider therefore rejects them rather than pretending its
    /// wall-clock limit is a hard CPU limit.
    private static let forbiddenSynchronousBuiltins: Set<String> = [
        "repeat", "padStart", "padEnd",
        "fill", "join", "concat", "flat", "flatMap", "copyWithin",
        "stringify", "parse", "toJSON",
        "exec", "test", "match", "matchAll", "search", "replace", "replaceAll", "split",
    ]

    private static func rejectForbiddenCapabilities(_ tokens: [JSToken]) throws {
        let schemaData = literalSchemaTokenIndices(tokens)
        let protectedIntrinsics: Set<String> = [
            "Object", "Array", "Promise", "Map", "JSON", "Math",
        ]
        for (index, token) in tokens.enumerated() {
            if case .regex = token.kind {
                throw WorkflowScriptAnalysisError.forbiddenCapability("regular expressions")
            }
            if token.symbol == "\\" {
                throw WorkflowScriptAnalysisError.unsupportedConstruct("escaped identifier")
            }
            if let template = token.templateValue, template.contains("${") {
                for expression in try templateExpressions(in: template) {
                    var embeddedLexer = JavaScriptLexer(source: expression)
                    let embedded = try embeddedLexer.tokens()
                    if embedded.contains(where: { $0.templateValue != nil }) {
                        throw WorkflowScriptAnalysisError.unsupportedConstruct(
                            "nested template expression"
                        )
                    }
                    // Apply the complete capability/member/mutation policy to interpolation code;
                    // checking only bare identifiers here would make a template an alternate route
                    // around computed-property and protected-intrinsic defenses.
                    try rejectForbiddenCapabilities(embedded)
                    if embedded.contains(where: {
                        ["for", "while", "do", "function"].contains($0.identifier ?? "")
                            || $0.symbol == "=>"
                    }) {
                        throw WorkflowScriptAnalysisError.unsupportedConstruct(
                            "control flow inside template expression"
                        )
                    }
                    if embedded.contains(where: {
                        ["agent", "parallel", "pipeline", "workflow", "phase", "log"]
                            .contains($0.identifier ?? "")
                    }) {
                        throw WorkflowScriptAnalysisError.unsupportedConstruct(
                            "runtime call inside template expression"
                        )
                    }
                }
            }
            if let string = token.stringValue,
               ["constructor", "prototype", "__proto__"].contains(string)
                    || (forbiddenSynchronousBuiltins.contains(string) && !schemaData.contains(index))
            {
                throw WorkflowScriptAnalysisError.forbiddenCapability(string)
            }
            // A fully parsed literal schema contains no expressions, getters, or computed keys.
            // Names such as `test` in properties/required are data, not RegExp method access.
            if schemaData.contains(index) { continue }
            guard let identifier = token.identifier else { continue }
            if identifier.hasPrefix("__") {
                throw WorkflowScriptAnalysisError.forbiddenCapability("reserved runtime binding")
            }
            if forbiddenSynchronousBuiltins.contains(identifier) {
                throw WorkflowScriptAnalysisError.forbiddenCapability(identifier)
            }
            if identifier == "Array", index + 1 < tokens.count,
               tokens[index + 1].symbol == "("
            {
                throw WorkflowScriptAnalysisError.forbiddenCapability("Array constructor")
            }
            if index + 2 < tokens.count, tokens[index + 1].symbol == ".",
               let member = tokens[index + 2].identifier
            {
                let unsafe: Set<String>
                switch identifier {
                case "Array": unsafe = ["from"]
                case "Object": unsafe = ["assign", "fromEntries"]
                case "String": unsafe = ["raw", "fromCharCode", "fromCodePoint"]
                default: unsafe = []
                }
                if unsafe.contains(member) {
                    throw WorkflowScriptAnalysisError.forbiddenCapability("\(identifier).\(member)")
                }
            }
            if protectedIntrinsics.contains(identifier), index + 1 < tokens.count,
               tokens[index + 1].symbol == "["
            {
                throw WorkflowScriptAnalysisError.forbiddenCapability(
                    "computed intrinsic property access"
                )
            }
            if identifier.hasPrefix("__mllm") || identifier.hasPrefix("__workflow")
                || identifier.hasPrefix("__mobileLLM")
            {
                throw WorkflowScriptAnalysisError.forbiddenCapability("reserved runtime binding")
            }
            if forbiddenIdentifiers.contains(identifier) {
                throw WorkflowScriptAnalysisError.forbiddenCapability(identifier)
            }
            if identifier == "random",
               index > 1,
               tokens[index - 1].symbol == ".",
               tokens[index - 2].identifier == "Math"
            {
                throw WorkflowScriptAnalysisError.forbiddenCapability("Math.random")
            }
        }
    }

    private static func literalSchemaTokenIndices(_ tokens: [JSToken]) -> Set<Int> {
        var result = Set<Int>()
        var index = 0
        while index < tokens.count {
            defer { index += 1 }
            guard tokens[index].symbol == "{" else { continue }
            var parser = LiteralParser(tokens: tokens, index: index)
            guard let value = try? parser.parseValue(depth: 0), case .object(let object) = value,
                  object["type"] != nil || object["properties"] != nil || object["$schema"] != nil
            else { continue }
            result.formUnion(index ..< parser.index)
            index = parser.index - 1
        }
        return result
    }

    /// Extracts exactly the JavaScript inside each `${...}` interpolation while ignoring template
    /// text. The old first-`${`/last-backtick slice accidentally lexed ordinary prose (for example
    /// the word "with") as privileged JavaScript and could also merge several expressions. This
    /// scanner is deliberately conservative: it understands braces, quoted strings, and comments;
    /// nested templates and ambiguous slash expressions fail closed before token analysis.
    private static func templateExpressions(in template: String) throws -> [String] {
        let scalars = Array(template.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "`", scalars.last == "`" else {
            throw WorkflowScriptAnalysisError.invalidSyntax("malformed template literal")
        }
        var expressions: [String] = []
        var index = 1
        let end = scalars.count - 1
        while index < end {
            if scalars[index] == "\\" {
                guard index + 1 < end else {
                    throw WorkflowScriptAnalysisError.invalidSyntax("unterminated template escape")
                }
                index += 2
                continue
            }
            guard scalars[index] == "$", index + 1 < end, scalars[index + 1] == "{" else {
                index += 1
                continue
            }
            let expressionStart = index + 2
            index = expressionStart
            var depth = 1
            var quote: UnicodeScalar?
            var lineComment = false
            var blockComment = false
            while index < end, depth > 0 {
                let scalar = scalars[index]
                if lineComment {
                    if scalar == "\n" || scalar == "\r" { lineComment = false }
                    index += 1
                    continue
                }
                if blockComment {
                    if scalar == "*", index + 1 < end, scalars[index + 1] == "/" {
                        blockComment = false
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }
                if let activeQuote = quote {
                    if scalar == "\\" {
                        guard index + 1 < end else {
                            throw WorkflowScriptAnalysisError.invalidSyntax(
                                "unterminated template expression string"
                            )
                        }
                        index += 2
                    } else {
                        if scalar == activeQuote { quote = nil }
                        index += 1
                    }
                    continue
                }
                if scalar == "\"" || scalar == "'" {
                    quote = scalar
                    index += 1
                    continue
                }
                if scalar == "`" {
                    throw WorkflowScriptAnalysisError.unsupportedConstruct(
                        "nested template expression"
                    )
                }
                if scalar == "/", index + 1 < end, scalars[index + 1] == "/" {
                    lineComment = true
                    index += 2
                    continue
                }
                if scalar == "/", index + 1 < end, scalars[index + 1] == "*" {
                    blockComment = true
                    index += 2
                    continue
                }
                if scalar == "/" {
                    // Distinguishing division from a regular-expression literal needs a full parser.
                    // Keep interpolation fail-closed; equivalent arithmetic can be computed outside.
                    throw WorkflowScriptAnalysisError.unsupportedConstruct(
                        "slash inside template expression"
                    )
                }
                if scalar == "\\" {
                    throw WorkflowScriptAnalysisError.unsupportedConstruct("template escape")
                }
                if scalar == "{" { depth += 1 }
                if scalar == "}" {
                    depth -= 1
                    if depth == 0 {
                        let expression = String(
                            String.UnicodeScalarView(scalars[expressionStart ..< index])
                        )
                        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw WorkflowScriptAnalysisError.invalidSyntax(
                                "empty template expression"
                            )
                        }
                        expressions.append(expression)
                    }
                }
                index += 1
            }
            guard depth == 0, quote == nil, !blockComment else {
                throw WorkflowScriptAnalysisError.invalidSyntax(
                    "unterminated template expression"
                )
            }
        }
        return expressions
    }

    private struct Instrumentation {
        let source: String
        let insertions: Set<Int>
    }

    private static func instrument(source: String, tokens: [JSToken]) throws -> Instrumentation {
        var insertions: Set<Int> = [0]
        var expressionStarts: [Int: Int] = [:]
        var expressionEnds: [Int: Int] = [:]
        var doTails: Set<Int> = []
        for i in tokens.indices where tokens[i].identifier == "do" {
            guard i + 1 < tokens.count, tokens[i + 1].symbol == "{",
                  let end = matchingClose(in: tokens, openingAt: i + 1, open: "{", close: "}"),
                  end + 1 < tokens.count, tokens[end + 1].identifier == "while"
            else { throw WorkflowScriptAnalysisError.unsafeLoop("do requires an exact braced body and while tail") }
            doTails.insert(end + 1)
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.identifier == "for" || token.identifier == "while" {
                guard let open = tokens.indices.dropFirst(index + 1).first(where: {
                    tokens[$0].symbol == "("
                }), let close = matchingClose(in: tokens, openingAt: open, open: "(", close: ")")
                else { throw WorkflowScriptAnalysisError.invalidSyntax("unbalanced \(token.identifier!) condition") }
                let after = close + 1
                if after >= tokens.count || tokens[after].symbol != "{" {
                    // `do { ... } while (...)` is already checkpointed at its `do` body.
                    if token.identifier == "while", doTails.contains(index) {
                        index += 1
                        continue
                    }
                    throw WorkflowScriptAnalysisError.unsafeLoop("\(token.identifier!) requires a braced body")
                }
                insertions.insert(tokens[after].end)
                index += 1
                continue
            }
            if token.identifier == "do" {
                guard index + 1 < tokens.count, tokens[index + 1].symbol == "{" else {
                    throw WorkflowScriptAnalysisError.unsafeLoop("do requires a braced body")
                }
                insertions.insert(tokens[index + 1].end)
            } else if token.symbol == "=>", index + 1 < tokens.count {
                if tokens[index + 1].symbol == "{" {
                    insertions.insert(tokens[index + 1].end)
                } else {
                    // Delimiter-balanced expressions preserve nested arrows and call arguments.
                    // Ambiguous ASI forms are rejected; braces are always an available spelling.
                    let start = index + 1
                    var end = start
                    var stack: [String] = []
                    while end < tokens.count {
                        let current = tokens[end]
                        if stack.isEmpty, [",", ";", ")", "]", "}"].contains(current.symbol ?? "") { break }
                        if stack.isEmpty, end > start, current.line > tokens[end - 1].line,
                           ["return", "const", "let", "throw", "if", "for", "while"].contains(current.identifier ?? "") {
                            throw WorkflowScriptAnalysisError.unsupportedConstruct("expression arrow requires an explicit delimiter or braced body")
                        }
                        if let symbol = current.symbol {
                            if let close = ["(": ")", "[": "]", "{": "}"][symbol] { stack.append(close) }
                            else if [")", "]", "}"].contains(symbol) {
                                guard stack.popLast() == symbol else { throw WorkflowScriptAnalysisError.invalidSyntax("arrow expression delimiters") }
                            }
                        }
                        end += 1
                    }
                    guard end > start, stack.isEmpty else { throw WorkflowScriptAnalysisError.invalidSyntax("arrow expression") }
                    expressionStarts[tokens[start].start, default: 0] += 1
                    expressionEnds[tokens[end - 1].end, default: 0] += 1
                }
            }
            // Ordinary object methods also create callable bodies, including async methods.
            if token.symbol == ")", index + 1 < tokens.count, tokens[index + 1].symbol == "{" {
                insertions.insert(tokens[index + 1].end)
            }
            index += 1
        }

        let scalars = Array(source.unicodeScalars)
        var result = ""
        result.reserveCapacity(source.utf8.count + insertions.count * 34)
        for position in 0 ... scalars.count {
            if let count = expressionEnds[position] { result += String(repeating: ")", count: count) }
            if insertions.contains(position) { result += "\n__workflowCheckpoint();\n" }
            if let count = expressionStarts[position] {
                result += String(repeating: "(__workflowCheckpoint(), ", count: count)
            }
            if position < scalars.count { result.unicodeScalars.append(scalars[position]) }
        }
        return Instrumentation(source: result, insertions: insertions.union(expressionStarts.keys))
    }

    private static func matchingClose(
        in tokens: [JSToken], openingAt start: Int, open: String, close: String
    ) -> Int? {
        var depth = 0
        for index in start ..< tokens.count {
            if tokens[index].symbol == open { depth += 1 }
            if tokens[index].symbol == close {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}

// MARK: - Metadata extraction

private struct MetadataExtraction {
    let metadata: WorkflowScriptMetadataV1
    let body: String
}

private struct MetadataExtractor {
    let source: String

    func extract() throws -> MetadataExtraction {
        var lexer = JavaScriptLexer(source: source)
        let tokens = try lexer.tokens()
        guard tokens.count >= 5,
              tokens[0].identifier == "export",
              tokens[1].identifier == "const",
              tokens[2].identifier == "meta",
              tokens[3].symbol == "=",
              tokens[4].symbol == "{"
        else { throw WorkflowScriptAnalysisError.missingMetadata }

        var parser = LiteralParser(tokens: tokens, index: 4)
        let value = try parser.parseValue(depth: 0)
        guard case .object(let object) = value else {
            throw WorkflowScriptAnalysisError.malformedMetadata("meta must be an object")
        }
        var end = parser.index
        let hadSemicolon = end < tokens.count && tokens[end].symbol == ";"
        if hadSemicolon { end += 1 }
        if end < tokens.count,
           tokens[end].line == tokens[parser.index - 1].line,
           !hadSemicolon
        {
            throw WorkflowScriptAnalysisError.malformedMetadata("meta must end its first statement")
        }
        let allowed = Set(["name", "description", "whenToUse", "phases"])
        guard Set(object.keys).isSubset(of: allowed) else {
            throw WorkflowScriptAnalysisError.malformedMetadata("unknown metadata field")
        }
        guard let rawName = object["name"], case .string(let name) = rawName,
              let rawDescription = object["description"],
              case .string(let description) = rawDescription
        else {
            throw WorkflowScriptAnalysisError.malformedMetadata("name and description are required strings")
        }
        let whenToUse: String?
        switch object["whenToUse"] {
        case nil: whenToUse = nil
        case .string(let value): whenToUse = value
        default: throw WorkflowScriptAnalysisError.malformedMetadata("whenToUse must be a string")
        }
        var phases: [WorkflowPhaseMetadataV1] = []
        if let rawPhases = object["phases"] {
            guard case .array(let values) = rawPhases else {
                throw WorkflowScriptAnalysisError.malformedMetadata("phases must be an array")
            }
            phases = try values.map { value in
                guard case .object(let phase) = value,
                      Set(phase.keys).isSubset(of: ["title", "detail", "model"]),
                      case .string(let title)? = phase["title"]
                else { throw WorkflowScriptAnalysisError.malformedMetadata("invalid phase entry") }
                let detail = try optionalString(phase["detail"], field: "phase.detail")
                let model = try optionalString(phase["model"], field: "phase.model")
                return try WorkflowPhaseMetadataV1(
                    title: title,
                    detail: detail,
                    requestedModel: model
                )
            }
        }
        let metadata: WorkflowScriptMetadataV1
        do {
            metadata = try WorkflowScriptMetadataV1(
                name: name,
                description: description,
                whenToUse: whenToUse,
                phases: phases
            )
        } catch {
            throw WorkflowScriptAnalysisError.malformedMetadata(String(describing: error))
        }

        let scalars = Array(source.unicodeScalars)
        let bodyStart = end < tokens.count ? tokens[end].start : scalars.count
        let prefix = String(String.UnicodeScalarView(scalars[0 ..< tokens[0].start]))
        let suffix = String(String.UnicodeScalarView(scalars[bodyStart ..< scalars.count]))
        return MetadataExtraction(metadata: metadata, body: prefix + suffix)
    }

    private func optionalString(_ value: JSONValue?, field: String) throws -> String? {
        switch value {
        case nil: nil
        case .string(let string): string
        default: throw WorkflowScriptAnalysisError.malformedMetadata("\(field) must be a string")
        }
    }
}

private struct LiteralParser {
    let tokens: [JSToken]
    var index: Int
    var nodes = 0

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= 16, index < tokens.count else {
            throw WorkflowScriptAnalysisError.malformedMetadata("literal nesting limit")
        }
        nodes += 1
        guard nodes <= 1_024 else {
            throw WorkflowScriptAnalysisError.malformedMetadata("literal node limit")
        }
        let token = tokens[index]
        if let string = token.stringValue { index += 1; return .string(string) }
        if case .number(let number) = token.kind {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8))
            index += 1
            return value
        }
        if token.symbol == "-", index + 1 < tokens.count,
           case .number(let number) = tokens[index + 1].kind {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(("-" + number).utf8))
            index += 2
            return value
        }
        if token.identifier == "true" { index += 1; return .bool(true) }
        if token.identifier == "false" { index += 1; return .bool(false) }
        if token.identifier == "null" { index += 1; return .null }
        if token.symbol == "[" { return try parseArray(depth: depth + 1) }
        if token.symbol == "{" { return try parseObject(depth: depth + 1) }
        throw WorkflowScriptAnalysisError.malformedMetadata("values must be pure JSON-like literals")
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var values: [JSONValue] = []
        while index < tokens.count, tokens[index].symbol != "]" {
            values.append(try parseValue(depth: depth))
            if index < tokens.count, tokens[index].symbol == "," {
                index += 1
                continue
            }
            guard index < tokens.count, tokens[index].symbol == "]" else {
                throw WorkflowScriptAnalysisError.malformedMetadata("array separator")
            }
        }
        guard index < tokens.count else {
            throw WorkflowScriptAnalysisError.malformedMetadata("unterminated array")
        }
        index += 1
        return .array(values)
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object: [String: JSONValue] = [:]
        while index < tokens.count, tokens[index].symbol != "}" {
            let key: String
            if let identifier = tokens[index].identifier { key = identifier }
            else if let string = tokens[index].stringValue { key = string }
            else { throw WorkflowScriptAnalysisError.malformedMetadata("object key") }
            guard key != "__proto__", key != "constructor", key != "prototype",
                  object[key] == nil
            else { throw WorkflowScriptAnalysisError.malformedMetadata("unsafe or duplicate object key") }
            index += 1
            guard index < tokens.count, tokens[index].symbol == ":" else {
                throw WorkflowScriptAnalysisError.malformedMetadata("object colon")
            }
            index += 1
            object[key] = try parseValue(depth: depth)
            if index < tokens.count, tokens[index].symbol == "," {
                index += 1
                continue
            }
            guard index < tokens.count, tokens[index].symbol == "}" else {
                throw WorkflowScriptAnalysisError.malformedMetadata("object separator")
            }
        }
        guard index < tokens.count else {
            throw WorkflowScriptAnalysisError.malformedMetadata("unterminated object")
        }
        index += 1
        return .object(object)
    }
}

// MARK: - Conservative lexer

private struct JSToken: Hashable {
    enum Kind: Hashable {
        case identifier(String)
        case string(String)
        case symbol(String)
        case number(String)
        case template(String)
        case regex
    }

    let kind: Kind
    let start: Int
    let end: Int
    let line: Int

    var identifier: String? { if case .identifier(let value) = kind { value } else { nil } }
    var stringValue: String? { if case .string(let value) = kind { value } else { nil } }
    var symbol: String? { if case .symbol(let value) = kind { value } else { nil } }
    var templateValue: String? { if case .template(let value) = kind { value } else { nil } }
}

private struct JavaScriptLexer {
    let scalars: [UnicodeScalar]
    var index = 0
    var line = 1
    var result: [JSToken] = []

    init(source: String) { scalars = Array(source.unicodeScalars) }

    mutating func tokens() throws -> [JSToken] {
        while index < scalars.count {
            if isWhitespace(scalars[index]) { consumeWhitespace(); continue }
            if peek("//") { consumeLineComment(); continue }
            if peek("/*") { try consumeBlockComment(); continue }
            let start = index
            let tokenLine = line
            let scalar = scalars[index]
            if scalar == "\"" || scalar == "'" {
                result.append(JSToken(
                    kind: .string(try consumeString(quote: scalar)),
                    start: start,
                    end: index,
                    line: tokenLine
                ))
                continue
            }
            if scalar == "`" {
                try consumeTemplate()
                let value = String(String.UnicodeScalarView(scalars[start ..< index]))
                result.append(JSToken(kind: .template(value), start: start, end: index, line: tokenLine))
                continue
            }
            if isIdentifierStart(scalar) {
                index += 1
                while index < scalars.count, isIdentifierContinue(scalars[index]) { index += 1 }
                let value = String(String.UnicodeScalarView(scalars[start ..< index]))
                result.append(JSToken(kind: .identifier(value), start: start, end: index, line: tokenLine))
                continue
            }
            if isDigit(scalar) {
                index += 1
                while index < scalars.count,
                      isDigit(scalars[index]) || [".", "e", "E", "+", "-"].contains(String(scalars[index]))
                { index += 1 }
                let value = String(String.UnicodeScalarView(scalars[start ..< index]))
                result.append(JSToken(kind: .number(value), start: start, end: index, line: tokenLine))
                continue
            }
            if scalar == "/", isRegexStart() {
                try consumeRegex()
                result.append(JSToken(kind: .regex, start: start, end: index, line: tokenLine))
                continue
            }
            let two = index + 1 < scalars.count
                ? String(String.UnicodeScalarView(scalars[index ... index + 1])) : ""
            let three = index + 2 < scalars.count
                ? String(String.UnicodeScalarView(scalars[index ... index + 2])) : ""
            let multi = ["===", "!==", ">>>", "**=", "&&=", "||=", "??="].contains(three)
                ? three
                : (["=>", "==", "!=", "<=", ">=", "++", "--", "&&", "||", "??", "?.",
                    "+=", "-=", "*=", "/=", "%=", "**", "<<", ">>"].contains(two) ? two : nil)
            if let multi { index += multi.unicodeScalars.count }
            else { index += 1 }
            result.append(JSToken(
                kind: .symbol(multi ?? String(scalar)),
                start: start,
                end: index,
                line: tokenLine
            ))
        }
        return result
    }

    private mutating func consumeWhitespace() {
        while index < scalars.count, isWhitespace(scalars[index]) {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }
    }

    private mutating func consumeLineComment() {
        index += 2
        while index < scalars.count, scalars[index] != "\n" { index += 1 }
    }

    private mutating func consumeBlockComment() throws {
        index += 2
        while index + 1 < scalars.count, !peek("*/") {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }
        guard index + 1 < scalars.count else {
            throw WorkflowScriptAnalysisError.invalidSyntax("unterminated block comment")
        }
        index += 2
    }

    private mutating func consumeString(quote: UnicodeScalar) throws -> String {
        index += 1
        var output = ""
        while index < scalars.count, scalars[index] != quote {
            let scalar = scalars[index]
            guard scalar != "\n", scalar != "\r" else {
                throw WorkflowScriptAnalysisError.invalidSyntax("newline in string literal")
            }
            if scalar == "\\" {
                index += 1
                guard index < scalars.count else {
                    throw WorkflowScriptAnalysisError.invalidSyntax("unterminated string escape")
                }
                let escaped = scalars[index]
                switch escaped {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                case "b": output.append("\u{8}")
                case "f": output.append("\u{c}")
                case "v": output.append("\u{b}")
                case "0": output.append("\0")
                case "\\", "\"", "'", "/": output.unicodeScalars.append(escaped)
                default:
                    throw WorkflowScriptAnalysisError.malformedMetadata("unsupported string escape")
                }
                index += 1
                continue
            }
            output.unicodeScalars.append(scalar)
            index += 1
        }
        guard index < scalars.count else {
            throw WorkflowScriptAnalysisError.invalidSyntax("unterminated string literal")
        }
        index += 1
        return output
    }

    private mutating func consumeTemplate() throws {
        index += 1
        while index < scalars.count {
            if scalars[index] == "\\" { index += 2; continue }
            if scalars[index] == "\n" { line += 1 }
            if scalars[index] == "`" { index += 1; return }
            index += 1
        }
        throw WorkflowScriptAnalysisError.invalidSyntax("unterminated template literal")
    }

    private mutating func consumeRegex() throws {
        index += 1
        var inClass = false
        while index < scalars.count {
            if scalars[index] == "\\" { index += 2; continue }
            if scalars[index] == "\n" {
                throw WorkflowScriptAnalysisError.invalidSyntax("newline in regular expression")
            }
            if scalars[index] == "[" { inClass = true }
            if scalars[index] == "]" { inClass = false }
            if scalars[index] == "/", !inClass {
                index += 1
                while index < scalars.count, isIdentifierContinue(scalars[index]) { index += 1 }
                return
            }
            index += 1
        }
        throw WorkflowScriptAnalysisError.invalidSyntax("unterminated regular expression")
    }

    private func isRegexStart() -> Bool {
        guard let previous = result.last else { return true }
        if let symbol = previous.symbol {
            return ["(", "[", "{", ",", ";", ":", "=", "!", "?", "&&", "||", "??", "=>"].contains(symbol)
        }
        return ["return", "case", "throw", "else", "do", "typeof", "void", "delete", "in", "of"]
            .contains(previous.identifier ?? "")
    }

    private func peek(_ value: String) -> Bool {
        let expected = Array(value.unicodeScalars)
        guard index + expected.count <= scalars.count else { return false }
        return Array(scalars[index ..< index + expected.count]) == expected
    }

    private func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || scalar == "$" || ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar)
    }

    private func isIdentifierContinue(_ scalar: UnicodeScalar) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar)
    }

    private func isDigit(_ scalar: UnicodeScalar) -> Bool { ("0" ... "9").contains(scalar) }
}
