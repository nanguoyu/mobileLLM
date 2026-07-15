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
    public enum EngineError: Error, Sendable, Equatable {
        case backendUnavailable
        case weightsNotFound
        case modelLoadFailed
        case contextInitFailed
        case notLoaded
        case decodeFailed
        case noUserMessage
    }

    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var context: OpaquePointer?
    private var contextCap: Int = 0          // the n_ctx the live context was built with
    private var loadedID: String?
    private var thinkingCapable = true
    private var eosText = "<|im_end|>"

    private let nThreads: Int32 = {
        Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }()

    public init() {}
    public var isLoaded: Bool { model != nil }

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
        context = nil; contextCap = 0
        progress(1)
    }

    public func unload() async {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil; model = nil; vocab = nil; loadedID = nil; contextCap = 0
    }

    /// (Re)create the decode context sized to `cap` tokens. Kept separate from `load` because n_ctx is
    /// fixed at context-creation on llama.cpp, while the user's context length is a per-generation lever.
    private func ensureContext(cap: Int) throws {
        let target = max(512, cap)
        if let context, contextCap == target {
            llama_memory_clear(llama_get_memory(context), true)   // fresh KV: we re-prefill full history
            return
        }
        if let context { llama_free(context) }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(target)
        cp.n_batch = 512                                          // small compute buffer; prefill is chunked
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        guard let model, let ctx = llama_init_from_model(model, cp) else {
            throw EngineError.contextInitFailed
        }
        context = ctx
        contextCap = target
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

            try ensureContext(cap: params.contextTokenCap)
            guard let context else { throw EngineError.contextInitFailed }

            let prompt = Self.buildChatML(messages: messages, thinking: params.thinking && thinkingCapable)
            var promptTokens = Self.tokenize(vocab: vocab, text: prompt, addSpecial: true)
            // Guard the KV window: keep the most recent tokens if the prompt overflows the context.
            let room = contextCap - max(8, params.maxTokens > 0 ? min(params.maxTokens, 256) : 256)
            if promptTokens.count > room, room > 0 {
                promptTokens.removeFirst(promptTokens.count - room)
            }

            let sampler = Self.makeSampler(vocab: vocab, params: params)
            defer { llama_sampler_free(sampler) }

            // Prefill (chunked to n_batch so the Metal compute buffer stays small).
            let prefillStart = Date()
            let nBatch = 512
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
            }
            let promptSecs = max(Date().timeIntervalSince(prefillStart), 0.0001)

            // Decode loop.
            var splitter = ThinkSplitter()
            var decoder = PieceDecoder()
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
                    for d in splitter.feed(text) { cont.yield(Self.map(d)) }
                }
                genTokens += 1
                if genTokens & 0b111 == 0 { peak = max(peak, Self.footprintBytes()) }

                var one = [tokenID]
                let ok = one.withUnsafeMutableBufferPointer { buf -> Bool in
                    llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
                }
                guard ok else { throw EngineError.decodeFailed }
            }

            let tail = decoder.flush()
            if !tail.isEmpty { for d in splitter.feed(tail) { cont.yield(Self.map(d)) } }
            for d in splitter.finish() { cont.yield(Self.map(d)) }

            let genSecs = max(Date().timeIntervalSince(genStart), 0.0001)
            peak = max(peak, Self.footprintBytes())
            cont.yield(.done(Stats(
                promptTokens: promptTokens.count,
                genTokens: genTokens,
                promptTPS: Double(promptTokens.count) / promptSecs,
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

    // MARK: - Prompt / tokenizer helpers

    /// Build a ChatML prompt from the full turn history. When thinking is off we pre-fill an empty
    /// `<think></think>` block after the assistant tag — the same trick Qwen3's own template uses to make
    /// the model skip reasoning (so nothing lands in `.reasoning`).
    static func buildChatML(messages: [ChatTurn], thinking: Bool) -> String {
        var s = ""
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
            s += "<|im_start|>\(role)\n\(m.content)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        if !thinking { s += "<think>\n\n</think>\n\n" }
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

    private static func map(_ d: ThinkSplitter.Delta) -> EngineDelta {
        switch d {
        case .reasoning(let s): .reasoning(s)
        case .answer(let s): .answer(s)
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
