# mobileLLM — Architecture

Implementation reference reviewed on 2026-10-22 against code commit `82933a0`.
Dated validation and open work are tracked in [STATUS.md](STATUS.md). For the original design intent,
see the frozen [DESIGN.md](DESIGN.md); for the dependency wiring of the local-weight engines, see
[WIRING.md](WIRING.md); the normative requirements live in [spec.md](../spec.md).

mobileLLM is a private, on-device chat app for open-weight LLMs on macOS + iOS. It runs three inference
engines — Apple **MLX** (resident weights), **llama.cpp** (memory-mapped GGUF), and **Apple Intelligence**
(the OS's own model, no weights of ours at all) — behind one protocol, so everything above the engine is
engine-agnostic and unit-testable without a Metal toolchain. Above the engines sits a durable **agent
runtime** (`AgentRuntime`): normal app sends use frozen-input, journaled runs with approvals, budgets, recovery,
optional online models, subagents, and dynamic workflows. If runtime assembly fails at launch, sending is
disabled with a visible reason — there is no silent fallback to the legacy in-process tool loop.

## Package graph

Ten Swift packages plus the app target. App assembly is split into frozen-input construction
(`AgentRunInputs.swift`), tool registration (`AgentToolCatalog.swift`), and runtime wiring
(`AgentRuntimeAssembly.swift`). Pure legacy chat context preparation lives in
`ChatContextPreparation.swift` alongside the UI state owner.

 MLX and llama.cpp are quarantined to one package each; the other
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
│                                                policy, budgets, recovery, subagents,       sqlite3 +
│                                                parallel tool batches, dynamic workflow      JavaScriptCore)
│                                                engine + JS runtime, online Responses provider
├─▶ AgentSandboxAPI ──▶ AgentContracts           protocol-only sandbox seam (adapter in runtime     (MLX-free)
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

The app is built with `xcodebuild` (MLX Metal kernels require it); the eight MLX-free product packages
test with SwiftPM on a Mac. AgentContracts and the verification tool use pinned Swift Crypto on Linux;
AgentRuntime still requires Apple frameworks. See [WIRING.md](WIRING.md#toolchain-compatibility) for
compiler/SDK compatibility. Simulator plus online models exercise production agent/workflow behavior;
local GPU/MLX performance and device resource behavior require Apple hardware.

## Agent runtime: durable runs, approvals, online models

`ChatStore` no longer owns the primary agent loop. Sending a message builds a frozen `AgentRunRequestSnapshot`
(context compiler, memory, skills, tool policy) and submits an `AgentRequest` to
`DurableAgentExecutor` → `AgentRunController`. The controller persists every step in a SQLite
`SQLiteRunJournal` (CAS commands, idempotency, recovery), projects run state to `AgentRunStore` for the
UI, and drives the state machine: context compiled → model attempt → tool invocation → synthesis →
terminal/final answer, with explicit waiting states for approval, user input, foreground, and model
resources. The legacy in-process `ToolLoop` survives only for tests and previews that construct a `ChatStore`
without an `AgentRunStore`; production never routes a send through it.

Submission and finalization atomically write canonical journal message references plus outbox rows. The SQLite
claim/ack primitives feed a production `ConversationOutboxProjector` (App wiring over `SQLiteOutboxProvider` +
`PayloadOutboxProvider`): it claims `acceptedUserMessage` / `finalAnswer` / `deleteConversation` rows, applies them
to the conversation JSON idempotently, and acknowledges them. It drains at bootstrap, on run start/terminal, and on
foreground resume, so crash-safe journal-to-conversation projection is now an implemented guarantee; `ChatStore`'s
live callbacks are an optimistic UI projection the outbox path reconciles (spec §33 gap 2 closed 2026-08-07).

Accepted-message payload v2 retains attachment references as well as text. Projection validates content
digests, restores referenced image files, and drains successive pages. Legacy text payloads still decode.
Recovered model requests resolve images against durable artifact metadata rather than an in-memory list.

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
models; at most one is active. Hosts under `api.deepseek.com` are spoken to over the Chat Completions wire
shape (`thinking` + `reasoning_effort`), the path covered by the current live service checks;
every other service uses the Responses shape. Gateway quirks get exactly one bounded retry each: a 400 that
names `max_output_tokens` falls back from Auto to the runtime ceiling, a 400 that names reasoning omits the
directive, a reasoning-only reply is re-asked without reasoning, and byte-identical repeated
`function_call` items with the same identity are collapsed so a chatty gateway cannot drain the tool budget.

Calls retain their provider call IDs, original wire names/arguments, and bounded reasoning state through
the journal and context compiler. Follow-up requests emit matching native call/result pairs only to
the same frozen model selection. Distinct IDs remain distinct even when arguments match. Responses
requests to official OpenAI use `store=false` and include encrypted reasoning for stateless replay.
Older records lacking native IDs retain the explicit text-result fallback. This is client-executed
function calling; provider-hosted tools in spec §15.5 remain deferred.

## Subagents, parallel tool batches, and dynamic workflows

- **Subagents** (`SubagentSpawner`): a parent run can spawn bounded children with a strict subset of its
  capability ceiling and attenuated budgets (model attempts, tool calls, network bytes, active time).
  Children get their own frozen inputs, journal, structured results, artifacts, and provenance; a
  workflow root is the orchestration anchor for the whole tree.
- **Parallel tool batches**: `AgentRequest.parallelToolBatchLimit` bounds how many tool calls in one
  model turn may execute concurrently (default 1 = serial). Each call keeps its own cancellation token,
  and journal settlement of the batch is serialized with stale-retry protection so parallel execution
  never races the durable ledger.
- **Dynamic workflows** (`/workflow <goal>`, spec §34): the primary orchestration path since 2026-08-09.
  The `/workflow` marker may appear anywhere in the message; the remaining text is the goal. `WorkflowLauncher`
  (App) calls the shared `AgentRuntimeAssembly.prepareCoordinatedWorkflow` entry point, also used by
  opt-in native evaluation. It first submits a durable, schema-constrained supervisor decision. It saves the exact
  `CollaborativeWorkflow` v7 program with the original goal, decision, enabled tool IDs and allowed skill catalog in immutable args.
  The supervisor delegates work, reads stored results, continues logical tasks and returns the answer.
  Host delegation remains available when workers have no external tools; explicit user stage requirements
  cannot be replaced by a direct answer solely to minimize agent count.
  The initial planner's `suppressModelTools` flag preserves its frozen catalog for delegation without
  calling tools during preparation. Later coordinator activations can read shared originals and send
  scoped team messages. Per-agent profiles narrow the frozen tools, skills and reasoning policy.
  Canonical local writes remain unavailable without an isolated execution provider; team inbox
  admission uses the separate `agent.message` capability. Recovery uses the original frozen inputs.
  `DynamicWorkflowScriptAnalyzer` still validates the program and accepts archived authored scripts
  under the same V1 vocabulary. The
  accepted script is content-addressed, journaled, and digest-bound to a launch approval (`/workflow` itself
  is the launch intent, so no extra Once/Always/Deny prompt), then `DynamicWorkflowEngine` runs it in
  `JavaScriptCoreWorkflowRuntime`: the script sees only `agent(prompt, options)`, `parallel(thunks)`,
  `spawn`, `waitAny`, `collaborate`, `pipeline(items, ...stages)`, `workflow(name, args)` (one nesting level, digest-pinned saved scripts),
  `phase`, `log`, `serialize`, `unique`, `webEvidence`, `args`, and `budget`. It has no filesystem, network, tool, model, secret,
  clock, or RNG of its own — every `agent()` call becomes an ordinary attenuated subagent run whose tool
  policy is a permitted subset of the conversation's frozen policy. The realm is a logical boundary, not an OS sandbox
  (spec §34.3). Execution is event-sourced in `SQLiteDynamicWorkflowJournal` (hash-chained, CAS appends);
  a rolling per-call prefix key lets a relaunched run reuse the committed prefix (Claude Code's
  started-order rule) and re-collect submitted-but-unsettled children without respawning them; a fair FIFO
  `WorkflowDispatchScheduler` (≤16 permits, default `max(1, min(4, cores − 2))`) and `WorkflowBudgetCoordinator`
  (recovered children form a dispatch fence) bound fan-out; controls are pause / resume / stop /
  restart-agent / reconcile. Hard ceilings include 1 000 agent calls and 4 096 items per collection.
  The wall-clock default is 30 minutes; the contract permits a configured limit up to 24 hours. One
  workflow root can be active per engine. The UI is message-anchored: a live record row under the
  `/workflow` message shows task progress, and the workspace groups logical tasks by actual stage.
  Task details expose stored public results, exact source-result links, assignments, elapsed time and
  usage. Coordinator calls and source live under Execution details. App bootstrap only re-projects persisted workflows —
  it never starts one or loads a model.
- **Staged orchestrator (archived)**: `WorkflowOrchestrator` — the earlier fixed-phase planner/handoff
  design — is retained for `WorkflowLauncher.resume` of legacy summaries that carry a `WorkflowPlan`, and
  for `MultiAgentWorkflowIntegrationTests`. New launches never use it.

The v7 coordinator runs a versioned task graph. Ready consumers start after their own source settles,
while unrelated siblings may continue. Each agent has a persistent session whose activations use the
same cumulative goal budget, including initial planning. Durable input distinguishes acceptance from
inclusion. Late input for a completed agent reopens its task, retains the prior artifact and invalidates
its consumers. A goal cannot finish with required tasks, mandatory input or uncertain effects unresolved.
Informational notices stay durable and can remain unread without starting another activation or blocking
completion; human instructions cannot be downgraded to notices.

Bounded context retains the original user goal, amendments, current graph and recent work. Exact earlier
session content remains available through `agent.read_context`. Shared results and their original tool
observations are readable through `agent.read_artifact`, with producer identity, offsets and digests.
Reading evidence does not repeat a model or network call. The v4 source generator now exists only as a
compatibility test fixture; archived workflows replay their journaled source. The unused fixed six-stage
fallback generator was removed.

A stable task ID tracks revisions and assignments. Reusing an agent key continues its durable session
across tasks; reassignment can select another agent. Each activation remains an ordinary durable child
run. Provider connections and KV-cache retention are separate from this recorded conversation. Other tasks receive selected settled
artifacts. Full outputs stay available even when a preview is truncated. Failures remain labeled and
successful siblings survive. Three identical actions without progress stop the run.

The UI's `WorkflowDisplay` groups continuations by recorded task ID and excludes supervisor calls from
worker counts. `DynamicWorkflowProjection` derives preparation, submission and settlement times, plus
event sequence numbers, from the journal. Dependency links resolve as of consumer preparation, so a
later upstream retry cannot silently change an earlier task's source. The app reads actual child run
states while work is pending. Successful outcomes, failed calls and uncertain effects remain distinct.

`WorkflowTaskDetailView` reads public worker output on demand through the verified value store.
Coordinator notes and provider reasoning are excluded. An observer-only `AgentRunStore` reuses the
existing approval/question controls and commands without a request builder or callbacks into the main
conversation. Parent pause and reconciliation still use workflow controls. The initial planner has its
own recorded run/handle/state and inspector, so a model approval cannot remain hidden behind Planning.
Closing an inspector detaches its subscriptions without stopping work. Rejected receipts expose their
safe failure. Completed history remains accessible, and unchanged projections do not rewrite snapshots
or bump conversation activity times.

The program permits at most 12 worker activations, 24 actual tool calls and 24 coordination decisions.
All normalized model steps, including preparation and tool-related follow-ups, share the 32-step goal
limit. Provider protocol retries consume recorded tokens within a step, so the limit is not a raw HTTP
request count. `await budget.snapshot()` reports actual usage only from settled
calls reached by replay. Unused worker tool allowances become available to later stages, while the durable
runtime ledger still enforces admission and all real consumption. The supervisor writes the final answer itself. Separate writer,
reviewer and consolidation roles are no longer mandatory. A model saying “approved” never established
correctness in the previous design; external task oracles and primary-source audits measure quality.
Blocked work and runtime exhaustion fail visibly. Reconciliation still prevents dispatch or completion
until an uncertain effect is resolved. Saved v1 programs retain their exact source and replay semantics.

See the [current evaluation report](evaluations/2026-10-26-agent-harness.md) for the frozen diagnostic,
subsequent repairs and recorded Simulator outcomes. Current-version six-family qualification and a
matched DSH comparison remain open, along with research coverage, semantic outcome checks and efficiency.
The [source comparison](evaluations/2026-10-23-autonomous-coordination.md) and
[native multi-stage evaluation](evaluations/2026-10-23-multistage-native.md) retain the earlier rationale
and outcomes at their tested revisions.

The JavaScript bridge trims only outer prompt whitespace before host dispatch, prefix hashing and
child construction. Interior newlines and indentation remain intact. Safe host errors are recorded even
when a script catches them and returns a generic message.

`unique(strings)` performs bounded, checkpointed whole-string deduplication in first-occurrence order.
It rejects non-string entries, getters, and oversized collections without invoking a user iterator.
`webEvidence(query?)` reads settled children reached by the current execution prefix and returns journal-derived web
observations, bounded verbatim excerpts, and observed source URLs. It performs no site requests, cannot
select another workflow, excludes non-web and remote tool namespaces, and keeps failed reads distinct
from retrieved pages. Search summaries never become page reads because a model calls them verified.
The packet has exact top-level keys `observations`, `sources`, and `truncated`. Observations contain
per-excerpt truncation flags and content digests; the external content itself remains untrusted.
An optional bounded text query selects up to three verbatim matching windows from the recorded text,
including middle sections absent from the old head/year/tail summary. This is a local read, not another
web request. Matching keeps the previous per-observation byte ceiling, records truncation and retains
the original content digest. Literal query terms and deterministic tie-breaking prevent model prose
from becoming evidence. The supervisor and dependent workers request relevant recorded evidence; cache keys include the query.
The program passes the packet with `serialize(packet)`. Its cache also invalidates when replay reaches
another settled child. Later journaled evidence cannot leak backward into an earlier replayed prompt.

The app's workflow envelope admits 32 model attempts and 24 tool calls by default. Cumulative input
and output capacities cover the admitted model passes while per-attempt ceilings stay unchanged.
The app child builder shrinks its usual strict share to the coordinator's current available capacity.
Capacity calculation, exact request construction and reservation occur without an intervening suspension
point. If a shrinking child builder temporarily has no capacity because other children hold reservations,
it waits for settlement and recomputes. Consumed capacity still fails immediately; fixed requests that
over-reserve are still rejected. Waiting is cancellable. Admission failures before any executor submission
are recorded as settled failures so they cannot remain phantom prepared calls during recovery. Settled and reserved cumulative
usage is subtracted; per-operation ceilings remain reusable. Recovery fences admission until submitted
children settle. A final child can be admitted with zero remaining tool calls without increasing the
workflow envelope. The optional `maxToolCalls` cap narrows each child before reservation. The coordination program declares it on every call, so a four-researcher/two-verifier wave can reserve four calls per researcher and
three per verifier instead of the first verifier hoarding a full six-call share. Zero remaining
tool capacity suppresses advertisement and results in an explicit `tool_choice: none`. Missing
caps retain legacy policy, and changing a cap invalidates the affected replay prefix.

Each model attempt reserves its timeout and cancellation grace from the actual remaining active-time
allowance. Both shrink together after long attempts, leaving time for a bounded repair without raising
the child or workflow limit.

A model-proposed batch larger than its positive remaining allowance is rejected as a whole. If its
authorization, arguments and duplicate checks otherwise pass, one repair pass may propose fewer calls
or a final answer. That pass consumes the existing model and repair budgets. A second oversized batch
fails; no prefix of a rejected batch executes and the tool ceiling never increases.

The app validates that phase and parallel declarations correspond to executable calls; strings and
comments cannot satisfy these checks. The analyzed coordination program awaits asynchronous calls
inside catch blocks. Archived V1 scripts retain their analysis contract. Actual ordering and result
quality still require execution evidence. The coordinator preserves the conversation's reasoning
setting because children inherit its frozen generation policy. Each child receives its own task,
selected input artifacts and real tool counters; an upstream claim about exhausted tools is only data.

A malformed model response gets one immediate repair. A successful repaired tool action ends that
repair phase; a later independent error can consume another repair only if the fixed cumulative
budget permits it. Failure of the immediate repair still terminates. Failed model responses preserve
reported token usage; missing metering after a contract violation conservatively consumes its reserved
token capacity. Cancellation acknowledgements are checked against committed child results before
escalating to reconciliation. After observer loss, cleanup may wait a total of 350 ms for a durable
terminal commit, without resubmitting the child. Cancelled-child usage is preserved in optional `terminalUsage`.
Workflow summary counters also remain visible on failure.

Online children share one admitted root family but use independent attempt lanes, allowing up to
sixteen siblings to overlap requests. Local children retain the shared residency/decode arbiter.
`stallMs` bounds child inactivity with a monotonic deadline reset by durable or streamed progress;
nil or zero disables it. A timeout cancels and settles the durable child. Isolation options requiring
worktrees remain unavailable. Sandbox isolation requires the explicitly configured OpenSandbox adapter,
whose native tools receive a goal-scoped workspace and frozen authority.

Workflows inherit the initiating conversation's exact tool policy without force-enabling tools or imposing a web
requirement, and child ceilings remain strictly attenuated (spec §33 gap 1, closed 2026-08-08). Interrupted
workflows stay visible after relaunch but remain inert until the user acts on them.

## Persistent agent sessions

`AgentSessionSnapshot` separates an agent conversation from its individual runs. `SQLiteRunJournal`
schema 6 stores append-only session revisions, accepted input references, reserved activations and
the messages included in each model request. Schema 5 run history remains readable before an explicit
write performs migration. Session data shares the conversation deletion boundary.

The session APIs on `AgentRunController` accept human steering and queued follow-ups. Request-context
commit includes message identities in the same transaction. Completion checks for pending input in
that transaction too, so a final answer cannot discard a message accepted while generation was active.
New turns reuse `DurableAgentExecutor`, frozen capability and model policy, and prior conversation
content. Prepared activation material is durable before idempotent submission. A failed or cancelled
activation retains unconsumed input for the next explicitly requested turn. Reads never resume work.

Human follow-up turns use the existing per-turn limits and keep their usage separate from the original
workflow report. Autonomous messages and goal amendments use workflow-managed activations under
the original goal budget. They cannot start standalone turns with fresh allowances. The initial planning
run seeds the coordinator session; later assignments record the actual sending coordinator identity. Task details open a separate agent conversation with stored replies, pending/included
message state and the existing approval controls. The workflow retains control of its seed task;
queued follow-ups can start after it completes. Independent follow-ups participate in background
quiescence even when their inspector has closed, and cold sessions require explicit resume.

## iOS lifecycle and continued processing

`LifecycleBridge` aggregates every connected `UIWindowScene` activation state (iPadOS Split View
included), and on iOS 17 a `UIKitBackgroundDrainProvider` begins a `UIBackgroundTask` when the app
quiesces a run: the controller journals a safe quiescence boundary and leaves resumable work in
`waitingForForeground` — a normal launch never auto-loads a model or silently resumes an unrelated run.
The iOS 26 `ContinuedProcessingBridge` adapts `BGContinuedProcessingTask`s with
`fail-if-not-immediately-runnable` strategy (no delayed queueing), requests `.gpu` only when the engine
needs it and the device supports it. Expiration and system cancellation use the quiescence path.
Only a granted, unexpired task exempts its owning conversation/workflow from background quiescence;
submission alone does not. MLX and llama.cpp both request GPU eligibility. Completion reports the
actual terminal success or failure, and resident weights stay available only while eligible work continues.
The physical-device submit/reject/expire/cancel matrix is pending; implementation seams and unit tests
are not acceptance evidence for sustained background execution.

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

llama.cpp reuses exact text-prompt KV prefixes while model/context/KV settings remain compatible,
recomputing the final retained token and invalidating on vision, cancellation, or failure. MLX reports
completion-token counts and timing from `streamDetails`, rather than counting emitted text chunks,
and translates native MLX tool calls through the shared tool parser.

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
`.comfortable` (green, peak ≤ 0.70 × ceiling), `.tight(maxContext:)` (amber, runs but budget-deep), or
`.unsupported` (gray, the planner estimates that weights exceed its budget — activation remains allowed).

- `peak = totalOnDiskBytes + runtimeOverhead + KV(context)`; `totalOnDiskBytes` includes an `mmproj`
  companion when present, and the MLX planner counts weights as resident
  anonymous/dirty bytes.
- The **llama.cpp planner** discounts mmap'd weight pages (only a fraction counts against the jetsam
  ceiling) so a big GGUF honestly fits a memory-tight phone — but it reads green only when the *raw* weights
  clear the green line, never on the clean-page gamble alone.
- The **device ceiling** is per tier: the 8 GB iPhone gets a hard 5.3 GB (jetsam ~5.5 GB); a 12 GB phone
  0.72 × RAM; a Mac `min(RAM − 4 GB, 0.80 × RAM)`.

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
  content-type guards, and a shared bounded HTTP client). The production adapter requires an HTTPS
  input URL; the underlying legacy client accepts HTTP(S), resolves every
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
- **MCP** (`MCPClient`): a Streamable HTTP JSON-RPC client using protocol `2025-11-25`, with
  bounded JSON/SSE responses, session IDs, pagination, overall deadlines, and redirect refusal.
  Production discovery runs only from explicit setup/refresh UI and populates `MCPDiscoveryCache`.
  `AppToolCatalog` advertises cached allowed descriptors; it does not discover servers during a send.
  `MCPToolV2Adapter` treats unmapped remote tools as `unknownExternal`, with no automatic retry and
  normal prepared-operation authorization. The older `MCPTool`/`ToolRegistry.build` discovery path
  remains for the legacy loop and tests. Tokens are resolved from Keychain at invocation time and
  are absent from persisted discovery metadata.

