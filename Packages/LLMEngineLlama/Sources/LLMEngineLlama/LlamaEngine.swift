// SPDX-License-Identifier: MIT

import Foundation
import llama
import LLMCore

/// The llama.cpp on-device engine: loads a GGUF model (mmap'd) and streams tokens through Metal,
/// routing the Bonsai `<think>` block to `.reasoning` and the rest to `.answer` via `ThinkSplitter`.
/// Conforms to `LLMCore.LLMEngine`, so the router drives it exactly like `MLXLLMEngine`.
///
/// Why a second engine at all: MLX keeps weights in anonymous (dirty) buffers that count fully against
/// the iOS jetsam ceiling; llama.cpp memory-maps the GGUF so its weight pages are clean/file-backed and
/// reclaimable under pressure — the difference that lets a 3.8 GB model breathe on an 8 GB phone. To keep
/// that discount we DISABLE Metal residency sets on iOS (they would wire the GPU buffers and erase it).
public actor LlamaEngine: LLMEngine {
    public enum EngineError: Error, Sendable, Equatable, LocalizedError {
        case backendUnavailable
        case weightsNotFound
        case modelLoadFailed
        case contextInitFailed
        case notLoaded
        case decodeFailed
        case noUserMessage
        /// The prompt can't be made to fit the context window even after dropping all droppable history
        /// (system prefix + final user turn alone overflow). Raised instead of truncating mid-token.
        case contextWindowExceeded
        /// A turn carries an image but this model has no vision projector loaded (the variant declares no
        /// mmproj, or its file was missing at load). Raised instead of silently dropping the image.
        case visionUnavailable
        /// An attached image couldn't be decoded / prepared for the vision encoder (corrupt or unsupported
        /// image bytes, or the multimodal tokenizer rejected the prompt+image pairing).
        case imageDecodeFailed

        /// Actionable, user-facing text. Load/context failures point at the real lever (a smaller quant or
        /// freeing memory); the overflow case names the way out (shorter system prompt / longer context).
        public var errorDescription: String? {
            switch self {
            case .backendUnavailable:
                return "The on-device inference backend failed to start. Restart the app; if it keeps failing, this build may be missing its Metal support."
            case .weightsNotFound:
                return "No GGUF weights were found for this model. Re-download the model, then try again."
            case .modelLoadFailed:
                return "Couldn't load the model — most often it's too large for the memory available. Choose a smaller quantization, or free memory by unloading any other model and closing background apps."
            case .contextInitFailed:
                return "Couldn't reserve the decode context at this context length. Pick a shorter context length, or free memory before retrying."
            case .notLoaded:
                return "No model is loaded yet. Load a model before starting a conversation."
            case .decodeFailed:
                return "Generation stopped on an internal decode error. Try again; if it persists, unload and reload the model."
            case .noUserMessage:
                return "There's no user message to respond to."
            case .contextWindowExceeded:
                return "The system prompt and your latest message alone don't fit this model's context window. Shorten the system prompt or raise the context length, then try again."
            case .visionUnavailable:
                return "This model can't read images — its vision component isn't available. Re-download the model to fetch its vision projector, or remove the image and send text only."
            case .imageDecodeFailed:
                return "Couldn't process the attached image. Make sure it's a valid JPEG or PNG, then try again."
            }
        }
    }

    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var context: OpaquePointer?
    /// The multimodal (vision) context from the variant's mmproj, initialized at load when the variant
    /// ships a vision projector whose file is present. `nil` for a text-only load. Freed before the model
    /// on unload/reload (it holds a reference to the text model).
    private var mtmdContext: OpaquePointer?
    private var contextCap: Int = 0          // the n_ctx the live context was built with
    private var contextKVBits: Int = -1      // the Sampling.kvBits the live context's KV cache was built for
    private var loadedID: String?
    private var thinkingCapable = true
    private var eosText = "<|im_end|>"
    private var promptTemplate: PromptTemplate = .chatML
    private var reasoningStyle: ReasoningStyle = .thinkTags

    private let nThreads: Int32 = {
        Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }()

    public init() {}
    public var isLoaded: Bool { model != nil }

    /// The loaded GGUF's declared training context length (`llama_model_n_ctx_train`) — the model's true
    /// capability ceiling. Lets the UI stop inventing a `nativeContext` for community (Explore) checkpoints
    /// that aren't in the catalog. `nil` when nothing is loaded (or the model declares no value). Distinct
    /// from `contextCap`, which is the size of the CURRENTLY-ALLOCATED decode context, not the ceiling.
    public var modelTrainingContext: Int? {
        guard let model else { return nil }
        let n = llama_model_n_ctx_train(model)
        return n > 0 ? Int(n) : nil
    }

    // MARK: - Backend (global, once)

    private static let backendReady: Bool = {
        #if os(iOS)
        // Keep mmap'd weight pages clean/reclaimable — don't let Metal wire them into a residency set.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        #endif
        llama_backend_init()
        return true
    }()

    // MARK: - Loading

    public func load(model modelSpec: LLMCore.LLMModel, variant: LLMCore.LLMVariant, weightsDir: URL,
                     progress: @Sendable @escaping (Double) -> Void) async throws {
        guard Self.backendReady else { throw EngineError.backendUnavailable }
        // Reloading over a resident model must free the predecessor first: llama_model_load_from_file
        // returns a fresh allocation, so overwriting the pointers would leak the old multi-GB model
        // (and `context = nil` below would leak its context — only llama_free releases it).
        if model != nil || context != nil || mtmdContext != nil { await unload() }
        let path = try Self.resolveGGUF(in: weightsDir, preferred: variant.source.fileName)

        var mp = llama_model_default_params()
        mp.use_mmap = true      // the whole memory thesis: weights stay file-backed & reclaimable
        mp.use_mlock = false
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0     // no Metal in the simulator
        #else
        mp.n_gpu_layers = 999   // all layers on the GPU
        #endif

        guard let m = path.withCString({ llama_model_load_from_file($0, mp) }) else {
            throw EngineError.modelLoadFailed
        }
        model = m
        vocab = llama_model_get_vocab(m)
        loadedID = modelSpec.id
        thinkingCapable = modelSpec.architecture.thinkingCapable
        eosText = modelSpec.architecture.eos
        promptTemplate = modelSpec.architecture.promptTemplate
        reasoningStyle = modelSpec.architecture.reasoningStyle
        context = nil; contextCap = 0; contextKVBits = -1

        // Vision: if the variant ships a projector AND its file is present, bring up the multimodal
        // context (mmproj → vision encoder) so image-bearing turns can be prefilled via mtmd. A declared
        // projector whose file is missing leaves `mtmdContext` nil → an image later throws visionUnavailable
        // rather than loading blind. use_gpu on, timings off (per the vision plan).
        if let projector = variant.visionProjector,
           let projectorPath = Self.resolveProjector(in: weightsDir, fileName: projector.fileName) {
            var mp2 = mtmd_context_params_default()
            mp2.use_gpu = true
            mp2.print_timings = false
            mp2.n_threads = nThreads
            mtmdContext = projectorPath.withCString { mtmd_init_from_file($0, m, mp2) }
        }
        progress(1)
    }

    public func unload() async {
        // Free the vision context BEFORE the model — it holds a reference to the text model.
        if let mtmdContext { mtmd_free(mtmdContext) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        mtmdContext = nil
        context = nil; model = nil; vocab = nil; loadedID = nil; contextCap = 0; contextKVBits = -1
    }

    /// (Re)create the decode context sized to `cap` tokens with the requested KV-cache width. Kept separate
    /// from `load` because n_ctx (and the KV-cache dtype) is fixed at context-creation on llama.cpp, while
    /// both are per-generation levers. `kvBits` mirrors `Sampling.kvBits`: 0 = f16 (default), 4 = Q4_0,
    /// 8 = Q8_0. Rebuilds when EITHER the size or the KV width changes.
    private func ensureContext(cap: Int, kvBits: Int) throws {
        let target = max(512, cap)
        if let context, contextCap == target, contextKVBits == kvBits {
            llama_memory_clear(llama_get_memory(context), true)   // fresh KV: we re-prefill full history
            return
        }
        if let context { llama_free(context) }
        // Reset BEFORE the fallible init below: if llama_init_from_model throws out of this function,
        // `context` must not keep pointing at the freed allocation (a retry would double-free, and the
        // reuse branch above would llama_memory_clear freed memory — a user-reachable UAF via kvBits).
        context = nil; contextCap = 0; contextKVBits = -1
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(target)
        cp.n_batch = 512                                          // small compute buffer; prefill is chunked
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        // KV-cache quantization. llama.cpp has no non-Flash-Attention matmul for a quantized V-cache, so a
        // quantized cache REQUIRES Flash Attention (the standard `-fa -ctk qN -ctv qN` config, supported on
        // Metal for all catalog head dims). We therefore force FA on ONLY in the quantized branch; kvBits 0
        // leaves both the f16 cache and the library-default (AUTO) attention untouched — no behavior change.
        switch kvBits {
        case 4:
            cp.type_k = GGML_TYPE_Q4_0; cp.type_v = GGML_TYPE_Q4_0
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        case 8:
            cp.type_k = GGML_TYPE_Q8_0; cp.type_v = GGML_TYPE_Q8_0
            cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        default:
            break   // 0 or unrecognized → f16 cache, attention left at the default
        }
        guard let model, let ctx = llama_init_from_model(model, cp) else {
            throw EngineError.contextInitFailed
        }
        context = ctx
        contextCap = target
        contextKVBits = kvBits
    }

    // MARK: - Generation

    public nonisolated func generate(messages: [ChatTurn],
                                     params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.run(messages: messages, params: params, into: continuation) }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func run(messages: [ChatTurn], params: Sampling,
                     into cont: AsyncThrowingStream<EngineDelta, Error>.Continuation) async {
        do {
            guard model != nil, let vocab else { throw EngineError.notLoaded }
            guard messages.contains(where: { $0.role == .user }) else { throw EngineError.noUserMessage }
            // An image the user is sending NOW with no vision projector loaded fails fast (rather than
            // being silently dropped): the model literally can't see it. Only the FINAL turn is held to
            // that bar — images on HISTORY turns (a thread continued after switching to a text-only
            // model) are dropped instead, because failing there would brick the whole conversation and
            // the past answers already reflect what the previous model saw.
            var messages = messages
            if mtmdContext == nil {
                if let last = messages.last, !last.images.isEmpty {
                    throw EngineError.visionUnavailable
                }
                messages = messages.map { turn in
                    turn.images.isEmpty ? turn : ChatTurn(role: turn.role, content: turn.content)
                }
            }

            try ensureContext(cap: params.contextTokenCap, kvBits: params.kvBits)
            guard let context else { throw EngineError.contextInitFailed }

            let wantThinking = params.thinking && reasoningStyle.canThink
            // `.auto` (Explore's community checkpoints) renders with the GGUF's own embedded template;
            // everything else uses its hand-verified builder. Auto falls back to ChatML if the GGUF
            // carries no template. Wrapped so the overflow fitter can re-render any history subset.
            func renderPrompt(_ msgs: [ChatTurn]) -> String {
                if promptTemplate == .auto, let m = model,
                   let rendered = Self.autoPrompt(msgs, modelPtr: m, reasoning: reasoningStyle, thinking: wantThinking) {
                    return rendered
                }
                return Self.buildPrompt(messages: msgs, template: promptTemplate,
                                        reasoning: reasoningStyle, thinking: wantThinking)
            }

            // Fit the history into the KV window by dropping WHOLE oldest non-system turns and rebuilding —
            // NEVER by chopping tokens off the front, which would shear the system prompt and the template
            // head mid-conversation. Reserve room for the answer; if even {system prefix + final user turn}
            // overflows, fail with a clear error rather than emit garbage from a half-formed prompt. Each
            // attached image also reserves ~600 tokens — its vision-encoder embeddings consume real context.
            let reserve = max(8, params.maxTokens > 0 ? min(params.maxTokens, 256) : 256)
            let budget = contextCap - reserve
            guard budget > 0, let kept = Self.fitMessages(messages, budget: budget, tokenCount: {
                Self.tokenize(vocab: vocab, text: renderPrompt($0), addSpecial: true).count + Self.imageTokenCount($0)
            }) else {
                throw EngineError.contextWindowExceeded
            }

            let sampler = Self.makeSampler(vocab: vocab, params: params)
            defer { llama_sampler_free(sampler) }

            // Prefill. With NO image in the kept history this is byte-identical to before: tokenize the
            // rendered prompt and llama_decode it in n_batch chunks. When a kept turn carries images, prefill
            // through mtmd instead (marker injection → tokenize text+images → chunk-by-chunk encode/decode),
            // which leaves the KV populated so the decode loop below continues from where the prefill ended.
            let prefillStart = Date()
            let nBatch = 512
            let promptTokenCount: Int
            let hasImages = kept.contains { !$0.images.isEmpty }
            if hasImages {
                promptTokenCount = try await mtmdPrefill(kept: kept, context: context,
                                                         renderPrompt: renderPrompt, nBatch: nBatch)
            } else {
                let promptTokens = Self.tokenize(vocab: vocab, text: renderPrompt(kept), addSpecial: true)
                var i = 0
                while i < promptTokens.count {
                    try Task.checkCancellation()
                    let end = min(i + nBatch, promptTokens.count)
                    var chunk = Array(promptTokens[i..<end])
                    let ok = chunk.withUnsafeMutableBufferPointer { buf -> Bool in
                        llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
                    }
                    guard ok else { throw EngineError.decodeFailed }
                    i = end
                    // Hand the cooperative pool a breath between chunks so downloads/saves keep progressing
                    // (these C calls have no suspension points of their own). The yield is an actor-reentrancy
                    // point: bail if a concurrent unload/reload swapped the context out from under us.
                    await Task.yield()
                    guard self.context == context else { throw CancellationError() }
                }
                promptTokenCount = promptTokens.count
            }
            let promptSecs = max(Date().timeIntervalSince(prefillStart), 0.0001)

            // Decode loop. Implicit-open reasoning (Qwen3.5) begins inside the think block. The answer
            // stripper removes a model's answer-wrapper tags (Hunyuan's <answer>…</answer>) so they never
            // reach the UI.
            var splitter = ThinkSplitter(startInThink: reasoningStyle == .thinkTagsImplicitOpen && wantThinking)
            var decoder = PieceDecoder()
            var answerStripper = LiteralStripper(tags: Self.answerStripTags(for: promptTemplate))
            func emit(_ d: ThinkSplitter.Delta) {
                switch d {
                case .reasoning(let s): cont.yield(.reasoning(s))
                case .answer(let s):
                    let out = answerStripper.isNoop ? s : answerStripper.feed(s)
                    if !out.isEmpty { cont.yield(.answer(out)) }
                }
            }
            var genTokens = 0
            var peak: Int64 = 0
            var stop: StopReason = .eos
            let genStart = Date()
            let maxTokens = params.maxTokens

            while true {
                try Task.checkCancellation()
                let tokenID = llama_sampler_sample(sampler, context, -1)

                if llama_vocab_is_eog(vocab, tokenID) { stop = .eos; break }
                if maxTokens > 0 && genTokens >= maxTokens { stop = .maxTokens; break }

                let piece = Self.tokenToPiece(vocab: vocab, token: tokenID)
                let text = decoder.feed(piece)
                if !text.isEmpty {
                    for d in splitter.feed(text) { emit(d) }
                }
                genTokens += 1
                if genTokens & 0b111 == 0 {
                    peak = max(peak, Self.footprintBytes())
                    // Every 8 tokens, let downloads/saves make progress (the decode loop is otherwise a
                    // suspension-free run of C calls that would peg a cooperative-pool thread for minutes).
                    await Task.yield()
                    guard self.context == context else { throw CancellationError() }   // reentrant teardown
                }

                var one = [tokenID]
                let ok = one.withUnsafeMutableBufferPointer { buf -> Bool in
                    llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
                }
                guard ok else { throw EngineError.decodeFailed }
            }

            let tail = decoder.flush()
            if !tail.isEmpty { for d in splitter.feed(tail) { emit(d) } }
            for d in splitter.finish() { emit(d) }
            let strippedTail = answerStripper.isNoop ? "" : answerStripper.flush()
            if !strippedTail.isEmpty { cont.yield(.answer(strippedTail)) }

            let genSecs = max(Date().timeIntervalSince(genStart), 0.0001)
            peak = max(peak, Self.footprintBytes())
            cont.yield(.done(Stats(
                promptTokens: promptTokenCount,
                genTokens: genTokens,
                promptTPS: Double(promptTokenCount) / promptSecs,
                tokensPerSecond: Double(genTokens) / genSecs,
                peakMemoryBytes: peak,
                stopReason: stop)))
            cont.finish()
        } catch is CancellationError {
            cont.yield(.done(Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
                                   peakMemoryBytes: Self.footprintBytes(), stopReason: .cancelled)))
            cont.finish()
        } catch {
            cont.finish(throwing: error)
        }
    }

    // MARK: - Vision (mtmd)

    /// Tokens reserved per attached image in the context-fit math. A vision encoder emits on the order of a
    /// few hundred embedding tokens per image (it varies with the model's tiling / input resolution); ~600
    /// is a deliberately safe upper bound that keeps the KV budget honest without starving the text. It is
    /// a reservation for FITTING only — the true image-token count comes back from mtmd after tokenization.
    static let imageTokenBudget = 600

    /// Total image-token reservation for a set of turns: `imageTokenBudget` per attached image. Zero for a
    /// text-only history, so adding this term to the fit's token count is a no-op on the text path.
    static func imageTokenCount(_ messages: [ChatTurn]) -> Int {
        messages.reduce(0) { $0 + $1.images.count } * imageTokenBudget
    }

    /// Prefix one media marker (each on its own line) per attached image to the content of every
    /// image-bearing turn, leaving text-only turns untouched. The rendered prompt then carries exactly one
    /// marker per image, in turn/image order, which is what `mtmd_tokenize` needs to interleave the image
    /// chunks. Pure (the marker is injected, not read from the C library) so it unit-tests without a model;
    /// with no images anywhere it returns the input unchanged, so the no-image prompt is byte-for-byte as
    /// before.
    static func injectMediaMarkers(_ messages: [ChatTurn], marker: String) -> [ChatTurn] {
        messages.map { turn in
            guard !turn.images.isEmpty else { return turn }
            let prefix = String(repeating: marker + "\n", count: turn.images.count)
            return ChatTurn(role: turn.role, content: prefix + turn.content, images: turn.images)
        }
    }

    /// Multimodal prefill: render the kept turns with a media marker injected per attached image, split the
    /// text + images into mtmd chunks, and evaluate them chunk-by-chunk into the live context's KV cache
    /// (image encode → decode for image chunks, plain decode for text) so the ordinary decode loop can
    /// continue from the end of the prefill. Returns the total prefilled token count (text + image tokens)
    /// for the stats line. Cancellation-checked and yields between chunks (chunk-level granularity is
    /// acceptable), bailing via the reentrancy guard if a concurrent reload swaps the context out.
    private func mtmdPrefill(kept: [ChatTurn], context: OpaquePointer,
                             renderPrompt: ([ChatTurn]) -> String, nBatch: Int) async throws -> Int {
        guard let mtmdCtx = mtmdContext else { throw EngineError.visionUnavailable }
        let marker = String(cString: mtmd_default_marker())
        let promptText = renderPrompt(Self.injectMediaMarkers(kept, marker: marker))

        // Decode each attached image (encoded JPEG/PNG bytes) into an mtmd bitmap, in prompt order.
        var bitmaps: [OpaquePointer?] = []
        defer { for b in bitmaps { if let b { mtmd_bitmap_free(b) } } }
        for turn in kept {
            for image in turn.images {
                try Task.checkCancellation()
                let wrapper: mtmd_helper_bitmap_wrapper = image.withUnsafeBytes { raw in
                    mtmd_helper_bitmap_init_from_buf(mtmdCtx, raw.bindMemory(to: UInt8.self).baseAddress,
                                                     image.count, false)
                }
                guard let bmp = wrapper.bitmap else { throw EngineError.imageDecodeFailed }
                bitmaps.append(bmp)
            }
        }

        // Split the text + bitmaps into chunks (marker count == bitmap count by construction).
        guard let chunks = mtmd_input_chunks_init() else { throw EngineError.imageDecodeFailed }
        defer { mtmd_input_chunks_free(chunks) }
        let tokenizeRC: Int32 = promptText.withCString { cText -> Int32 in
            // text_len in BYTES (matches the text path's `utf8.count`), robust to any embedded null.
            var input = mtmd_input_text(text: cText, text_len: promptText.utf8.count,
                                        add_special: true, parse_special: true)
            var bmpArray = bitmaps
            return bmpArray.withUnsafeMutableBufferPointer { buf in
                mtmd_tokenize(mtmdCtx, chunks, &input, buf.baseAddress, bitmaps.count)
            }
        }
        guard tokenizeRC == 0 else { throw EngineError.imageDecodeFailed }

        // Evaluate chunk-by-chunk into the KV cache; only the last chunk needs logits (for the first sample).
        let nChunks = mtmd_input_chunks_size(chunks)
        var nPast: llama_pos = 0
        for idx in 0..<nChunks {
            try Task.checkCancellation()
            guard let chunk = mtmd_input_chunks_get(chunks, idx) else { throw EngineError.decodeFailed }
            let isLast = idx == nChunks - 1
            var newNPast: llama_pos = 0
            let rc = mtmd_helper_eval_chunk_single(mtmdCtx, context, chunk, nPast, /*seq_id*/ 0,
                                                   Int32(nBatch), /*logits_last*/ isLast, &newNPast)
            guard rc == 0 else { throw EngineError.decodeFailed }
            nPast = newNPast
            await Task.yield()
            guard self.context == context else { throw CancellationError() }   // reentrant teardown
        }
        return Int(mtmd_helper_get_n_tokens(chunks))
    }

    // MARK: - Prompt / tokenizer helpers

    /// Serialize the chat history into the model's prompt string, dispatching on its `PromptTemplate`
    /// and appending the reasoning-control suffix for its `ReasoningStyle`. `thinking` is the effective
    /// per-turn choice (the caller has already ANDed it with the model's capability).
    ///
    /// BOS POLICY (all builders): a builder NEVER writes a literal begin-of-sentence token. Tokenization
    /// runs with `addSpecial: true`, so llama.cpp prepends the GGUF's own BOS whenever its metadata sets
    /// `add_bos_token=true`; a literal BOS in the string would then be a SECOND one (`parse_special: true`
    /// re-tokenizes it), which measurably degrades output. The ChatML/Gemma builders always relied on this;
    /// the DeepSeek/Hunyuan builders now do too. `PromptBuilderTests` pins that no builder output emits one.
    static func buildPrompt(messages: [ChatTurn], template: PromptTemplate,
                            reasoning: ReasoningStyle, thinking: Bool) -> String {
        switch template {
        case .chatML:   return chatMLPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .deepSeek: return deepSeekPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .hunyuan:  return hunyuanPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .gemma:    return gemmaPrompt(messages)
        case .auto:     return chatMLPrompt(messages, reasoning: reasoning, thinking: thinking)  // fallback
        }
    }

    /// Choose the chat turns whose rendered prompt fits `budget` tokens, for context-overflow handling.
    ///
    /// Policy: keep EVERY system turn and the final turn (the user's current query) unconditionally; if the
    /// whole history overflows, drop whole non-system turns oldest-first, re-measuring after each drop, and
    /// stop as soon as it fits — so the system prefix and the live question always survive and the newest
    /// history is preferred. Returns the kept messages, or `nil` when even {all system turns + the final
    /// turn} overflows (the caller fails with `.contextWindowExceeded` rather than truncate mid-token).
    ///
    /// Pure + tokenizer-free: `tokenCount` renders and measures a candidate (injected so the selection is
    /// unit-testable without loading a model). Called at most once per droppable turn.
    static func fitMessages(_ messages: [ChatTurn], budget: Int,
                            tokenCount: ([ChatTurn]) -> Int) -> [ChatTurn]? {
        if tokenCount(messages) <= budget { return messages }
        // Droppable = non-system turns except the final one, oldest first (ascending index order).
        let lastIndex = messages.indices.last
        let droppable = messages.indices.filter { $0 != lastIndex && messages[$0].role != .system }
        var removed = Set<Int>()
        for idx in droppable {
            removed.insert(idx)
            let kept = messages.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
            if tokenCount(kept) <= budget { return kept }
        }
        // Nothing droppable is left: only the system prefix and the final turn remain.
        let minimal = messages.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
        return tokenCount(minimal) <= budget ? minimal : nil
    }

    /// Render the prompt with the template EMBEDDED IN THE GGUF via llama.cpp — the path for arbitrary
    /// community checkpoints (Explore), where no hand-written builder exists. Returns nil when the model
    /// ships no template or llama.cpp can't render it, so the caller can fall back to ChatML.
    static func autoPrompt(_ messages: [ChatTurn], modelPtr: OpaquePointer,
                           reasoning: ReasoningStyle, thinking: Bool) -> String? {
        guard let tmpl = llama_model_chat_template(modelPtr, nil) else { return nil }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        var chat: [llama_chat_message] = []
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
            guard let r = strdup(role), let c = strdup(m.content) else { return nil }
            owned.append(r); owned.append(c)
            chat.append(llama_chat_message(role: UnsafePointer(r), content: UnsafePointer(c)))
        }
        var buf = [CChar](repeating: 0, count: 1 << 15)
        var n = chat.withUnsafeBufferPointer {
            llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, true, &buf, Int32(buf.count))
        }
        if n > Int32(buf.count) {                       // grow once if the template needs more room
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = chat.withUnsafeBufferPointer {
                llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, true, &buf, Int32(buf.count))
            }
        }
        guard n > 0 else { return nil }
        let rendered = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return rendered + thinkSuffix(reasoning, thinking: thinking)
    }

    /// The `<think>` control suffix appended after the assistant-turn opener:
    /// - `.thinkTags` — the model emits its own `<think>`: nothing when thinking, an empty closed block
    ///   to suppress reasoning when not.
    /// - `.thinkTagsImplicitOpen` — the template pre-fills the opening tag: an open `<think>\n` when
    ///   thinking (the stream begins inside the block), the empty closed block to suppress when not.
    static func thinkSuffix(_ reasoning: ReasoningStyle, thinking: Bool) -> String {
        switch reasoning {
        case .none: return ""
        case .thinkTags: return thinking ? "" : "<think>\n\n</think>\n\n"
        case .thinkTagsImplicitOpen: return thinking ? "<think>\n" : "<think>\n\n</think>\n\n"
        }
    }

    /// ChatML (Qwen3/3.5/3.6, MiniCPM5, Bonsai): `<|im_start|>role\n…<|im_end|>\n`, then the assistant
    /// opener + think suffix.
    static func chatMLPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        var s = ""
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
            s += "<|im_start|>\(role)\n\(m.content)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// DeepSeek(-R1 distills): raw system, then each USER turn already carries the trailing `<｜Assistant｜>`
    /// opener; assistant history turns end with the DeepSeek EOS. The model emits its own `<think>`
    /// (explicit), so no opener is pre-filled unless we suppress. The leading `<｜begin▁of▁sentence｜>` is
    /// NOT written here — `tokenize(addSpecial: true)` owns the BOS (see `buildPrompt`'s BOS policy).
    static func deepSeekPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        let eos = "<｜end▁of▁sentence｜>"
        var s = ""
        if let sys = messages.first(where: { $0.role == .system })?.content, !sys.isEmpty { s += sys }
        for m in messages {
            switch m.role {
            case .system: break
            case .user: s += "<｜User｜>\(m.content)<｜Assistant｜>"
            case .assistant: s += "\(m.content)\(eos)"
            }
        }
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// Tencent Hunyuan: raw system, then each USER turn carries the trailing `<｜hy_Assistant｜>` opener;
    /// assistant history turns end with the Hunyuan EOS. Explicit `<think>`. The leading
    /// `<｜hy_begin▁of▁sentence｜>` is NOT written here — `tokenize(addSpecial: true)` owns the BOS (see
    /// `buildPrompt`'s BOS policy).
    static func hunyuanPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        let eos = "<｜hy_place▁holder▁no▁2｜>"
        var s = ""
        if let sys = messages.first(where: { $0.role == .system })?.content, !sys.isEmpty { s += sys }
        for m in messages {
            switch m.role {
            case .system: break
            case .user: s += "<｜hy_User｜>\(m.content)<｜hy_Assistant｜>"
            case .assistant: s += "\(m.content)\(eos)"
            }
        }
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// Google Gemma 4: asymmetric turn markers — `<|turn>role\n…<turn|>\n` per turn, then the model
    /// opener `<|turn>model\n`. Shipped non-thinking (reasoning `.none`): with no thinking token injected
    /// the model answers directly, so no `<|channel>thought` channel appears. BOS is added by the
    /// tokenizer (add_special), not written here. (assistant role → "model".)
    static func gemmaPrompt(_ messages: [ChatTurn]) -> String {
        var s = ""
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "model" }
            s += "<|turn>\(role)\n\(m.content)<turn|>\n"
        }
        s += "<|turn>model\n"
        return s
    }

    static func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) -> [llama_token] {
        let cap = Int32(text.utf8.count + 2)
        var tokens = [llama_token](repeating: 0, count: Int(cap))
        let n = text.withCString { cstr in
            llama_tokenize(vocab, cstr, Int32(text.utf8.count), &tokens, cap, addSpecial, /*parse_special*/ true)
        }
        if n < 0 { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    /// Token → raw bytes (no null terminator). Grows the buffer if a single piece needs > 16 bytes.
    static func tokenToPiece(vocab: OpaquePointer, token: llama_token) -> [CChar] {
        var buf = [CChar](repeating: 0, count: 16)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, /*special*/ false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            return Array(buf.prefix(Int(max(0, n2))))
        }
        return Array(buf.prefix(Int(n)))
    }

    /// A sampler chain matching the app's `Sampling`: penalties → top-k → top-p → temp → dist, or greedy
    /// when temperature is ~0. Order follows the llama.cpp convention.
    static func makeSampler(vocab: OpaquePointer, params: Sampling) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if params.repetitionPenalty > 1.0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, Float(params.repetitionPenalty), 0, 0))
        }
        if params.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if params.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(params.topK))) }
        if params.topP < 1.0 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(params.topP), 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(params.temperature)))
        let seed = params.seed.map { UInt32(truncatingIfNeeded: $0) } ?? 0xFFFF_FFFF   // 0xFFFFFFFF = random
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        return chain
    }

    static func resolveGGUF(in dir: URL, preferred: String?) throws -> String {
        let fm = FileManager.default
        if let preferred {
            let p = dir.appendingPathComponent(preferred)
            if fm.fileExists(atPath: p.path) { return p.path }
        }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let gguf = contents.first(where: { $0.pathExtension.lowercased() == "gguf" }) { return gguf.path }
        // A single-file download may have landed at `dir` itself.
        if dir.pathExtension.lowercased() == "gguf", fm.fileExists(atPath: dir.path) { return dir.path }
        throw EngineError.weightsNotFound
    }

    /// Resolve a vision projector (mmproj) file to load. Order: (1) an absolute `fileName` that exists — the
    /// CLI `--mmproj` escape hatch; (2) `dir/fileName`, where the downloader places it beside the GGUF; (3)
    /// a basename match anywhere in `dir`. Returns nil when the projector isn't present (the caller then
    /// runs text-only, and an image later throws `.visionUnavailable`).
    static func resolveProjector(in dir: URL, fileName: String) -> String? {
        let fm = FileManager.default
        if fileName.hasPrefix("/"), fm.fileExists(atPath: fileName) { return fileName }
        let direct = dir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct.path }
        let base = (fileName as NSString).lastPathComponent
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let hit = contents.first(where: { $0.lastPathComponent == base }) { return hit.path }
        return nil
    }

    /// Literal answer-wrapper tags to strip from the answer stream for a given template. Hunyuan wraps its
    /// final answer in `<answer>…</answer>`; the ChatML/DeepSeek families don't wrap.
    static func answerStripTags(for template: PromptTemplate) -> [String] {
        switch template {
        case .hunyuan: ["<answer>", "</answer>"]
        case .chatML, .deepSeek, .gemma, .auto: []
        }
    }

    /// Current resident footprint (`phys_footprint` — dirty + compressed, the number iOS jetsams on).
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
