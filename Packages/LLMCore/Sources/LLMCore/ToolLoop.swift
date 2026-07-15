// SPDX-License-Identifier: MIT

import Foundation

/// Builds the tools instruction injected into the system turn (Qwen/ChatML tool convention).
public enum ToolPrompt {
    public static func systemBlock(_ schemas: [ToolSchema]) -> String {
        guard !schemas.isEmpty else { return "" }
        let list = schemas.map { s -> String in
            let ps = s.parameters.map { "\($0.name) (\($0.kind.rawValue)\($0.required ? "" : ", optional")): \($0.description)" }
                .joined(separator: "; ")
            return "- \(s.name): \(s.description)" + (ps.isEmpty ? "" : " Parameters: \(ps).")
        }.joined(separator: "\n")
        return """
        You can call tools when they help. Available tools:
        \(list)

        To call a tool, output ONLY this and then stop:
        <tool_call>{"name": "<tool>", "arguments": {<args>}}</tool_call>
        You will be given the result and can continue. If no tool is needed, just answer.
        """
    }

    /// Return `messages` with the tools block folded into the system turn (adding one if absent).
    public static func inject(_ schemas: [ToolSchema], into messages: [ChatTurn]) -> [ChatTurn] {
        let block = systemBlock(schemas)
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

    public init(engine: any LLMEngine, registry: ToolRegistry, maxIterations: Int = 4) {
        self.engine = engine
        self.registry = registry
        self.maxIterations = max(1, maxIterations)
    }

    public func run(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<ToolLoopEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var history = ToolPrompt.inject(registry.schemas, into: messages)
                    var lastStats = Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
                                          peakMemoryBytes: 0, stopReason: .eos)
                    for iteration in 0..<maxIterations {
                        var raw = ""
                        var processor = ToolCallProcessor()
                        var call: ToolCall?

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
                                    }
                                }
                            case .done(let stats):
                                lastStats = stats
                            }
                        }
                        if call == nil {
                            for e in processor.finish() {
                                switch e {
                                case .text(let t): if !t.isEmpty { continuation.yield(.answer(t)) }
                                case .call(let c): call = c
                                }
                            }
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
                        history.append(ChatTurn(role: .user, content: "<tool_response>\n\(result)\n</tool_response>"))

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
