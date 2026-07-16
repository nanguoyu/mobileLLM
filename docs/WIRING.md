# mobileLLM — Dependency wiring (the 1-bit fork)

> **Status (current):** both engines are wired and shipping. The MLX stack below lives in the
> **`LLMEngineMLX`** package (not `LLMCore`, which stays MLX-free); the second, llama.cpp engine is in
> **`LLMEngineLlama`** (bottom of this file). `Packages/*/Package.swift` are the source of truth for the
> exact pins; the ones quoted here are kept in sync with them. See [ARCHITECTURE.md](ARCHITECTURE.md) for
> how the two engines route.

The only non-trivial dependency is the **1-bit-capable MLX stack**. `bits=1` affine quantized_matmul
is not in upstream MLX (PR [ml-explore/mlx#3161](https://github.com/ml-explore/mlx/pull/3161), unmerged);
it ships in Prism ML's forks.

## The chain

```
LLMEngineMLX ─depends on→  nanguoyu/mlx-swift-lm @ ab01613
                          │  (fork of ml-explore/mlx-swift-lm; ONE repointed dep line)
                          └─depends on→  PrismML-Eng/mlx-swift @ e40e0a5  (prism HEAD; see Toolchain notes)
                                            └─ adds the bits=1 affine Metal kernel (mlx#3161)
```

- **Upstream `mlx-swift-lm`** requires `mlx-swift` `.upToNextMinor(from: "0.31.4")` → `>=0.31.4, <0.32`.
- **PrismML `v0.31.6_prism`** is the fork rebased on mlx-swift **0.31.6** — inside that range, **same
  minor → no API drift, no kernel rebase.** (That tag is SHA `563961d…`; the actual pin is prism **HEAD
  `e40e0a5`** — same 1-bit kernels, a toolchain-compatible tools version — see **Toolchain notes** below.)
- Provides products **MLXLLM** (+ `LLMModelFactory`, `Qwen35TextModel` for `qwen3_5_text` = 27B,
  `Qwen3Model` for `qwen3` = 8B/4B/1.7B) and **MLXLMCommon** (generation loop, tokenizer, chat template).

## LLMEngineMLX/Package.swift (the MLX engine — already wired)

The MLX deps live in `LLMEngineMLX` (never `LLMCore`), so `LLMCore` and the rest stay MLX-free. The engine
pulls the fork plus the two Hugging Face packages its load macros expand against:

```swift
.package(url: "https://github.com/PrismML-Eng/mlx-swift",  revision: "e40e0a5…"),  // bits=1 kernel
.package(url: "https://github.com/nanguoyu/mlx-swift-lm",  revision: "ab01613…"),  // repointed to the fork
.package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),  // Tokenizers
.package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),   // HuggingFace
.package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "603.0.0"),  // match 6.2 toolchain
// target deps: MLX, MLXRandom (mlx-swift); MLXLLM, MLXLMCommon, MLXHuggingFace (mlx-swift-lm);
//              Tokenizers (swift-transformers); HuggingFace (swift-huggingface).
```

## Rules
- **Run MLX code via `xcodebuild` only.** `swift build` *compiles* the fork fine, but `swift run` fails
  at runtime two ways: (1) `@rpath/libc++.1.dylib` not found → add `-rpath /usr/lib` (done on LLMSmoke);
  (2) "Failed to load the default metallib" → only xcodebuild bundles `mlx-swift_Cmlx.bundle/…/default.metallib`.
  So: `xcodebuild -scheme llm-smoke -destination 'platform=macOS,arch=arm64' -derivedDataPath <DD> -skipMacroValidation build`, then run `<DD>/Build/Products/Debug/llm-smoke`.
- The MLX-free packages (AppUI / AppRuntime / LLMCore / MobileLLMUI) keep their fast `swift test` loop.
- **Simulator has no 1-bit Metal path** → validate on real devices only.
- **HF model loader (in `LLMEngineMLX`):** `MLXHuggingFace`'s `#huggingFaceLoadModelContainer`
  macro expands to code referencing `HuggingFace.HubClient` + `Tokenizers.AutoTokenizer`, so the consumer
  must add **swift-transformers** (product `Tokenizers`) and **swift-huggingface** (product `HuggingFace`)
  as direct deps and `import HuggingFace, Tokenizers`, and build with `-skipMacroValidation`.

## Toolchain notes (resolved 2026-07-15)
- The `v0.31.x_prism` *tags* declare swift-tools **6.3** (`experimentalCGen`) → need a Swift 6.3 toolchain.
  The installed toolchain is 6.2.4, so we pin `prism` **HEAD `e40e0a5`** (tools 5.12, same 1-bit kernels).
- Pin **swift-syntax to the 602 line** (Swift 6.2) — the default 603 (6.3 ABI) breaks mlx-swift-lm's macros.

## ✅ Kernel gate PASSED (2026-07-15, macOS)
`quantizedMatmul(bits:1, group 128, affine)` runs on real Metal and **matches** dequantize·matmul
(`maxDiff = 3.05e-05`, finite, non-degenerate). Upstream MLX asserts on bits=1, so this *is* the proof
the fork is correctly wired. Next gate: full Bonsai-8B decode (needs the HF loader deps above).

## Exit path (when mlx#3161 merges upstream)
Repoint `nanguoyu/mlx-swift-lm`'s dep line back to `ml-explore/mlx-swift` (a tagged release that includes
#3161) and retire the fork. Gate the switch on a byte-identical logits check on one checkpoint; the
on-disk affine-quant format is unchanged, so **no re-download**.

---

## llama.cpp engine (the second, user-selectable backend)

**Package `LLMEngineLlama`** (sibling to `LLMEngineMLX`) vendors a prebuilt **`llama.xcframework`** as an
SPM `.binaryTarget` and exposes a `LlamaEngine` actor conforming to `LLMCore.LLMEngine`. No fork, no build
macros → it needs **neither `-skipMacroValidation` nor a special toolchain** (unlike the MLX package).

### Building the XCFramework
`scripts/build-llama-xcframework.sh` clones mainline **ggml-org/llama.cpp @ `956973c`**, runs the official
`./build-xcframework.sh` (Metal **embedded** — no `.metallib` to ship), trims to the **iOS + macOS** slices,
and installs it to `Packages/LLMEngineLlama/Vendor/llama.xcframework` (~355 MB, **gitignored** — a fresh
checkout regenerates it). The framework module is `llama` (`import llama`); headers include `llama.h`,
`ggml-metal.h`, `gguf.h`.

### Why a second engine
MLX keeps weights in **anonymous/dirty** buffers that count fully against the iOS jetsam ceiling; llama.cpp
**mmaps** the GGUF so weight pages are **clean/file-backed and reclaimable**. That's the difference that
lets a 3.8 GB model breathe on an 8 GB phone. To keep the discount we set **`GGML_METAL_NO_RESIDENCY=1` on
iOS** (residency sets would *wire* the GPU buffers and erase it). `use_mmap = true`, `n_gpu_layers = 999`
(0 on the simulator — no Metal there).

### Engine internals (`LlamaEngine.swift`)
- **Model at `load`, context lazily in `run`** sized to `Sampling.contextTokenCap` (n_ctx is fixed at
  context creation on llama.cpp); KV is cleared each generation (we re-prefill the full history).
- **ChatML built by hand** (`buildChatML`) threading the *full* turn history. Thinking-off pre-fills an
  empty `<think>\n\n</think>` after the assistant tag — the same trick Qwen3's template uses — so nothing
  lands in `.reasoning` when the user picks Hidden.
- **Prefill is chunked to `n_batch = 512`** to keep the Metal compute buffer small on phones.
- **`PieceDecoder`** reassembles UTF-8 across token pieces (a CJK/emoji char can split mid-sequence) →
  feeds `ThinkSplitter` → `.reasoning`/`.answer`. **Flush both at stream end** (mirrors the MLX path).
- Sampler chain: penalties → top-k → top-p → temp → dist (greedy at temp ≤ 0).
- `peakMemoryBytes` = sampled `phys_footprint` (the number iOS jetsams on).

### Routing
`@main` builds `RoutingEngine(engines: [.mlx: MLXLLMEngine(), .llamaCpp: LlamaEngine()])`. The router loads
each variant on the engine its `backend` names and **unloads the other engine on a cross-engine switch**, so
two weight stacks never co-reside — the on-device memory-safety guarantee. The two GPU stacks (ggml C syms
vs mlx C++) link together without symbol collision.

### ✅ Gates PASSED (2026-07-15, macOS)
- **Day-0**: `llama-simple -m Bonsai-8B-Q1_0.gguf` on mainline + Metal → "The capital of France is Paris."
- **27B mainline-confirmed**: `Bonsai-27B-Q1_0.gguf` (3.8 GB, hybrid GDN) decodes at **11.2 tok/s** — the
  log shows `kernel_gated_delta_net`, `kernel_ssm_conv`, and `kernel_mul_mv_q1_0` all on Metal → **no
  llama.cpp fork needed**; one mainline framework serves every Bonsai size. 27B stays *experimental* for
  MEMORY, not arch.
- **Engine end-to-end**: `swift run llama-smoke Bonsai-8B-Q1_0.gguf` → correct answer via
  `LlamaEngine → PieceDecoder → ThinkSplitter → EngineDelta`, 23.6 tok/s Release, peak 1218 MB.
- **Integration**: the app **builds for macOS and iOS-device** (codesigned, `llama.framework` embedded)
  with both engines linked. Package tests green (`PieceDecoder`, `ChatML`).

### Rules
- Running `llama-smoke` / `llama-simple` locally needs **`DYLD_FALLBACK_LIBRARY_PATH=/usr/lib`** (libc++ rpath).
- Give every `LLMEngineLlama` target an **explicit `path:`** in Package.swift — without it, xcodebuild's
  package resolution reported "overlapping sources" for the test target (SwiftPM path inference).
- **Simulator has no Metal** → `n_gpu_layers = 0` there; validate GGUF generation on real devices.