## Authenticated web service selection

`AppSettings.deepSeekWebServiceID` optionally selects a configured official DeepSeek account for both
search and page reading, independently of the model selected for inference. `makeAgentSnapshot`
captures that identity. The frozen catalog substitutes `AppDeepSeekWebToolAdapter` descriptors for the
same `builtin.web_search` and `builtin.fetch_webpage` logical IDs, preserving conversation tool choices
without advertising duplicates. The descriptor trust revision encodes the non-secret account identity;
the executable catalog can reconstruct the exact adapter after recovery without an in-memory registry.

Each call crosses the normal Tool V2 prepare/authorize/execute boundary with `web.search` or `web.page`
data categories and the fixed `https://api.deepseek.com` destination. The selected account must still
be configured for that origin before its Keychain credential is read. `DeepSeekWebClient` calls
`/v1/tools/search` or `/v1/tools/fetch` through the bounded nonredirecting transport. Search returns
typed source links, summaries and bounded page excerpts when available; Fetch returns bounded Markdown. Invalid URL arguments settle as normal tool
failures during execution before credentials or network access; preparation does not abort the
workflow for such inputs. Neither operation calls a model. The UI leaves
public engines/direct page reads as the default; choosing DeepSeek replaces both, with no fallback.
These standalone APIs are separate from provider-hosted model tools in spec §15.5. Tool observations
label search summaries, search-returned page excerpts and separate Fetch results distinctly.
New Search descriptors use revision v2 and default `include_content` to true. Callers can request
summary-only discovery with false. Archived v1 descriptors reconstruct their original summary-only
schema and behavior. The client keeps at most six results, 800 UTF-8 bytes of summary and 3,000 bytes
of page excerpt per result under the unchanged 1 MiB HTTP response ceiling. Structured source records
keep each URL separate from its untrusted text, so embedded hyperlinks are not promoted to returned
sources. Empty page text remains summary-only; publication metadata is not a crawl or modification date.

