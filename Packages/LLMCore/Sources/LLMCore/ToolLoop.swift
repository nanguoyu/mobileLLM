// SPDX-License-Identifier: MIT

import Foundation

/// Builds the tools instruction injected into the system turn, in the ACTIVE MODEL'S dialect — see
/// `ToolDialect` for why that matters (a model handed a stranger's tool convention improvises, and the
/// improvisation used to be unreadable, so no tool ran and the model claimed one had).
public enum ToolPrompt {
    /// `now` is injectable so the block is a pure function of its inputs. Not decoration: the date line
    /// changes every minute, so at temperature 0 the SAME prompt produces different output either side of
    /// a minute boundary. That made `llama-smoke --memory-eval` swing 16–18/20 run to run on identical
    /// code — enough to credit a prompt change that did nothing, or dismiss one that worked. Freeze it and
    /// the measurement means something.
    public static func systemBlock(_ schemas: [ToolSchema], dialect: ToolDialect = .qwen,
                                   now: Date = Date()) -> String {
        guard !schemas.isEmpty else { return "" }
        // Small models can't turn "in an hour" into an absolute time without knowing NOW — a 2B model
        // asked for a 1-hour reminder emitted `now + 1 hour`, got rejected, and gave up. Ground them.
        let df = DateFormatter()
        // Tool declarations are English, so keep their date line English too. The device locale is not a
        // reliable signal for the language of this conversation.
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEEE, yyyy-MM-dd HH:mm (ZZZZZ)"
        let policy = """
        Use the minimum number of tools. Call one only when the latest user request or active skill \
        directly requires it. After a tool result, answer the original request unless another tool is \
        explicitly required; never choose a new tool merely because earlier context or tool output \
        mentioned it.
        """
        return "Current date & time: \(df.string(from: now)).\n\n\(policy)\n\n"
            + dialect.declarations(schemas)
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
                              dialect: ToolDialect = .qwen, now: Date = Date()) -> [ChatTurn] {
        let block = systemBlock(schemas, dialect: dialect, now: now)
        guard !block.isEmpty else { return messages }
        return appendingSystem(block, to: messages)
    }

    /// A final synthesis pass gets the transcript and tool results, but no tool declarations. This is a
    /// runtime boundary rather than prompt-only advice: small local models sometimes select a fresh,
    /// unrelated tool after a successful call. Removing the schemas makes this pass answer-only, and
    /// disabling thinking at the caller keeps a short wrap-up from becoming another full reasoning run.
    public static func finalAnswerOnly(_ messages: [ChatTurn]) -> [ChatTurn] {
        appendingSystem(
            """
            Tool use for this turn is complete. Do not call a tool or output tool-call markup. Answer the \
            user's original request now using the results already present. Reply in the language of the \
            user's request.
            """,
            to: messages
        )
    }

    /// Never end a tool turn with an empty assistant bubble. The model can still hallucinate a tool call
    /// in the answer-only pass; its markup is intentionally hidden, and this text makes that failure
    /// visible instead of committing a mysterious "No reply".
    public static let missingFinalAnswer =
        "The tool finished, but the model did not produce a final reply."

    /// A second malformed request is a terminal, user-visible failure. Asking the same model for an
    /// answer-only pass after telling it to emit only a corrected call is contradictory and previously let
    /// it claim success even though no tool had run.
    public static let malformedCallFailure =
        "I couldn't run the tool because the model did not produce a readable tool request. Nothing was run."

