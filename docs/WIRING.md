# mobileLLM — Dependency wiring (the 1-bit fork)

The only non-trivial dependency is the **1-bit-capable MLX stack**. `bits=1` affine quantized_matmul
is not in upstream MLX (PR [ml-explore/mlx#3161](https://github.com/ml-explore/mlx/pull/3161), unmerged);
it ships in Prism ML's forks.

## The chain

```
LLMCore  ─depends on→  nanguoyu/mlx-swift-lm @ branch prism-1bit   (commit c8ed23a)
                          │  (fork of ml-explore/mlx-swift-lm; ONE repointed dep line)
                          └─depends on→  PrismML-Eng/mlx-swift @ 563961d  (branch v0.31.6_prism)
                                            └─ adds the bits=1 affine Metal kernel (mlx#3161)
```

- **Upstream `mlx-swift-lm`** requires `mlx-swift` `.upToNextMinor(from: "0.31.4")` → `>=0.31.4, <0.32`.
- **PrismML `v0.31.6_prism`** is the fork rebased on mlx-swift **0.31.6** — inside that range, **same
  minor → no API drift, no kernel rebase.** (Pin SHA `563961d…`.)
- Provides products **MLXLLM** (+ `LLMModelFactory`, `Qwen35TextModel` for `qwen3_5_text` = 27B,
  `Qwen3Model` for `qwen3` = 8B/4B/1.7B) and **MLXLMCommon** (generation loop, tokenizer, chat template).

## LLMCore/Package.swift (when the MLX engine is added)

```swift
.package(url: "https://github.com/nanguoyu/mlx-swift-lm", revision: "<c8ed23a full SHA>"),
// target deps: .product(name: "MLXLLM", package: "mlx-swift-lm"),
//              .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
```

## Rules
- **Run MLX code via `xcodebuild` only.** `swift build` *compiles* the fork fine, but `swift run` fails
  at runtime two ways: (1) `@rpath/libc++.1.dylib` not found → add `-rpath /usr/lib` (done on LLMSmoke);
  (2) "Failed to load the default metallib" → only xcodebuild bundles `mlx-swift_Cmlx.bundle/…/default.metallib`.
  So: `xcodebuild -scheme llm-smoke -destination 'platform=macOS,arch=arm64' -derivedDataPath <DD> -skipMacroValidation build`, then run `<DD>/Build/Products/Debug/llm-smoke`.
- The MLX-free packages (AppUI / AppRuntime / LLMCore) keep their fast `swift test` loop.
- **Simulator has no 1-bit Metal path** → validate on real devices only.
- **HF model loader (later, for the real engine):** `MLXHuggingFace`'s `#huggingFaceLoadModelContainer`
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