For enriched results, the evidence reader considers a bounded pool of source records, prioritizes
cited URLs and query matches, removes exact duplicate observations and selects at most 32 records.
Its total excerpt text is bounded to 24 KiB. The source index retains observed URL/kind metadata within
its existing URL-byte limit. The coordinator receives that index, and analysis-only later workers
receive relevant recorded excerpts before their work wave. This enables verification from existing
material without another search or page request. The snapshot precedes the parallel wave, so peers'
completion timing cannot change its replay inputs. Only a Fetch HTTP 404 is classified by
the local adapter as `tool.web.safe-read-miss`. The runtime accepts this nonessential miss only for the
built-in public-page reader with pure read effects, no external uncertainty and no requested user action.
It keeps the failed observation, charges its invocation, and allows remaining batch calls and planning.
Remote tools cannot select this behavior by returning the same failure code; denial, quota and uncertain
write paths retain their stop/reconciliation rules. Distinct page misses provide negative evidence;
the normal fingerprint and total-call guards still prevent repeated or unbounded attempts.

DeepSeek Chat Completions explicitly sends `tools: []` and `tool_choice: none` for tool-free synthesis,
and projects completed observations as untrusted read-only text in that request. Native call identities
and provider continuation remain in the journal and in active tool-use requests; only the no-tool wire
projection omits native call tokens. Raw DSML envelopes are never accepted as final
answers or executed as unadvertised calls; they follow the bounded malformed-response path.