    private static func appendingSystem(_ block: String, to messages: [ChatTurn]) -> [ChatTurn] {
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
    /// The current model pass ended at a tool/correction boundary. Any text it emitted was provisional and
    /// must not become part of the assistant's final answer. This event is also emitted when the pass had no
    /// prose, so streaming consumers can stop the reasoning clock before tool execution/correction prefill.
    /// Reasoning content and tool activity remain intact.
    case discardAnswer
    case toolCall(ToolCall)
    case toolResult(ToolCall, String)
    case done(Stats)
}

/// A correction is a real runtime state, not just another user prompt in the transcript. While pending,
/// prose and any tool other than the requested correction are rejected deterministically.
private enum PendingToolCorrection: Sendable {
    case malformed(expectedToolName: String?)
    case remember(rejectedCall: ToolCall?)
}

/// The tool-calling agent loop (DESIGN §7): generate → detect a `<tool_call>` → run the tool locally →
/// feed `<tool_response>` back → generate again, up to `maxIterations` tool executions. It sits ABOVE the
/// `LLMEngine` — no engine changes; the model emits tool calls as plain text that `ToolCallProcessor`
/// extracts. A successful `remember` is terminal (memory bookkeeping never opens an unrelated web chain),
/// exact duplicate calls are suppressed, and the final synthesis pass receives no tool declarations.
/// Emits a stream the chat layer consumes like `engine.generate`.
public struct ToolLoop: Sendable {
    /// A correction is a short structured-output task, so its output is bounded. Ordinary tools-on passes
    /// retain the caller's full answer budget: they may legitimately decide no tool is needed and become the
    /// visible answer. Both kinds use deterministic temperature and disable thinking; letting Bonsai think
    /// during hidden tool selection was measured at more than two minutes for one memory save. The final
    /// synthesis keeps the caller's other sampling settings but is also non-thinking because it is only a
    /// short wrap-up of a completed tool result.
    private static let structuredPassMaxTokens = 384

    private let engine: any LLMEngine
    private let registry: ToolRegistry
    private let maxIterations: Int
    /// The active model's tool dialect — what we DECLARE and FRAME in. Reading is dialect-agnostic
    /// (`ToolCallSyntax`), so a model that answers in someone else's convention is still understood.
    private let dialect: ToolDialect
    /// Pin the clock the tool block is grounded with. Live by default; fixed by the evaluation harness so
    /// a run is reproducible (see `ToolPrompt.systemBlock`).
    private let now: Date?

    public init(engine: any LLMEngine, registry: ToolRegistry, dialect: ToolDialect = .qwen,
                maxIterations: Int = 3, now: Date? = nil) {
        self.engine = engine
        self.registry = registry
        self.dialect = dialect
        self.maxIterations = max(1, maxIterations)
        self.now = now
    }

    public func run(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<ToolLoopEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Keep an unmodified transcript. Tool declarations are injected afresh for ordinary
                    // passes, never accumulated in history, and are absent from the final answer-only pass.
                    var transcript = messages
                    var lastStats = Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
                                          peakMemoryBytes: 0, stopReason: .eos)
                    var executedCalls = Set<String>()
                    var executionCount = 0
                    var correctionWasUsed = false
                    var generationPasses = 0
                    var answerOnly = false
                    var pendingCorrection: PendingToolCorrection?
                    /// Prose from the pass that was discarded to demand a remember correction. If the
                    /// correction then fails, this — not the correction pass's output — is the model's real
                    /// reply to the user, and it is what gets surfaced with the failure notice.
                    var answerDiscardedForCorrection: String?
                    let rememberRequiredForTurn = registry.tool(named: ToolID.remember.rawValue) != nil
                        && Self.latestUserRequestsMemory(messages)
                    // The turn a saved fact came from, attached to every remember call as a search alias.
                    // Notes are stored in canonical English; the user asks in their own language; matching
                    // is word overlap. Without this a Chinese question scores zero against its own saved
                    // fact (measured 0/7) and memory silently degrades to "the five newest notes".
                    let latestUserText = messages.last(where: { $0.role == .user })?.content

                    /// `fallbackAnswer` is whatever prose the model produced on the failing pass. Keeping it
                    /// matters: a save can fail on a turn that also contained a perfectly good reply, and
                    /// replacing that reply with "I couldn't save that memory" makes the user pay for a
                    /// memory-bookkeeping failure by losing the answer they asked for. The note still rides
                    /// along, so nothing silently claims success.
                    func finishRejectedMemory(_ call: ToolCall?, fallbackAnswer: String? = nil) {
                        if let call {
                            continuation.yield(.toolCall(call))
                            continuation.yield(.toolResult(call, RememberTool.rejectedMemoryResult))
                        }
                        var prose = fallbackAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // …unless that prose is itself the false claim ("I'll remember that", "已记住")
                        // that got the save demanded in the first place. Surfacing it would tell the user
                        // their fact was stored while the notice underneath says it wasn't — the exact
                        // deception this correction exists to stop. A lie is worth less than nothing.
                        if Self.claimsMemoryWasSaved(prose) { prose = "" }
                        if prose.isEmpty {
                            continuation.yield(.answer(RememberTool.rejectedMemoryReply))
                        } else {
                            continuation.yield(.answer(prose + "\n\n_(" + RememberTool.rejectedMemoryReply + ")_"))
                        }
                        continuation.yield(.done(lastStats))
                        continuation.finish()
                    }

