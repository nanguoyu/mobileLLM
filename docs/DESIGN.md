# mobileLLM — Design

*An open-source, private, on-device runner for open-weight LLMs on macOS + iOS (Swift + MLX). Everything
runs on the user's own silicon — no account, no cloud, nothing leaves the device. It is built to host
many open-weight model families over time: Prism ML's Bonsai (1-bit) is the first included, and the goal
is **≥7 families**. Two inference engines sit behind one protocol — an **MLX** engine today, and a
**llama.cpp** engine planned for large models on memory-tight phones (mmap'd weights). The 1-bit weight
format (`Q1_0`) is already merged into mainline llama.cpp.*

Status: **design approved-for-build pending sign-off.** Produced from a multi-agent design pass
(foundation audit · engine wiring · model catalog · architecture · product/UX · adversarial critique),
2026-07-15. Every "verified" number below comes from a Hugging Face primary source (config.json /
safetensors index), not a model card.

---

## 1. What we're building & the honest constraints

A commercial-grade, private chat app (ChatGPT-app calm × Raycast keyboard-speed × Linear structure)
where the model runs on the user's own silicon. Two facts shape **every** decision:

1. **Weights must be RESIDENT (MLX engine).** LLM decode is bandwidth-bound at batch-1: streaming
   weights from flash = seconds/token (unusable). On the MLX engine there is **no** two-phase /
   weight-streaming rung — a model either fits in RAM or it cannot run, and the only memory lever is
   the KV cache. (Fitting a large model on a memory-tight phone is exactly what the planned llama.cpp
   engine's mmap'd weights are for, trading tok/s for footprint.)
2. **1-bit needs the fork.** `bits=1` is not in upstream MLX (only {2,3,4,5,6,8}); the 1-bit Metal
   kernel lives in `ml-explore/mlx` PR **#3161** (open/unmerged) and ships in the PrismML forks
   (`PrismML-Eng/mlx`, `PrismML-Eng/mlx-swift@prism`). **mobileLLM uses the fork**, quarantined behind
   the `LLMCore` package so it is the only place in the app that ever sees a non-upstream MLX.

### 1.1 Verified model facts (HF, live)

| Model | Repo | model_type | Layers / hidden / vocab | Native ctx | On-disk |
|---|---|---|---|---|---|
| **Bonsai-27B** | `prism-ml/Bonsai-27B-mlx-1bit` | `qwen3_5_text` (hybrid GDN) | 64 (48 linear + **16** full) / 5120 / 248 320 | 262 144 | **5.13 GB** |
| Ternary-27B | `prism-ml/Ternary-Bonsai-27B-mlx-2bit` | `qwen3_5_text` | same | 262 144 | **8.49 GB** |
| **Bonsai-8B** | `prism-ml/Bonsai-8B-mlx-1bit` | **`qwen3`** (dense) | 36 / 4096 / 151 669 | 65 536 | **1.28 GB** |
| Ternary-8B | `prism-ml/Ternary-Bonsai-8B-mlx-2bit` | `qwen3` | 36 / 4096 / 151 669 | 65 536 | **2.30 GB** |
| Bonsai-4B | `prism-ml/Bonsai-4B-mlx-1bit` | `qwen3` | 36 / 2560 / 151 669 | 32 768 | **0.63 GB** |
| Bonsai-1.7B | `prism-ml/Bonsai-1.7B-mlx-1bit` | `qwen3` | 28 / 2048 / 151 669 | 32 768 | **0.27 GB** |

Quant: `group_size 128`; 1-bit `{bits:1}` (Binary), ternary `{bits:2}` (Ternary). EOS `<|im_end|>`.
Every repo ships `chat_template.jinja` (ChatML/Qwen) and is **thinking-mode capable** (`<think>`).
License **Apache-2.0**.

**Two corrections the research surfaced (important):**
- **Only the 27B is `qwen3_5`** (Gated-DeltaNet hybrid → needs `Qwen35.swift` + `MambaCache`, already
  in mlx-swift-lm). **8B / 4B / 1.7B are plain `qwen3` dense** → the standard `Qwen3.swift` (upstream).
  The small models are architecturally simpler.
- **AWQ-4bit and gguf variants are excluded.** AWQ is AWQ-gemm (non-MLX-native) and bundles an fp16
  vision tower (6–19 GB); gguf is a llama.cpp format (out of scope for the MLX engine — a target for
  the planned second engine). The real stock-MLX path is the **ternary 2-bit** variants.

### 1.2 The feasibility matrix (peak ≈ weights + ~0.5 GB runtime + KV@ctx)

Usable app ceilings: **8 GB iPhone 16 Pro ≈ 5.3 GB** (jetsam ~5.5 GB) · 12 GB iPhone ≈ 8.5 GB ·
Mac ≈ RAM − 4 GB.

| Variant (peak@4K) | 8 GB iPhone 16 Pro | 12 GB iPhone | Mac |
|---|---|---|---|
| **27B 1-bit** — ~5.9 GB | 🔴 **not supported** (weights 5.13 alone ≈ ceiling; short-context can't help — it's the *weights*, not the KV) | 🟢 green | 🟢 green |
| 27B ternary-2bit — ~9.3 GB | 🔴 | 🔴 (weights 8.49 > 8.5) | 🟢 green |
| **8B 1-bit** — ~2.4 GB | 🟢 **green (the iPhone hero)** | 🟢 | 🟢 |
| 8B ternary-2bit — ~3.4 GB | 🟢 | 🟢 | 🟢 |
| 4B / 1.7B (either quant) | 🟢 | 🟢 | 🟢 |

> **Honesty note (critique A1) + user decision:** on paper the 27B weights (5.13 GB) sit right at the
> 8 GB 16 Pro's ceiling before a single KV byte, so it is *expected not to fit* and short-context can't
> help (it's the weights, not the KV). **The user wants to test this empirically on their own 16 Pro**,
> so we do NOT hard-disable it: on the 8 GB phone 27B-1bit renders as an honest **amber "Experimental —
> may be interrupted"** with a **"Try anyway"** that bypasses the soft OOM pre-flight and actually
> attempts the resident load (with the `increased-memory-limit` entitlement + KV-4bit + a low context
> cap for the best shot). If iOS jetsams it, that's the real answer — surfaced as a recoverable event,
> never a silent crash. On Mac + 12 GB iPhone it's a normal green flagship. **8B-1bit stays the safe
> iPhone default.**

**Defaults:** Mac → 27B-1bit · 12 GB iPhone → 27B-1bit · **8 GB iPhone → 8B-1bit** (27B-1bit selectable
as Experimental).

**Accent:** mobileLLM's identity is a **teal "on-device intelligence" hue**. Light `#0D9488` / dark
`#2DD4BF`, with a low-opacity `accentSoft`; the `Theme` token indirection makes this a self-contained ramp.

The 27B's hybrid attention is a genuine selling point: only its **16 full-attn layers grow a KV cache**
(the 48 Gated-DeltaNet layers hold fixed `MambaCache` state) → **near-constant memory as context grows**
(~64 KB/token vs 8B's ~144 KB/token).

---

## 2. Architecture

Three tiers: an **MLX-free foundation layer** (kept inline for v1), a **fork-quarantined engine**, and the app.

```
mobileLLM.app  (Xcode target — build via xcodebuild only; SwiftPM can't compile the fork's Metal)
├── imports  Shared* (copied), LLMCore
├── @MainActor  ChatStore · ConversationVM · views (Chat / History / Models / Settings)
└── ModelManager (actor)  — download + lifecycle orchestration

LLMCore  (Swift package — THE ONLY place the fork appears)
├── LLMEngine (actor) · ThinkSplitter · Sampling · LLMMemoryGovernor · LLMCatalog · schema
└── deps → nanguoyu/mlx-swift-lm (fork; one repointed dep line → PrismML-Eng/mlx-swift@prism)

Shared* — MLX-FREE foundation code (v1: kept inline in the app; see §5)
├── UI: Theme, Motion, Chip, Segmented, studioCard, toastBanner
└── Runtime: ModelDownloader (resumable .part streaming), DownloadMeter, MemoryProbe,
             DeviceTier, ThermalGovernor(clearCache injected), GenerationControl, DurableStore
```

### 2.1 The fork quarantine (SPM identity trick)

`ml-explore/mlx-swift` and `PrismML-Eng/mlx-swift` share SPM identity `mlx-swift` → an app can hold
only one. mobileLLM resolves the **fork** everywhere. The mechanism: fork `mlx-swift-lm` and edit its
**single** dependency line to point at `PrismML-Eng/mlx-swift@prism`; `LLMCore` depends on that fork.
Vendor both fork repos as git submodules under `Packages/` with `.package(path:)` (lets the exact
Metal tree be reviewed before it ships).

> **Critique B1 / B4 (do this FIRST, before any UI):** the real risk is not URL identity — it's whether
> the pinned `mlx-swift-lm` compiles against the fork's `mlx-swift 0.31.1` base (version constraint +
> API drift: `KVCache` shape, `generate` signature). This can require editing the version requirement
> and rebasing the prism kernels onto a newer base — budget multi-day. **Gate the pin on: clean
> `xcodebuild` + a `bits=1` smoke-decode on Bonsai-8B returning non-garbage.** Vendor with
> `--recurse-submodules`; CI-assert the generated `quantized.h` is present. Pin the branch HEAD
> (full mobile-decode kernel stack), not the old `v0.0.1-prism` tag.

### 2.2 `LLMEngine` (actor, in LLMCore)

Sits one level below `ChatSession` so the product can regenerate / edit / branch, trim context, and
instrument peak memory.

```swift
public actor LLMEngine {
    func load(_ id, variant, weightsDir, progress) async throws   // LLMModelFactory.loadContainer
    func unload() async                                            // container=nil; MLX.GPU.clearCache()
    func generate(messages:[ChatTurn], params:Sampling) -> AsyncThrowingStream<Delta, Error>
    enum Delta { case reasoning(String); case answer(String); case done(Stats) }
    struct Stats { promptTokens, genTokens; promptTPS, tokensPerSecond; peakMemoryBytes; stopReason }
    struct Sampling { maxTokens; temperature=0.7; topP=0.95; topK=20; repetitionPenalty=1.05;
                      seed?; thinking=true; contextTokenCap=8192; kvBits=4; quantizedKVStart=256 }
}
```

- **load** → `LLMModelFactory.loadContainer(directory:)` (offline; weights arrive via §5). The factory
  builds `Qwen35Model` (27B) or `Qwen3Model` (8B/4B/1.7B) and rebuilds `Linear→QuantizedLinear` from
  `{bits:1, group_size:128}` — **this is where the fork kernel is mandatory** (upstream asserts
  `bits∈{2,…}` → a first-decode assert is the canary that the wrong mlx-swift resolved). iOS:
  `MLX.GPU.set(cacheLimit: 32<<20)` (weights are resident; give the reuse pool little).
- **generate** runs in `container.perform { … }`: build `UserInput(chat:)`, set
  `additionalContext=["enable_thinking": params.thinking]`, apply the repo `chat_template.jinja` via
  swift-jinja, `resetPeakMemory()`, iterate `MLXLMCommon.generate`. Each chunk → `ThinkSplitter.feed`
  → `.reasoning`/`.answer`; `.info` → `.done(Stats)` reading `MLX.GPU.peakMemory`. Per-token:
  `Task.checkCancellation()` + `thermal.throttleIfNeeded()`.
- **KV 4-bit**: `kvBits=4` quantizes each cache to `QuantizedKVCache` after `quantizedKVStart` tokens;
  it correctly **skips `MambaCache`** (never quantize recurrent state). Enforce `contextTokenCap` by
  history-trim before prefill (always keep the system turn).

### 2.3 State & data flow (tap → streamed token)

`@MainActor @Observable ChatStore` owns all UI state; the engine is an actor; they talk over the
`AsyncThrowingStream`. On send: append user + empty-assistant messages, build `[ChatTurn]` from
history trimmed to `contextTokenCap` + system prompt, launch `genTask`; each delta hops to `@MainActor`
to grow a small `StreamingState { reasoning, answer, phase, stats }`; `.done` commits into the message
and `ConversationStore.save`. Only the streaming strings mutate per token (no array churn → smooth).

> **Critique D1 / D3 / D4 (production correctness):**
> - **Stop is a cooperative boundary-stop**, not instant. A long **prefill** on 27B is one
>   uninterruptible MLX op — Stop lands at the next token boundary. UX says "Stopping…", never "instant".
> - **Backgrounding with 5 GB resident = jetsam bait.** On `scenePhase → .background`: cancel + commit
>   any partial answer, lower `cacheLimit` + `clearCache()`, and for the largest models on 8 GB
>   proactively `unload()` (warm-reload on foreground with a toast). Define this — it's the line between
>   "resumes where I left off" and "app was killed".
> - **Model swap must serialize** cancel → *await GPU drain* → `clearCache()` → load, behind a
>   `switching` state, or two weight sets briefly co-reside (10 GB) or buffers free under a live kernel.

### 2.4 Persistence — files, not SwiftData

Both stores build on `DurableStore` — a recovery skeleton with a versioned Codable manifest, atomic
writes, **corrupt-manifest → backup-not-wipe recovery**, and bad-record skipping. Losing a long chat
is a serious failure — keep that defensive posture.

- **ConversationStore** (actor): one `conversation-<uuid>.json` per thread + a light `index.json`
  (id, title, updatedAt, model, count) for fast list rendering. `Message { role, answer, reasoning?,
  stats?, parentID? (branching) }`. Atomic per-file writes. Single writer (critique G1).
- **ModelRegistryStore** (actor): `registry.json` — per variant install state; source of truth for the
  model manager's tri-state + offline load; rebuildable by re-scanning the weights dir.
- Weights live under a **no-backup-flagged** dir (multi-GB shards must not hit iCloud backup).

### 2.5 Memory / thermal governance & errors

`LLMMemoryGovernor.plan(model, variant, device, context) -> LLMFit` — resident-only, no streaming rung.
`peak = onDiskBytes + ~0.5 GB + KV(ctx)`; `peak ≤ 0.70·ceiling` → green; `≤ ceiling` → amber+maxContext;
`weights alone > ceiling` → gray/unsupported. **OOM pre-flight** in `ModelManager.activate` compares
live `MemoryProbe.availableBytes()` against the peak and throws a **recoverable**
`insufficientMemory(needed, available)` before load (never let jetsam fire). Ship
`increased-memory-limit` (helps 12 GB, never claimed for 8 GB). **Thermal**: the `ThermalGovernor`
calls `throttleIfNeeded()` on a wall-clock boundary (~every 250 ms of decode, not only per-N-tokens);
`.critical` → bounded pause then recoverable `pausedForHeat` (the one hard anti-shutdown guarantee).

One `LLMError` enum surfaced via `.toastBanner` + inline, always with a forward action:
`insufficientMemory` ("Switch to 8B") · `pausedForHeat` (auto-resumes) · `weightsCorrupt` (re-download,
resumes) · `forkKernelMissing` (CI canary) · `cancelled` (commit partial, not an error).

---

## 3. Model catalog (extensible)

```swift
struct LLMModel { id; displayName; family; publisher; summary; license; architecture; variants; default }
struct LLMArchitecture { modelType; swiftModelClass; hidden; layers; vocab; tieWordEmbeddings;
                         attention: AttentionShape; nativeContext; thinkingCapable; eos; chatTemplate }
enum AttentionShape { case fullAttention(kvHeads,headDim,layers)               // dense qwen3
                      case hybridLinear(fullLayers,kvHeads,headDim,recurrent) } // qwen3_5 GDN
struct LLMVariant { quant: QuantSpec; backend: Backend; onDiskBytes; source }
enum Backend { case mlxFork      // 1-bit, PrismML fork
               case mlxStock     // ternary-2bit, upstream bits∈{2,…}
               case awqUnsupported }  // excluded
```

Seed: `bonsai-27b` (qwen3_5, 1-bit + ternary), `bonsai-8b` / `bonsai-4b` / `bonsai-1.7b` (qwen3,
1-bit + ternary). Adding Qwen3/Llama/Mistral later = append an `LLMModel` with the right
`modelType`/`swiftModelClass` (LLMModelFactory keys) — no schema change.

> **Critique E1 (scope honestly):** the **download + UI layer is family-agnostic**, but the **governor's
> memory model is qwen-shaped**. It can't yet express sliding-window attention (Mistral/Gemma — bounded
> KV) or MoE (all experts resident dominates memory). Ship the catalog as **"qwen-family v1"**; add
> `slidingWindow(...)` / `moe(residentExpertBytes:...)` cases when a non-qwen model is actually added,
> so fit-estimates never silently lie.

---

## 4. Product & interaction design (commercial-grade)

North star: **on-device is the hero** — every apparent limitation (offline, thermal, OOM, download)
is truthfully reframed as privacy / control / protection. **Never dead-end** — every error carries a
forward action; irreversible actions get **undo**, not just confirmation.

**Information architecture.** iPhone: 3 tabs — **Chat** (NavigationStack: list → thread), **Models**,
**Settings**; active model is a header subtitle tap-target → quick switcher sheet. Mac:
`NavigationSplitView` (sidebar · conversation list · thread), full menu-bar map (⌘N new, ⌘. stop,
⌘R regenerate, ⌘L switch model, ⌘⇧T thinking, ⌘F find), and a v1.1 `MenuBarExtra` ⌥Space quick-ask.

**The chat surface.** User = right-aligned accent bubble; assistant = full-width document text (no
bubble) so markdown/code read cleanly. Composer: multiline auto-grow; **one morphing Send↔Stop button**
(no reflow); inline **🧠 Thinking** toggle; **live context meter** `1,240 / 8K` (amber @85%, red @98%).
Send → user bubble springs up → **warming shimmer** (owns prefill latency honestly) → tokens stream
with a blinking caret, **incremental markdown**, sticky-bottom autoscroll + a "⌄ N new" pill when
scrolled away.

**The signature interaction — thinking disclosure.** While `<think>` streams, a disclosure auto-expands
("Thinking…", dimmed backstage text); when the first answer token arrives it **auto-collapses** with a
spring, its label morphing to "Thought for 4.2s", spotlighting the answer. Tap to re-read. Setting:
auto-collapse (default) / always-expand / hidden.

> **Critique F1 (correctness):** `ThinkSplitter` must have a **`finish()`** that flushes the residual
> buffer at stream end (it withholds up to `tag.count−1` trailing chars as a possible partial tag —
> without a flush the final chars are lost). Validate `<think>` boundary detection against real Bonsai
> output (special-token vs literal string) on-device before trusting substring matching.

**Rich content.** GFM markdown (scrollable tables), fenced code cards (language label + Copy, syntax
highlight, horizontal scroll — never wrap code), inline-code chips, LaTeX (`$…$`/`$$…$$` with raw-TeX
fallback). Message actions (hover Mac / long-press iPhone): Copy · Regenerate · Read-aloud · **Fork
from here** · rate (local only). **Edit-and-resend** truncates + re-generates with a `‹1/2›` branch
pager (v1.0). **Quiet stats:** per-message footer `Bonsai 8B · 41 tok · 23 tok/s · stop: eos`; opt-in
`⌘⇧I` HUD (tok/s · peak vs ceiling · thermal dot).

**Conversation management.** Recency-grouped list (Pinned/Today/…); auto-title (first user line now,
model-summarized later as a *preemptible idle* job — critique F4); full-text search; new/rename/pin;
**soft-delete + Undo toast** (safety rule against irreversible loss); export MD/JSON; fork.

**Model management.** Catalog cards with the **device-recommended default pinned first**, a
**Segmented** 1-bit ↔ ternary selector that live-updates the fit badge (`LLMFitBadge` bound to `LLMFit`)
+ size, and a **bytes/speed/ETA download meter** with **pause/resume**. One active model
(bandwidth-bound = one resident); switching is first-class (unload→load warm toast).

> **Critique D2 (honest download copy):** the downloader is a `URLSessionDataTask` streaming into
> `.part` — iOS **background** URLSession supports only download/upload tasks, **not** data tasks. So
> **downloading continues only in the foreground** (resume-on-relaunch works). Copy: *"Keep mobileLLM
> open while downloading — it resumes automatically if interrupted."* A true background
> `URLSessionDownloadTask` path (loses mid-file resume) is a later option, not a v1 claim.

**Onboarding (3 calm screens):** promise (private, on-device, no account) → pick first model
(device-recommended pre-selected, honest size, resumable download) → "You're set" with example prompts.
First-run also carries a one-line content note (critique H1: on-device ≠ no liability).

**States, a11y, i18n.** Every state has warm, action-oriented copy (empty / no-model / warming /
streaming / stopped / error / OOM-refusal / thermal-pause / context-full / offline / model-deleted).
VoiceOver labels on all controls (fit-badge text *is* its label); Dynamic Type to XXXL (code scrolls,
never clips); all copy in a `.xcstrings` catalog from day one; motion via `Motion` (Reduce-Motion → 
crossfades, steady caret).

---

## 5. Foundation layer (MLX-free)

**v1 = keep the ~6 MLX-free foundation files inline in the app. Do NOT extract a standalone shared
package yet.**

> **Critique B3:** extracting an `AppFoundation` package now would force designing a stable public API
> before it has more than one real consumer — premature abstraction. The files are small,
> self-contained, and already MLX-free — keep them inline, ship, and defer the shared-package extraction
> to a deliberate later pass, once the API has settled.

| Component | MLX-coupled | v1 action |
|---|---|---|
| Design system: Theme / Motion / Chip / Segmented / studioCard / toastBanner | No | **inline** the tokens + shared controls; add the app's own controls per surface |
| `DownloadMeter` + `formatETA` | No | **inline** verbatim |
| Resumable streaming downloader | No (Foundation + CryptoKit + Hub) | **inline**; parameterize the component-set check (LLM repos ship a flat file list); give it an LLM-specific on-disk manifest name |
| `MemoryProbe` (`phys_footprint`) | No | **inline** verbatim (jetsam-accurate) |
| `DeviceTier` | No | **inline** (LLM-relevant fields only) |
| `ThermalGovernor` | Barely (3× `MLX.GPU.clearCache()`) | **inline with `clearCache` injected** as `@Sendable ()->Void` → MLX-free |
| `DurableStore` recovery skeleton | No | **adapt** → `ConversationStore` / `ModelRegistryStore` |
| `ModelsView` / `SettingsView` view builders | No | **adapt** (retarget to `LLMModel`, `FitBadge` → `LLMFitBadge`) |

The two hardest subsystems — the resumable multi-GB downloader and the thermal governor — are
effectively MLX-free already: that is the big head start.

---

## 6. Roadmap

**MVP — prove the hard tech + one clean loop**
1. **Fork pin + `bits=1` smoke-decode gate FIRST** (Bonsai-8B → non-garbage). This is the schedule risk;
   settle it before any UI.
2. Stand up the MLX-free foundation files inline; bring up `LLMCore` + `LLMEngine`.
3. **8B-1bit + 27B-1bit, iPhone + Mac.** 8B-1bit is the safe green path everywhere; **27B-1bit ships in
   the MVP too** (user decision — they want to personally test whether it runs on the 8 GB 16 Pro). 27B
   is green on Mac/12 GB and an honest amber "Experimental · Try anyway" on the 8 GB phone.
4. One conversation surface: send → stream → thinking disclosure (with `finish()`) → honest
   boundary-Stop → persist (`DurableStore` + corrupt-recovery).
5. Model manager: foreground download (honest copy), fit badge (green/gray), delete.
6. OOM pre-flight + `.critical` thermal pause + the backgrounding policy (§2.3).

**v1.0**
- **27B-1bit on Mac + 12 GB iPhone** (after 8B validates); ternary-2bit stock variants.
- Edit-and-resend **branch pager**, fork-from-here, regenerate-with-different-model.
- Full stats HUD, LaTeX, syntax highlighting, full-text search, `.xcstrings`.

**v1.1+**
- **Second inference engine (llama.cpp)** behind the same protocol — mmap'd weights to fit large models
  on memory-tight phones (the 1-bit `Q1_0` format is already upstream in llama.cpp).
- `AppFoundation` shared-package extraction, once the foundation API has settled (a separately-tested refactor).
- `MenuBarExtra` quick-ask; background `URLSessionDownloadTask` path; vision (mmproj) when MLX supports it.

**Device testing is LAST** (per the user's instruction; the phone isn't connected to the Mac yet).
Simulator has no Metal path for the 1-bit kernels → inference is validated on real devices only.

---

## 7. Risks

| Risk | Impact | De-risk |
|---|---|---|
| **Fork ↔ mlx-swift-lm version/API rebase** | High (schedule) | Compile-gate + `bits=1` smoke-decode **before UI**; vendor submodules with recurse; may need to edit version constraint / rebase kernels — budgeted. |
| **8 GB iPhone × 27B** | Crash | 8B-1bit is the iPhone hero; 27B gray/disabled on 8 GB; OOM pre-flight refuses recoverably. |
| **Backgrounding a 5 GB resident model** | Jetsam kill | Explicit background policy: commit partial, lower cache, unload the largest models. |
| **Metal builds via Xcode only** | CI/dev friction | `xcodebuild` everywhere; copied MLX-free code keeps a fast `swift test` loop. |
| **Supply chain (unmerged #3161)** | Maintenance | Pin exact SHAs; **exit path:** when #3161 merges + ships in a tagged mlx-swift, repoint the fork back to upstream and delete it — the on-disk affine-quant format survives the merge (gate on a byte-identical logits check first), no re-download. |

---

## 8. Decisions (locked 2026-07-15)
1. **Accent** — mobileLLM's own **teal** intelligence hue (light `#0D9488` / dark `#2DD4BF`).
2. **MVP models** — **8B-1bit + 27B-1bit**, iPhone + Mac. 27B ships so the user can personally test the
   8 GB 16 Pro (Experimental · Try-anyway); 8B-1bit is the safe default.
3. **Name** — `mobileLLM` (bundle id TBD at Xcode-project creation, e.g. `wang.mobilellm`).
4. **Repo** — **private** GitHub repo under the user's account.

Device testing is LAST (phone not yet connected to the Mac).
