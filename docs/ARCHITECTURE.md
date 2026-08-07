# mobileLLM — Architecture

What the code *is* today (2026-08-06). For the original design intent and how the build diverged from it,
see the frozen [DESIGN.md](DESIGN.md); for the dependency wiring of the local-weight engines, see
[WIRING.md](WIRING.md); the normative requirements live in [spec.md](../spec.md).

mobileLLM is a private, on-device chat app for open-weight LLMs on macOS + iOS. It runs three inference
engines — Apple **MLX** (resident weights), **llama.cpp** (memory-mapped GGUF), and **Apple Intelligence**
(the OS's own model, no weights of ours at all) — behind one protocol, so everything above the engine is
engine-agnostic and unit-testable without a Metal toolchain. Above the engines sits a durable **agent
runtime** (`AgentRuntime`): normal app sends use frozen-input, journaled runs with approvals, budgets, recovery,
optional online models, subagents, and staged workflows. Assembly failure still has a legacy compatibility path.

## Package graph

Ten Swift packages plus the app target. MLX and llama.cpp are quarantined to one package each; the other
eight are MLX-free and keep a fast `swift test` loop.

```
App (mobileLLM.app, Xcode target)
│   assembles RoutingEngine(engines: [.mlx: MLXLLMEngine(), .llamaCpp: LlamaEngine(),
│                                     .apple: AppleLLMEngine()])
│   + the resumable ModelDownloader and the agent executor/online config, injected into
│   AppContainer at composition root
├─▶ AgentContracts ◀─ shared by runtime, sandbox API, UI       versioned run/step/request/   (MLX-free)
│                        approval/budget/workflow contracts
├─▶ AgentRuntime ──▶ AgentContracts, LLMCore     durable executor, SQLite journal, approval  (MLX-free,
│                                                policy, budgets, recovery, subagents,       sqlite3)
│                                                parallel tool batches, workflow orchestrator,
│                                                online Responses API provider
├─▶ AgentSandboxAPI ──▶ AgentContracts           protocol-only sandbox seam (no provider     (MLX-free)
│                                                ships in the open-source build)
├─▶ MobileLLMUI ──▶ AppUI, AppRuntime, LLMCore,  SwiftUI surface + @Observable stores,        (MLX-free)
│                   AgentContracts, AgentRuntime agent run/approval/workflow UI
├─▶ LLMEngineMLX ─▶ LLMCore + AppRuntime + PrismML fork resident-weights MLX engine            (Metal)
├─▶ LLMEngineLlama ▶ LLMCore + AppRuntime + llama.xcframework mmap'd-GGUF llama.cpp engine      (Metal)
└─▶ LLMEngineApple ▶ LLMCore + FoundationModels (weak) Apple Intelligence engine              (MLX-free)

LLMCore ──▶ AppRuntime            catalog + schema, RoutingEngine, governors, legacy tools/MCP, (MLX-free)
                                  context policy, Explore, ThinkSplitter, LLMEngine protocol
AppRuntime  (Foundation + CryptoKit)   downloader, generation/thermal governance, DurableStore (MLX-free)
AppUI       (SwiftUI, no deps)         ink-wash design tokens + shared controls                (MLX-free)
```

The app is built with `xcodebuild` (MLX Metal kernels require it); the eight MLX-free packages test with
plain SwiftPM. Inference is validated on real devices — the simulator has no Metal path for the 1-bit MLX
kernels or GGUF Metal (agent/online/workflow behavior is validated on the simulator instead).

## Agent runtime: durable runs, approvals, online models

`ChatStore` no longer owns the primary agent loop. Sending a message builds a frozen `AgentRunRequestSnapshot`
(context compiler, memory, skills, tool policy) and submits an `AgentRequest` to
`DurableAgentExecutor` → `AgentRunController`. The controller persists every step in a SQLite
`SQLiteRunJournal` (CAS commands, idempotency, recovery), projects run state to `AgentRunStore` for the
UI, and drives the state machine: context compiled → model attempt → tool invocation → synthesis →
terminal/final answer, with explicit waiting states for approval, user input, foreground, and model
resources. The legacy in-process `ToolLoop` remains only as an assembly-failure/test-preview compatibility path.

Submission and finalization atomically write canonical journal message references plus outbox rows. The SQLite
claim/ack primitives feed a production `ConversationOutboxProjector` (App wiring over `SQLiteOutboxProvider` +
`PayloadOutboxProvider`): it claims `acceptedUserMessage` / `finalAnswer` / `deleteConversation` rows, applies them
to the conversation JSON idempotently, and acknowledges them. It drains at bootstrap, on run start/terminal, and on
foreground resume, so crash-safe journal-to-conversation projection is now an implemented guarantee; `ChatStore`'s
live callbacks are an optimistic UI projection the outbox path reconciles (spec §33 gap 2 closed 2026-08-07).

Every external operation — online-model inference and every network/privacy tool call — passes a single
`prepare → authorize → execute` boundary:

- **prepare** builds an immutable `ExternalOperationPlan` (kind, destination, data categories, argument
  digest, response ceiling, timeout);
- **authorize** checks the run's immutable capability ceiling and the step grant, then consults the
  per-conversation approval mode — `ask`, `safePreset` (app-local work, bounded network/private reads, and
  selected online-provider egress auto-approved), or `fullAccess` — and records a durable receipt bound to the exact
  operation;
- **execute** runs inside an authorized boundary (Tool V2 `AuthorizedToolInvocation`, or the model
  boundary for provider inference) that rejects any observed widening of destination/arguments/effect.

Budgets (model attempts, tool invocations, network bytes, generated/persisted bytes, active time) are
accounted in a ledger and attenuate for children; recovery replays journaled boundaries and asks for
reconciliation when an uncertain external write cannot be replayed safely.

### Online models (OpenAI-compatible Responses API)

`ResponsesAPIModelProvider` calls any configured OpenAI-compatible `/responses` endpoint (base URL,
model id, API key resolved from the device Keychain per service). The online model is selected per
conversation, and per-conversation controls cover: approval mode, reasoning on/off + effort
(low/medium/high, sent as `reasoning.effort`), context length, sampling, and the output budget — the
default is **Auto** (omit `max_output_tokens` so the service uses the model's own maximum; a declared
model maximum still bounds the accounting ceiling). Streaming emits reasoning and answer deltas as they
arrive; truncated-`max_output_tokens` runs get one bounded continuation retry that preserves already
streamed text. The provider is itself an authorized external operation
(destination `openai.responses:<serviceID>:<modelName>`), so Ask mode requests bounded conversation consent;
Safe preset and Full access bind authorization without presenting a prompt. Multiple services can be configured in Settings → Online
models; at most one is active.

## Subagents, parallel tool batches, and staged workflows

- **Subagents** (`SubagentSpawner`): a parent run can spawn bounded children with a strict subset of its
  capability ceiling and attenuated budgets (model attempts, tool calls, network bytes, active time).
  Children get their own frozen inputs, journal, structured results, artifacts, and provenance; a
  workflow root is the orchestration anchor for the whole tree.
- **Parallel tool batches**: `AgentRequest.parallelToolBatchLimit` bounds how many tool calls in one
  model turn may execute concurrently (default 1 = serial). Each call keeps its own cancellation token,
  and journal settlement of the batch is serialized with stale-retry protection so parallel execution
  never races the durable ledger.
- **Staged workflows v1** (`/workflow <goal>`): the launcher submits a workflow-root *planner* run that
  emits a structured JSON plan (2–4 phases, each with 1–4 child instructions); if the planner can't
  produce valid JSON after its bounded repair, the deterministic fallback is Explore → Plan → Audit →
  Revise → Verify → Deliver (6 phases, 7 children). `WorkflowOrchestrator` fans out subagents per phase,
  passes structured `WorkflowHandoff`s (including audit findings) into the next phase, and delivers the
  final plan back to the conversation. The UI is message-anchored: a live record row under the
  `/workflow` message shows `phase x/y · subagents a/b · tokens · tool calls`, and the summary page shows
  each phase's acceptance criteria and every child's task/status. This is not the future Dynamic Workflows
  language/graph system: there is no branching DAG, saved definition, or parallel child scheduler.

One workflow integration gap remains: summaries and child IDs persist, but app bootstrap does not yet reconstruct
and advance an unfinished workflow, so end-to-end workflow relaunch is not complete. The tool-policy gap is closed:
workflows inherit only the conversation's allowed tools, and a preflight gate (`WorkflowToolPolicyGate`) pauses the
launch for the user to explicitly enable a missing required research tool instead of force-enabling anything.

## iOS lifecycle and continued processing

`LifecycleBridge` aggregates every connected `UIWindowScene` activation state (iPadOS Split View
included), and on iOS 17 a `UIKitBackgroundDrainProvider` begins a `UIBackgroundTask` when the app
quiesces a run: the controller journals a safe quiescence boundary and leaves resumable work in
`waitingForForeground` — a normal launch never auto-loads a model or silently resumes an unrelated run.
On iOS 26 `ContinuedProcessingBridge` schedules `BGContinuedProcessingTask`s with
`fail-if-not-immediately-runnable` strategy (no delayed queueing), requests `.gpu` only when the engine
needs it and the device supports it, and cancels cleanly on foreground-resume. Runs interrupted by
expiration or system cancellation remain recoverable through the journal.

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
`mlxStock` / `awqUnsupported` → `.mlx`; `llamaCppGGUF` → `.llamaCpp`; `appleSystem` → `.apple`); loading a
variant whose engine differs from the active one `unload()`s the other first, so two GPU weight stacks
never co-reside — the on-device memory-safety guarantee. Because the router only knows the protocol, the
real engines inject at app assembly and the router stays testable with mock engines.

