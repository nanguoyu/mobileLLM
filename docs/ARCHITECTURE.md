# mobileLLM — Architecture

What the code *is* today (2026-07-16). For the original design intent and how the build diverged from it,
see the frozen [DESIGN.md](DESIGN.md); for the dependency wiring of the two engines, see [WIRING.md](WIRING.md).

mobileLLM is a private, on-device chat app for open-weight LLMs on macOS + iOS. It runs two inference
engines — Apple **MLX** (resident weights) and **llama.cpp** (memory-mapped GGUF) — behind one protocol,
so everything above the engine is engine-agnostic and unit-testable without a Metal toolchain.

## Package graph

Six Swift packages plus the app target. MLX and llama.cpp are quarantined to one package each; the other
four are MLX-free and keep a fast `swift test` loop.

```
App (mobileLLM.app, Xcode target)
│   assembles RoutingEngine(engines: [.mlx: MLXLLMEngine(), .llamaCpp: LlamaEngine()])
│   + the resumable ModelDownloader, injected into the AppContainer composition root
├─▶ MobileLLMUI ──▶ AppUI, AppRuntime, LLMCore        SwiftUI surface + @Observable stores   (MLX-free)
├─▶ LLMEngineMLX ─▶ LLMCore + PrismML mlx-swift fork   resident-weights MLX engine            (Metal)
└─▶ LLMEngineLlama ▶ LLMCore + llama.xcframework       mmap'd-GGUF llama.cpp engine            (Metal)

LLMCore ──▶ AppRuntime            catalog + schema, RoutingEngine, governors, tools/MCP,       (MLX-free)
                                  context policy, Explore, ThinkSplitter, LLMEngine protocol
AppRuntime  (Foundation + CryptoKit)   downloader, memory/thermal governors, DurableStore      (MLX-free)
AppUI       (SwiftUI, no deps)         ink-wash design tokens + shared controls                (MLX-free)
```

The app is built with `xcodebuild` (MLX Metal kernels require it); the four MLX-free packages test with
plain SwiftPM. Inference is validated on real devices — the simulator has no Metal path for the 1-bit MLX
kernels or GGUF Metal.

## The engine protocol and routing

`LLMCore.LLMEngine` is the whole contract the app codes against:

```swift
protocol LLMEngine: Sendable {
    func load(model:variant:weightsDir:progress:) async throws
    func unload() async
    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error>
}
enum EngineDelta { case reasoning(String); case answer(String); case done(Stats) }
```

Reasoning and answer are already split from the raw token stream by the engine's `ThinkSplitter`; `.done`
closes the stream with `Stats` (tokens, tok/s, peak memory, stop reason).

`RoutingEngine` (an actor conforming to `LLMEngine`) holds one concrete engine per `EngineKind` and keeps
**at most one resident**. A variant names its engine through `variant.backend.engine` (`mlxFork` /
`mlxStock` / `awqUnsupported` → `.mlx`; `llamaCppGGUF` → `.llamaCpp`); loading a variant whose engine
differs from the active one `unload()`s the other first, so two GPU weight stacks never co-reside — the
on-device memory-safety guarantee. Because the router only knows the protocol, the real engines inject at
app assembly and the router stays testable with mock engines.

- **`LLMEngineMLX`** — loads resident weights via `LLMModelFactory`; the 1-bit (`bits=1`) path needs the
  PrismML fork kernel (not in upstream MLX). The single package that sees a non-upstream MLX.
- **`LLMEngineLlama`** — vendors a prebuilt `llama.xcframework` (mainline llama.cpp, Metal embedded) as a
  binary target and mmaps the GGUF, so weight pages are clean/file-backed and reclaimable under memory
  pressure. No fork, no build macros.

**Auto engine policy** (`AppSettings.preferredVariant`, pure + unit-tested): given a model, device, and the
user's `EnginePreference` (`.auto` / `.mlx` / `.llamaCpp`), pick a variant by greenest governor fit, then the
device-preferred engine (**MLX on Mac, llama.cpp on iPhone**), then the model's default quant, then the
smaller download. An explicit pin scopes to that engine, falling back only if the model lacks it.

## Memory governor + context policy

`LLMMemoryGovernor.plan(model:variant:device:context:) -> LLMFit` is resident-only — decode is
bandwidth-bound at batch-1, so weights must fit in RAM; the only lever is the KV cache. It returns
`.comfortable` (green, peak ≤ 0.70·ceiling), `.tight(maxContext:)` (amber, runs but budget-deep), or
`.unsupported` (gray, the weights don't fit — no context helps).

- `peak = onDiskBytes + runtimeOverhead + KV(context)`; the MLX planner counts weights as resident
  anonymous/dirty bytes.
- The **llama.cpp planner** discounts mmap'd weight pages (only a fraction counts against the jetsam
  ceiling) so a big GGUF honestly fits a memory-tight phone — but it reads green only when the *raw* weights
  clear the green line, never on the clean-page gamble alone.
- The **device ceiling** is per tier: the 8 GB iPhone gets a hard 5.3 GB (jetsam ~5.5 GB); a 12 GB phone
  0.72·RAM; a Mac `min(RAM − 4 GB, 0.80·RAM)`.