## Memory

`MemoryStore` persists facts atomically with provenance, content revision, canonicalization status,
and an optional original-language retrieval alias. Model-eligible facts use canonical English
`The user …` text. Legacy unverified records remain manageable in the UI; `MemoryRanking` excludes
them from ranked results. That ranker uses ICU word segmentation and scores both the English
fact and the user's original-language alias. Memory remains user data, not a workflow scratchpad.

There are two input paths:

- The legacy `ChatStore.startGeneration` path refreshes its UI mirror and uses the shared bounded
  `selectedMemoryFacts` ranking helper. Its tests remain compatibility checks.
- Production `makeAgentSnapshot` applies the Memory switch and the same ranking helper to
  `MemoryStore`'s committed snapshot. A tool save is visible on the next send without opening Settings
  or waiting for a UI refresh. `AppFrozenInputBuilder` freezes the selected canonical facts.
  `ProductionRegressionTests` covers switch exclusion, relevance, and freshness through that assembly.

`remember` and `recall` are Tool V2 adapters in production. The management screen supports adding,
editing, deleting, and viewing provenance. There is no additional model call to extract memories in
the background. Automatic recall remains independent of the master tools switch. Disabling Memory
also removes its tools from new runs. The remember adapter receives bounded original user text from
the runtime for retrieval aliases; this source is authorization-bound and is not a model argument.