- **`LLMEngineMLX`** — loads resident weights via `LLMModelFactory`; the 1-bit (`bits=1`) path needs the
  PrismML fork kernel (not in upstream MLX). The single package that sees a non-upstream MLX.
- **`LLMEngineLlama`** — vendors a prebuilt `llama.xcframework` (mainline llama.cpp, Metal embedded) as a
  binary target and mmaps the GGUF, so weight pages are clean/file-backed and reclaimable under memory
  pressure. No fork, no build macros.
- **`LLMEngineApple`** — the OS's own model via `FoundationModels`. It owns no weights: `load()` is an
  availability check that throws the real reason, `unload()` is a genuine no-op, and `generate()` builds a
  fresh `LanguageModelSession` per call (our contract passes full history every time, so a retained session
  would replay history onto itself). The framework is weak-linked and every use sits behind `#if
  canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)`, so the package keeps the repo's iOS 17 /
  macOS 14 floor — declaring a 26 platform would make the app unable to link it at all.

  Two consequences worth knowing. `ResponseStream` yields **cumulative** snapshots, so `SnapshotDiffer`
  subtracts what was already emitted — over unicode scalars, not `Character`s, because a cumulative stream
  extends grapheme clusters it already sent. And below macOS 26 a test cannot even *name* the framework's
  types, which is why every decision is factored into pure functions over plain types (`SystemModelStatus`
  is LLMCore's framework-free availability vocabulary; `AppleChatMapping` decides chat + sampling shape),
  leaving the gated code as pure translation. `APPLE_LLM_LIVE=1 swift test` runs one real round-trip on an
  eligible device.

### Local generation lifecycle and thermal control

The two local-weight engines create a fresh `GenerationGovernance` for every stream. Its cooperative
`GenerationControl` implements pause, resume, and cancellation without blocking an executor thread;
`ThermalGovernor` checks cached iOS thermal/memory-pressure state only at safe engine boundaries. MLX can
clear its GPU reuse cache through an injected callback; llama.cpp keeps its mmap ownership unchanged and
uses the same policy for pacing and cancellation.

`GenerationLifecycle` owns a lease for each decode task. Stream termination cancels the matching lease,
and `load` / `unload` cancel and await every retiring lease before replacing a model container or freeing a
native llama context. This is a resource-safety invariant, not just UI state: an old decode task cannot
continue through C/Metal after its model has been released. llama.cpp checks cooperative pause/cancel state
at every token and at each prefill chunk; MLX checks at each streamed response boundary. The heavier
thermal/memory-pressure probe is monotonic-clock limited to at most four times per second on both engines.

**Auto engine policy** (`AppSettings.preferredVariant`, pure + unit-tested): given a model, a device, and
an `EnginePreference` (globally `.auto` — there is no user-facing engine setting; the model card's engine
picker chooses per activation), pick a variant by greenest governor fit, then the device-preferred engine
(**MLX on Mac, llama.cpp on iPhone**), then the model's default quant, then the smaller total download
(text weights plus a required vision projector). In the
simulator the policy never picks MLX (it can't run there); a pinned engine scopes to it, falling back only
if the model lacks it.

## Memory governor + context policy

`LLMMemoryGovernor.plan(model:variant:device:context:) -> LLMFit` is resident-only — decode is
bandwidth-bound at batch-1, so weights must fit in RAM; the only lever is the KV cache. It returns
`.comfortable` (green, peak ≤ 0.70·ceiling), `.tight(maxContext:)` (amber, runs but budget-deep), or
`.unsupported` (gray, the planner estimates that weights exceed its budget — activation remains allowed).

- `peak = totalOnDiskBytes + runtimeOverhead + KV(context)`; `totalOnDiskBytes` includes an `mmproj`
  companion when present, and the MLX planner counts weights as resident
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

Tool calling is an **agent loop above the engine** — no engine changes. Production agent runs execute
tools through **Tool V2** adapters (`LegacyLocalToolAdapter`, `AppWebSearchToolAdapter`,
`AppWebScraperToolAdapter`, `MCPToolV2Adapter`) inside the `prepare → authorize → execute` boundary:
the descriptor carries schema/effects/timeouts/trust, and every network hop runs inside an authorized
`ExternalOperationPlan` (engine hosts, Wikipedia language host, user-configured MCP endpoint, or the
`<serviceID>:<tool>` destination for future server-side native tools). `LLMCore.ToolLoop` remains as the
legacy/simplified loop (for older compatibility paths and its fixture suites): it runs
generate → detect a `<tool_call>{…}</tool_call>` in the stream → run the tool locally → feed a
`<tool_response>` back → generate again, with a three-execution mobile budget. Exact duplicate calls are
suppressed. A successful `remember` goes directly to one tool-free, non-thinking synthesis pass, while
other tools can still form the shipped three-step location/search/read and briefing chains. The final pass
receives no tool schemas, so a weak model cannot turn memory bookkeeping into an unrelated web search.
`ToolPrompt` folds the advertised tool schemas into ordinary system turns; `ToolCallProcessor` extracts
calls from plain text and hides any hallucinated call markup in the final pass.

- **Built-in tools** (`Tool` protocol): `web_search` — real, keyless SERP search across **five engines**
  (DuckDuckGo's html endpoint first, then Bing RSS, Brave, Yahoo, Marginalia), each with heuristic
  parsers over scraped result pages, tracker unwrapping, and a priority fall-through (first engine with
  results wins, ≤6 results per call; failures degrade to a readable string and the fixtures need
  occasional refresh); `fetch_webpage` — readable-text extraction (boilerplate stripped, 6000-char cap,
  content-type guards, and a shared bounded HTTP client). That client accepts only HTTP(S), resolves every
  hostname and rejects the request if any answer is non-public, disables automatic redirects and
  re-validates every hop, and cancels the URLSession data task at a 2 MiB streaming ceiling. `web_search`
  uses the same bounded transport. URLSession cannot pin the validated IP to CFNetwork's later TLS
  connection, so the residual DNS-rebinding race is documented in SECURITY.md rather than hidden;
  `remember`/`recall` — persistent facts in a durable `MemoryStore`
  beside the conversation records (see **Memory** below); `wikipedia` (summary lookup, zh for CJK / en otherwise);
  `CalculatorTool` (pure-Swift recursive-descent evaluator — malformed input returns an error string,
  never traps) and `DateTimeTool`. Calendar, reminder and location tools ride EventKit/CoreLocation
  behind injectable seams (`EventStoring` / `LocationProviding`) — **off by default**, enabled in
  the chat's Tools submenu or Settings → Choose tools; TCC permission is requested when a privacy tool is
  selected (and defensively on first invocation), with denial answered by an instructive string.
  `ToolRegistry.assemble(config:)` is the config-driven builder: a tool materializes
  only when its toggle is on AND its dependency seam is injected, so tests and previews never touch the
  network, EventKit or GPS. Tool results are framed as untrusted external data before being fed back to
  the model.
- **MCP** (`MCPClient`): a self-contained JSON-RPC 2.0 client over **Streamable HTTP** (protocol
  `2025-11-25`), handling both plain-JSON and single-event SSE replies, session ids, and pagination — enough
  to `initialize`, `tools/list`, and `tools/call` a user-configured remote server (sandboxed iOS can't reach
  stdio). `MCPTool` bridges each remote tool into the local `Tool` protocol; `ToolRegistry.build(mcpServers:)`
  assembles the standard tools plus every **enabled** server's tools minus the ones the user muted, skipping
  servers that fail to connect. Master tool access is **off by default** (calls add another full model pass,
  network tools also wait for their endpoint, and small models call tools unevenly).

## Memory

Facts live in a durable, atomic `MemoryStore` beside the conversation records, each tagged with its source
(model-saved or user-added) so the screen can say who wrote it. Records written before that tag existed
decode as model-saved rather than being rejected — `DurableStore` drops what it can't decode, so a stock
synthesized `Codable` would have silently forgotten every fact already saved.

Memory does **not** depend on the model calling `recall`. Before every send, `ChatStore` searches the store
with the outgoing turn (plus one turn of carry-over) and folds a capped block (≤5 facts, ≤400 chars) into
the system turn after the skill block; the context meter charges for it. That's the reliability win — a 2B
model rarely thinks to call a tool, which is what made memory effectively write-only. The mirror
(`MemoryBook`) is refreshed *inside* the generation task, so a fact the model saved last turn is in this
turn's prompt. Model-saved facts use one canonical English `The user …` representation across models and
conversation languages; the visible reply still follows the user's language. `MemoryRanking` is the one
lexical ranker the store, the `recall` tool, and the injector share. When automatic injection gets no
lexical hit (for example, a Chinese question against an English note), it falls back to the newest few
facts; explicit `recall` remains a strict search and asks the model to translate its query to English.

Injection is gated on the memory switch (it *is* an automatic recall) but deliberately **not** on the master
tools switch — the block calls nothing, so typed facts still reach a model running with no tools. That is
why the switch also lives on the Memory screen (Settings → Behavior → Memory), beside the facts it controls.
Everything the store holds is listed there, with provenance and date:
editable, deletable, addable by hand. Chat tool activity shows only save status; the canonical English
payload remains visible here as the single editable source of truth.

There is no background extraction pass: a second generation to mine each turn for facts would double
on-device cost, so v1 is the `remember` tool plus a schema description sharp enough to trigger it.

## Skills

A `Skill` is a named instruction pack (`name`, emoji, one-line summary, instructions) persisted in a
durable JSON store beside the conversation records, seeded once with five built-ins (immutable;
duplicate-to-edit). Activation is **explicit and per-conversation** — the thread records its `skillID`,
the composer's [+] menu switches it, and the system prompt is composed as base + "## Active skill" so the
context meter charges it honestly. There is deliberately no model self-routing of skills in v1: 2–8B
on-device models pick badly from catalogs, so the human picks. Interop: `SkillIO` parses and emits the
AI Edge Gallery community `SKILL.md` format (frontmatter `name`/`description`/`metadata`, markdown body),
with URL normalization for webhost/repo links and honest capability flags on import — a skill whose
instructions invoke the Gallery's `run_js` tool needs a JS runtime this app doesn't ship (a
WKWebView/JavaScriptCore bridge is the v2 path), and `require-secret` declarations aren't wired.

## Image input (vision GGUF) + dictation

Vision runs entirely on the **llama.cpp** side through the `mtmd` API already inside the vendored
xcframework. A vision-capable catalog variant declares its official `mmproj` projector
(`LLMVariant.visionProjector`); the downloader fetches it alongside the weight file (both required for
"installed"), the memory governor counts its bytes, and `LlamaEngine` opens an `mtmd` context at load.
When a turn carries images (`ChatTurn.images`, encoded JPEG/PNG bytes), the templated prompt gets one
media marker per image and prefill runs through `mtmd_tokenize` + chunked `mtmd_helper_eval` before the
normal decode loop continues; with no image the text path is byte-identical. In the UI the composer's
photo button appears only when the active model can actually see (PhotosPicker + paste, ≤3 images,
downscaled to 1568 px JPEG); attachment bytes persist as files under `attachments/` — never inlined into
conversation JSON — and are purged with their turns (hard-delete, delete-all, regenerate/edit truncation).
Accepting a send is conditional on those files reaching disk: a write failure removes any partial files,
rolls back the provisional user/assistant pair, restores the exact draft/images, and never starts inference
with a dangling image reference. Download/storage totals include the projector as well as the text model.
Dictation is a separate composer affordance: `DictationService` (SFSpeechRecognizer + AVAudioEngine,
on-device recognition where supported) streams partial transcripts into the draft.

## Catalog — Featured + Explore

The model library has two tiers.

- **Featured** (`LLMCatalog`, curated, hand-verified): 12 `LLMModel`s across 5 families — Bonsai (Prism ML),
  Qwen (Alibaba), Hunyuan (Tencent), DeepSeek, Gemma (Google). See the README table. The schema
  (`LLMModel` → `LLMVariant` → `LLMArchitecture` / `AttentionShape` / `QuantSpec` / `Backend`) is extensible:
  adding a model is an entry with the right `modelType` / `swiftModelClass`, no schema change. A model can
  ship variants on both local-weight engines (e.g. Bonsai as MLX 1-bit + GGUF), keyed uniquely by repo +
  format tag. The Apple system model is the one entry that ships none: 0 bytes, no filenames, zeroed
  architecture (so KV math computes 0 rather than inventing Apple's unpublished shape), and
  `isSystemProvided` marks it as a category rather than a violation of "every model ships weights".
- **Explore** (`RemoteCatalog`, live): browses `mlx-community` (MLX) and the GGUF orgs (bartowski, unsloth,
  ggml-org, lmstudio-community) via the public Hugging Face Hub API, grouping repos into models-with-variants
  by peeling the quant descriptor off each repo name (pure + unit-tested). A discovered `RemoteModel` becomes
  an `LLMModel` with a **generic** architecture — it loads from the checkpoint's own chat template, no hand
  adapter — which is exactly why Explore models are flagged **Unverified** and their fit uses an estimated
  size. Family and license come only from recognized Hub tags or parsed config metadata; an absent,
  unfamiliar, or conflicting value remains explicit `Unknown / unverified`, never a fabricated Qwen /
  Apache-2.0 label. Hub listing commit SHAs propagate into each variant's `ModelSource.revision`. Once
  picked, a community model flows through the same download / fit / activate pipeline as a curated one.

`ThinkSplitter` is the shared reasoning splitter: it routes text outside `<think>…</think>` to `.answer` and
inside to `.reasoning`, withholds a possible partial-tag tail across chunk boundaries, and **must be
`finish()`-ed** at stream end to flush that tail (or the last few characters are lost). `startInThink: true`
handles the implicit-open convention (DeepSeek-R1 distills stream reasoning first, emitting only the closing tag).

## Model downloads and integrity

`ModelDownloader` streams selected files into resumable `.part` files. The variant's declared revision is
used consistently for both the Hub tree and resolve URLs; each URL path segment is encoded independently,
so a revision containing `/`, spaces, `?`, or `#` cannot change URL structure. Repository identifiers and
remote file paths pass root-confinement checks before any directory or file is created. A revision change
invalidates files and partial data attributed to the previous revision, so a same-sized config or stale
Range prefix cannot cross the revision boundary.

For Hugging Face LFS files, SHA-256 is computed incrementally while bytes are written. A resumed 206 request
first hashes its existing prefix and continues the same digest over new bytes; if a server ignores Range
and returns 200, both the file and digest restart from zero. Size and Hub LFS digest must match before the
`.part` file is promoted. The version-2 manifest records the revision, sizes, and digests. Normal launch
probes trust that download-time attestation plus current sizes to avoid rereading multiple gigabytes;
`verifyDownloadedIntegrity` is the explicit full-file re-audit path. Legacy v1 manifests are a one-time
migration exception: a utility executor hashes them off the MainActor, atomically promotes a valid
snapshot to v2, and never rehashes it on later launches. File-scoped GGUF/mmproj downloads merge their
manifest entries, and install probes require an attested entry for every requested component.

## Persistence, governance, lifecycle

Chat data lives in **files** (not SwiftData), built on `AppRuntime.DurableStore` — versioned Codable
manifest, atomic writes, corrupt-manifest → backup-not-wipe recovery. `AppSettings` persists one small
Codable snapshot to `UserDefaults` (system prompt, thinking mode, tools + MCP servers, dictation language,
sampling, context length, appearance), with hand-written decoding so older snapshots migrate rather than
throw. There is deliberately **no user-facing default-model or engine-preference setting**: each
conversation records the (model, variant) that actually answered it — restamped on every send and restored
only when the user explicitly opens that thread. Launch hydrates the list without selecting a conversation;
`defaultModelID` survives only as an auto-tracked "last successfully used" identity for a new chat. Engine
choice lives on the model card; the Auto policy picks the
greenest-fitting variant per device (and never picks MLX in the simulator, where it can't run — activation
refuses it with a typed error rather than hanging Metal init). Multi-GB weights live under a no-backup Application Support dir so they don't hit iCloud.

`LLMMemoryGovernor` and `DeviceTier` provide advisory fit badges; they never disable an installed model or
refuse a load. Selecting or sending with a model always makes a real attempt, leaving the device as the
authority. Cold launch restores only a model identity and never calls an engine load, so opening the app
cannot allocate several gigabytes. The generation lifecycle above applies cancellation/thermal policy
inside both local engines. When the app backgrounds
(`scenePhase → .background`) it frees the resident model, so a multi-GB model isn't holding RAM while unused.

## Keyboard (the hard-won part)

SwiftUI's automatic keyboard avoidance is **half-broken** in this app's TabView → NavigationStack →
pushed-detail tree: it moves nothing, yet still folds the keyboard height into `safeAreaInsets.bottom`.
The composer therefore does what UIKit apps do (and what FlowDown's `SafeInputView` does): a tracker view
pinned between `keyboardLayoutGuide.top` and the window bottom measures the true overlap
(`KeyboardHeight.swift`), the net lift is computed against **UIKit's** `window.safeAreaInsets.bottom`
(which never includes the keyboard), and the composer pads by it while `.ignoresSafeArea(.keyboard)`
keeps the broken automatic path switched off. Keyboard notifications are not used — sheet present/dismiss
storms strand them. The geometry is pinned by an XCUITest (`UITests/KeyboardUITests.swift`): composer hugs
the bottom at rest, the input row sits above the keyboard while focused, tapping blank space dismisses.

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