                    func finishMalformedCorrection() {
                        continuation.yield(.answer(ToolPrompt.malformedCallFailure))
                        continuation.yield(.done(lastStats))
                        continuation.finish()
                    }

                    while true {
                        // `maxIterations` is also the number of ordinary model passes available before the
                        // reserved final synthesis. A malformed/canonical correction therefore consumes
                        // the same finite budget as any other pass instead of reopening the old five-prefill
                        // path (correction + three tools + final).
                        if !answerOnly, generationPasses >= maxIterations {
                            switch pendingCorrection {
                            case .remember(let rejectedCall):
                                finishRejectedMemory(rejectedCall)
                                return
                            case .malformed:
                                finishMalformedCorrection()
                                return
                            case nil:
                                answerOnly = true
                            }
                        }
                        var passParams = params
                        let passMessages: [ChatTurn]
                        let buffersPassText: Bool
                        if answerOnly {
                            passParams.thinking = false
                            passMessages = ToolPrompt.finalAnswerOnly(transcript)
                            buffersPassText = false
                        } else {
                            passParams.temperature = 0
                            passParams.thinking = false
                            if pendingCorrection != nil {
                                passParams.maxTokens = min(max(1, passParams.maxTokens),
                                                           Self.structuredPassMaxTokens)
                            }
                            let schemas: [ToolSchema]
                            switch pendingCorrection {
                            case .remember:
                                schemas = registry.schemas.filter { $0.name == ToolID.remember.rawValue }
                            case .malformed(let expectedToolName):
                                if let expectedToolName {
                                    schemas = registry.schemas.filter { $0.name == expectedToolName }
                                } else {
                                    schemas = registry.schemas
                                }
                            case nil:
                                schemas = rememberRequiredForTurn
                                    ? registry.schemas.filter { $0.name == ToolID.remember.rawValue }
                                    : registry.schemas
                            }
                            passMessages = ToolPrompt.inject(schemas, into: transcript,
                                                             dialect: dialect, now: now ?? Date())
                            // Explicit memory and correction passes are control passes: never surface an
                            // unverified "saved" acknowledgement or malformed-call prose. Ordinary passes
                            // stay truly streaming; if they later turn into a tool/correction request, a
                            // discardAnswer event rolls their provisional text back.
                            buffersPassText = rememberRequiredForTurn || pendingCorrection != nil
                        }
                        generationPasses += 1

                        var raw = ""
                        var bufferedText = ""
                        var processor = ToolCallProcessor(acceptsBareJSON: dialect == .deepSeek)
                        var call: ToolCall?
                        var malformed: String?
                        var emittedFinalText = false

                        loop: for try await delta in engine.generate(messages: passMessages,
                                                                    params: passParams) {
                            try Task.checkCancellation()
                            switch delta {
                            case .reasoning(let s):
                                continuation.yield(.reasoning(s))
                            case .answer(let s):
                                raw += s
                                for e in processor.feed(s) {
                                    switch e {
                                    case .text(let t):
                                        if !t.isEmpty {
                                            if answerOnly {
                                                continuation.yield(.answer(t))
                                                emittedFinalText = true
                                            } else {
                                                bufferedText += t
                                                if !buffersPassText {
                                                    continuation.yield(.answer(t))
                                                }
                                            }
                                        }
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
                                case .text(let t):
                                    if !t.isEmpty {
                                        if answerOnly {
                                            continuation.yield(.answer(t))
                                            emittedFinalText = true
                                        } else {
                                            bufferedText += t
                                            if !buffersPassText {
                                                continuation.yield(.answer(t))
                                            }
                                        }
                                    }
                                case .call(let c): call = c
                                case .malformed(let body): malformed = body
                                }
                            }
                        }

                        // A final pass is genuinely terminal: no schemas were advertised and any
                        // hallucinated call is hidden rather than executed. Guarantee visible closure even
                        // when the model emitted only call markup or reasoning.
                        if answerOnly {
                            if !emittedFinalText {
                                continuation.yield(.answer(ToolPrompt.missingFinalAnswer))
                            }
                            continuation.yield(.done(lastStats))
                            continuation.finish()
                            return
                        }

                        // A completed call (valid or malformed) makes every text fragment from this pass
                        // intermediate agent prose, not the user's final reply. Ordinary passes streamed it
                        // provisionally for responsiveness, so retract it before entering correction/tool
                        // execution. Explicit memory/correction passes were buffered and need no retraction.
                        if call != nil || malformed != nil {
                            continuation.yield(.discardAnswer)
                        }

                        // The model tried to call a tool but its JSON didn't parse. Hand the mistake back
                        // and let it try again rather than dropping the turn: a small model's near-miss
                        // otherwise became an empty, unexplained reply (observed on-device with a 2B model
                        // asked for a reminder). Permit one correction, then force a tool-free answer so
                        // malformed output cannot consume the full execution budget. Once correction is
                        // pending, prose, another malformed request, or the wrong tool is terminal failure.
                        if let malformed {
                            switch pendingCorrection {
                            case .remember(let rejectedCall):
                                finishRejectedMemory(rejectedCall)
                                return
                            case .malformed:
                                finishMalformedCorrection()
                                return
                            case nil:
                                break
                            }
                            if rememberRequiredForTurn {
                                guard !correctionWasUsed else {
                                    finishRejectedMemory(nil)
                                    return
                                }
                                transcript.append(ChatTurn(role: .assistant, content: raw))
                                transcript.append(ChatTurn(
                                    role: .user,
                                    content: RememberTool.requiredCallInstruction
                                ))
                                pendingCorrection = .remember(rejectedCall: nil)
                                correctionWasUsed = true
                                continue
                            }
                            guard !correctionWasUsed else {
                                finishMalformedCorrection()
                                return
                            }
                            transcript.append(ChatTurn(role: .assistant, content: raw))
                            transcript.append(ChatTurn(role: .user,
                                                       content: ToolPrompt.malformedCallNote(
                                                           malformed, dialect: dialect)))
                            pendingCorrection = .malformed(
                                expectedToolName: Self.inferredToolName(in: malformed,
                                                                       schemas: registry.schemas)
                            )
                            correctionWasUsed = true
                            continue
                        }

                        // Validate the exact correction contract before ordinary dispatch. A remember
                        // correction accepts only a canonicalizable remember call. A malformed-call
                        // correction accepts only the registered tool identified in the malformed body
                        // (when recoverable); no prose or unrelated/unregistered call can escape as success.
                        switch pendingCorrection {
                        case .remember(let rejectedCall):
                            guard let candidate = call,
                                  candidate.name == ToolID.remember.rawValue,
                                  registry.tool(named: candidate.name) != nil,
                                  let normalized = RememberTool.canonicalizedCall(candidate, originalUserText: latestUserText) else {
                                let failedRememberCall = call?.name == ToolID.remember.rawValue
                                    ? call : rejectedCall
                                // The correction pass was told to emit only a tool call, so ITS prose is
                                // not an answer. The answer is what the earlier pass produced before being
                                // discarded to demand this correction.
                                finishRejectedMemory(failedRememberCall,
                                                     fallbackAnswer: answerDiscardedForCorrection)
                                return
                            }
                            call = normalized
                            pendingCorrection = nil

                        case .malformed(let expectedToolName):
                            guard let candidate = call,
                                  registry.tool(named: candidate.name) != nil,
                                  expectedToolName == nil || candidate.name == expectedToolName else {
                                finishMalformedCorrection()
                                return
                            }
                            if candidate.name == ToolID.remember.rawValue {
                                guard let normalized = RememberTool.canonicalizedCall(candidate, originalUserText: latestUserText) else {
                                    finishRejectedMemory(candidate)
                                    return
                                }
                                call = normalized
                            }
                            pendingCorrection = nil

                        case nil:
                            if rememberRequiredForTurn,
                               let candidate = call,
                               candidate.name != ToolID.remember.rawValue {
                                guard !correctionWasUsed else {
                                    finishRejectedMemory(nil)
                                    return
                                }
                                pendingCorrection = .remember(rejectedCall: nil)
                                correctionWasUsed = true
                                transcript.append(ChatTurn(role: .assistant, content: raw))
                                transcript.append(ChatTurn(
                                    role: .user,
                                    content: RememberTool.requiredCallInstruction
                                ))
                                continue
                            }
                            if let candidate = call,
                               candidate.name == ToolID.remember.rawValue {
                                if let normalized = RememberTool.canonicalizedCall(candidate, originalUserText: latestUserText) {
                                    call = normalized
                                } else {
                                    guard !correctionWasUsed else {
                                        finishRejectedMemory(candidate)
                                        return
                                    }
                                    pendingCorrection = .remember(rejectedCall: candidate)
                                    correctionWasUsed = true
                                    transcript.append(ChatTurn(role: .assistant, content: raw))
                                    transcript.append(ChatTurn(
                                        role: .user,
                                        content: RememberTool.canonicalRetryInstruction
                                    ))
                                    continue
                                }
                            }
                        }

                        // A tools-on model may claim it remembered something without issuing a call. If the
                        // latest user explicitly asked to remember/save, or the prose itself claims success,
                        // one runtime-enforced remember-only correction is required. A second prose answer
                        // fails deterministically; it is never committed as the assistant's final answer.
                        guard let call else {
                            let rememberAvailable = registry.tool(named: ToolID.remember.rawValue) != nil
                            let rememberRequired = rememberRequiredForTurn
                                || (rememberAvailable && Self.claimsMemoryWasSaved(bufferedText))
                            if rememberRequired {
                                continuation.yield(.discardAnswer)
                                guard !correctionWasUsed else {
                                    // The correction was already spent, so this prose is the model's last
                                    // word on the turn — surface it rather than trading a real answer for
                                    // a bookkeeping notice.
                                    finishRejectedMemory(nil, fallbackAnswer: bufferedText)
                                    return
                                }
                                correctionWasUsed = true
                                pendingCorrection = .remember(rejectedCall: nil)
                                answerDiscardedForCorrection = bufferedText
                                transcript.append(ChatTurn(role: .assistant, content: raw))
                                transcript.append(ChatTurn(
                                    role: .user,
                                    content: RememberTool.requiredCallInstruction
                                ))
                                continue
                            }
                            if buffersPassText, !bufferedText.isEmpty {
                                continuation.yield(.answer(bufferedText))
                            }
                            continuation.yield(.done(lastStats))
                            continuation.finish()
                            return
                        }

                        guard let tool = registry.tool(named: call.name) else {
                            continuation.yield(.answer("\n_(No tool named “\(call.name)”.)_"))
                            continuation.yield(.done(lastStats))
                            continuation.finish()
                            return
                        }

                        // A weak quantized model can repeat the exact same call forever. Compare a stable
                        // name+arguments fingerprint so identical retries do not execute twice, while
                        // legitimate repeated tools with different arguments (two distinct web searches)
                        // remain possible.
                        let fingerprint = Self.fingerprint(call)
                        guard executedCalls.insert(fingerprint).inserted else {
                            transcript.append(ChatTurn(role: .assistant, content: raw))
                            answerOnly = true
                            continue
                        }

                        // Run the tool locally, feed the result back, and loop.
                        try Task.checkCancellation()
                        continuation.yield(.toolCall(call))
                        let result = await tool.execute(argumentsJSON: call.argumentsJSON)
                        try Task.checkCancellation()
                        continuation.yield(.toolResult(call, result))
                        transcript.append(ChatTurn(role: .assistant, content: raw))
                        transcript.append(ChatTurn(
                            role: .user,
                            content: ToolPrompt.frameToolResult(result, name: call.name, dialect: dialect)
                        ))
                        executionCount += 1

                        // Remembering is side-effect bookkeeping, never a source for another tool. Every
                        // remember result is terminal in tool-selection: success/duplicate gets one
                        // tool-free synthesis; an execution error gets an application-owned failure and no
                        // further model call. Other selected
                        // tools remain freely chainable up to three executions, covering the shipped
                        // search→fetch and location→search→fetch/second-search skills without the old
                        // four-tool-plus-final runaway.
                        if call.name == ToolID.remember.rawValue {
                            if result.hasPrefix("Error:") {
                                continuation.yield(.answer(RememberTool.rejectedMemoryReply))
                                continuation.yield(.done(lastStats))
                                continuation.finish()
                                return
                            }
                            answerOnly = true
                        } else if executionCount >= maxIterations {
                            answerOnly = true
                        }
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Canonicalize JSON object key order so semantically identical calls with reordered keys compare
    /// equal. Fall back to trimmed raw text for a malformed-but-parseable dialect shape.
    private static func fingerprint(_ call: ToolCall) -> String {
        let raw = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let arguments = String(data: canonical, encoding: .utf8) else {
            return "\(call.name):\(raw)"
        }
        return "\(call.name):\(arguments)"
    }

    private static func inferredToolName(in malformedBody: String,
                                         schemas: [ToolSchema]) -> String? {
        let lower = malformedBody.lowercased()
        return schemas.map(\.name)
            .sorted { $0.count > $1.count }
            .first { lower.contains($0.lowercased()) }
    }

    /// Did the user ASK for something to be remembered? A match makes the whole turn remember-only: no other
    /// tool is advertised, and a failure to save replaces the reply entirely. That is a heavy consequence
    /// for a substring match, so the two error directions are not equal —
    ///
    /// - a **false negative** costs nothing visible: the model is still told by the `remember` schema to
    ///   save durable facts, and the memory screen accepts anything it misses;
    /// - a **false positive** costs the user their answer to a question the turn was actually about.
    ///
    /// `别忘 / 不要忘 / don't forget / do not forget` were therefore removed. They are far more often an
    /// instruction about the REPLY than a memory request — "别忘了用中文回答", "don't forget the units" — and
    /// each one hijacked the entire turn, leaving the real question unanswered. What remains is phrasing
    /// that only makes sense as a request to store something.
    private static func latestUserRequestsMemory(_ messages: [ChatTurn]) -> Bool {
        guard let content = messages.last(where: { $0.role == .user })?.content else { return false }
        let lower = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("remember ") || lower.hasPrefix("remember:")
            || lower.contains("please remember") || lower.contains("can you remember")
            || lower.contains("could you remember") || lower.contains("would you remember")
            || lower.contains("i want you to remember") || lower.contains("i need you to remember") {
            return true
        }
        let asksToStoreInMemory = ["save", "store"].contains { verb in
            (lower.contains("\(verb) this") || lower.contains("\(verb) that")
                || lower.contains("\(verb) it") || lower.contains("\(verb) my"))
                && (lower.contains(" to memory") || lower.contains(" in memory"))
        }
        if asksToStoreInMemory || lower.contains("save to memory") || lower.contains("store in memory") {
            return true
        }
        return ["请记住", "请帮我记", "帮我记", "记一下", "保存到记忆", "存入记忆"]
            .contains { content.contains($0) }
    }

    private static func claimsMemoryWasSaved(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["nothing was saved", "not saved", "wasn't saved", "couldn't save", "cannot save",
            "can't save", "无法保存", "没有保存", "未保存"].contains(where: lower.contains) {
            return false
        }
        let normalized = lower.replacingOccurrences(of: "_", with: " ")
        if normalized.contains("memory saved") || normalized.contains("saved successfully")
            || normalized.contains("i'll remember") || normalized.contains("i will remember")
            || normalized.contains("i've remembered") || normalized.contains("i have remembered")
            || normalized.contains("i've saved that") || normalized.contains("i have saved that") {
            return true
        }
        return ["已记住", "记住了", "我会记住", "已保存", "保存好了", "记下了"]
            .contains { text.contains($0) }
    }
}