## Context compilation

`ContextCompiler` is a pure transformation of frozen inputs. Base policy and the current user turn
must fit. Tool schemas are included whole or omitted, then optional sources are allocated in order:
run state and recent tool results, then Skills, Memory, history, and artifact excerpts under policy 2.
Policy 1 preserves the previous allocation order for already frozen runs. Oversized optional text can
be truncated to a valid UTF-8 prefix. The compiled manifest records
source revisions, selected ranges, schema digests, policy versions, and the rendered prompt digest.
The deterministic estimate uses three UTF-8 bytes per token plus a 12.5% margin and framing costs.

Production context compilation does not perform a summary model pass or add the legacy extractive
breadcrumb. The app currently advertises at most eight local or sixteen online tools, selected by
`DeterministicToolSelector` within the conversation's allowed set, with 4,096/16,384 schema-token budgets.
The composer's Tools menu supports up to eight pins per conversation. A pin only retains an already
allowed tool; revocation removes its pin. Chinese intent aliases participate in deterministic selection.

## Skills

A `Skill` is a named instruction pack (`name`, emoji, one-line summary, instructions) persisted in a
durable JSON store beside the conversation records, seeded once with five built-ins (immutable;
duplicate-to-edit). Activation is **explicit and per-conversation** — the thread records its `skillID`,
the composer's [+] menu switches it, and the system prompt is composed as base + "## Active skill" so the
context meter charges it honestly. On-device conversations and agent tasks keep explicit selection. Online collaboration additionally
freezes a catalog of built-in packs and the chat's explicitly selected custom pack. Agents may discover
metadata, read useful instructions or bind a pack to a task profile. Other custom packs remain private.
Profiles can narrow enabled tools and reasoning effort inside the parent policy; skill text grants no
extra execution capability. Selected instructions remain complete under context policy 3. Interop: `SkillIO` parses and emits the
AI Edge Gallery community `SKILL.md` format (frontmatter `name`/`description`/`metadata`, markdown body),
with URL normalization for webhost/repo links and capability flags on import. Skills that invoke the
Gallery's `run_js` tool are flagged because that tool is unavailable. The
JavaScriptCore workflow provider only orchestrates subagents and does not implement `run_js`; imported
`require-secret` declarations are also not wired to a secret provider.