`ContextPolicy` turns that into the context-length UI. The ladder is powers of two up to 262 144; a model's
`options` are capped at its native context (Qwen3.5 = 256K, a 4K model = 4K); `effective(requested:model:)`
clamps a request to what the model was trained for (asking a 4K checkpoint for 32K degrades it, it doesn't
extend it); `fits` / `largestFitting` re-score each rung through the governor. Hybrid Gated-DeltaNet models
(qwen3_5) grow a KV cache only in their full-attention layers, so memory stays near-constant as context grows.

## Tools + MCP

Tool calling is an **agent loop above the engine** — no engine changes. `ToolLoop` runs
generate → detect a `<tool_call>{…}</tool_call>` in the stream → run the tool locally → feed a
`<tool_response>` back → generate again, up to `maxIterations`. `ToolPrompt` folds the advertised tool
schemas into the system turn (Qwen/ChatML convention); `ToolCallProcessor` extracts calls from plain text.

- **Built-in tools** (`Tool` protocol): `CalculatorTool` (`NSExpression`, on-device, float-promoted),
  `DateTimeTool` (on-device clock), and `WebSearchTool` (Wikipedia summary, zh for CJK / en otherwise —
  the one that touches the network). `ToolRegistry.standard` is the three; `.builtIn` is the two offline ones.
- **MCP** (`MCPClient`): a self-contained JSON-RPC 2.0 client over **Streamable HTTP** (protocol
  `2025-11-25`), handling both plain-JSON and single-event SSE replies, session ids, and pagination — enough
  to `initialize`, `tools/list`, and `tools/call` a user-configured remote server (sandboxed iOS can't reach
  stdio). `MCPTool` bridges each remote tool into the local `Tool` protocol; `ToolRegistry.build(mcpServers:)`
  assembles the standard tools plus every **enabled** server's tools minus the ones the user muted, skipping
  servers that fail to connect. Tools are **off by default** (they add a round-trip and small models call them
  unevenly).

## Catalog — Featured + Explore

The model library has two tiers.

- **Featured** (`LLMCatalog`, curated, hand-verified): 12 `LLMModel`s across 5 families — Bonsai (Prism ML),
  Qwen (Alibaba), Hunyuan (Tencent), DeepSeek, Gemma (Google). See the README table. The schema
  (`LLMModel` → `LLMVariant` → `LLMArchitecture` / `AttentionShape` / `QuantSpec` / `Backend`) is extensible:
  adding a model is an entry with the right `modelType` / `swiftModelClass`, no schema change. A model can
  ship variants on both engines (e.g. Bonsai as MLX 1-bit + GGUF), keyed uniquely by repo + format tag.
- **Explore** (`RemoteCatalog`, live): browses `mlx-community` (MLX) and the GGUF orgs (bartowski, unsloth,
  ggml-org, lmstudio-community) via the public Hugging Face Hub API, grouping repos into models-with-variants
  by peeling the quant descriptor off each repo name (pure + unit-tested). A discovered `RemoteModel` becomes
  an `LLMModel` with a **generic** architecture — it loads from the checkpoint's own chat template, no hand
  adapter — which is exactly why Explore models are flagged **Unverified** and their fit uses an estimated
  size. Once picked, a community model flows through the same download / fit / activate pipeline as a curated one.

`ThinkSplitter` is the shared reasoning splitter: it routes text outside `<think>…</think>` to `.answer` and
inside to `.reasoning`, withholds a possible partial-tag tail across chunk boundaries, and **must be
`finish()`-ed** at stream end to flush that tail (or the last few characters are lost). `startInThink: true`
handles the implicit-open convention (DeepSeek-R1 distills stream reasoning first, emitting only the closing tag).

## Persistence, governance, lifecycle

Chat data lives in **files** (not SwiftData), built on `AppRuntime.DurableStore` — versioned Codable
manifest, atomic writes, corrupt-manifest → backup-not-wipe recovery. `AppSettings` persists one small
Codable snapshot to `UserDefaults` (default model, engine preference, system prompt, thinking mode, tools +
MCP servers, sampling, context length, appearance), with hand-written decoding so older snapshots migrate
rather than throw. Multi-GB weights live under a no-backup Application Support dir so they don't hit iCloud.

`MemoryProbe` reads `phys_footprint` (the number iOS jetsams on); an OOM pre-flight refuses recoverably
before a load that wouldn't fit; `ThermalGovernor` throttles on a wall-clock boundary and pauses on
`.critical`; `DeviceTier` classifies the hardware. When the app backgrounds (`scenePhase → .background`) it
frees the resident model, so a multi-GB model isn't holding RAM while unused.

## Design tokens (ink-wash 水墨)

`AppUI.Theme` is the design system: an ink-wash palette sampled from the app icon — warm rice-paper (宣纸)
surfaces, ink text, mountain-grey (远山) neutrals, and the seal's cinnabar red (印章红) as the single accent.
Colors are dynamic (resolve per light/dark scheme at draw time, no asset catalog); fit badges use a calm
celadon-green / ochre-amber / mountain-grey ramp. `Motion` routes every animation so Reduce-Motion collapses
springs to short eases. Shared controls: `Chip`, `Segmented` (sliding `matchedGeometryEffect` tile),
`StudioButtonStyle`, `studioCard`, `toastBanner`, `DotLabelStyle`.

The shell (`RootView`): **iOS** is a `TabView` — Chat (NavigationStack list → thread), Models, Settings;
**macOS** is a `NavigationSplitView` (conversation sidebar + thread, ⌘N new). The Models screen is a
`Featured` / `Explore` segmented split.
