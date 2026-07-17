// SPDX-License-Identifier: MIT

import Foundation

/// Builds the tools instruction injected into the system turn, in the ACTIVE MODEL'S dialect — see
/// `ToolDialect` for why that matters (a model handed a stranger's tool convention improvises, and the
/// improvisation used to be unreadable, so no tool ran and the model claimed one had).
public enum ToolPrompt {
    public static func systemBlock(_ schemas: [ToolSchema], dialect: ToolDialect = .qwen) -> String {
        guard !schemas.isEmpty else { return "" }
        // Small models can't turn "in an hour" into an absolute time without knowing NOW — a 2B model
        // asked for a 1-hour reminder emitted `now + 1 hour`, got rejected, and gave up. Ground them.
        let df = DateFormatter()
        df.dateFormat = "EEEE, yyyy-MM-dd HH:mm (ZZZZZ)"
        return "Current date & time: \(df.string(from: Date())).\n\n" + dialect.declarations(schemas)
    }

    /// Frame a tool's raw output as EXTERNAL, UNTRUSTED data before feeding it back to the model. A tool
    /// can return attacker-controlled text — a fetched web page, a file's contents — and without a trust
    /// boundary the model may obey a directive embedded in that text (prompt injection). The frame is
    /// dialect-specific; the "data, not instructions" fence is not. `result` is emitted verbatim inside it.
    public static func frameToolResult(_ result: String, name: String = "tool",
                                       dialect: ToolDialect = .qwen) -> String {
        dialect.frameResult(result, name: name)
    }

    /// Hand a malformed tool call back to the model with a worked example IN ITS OWN dialect. Small models
    /// miss the shape often enough that silently dropping the attempt (the old behavior) reads to the user
    /// as the model saying nothing at all; one corrective round trip usually lands it.
    public static func malformedCallNote(_ body: String, dialect: ToolDialect = .qwen) -> String {
        dialect.malformedNote(body)
    }

    /// Return `messages` with the tools block folded into the system turn (adding one if absent).
    public static func inject(_ schemas: [ToolSchema], into messages: [ChatTurn],
                              dialect: ToolDialect = .qwen) -> [ChatTurn] {
        let block = systemBlock(schemas, dialect: dialect)
        guard !block.isEmpty else { return messages }
        var out = messages
        if let i = out.firstIndex(where: { $0.role == .system }) {
            out[i] = ChatTurn(role: .system, content: out[i].content.isEmpty ? block : out[i].content + "\n\n" + block)
        } else {
            out.insert(ChatTurn(role: .system, content: block), at: 0)
        }
        return out
    }
}

/// One event from the agentic loop — a superset of `EngineDelta` that also surfaces tool activity.
public enum ToolLoopEvent: Sendable, Equatable {
    case reasoning(String)
    case answer(String)
    case toolCall(ToolCall)
    case toolResult(ToolCall, String)
    case done(Stats)
}

/// The tool-calling agent loop (DESIGN §7): generate → detect a `<tool_call>` → run the tool locally →
/// feed `<tool_response>` back → generate again, up to `maxIterations` (a hard guard FlowDown lacks). It
/// sits ABOVE the `LLMEngine` — no engine changes; the model emits tool calls as plain text that
/// `ToolCallProcessor` extracts. Emits a stream the chat layer consumes like `engine.generate`.
public struct ToolLoop: Sendable {
    private let engine: any LLMEngine
    private let registry: ToolRegistry
    private let maxIterations: Int
    /// The active model's tool dialect — what we DECLARE and FRAME in. Reading is dialect-agnostic
    /// (`ToolCallSyntax`), so a model that answers in someone else's convention is still understood.
    private let dialect: ToolDialect

    public init(engine: any LLMEngine, registry: ToolRegistry, dialect: ToolDialect = .qwen,
                maxIterations: Int = 4) {
        self.engine = engine
        self.registry = registry
        self.dialect = dialect
        self.maxIterations = max(1, maxIterations)
    }

    public func run(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<ToolLoopEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var history = ToolPrompt.inject(registry.schemas, into: messages, dialect: dialect)
                    var lastStats = Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
                                          peakMemoryBytes: 0, stopReason: .eos)
                    for iteration in 0..<maxIterations {
                        var raw = ""
                        var processor = ToolCallProcessor(acceptsBareJSON: dialect == .deepSeek)
                        var call: ToolCall?
                        var malformed: String?

                        loop: for try await delta in engine.generate(messages: history, params: params) {
                            try Task.checkCancellation()
                            switch delta {
                            case .reasoning(let s):
                                continuation.yield(.reasoning(s))
                            case .answer(let s):
                                raw += s
                                for e in processor.feed(s) {
                                    switch e {
                                    case .text(let t): if !t.isEmpty { continuation.yield(.answer(t)) }
                                    case .call(let c): call = c; break loop   // stop generating; run the tool
                                    case .malformed(let body): malformed = body; break loop
                                    }
                                }
                            case .done(let stats):
                                lastStats = stats
                            }
                        }
                        if call == nil, malformed == nil {
                            for e in processor.finish() {
                                switch e {
                                case .text(let t): if !t.isEmpty { continuation.yield(.answer(t)) }
                                case .call(let c): call = c
                                case .malformed(let body): malformed = body
                                }
                            }
                        }

                        // The model tried to call a tool but its JSON didn't parse. Hand the mistake back
                        // and let it try again rather than dropping the turn: a small model's near-miss
                        // otherwise became an empty, unexplained reply (observed on-device with a 2B model
                        // asked for a reminder). Costs one iteration, like any other round trip.
                        if let malformed {
                            history.append(ChatTurn(role: .assistant, content: raw))
                            history.append(ChatTurn(role: .user,
                                                    content: ToolPrompt.malformedCallNote(malformed,
                                                                                          dialect: dialect)))
                            continue
                        }

                        // No tool requested → this is the final answer.
                        guard let call, let tool = registry.tool(named: call.name) else {
                            if let call { // model asked for a tool we don't have — tell it, then stop.
                                continuation.yield(.answer("\n_(No tool named “\(call.name)”.)_"))
                            }
                            continuation.yield(.done(lastStats))
                            continuation.finish()
                            return
                        }

                        // Run the tool locally, feed the result back, and loop.
                        continuation.yield(.toolCall(call))
                        let result = await tool.execute(argumentsJSON: call.argumentsJSON)
                        continuation.yield(.toolResult(call, result))
                        history.append(ChatTurn(role: .assistant, content: raw))
                        history.append(ChatTurn(role: .user,
                                                content: ToolPrompt.frameToolResult(result, name: call.name,
                                                                                    dialect: dialect)))

                        if iteration == maxIterations - 1 {   // last pass: one more answer, no more tools
                            var final = ToolCallProcessor()
                            for try await delta in engine.generate(messages: history, params: params) {
                                try Task.checkCancellation()
                                switch delta {
                                case .reasoning(let s): continuation.yield(.reasoning(s))
                                case .answer(let s): for e in final.feed(s) { if case .text(let t) = e, !t.isEmpty { continuation.yield(.answer(t)) } }
                                case .done(let stats): lastStats = stats
                                }
                            }
                            for e in final.finish() { if case .text(let t) = e, !t.isEmpty { continuation.yield(.answer(t)) } }
                            continuation.yield(.done(lastStats))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(.done(lastStats))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