## Image input (vision GGUF) + dictation

Vision runs entirely on the **llama.cpp** side through the `mtmd` API already inside the vendored
xcframework. A vision-capable catalog variant declares its official `mmproj` projector
(`LLMVariant.visionProjector`); the downloader fetches it alongside the weight file (both required for
"installed"), and the memory governor includes its bytes. `LlamaEngine` resolves the projector path
at load and creates the `mtmd` context only on the first image-bearing generation, so text-only use
does not allocate the vision encoder.
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
  an `LLMModel` after attempting to resolve context/architecture metadata from its pinned MLX config or
  Hugging Face GGUF metadata. Missing metadata uses an explicitly unverified generic fallback. These
  models use their own chat template and remain **Unverified** even when metadata resolution succeeds. Family and license come only from recognized Hub tags or parsed config metadata; an absent,
  unfamiliar, or conflicting value remains explicit `Unknown / unverified`, never a fabricated Qwen /
  Apache-2.0 label. Hub listing commit SHAs propagate into each variant's `ModelSource.revision`. Once
  picked, a community model flows through the same download / fit / activate pipeline as a curated one.

`ThinkSplitter` is the shared reasoning splitter: it routes text outside `<think>…</think>` to `.answer` and
inside to `.reasoning`, withholds a possible partial-tag tail across chunk boundaries, and **must be
`finish()`-ed** at stream end to flush that tail (or the last few characters are lost). `startInThink: true`
handles the implicit-open convention used by the curated Qwen3.5 entries. The curated DeepSeek-R1
entry uses explicit think tags.

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
inside both local engines. On iOS, connected-scene aggregation drives durable quiescence before
model suspension; dynamic
workflows are included through the app coordinator. The macOS scene bridge requests run quiescence
and model suspension. Recovery remains an explicit user action.

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

