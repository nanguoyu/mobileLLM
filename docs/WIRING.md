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
- **Build via `xcodebuild` only** once MLX is in the graph — SwiftPM CLI can't compile the fork's Metal.
  The MLX-free packages (AppUI / AppRuntime / LLMCore-without-MLX) keep their fast `swift test` loop.
- **Simulator has no 1-bit Metal path** → validate `bits=1` decode on real devices only.
- **Acceptance gate:** clean `xcodebuild` + a `bits=1` smoke-decode on Bonsai-8B returning non-garbage.

## Exit path (when mlx#3161 merges upstream)
Repoint `nanguoyu/mlx-swift-lm`'s dep line back to `ml-explore/mlx-swift` (a tagged release that includes
#3161) and retire the fork. Gate the switch on a byte-identical logits check on one checkpoint; the
on-disk affine-quant format is unchanged, so **no re-download**.