## Runtime integration hardening (2026-09-06)

MCP discovery persists credential-free server metadata. Legacy inline tokens are scrubbed when the
cache opens; invocation resolves the current Keychain credential. Endpoint edits invalidate prior
explicit discovery. Clearing the cache also invalidates late discovery callbacks.

The app-level erase coordinator writes `<conversation-directory>.erase-pending` before removal.
It blocks new actions, drains workflow launch/monitor tasks, runtime mutations and workers, pauses
the outbox projector, and then removes conversation, workflow, journal and artifact content. Full
app erase also clears model data, memory, custom skills, all online credentials, discovery and settings.
The marker survives failure; bootstrap completes it before opening the runtime. Successful erasure
reopens clean execution lanes and leaves the existing container usable.

Local model registration is append-only. Bootstrap hydrates adopted models before assembling providers,
and an explicit send or workflow generation registers a newly adopted exact model before submission.
Changing metadata under an existing frozen selection fails rather than replacing that selection.

RunGroupAdmission admits one root family at a time, with up to sixteen sibling lanes. Remote siblings
use independent attempt lanes and can overlap network requests; local work retains the shared model
arbiter. Workflow foreground loss is wired through the app lifecycle coordinator.

Online transport accounts bounded byte chunks before parsing, hashes the received bytes, rejects
redirects, sums usage across fallback attempts, and reduces retry output limits by prior consumption.
Workflow analysis recognizes exact do/while pairs and instruments expression arrows, callable method
bodies, and callbacks nested in loop conditions. JavaScriptCore remains a logical realm with cooperative
termination; this orchestration realm does not advertise OS isolation or a hard heap limit.
The optional OpenSandbox execution environment is a separate container boundary.


DeepSeek Chat Completions retains native-call reasoning exactly when replaying tool history. A call
made during a thinking-disabled repair has no reasoning text; its later wire representation includes
an explicit empty `reasoning_content` field, as do ordinary historical assistant messages with no
retained reasoning. This lets an enabled-thinking continuation satisfy the API without inventing text
or rewriting the original record. Invalid native arguments use the controller's existing metered repair
path, with the entire rejected batch left unexecuted.


## Delivery checks

New app launches freeze `_mobileLLMDeliveryV1` and `_mobileLLMReviewRequiredV1`. Preparation declares
whether the user requested information, source text, saved files, a running application or publication.
`WorkflowDeliveryPolicy` checks this declaration against host-supplied environment capabilities before
dispatch and at delivery. The current assembly registers no workspace/execution provider. Requested
outcome classification is model-inferred; it cannot grant capabilities. Existing launches retain their
original policy. Ordinary chat still enters collaboration through Work with agents or `/workflow`.

`WorkflowTaskReview` freezes criteria and producer dependencies on a required task. Its agent must be
independent of those producers. The native engine binds criterion results to current input artifacts
and the human-amendment revision. `DurableSubagentSpawner` supplies successful tool receipts from the
typed tool journal, including local operations. A claimed invocation cannot replace an actual receipt.
`WorkflowTaskGraph.recordReview` retains failed reviews, reopens affected producers with original and
feedback artifacts, and invalidates dependent reviews. Unaffected branches remain settled. At most two
automatic corrections per producer and human-amendment revision share the goal budget; a blocked review
does not automatically retry its producer. Completion requires passing current reviews covering required
work. Human amendments invalidate prior acceptance. The UI loads original report details on demand and
shows criterion assessments separately from tool execution metadata.

New app goals freeze `_mobileLLMOutputLimitsV1` before planning. It detects explicit supported English
final/worker word limits, common Chinese character limits and direct JSON-only output requests from
human instructions. Quoted examples and code are excluded. Human amendments can change these bounds;
model notes cannot. The recognizer does not claim to interpret every natural-language condition.

Checks include the whole deliverable, including headings, tables and appendices. A rejected worker
result remains in the artifact history with its validation failure. One automatic correction per task
and human-amendment revision uses the same agent session and budget; another failure stays unfinished.
The coordinator has at most two final-format corrections before a pause. Accepted delivery records an
answer digest, checked again before publication. No validator edits or truncates the answer. Older goals
without this policy retain their original contract. The UI distinguishes completed generation from a
result that was rejected by these checks.

The format checks enforce supported output constraints and delivery consistency; review verdicts remain
model assessments. Factual correctness, research coverage and artifact semantics need independent checks. In the recorded SQL tasks,
the evaluator executes the generated SQL; the app has no production SQL execution tool without the
separate provider. Implementation status and open qualification are tracked in
[STATUS.md](STATUS.md#remaining-harness-qualification).

## Optional execution environment

The [OpenSandbox integration](OPENSANDBOX.md) keeps the Swift protocol package independent. AgentRuntime
implements authenticated, bounded HTTP transport, durable execution handles and Tool V2 adapters. The
external gateway uses the pinned official OpenSandbox SDK and runs code in an isolated Linux guest.
The app never executes model-generated host commands. One workspace belongs to one goal; workers
share files through that scope. Executable delivery compares native startup, browser and archive receipts
against the current source digest and accepted review. Task details expose the original verified files.
