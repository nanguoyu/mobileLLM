# iOS Agent Harness Specification

**Status:** Independently reviewed; required changes incorporated

**Date:** 2026-08-01

**Scope:** Full-featured iOS agent harness, local-model-first

**Out of scope for this release:** online model implementations, subagent execution, Agent Sandbox Runtime implementation, Dynamic Workflows

## 1. Executive summary

mobileLLM will evolve from an in-process chat tool loop into a durable, policy-driven iOS agent runtime.
The first release is a complete single-agent harness, not a partial workflow engine. It must reliably execute
multi-step model and tool interactions, request user input and approval, survive interruption, manage local-model
resources, preserve a complete operational record, and remain responsive in the existing unified chat UI.

The first release uses local models only and retains the iOS 17 deployment target. The architecture must admit
future online model providers without changing run semantics. It must also reserve stable integration seams for
subagents and for a separately developed, commercial Agent Sandbox Runtime, without linking or imitating that
private runtime today.

iOS is the product and acceptance scope. Because the repository shares packages and `ChatStore` with macOS, the
MLX-free runtime must continue to compile on macOS and existing Mac chat behavior must not regress; Mac-specific agent
features and sandbox integration are not part of this release.

The future Dynamic Workflows feature will orchestrate instances of the same `AgentExecutor` defined here. The
current release will not implement workflow scripts, a general DAG scheduler, or simulated parallel agents.

## 2. Frozen product decisions

The following decisions are requirements, not open questions:

1. The first release uses local models only. Model-provider APIs remain implementation-neutral so online providers
   can be added later without rewriting the agent runtime.
2. The app retains its iOS 17 minimum deployment target.
3. Tool choices persist per conversation. The runtime intelligently narrows the user-allowed set for each model
   pass, but it never enables a tool the user did not allow.
4. External reads and external writes require approval. Selecting a tool and approving a concrete external action
   are separate decisions.
5. The first release executes one root agent. It reserves subagent contracts and parent-child identifiers but does
   not spawn child agents.
6. Chat and agent execution share one UI. Simple answers remain visually simple; execution detail is progressively
   disclosed when a run performs work.
7. The open-source target exposes a versioned Agent Sandbox API but includes no sandbox implementation. A future
   private module may supply that implementation through dependency injection.
8. Dynamic Workflows is explicitly deferred. Compatibility seams are required; speculative workflow machinery is
   prohibited in the first release.
9. App launch must not load a model, reopen the previous conversation, or silently resume a suspended run. Pending
   runs are discoverable and resume only through explicit user intent, except for an already-authorized operating
   system continued-processing task that is still active.
10. Implementation is followed by one consolidated independent audit. Development uses continuous automated tests,
    but must not devolve into an unbounded implement-audit-reimplement loop.
11. Across the app, at most one root run actively progresses at a time. Other runs may remain durably paused or
    waiting without owning model or tool-execution resources.
12. Every boundary-crossing operation uses an enforceable `prepare -> authorize -> execute` transaction. Approval
    covers the prepared operation, not merely a tool name or model-generated preview.

## 3. Goals

### 3.1 Complete iOS agent behavior

The harness must support:

- zero-tool answers without an additional planning or routing model pass;
- multi-step model -> tool -> model execution;
- one or more tool calls returned by a model pass;
- typed action validation and one bounded repair attempt for malformed structured output;
- explicit requests for additional user input;
- external-access approval and durable approval receipts;
- pause, resume, and cancellation at well-defined boundaries;
- deterministic recovery after app suspension, termination, or process crash;
- bounded retries, deadlines, duplicate suppression, and no-progress detection;
- durable artifacts for images, documents, web content, structured data, and large tool results;
- existing Memory, Skills, MCP, vision, and conversation features;
- coherent context budgeting across conversation, memory, skills, tools, run state, and artifacts;
- thermal, memory, time, token, tool-call, network, and output budgets;
- inspectable operational events without persisting hidden chain-of-thought;
- clear terminal and nonterminal status in the existing chat experience;
- testability without loading real model weights, plus real-device evaluation with supported local models.

### 3.2 Future compatibility

The architecture must allow later additions of:

- online model providers with explicit data-egress consent;
- bounded or workflow-managed subagents;
- the private Agent Sandbox Runtime;
- a separate Dynamic Workflows runtime that coordinates many `AgentExecutor` instances;
- saved, versioned orchestration definitions.

Future compatibility means stable contracts and identifiers. It does not mean implementing unused schedulers,
interpreters, or UI now.

## 4. Non-goals

The first release must not implement:

- a JavaScript, Python, WASM, or custom workflow scripting runtime;
- a general-purpose DAG scheduler or visual workflow editor;
- child-agent execution, recursive delegation, or agent teams;
- parallel local-model decoding presented as parallel agents;
- online model API clients or silent cloud fallback;
- the commercial Agent Sandbox Runtime or a production substitute for it;
- arbitrary shell, process, or unrestricted filesystem access;
- cross-device task distribution or synchronization;
- KV-cache serialization as a recovery mechanism;
- an embeddings or vector database unless measurement proves the simpler context selector inadequate;
- automatic re-entry into the last conversation or automatic model loading at launch.

## 5. Current architecture and migration constraints

The existing system has valuable components that must be preserved:

- `LLMEngine` provides engine-independent streaming reasoning, answer, and completion events.
- `RoutingEngine` keeps at most one local engine resident, which is a hard memory-safety invariant.
- `GenerationLifecycle` and `GenerationGovernance` provide cooperative cancellation, pause, thermal governance, and
  safe model load/unload draining.
- `ToolDialect`, `ToolCallProcessor`, and `ToolLoop` provide tolerant parsing, duplicate suppression, bounded tool
  execution, untrusted-result framing, and a tool-free final synthesis pass.
- `ToolRegistry` supports built-in tools and remote MCP tools selected by the user.
- `ConversationStore`, `DurableStore`, `MemoryStore`, and attachment persistence already establish defensive local
  storage patterns.

The migration must address these limitations:

- `ChatStore.startGeneration` currently owns UI state, context construction, memory injection, tool assembly,
  execution, recovery, and persistence.
- `ToolLoop` holds its run state only in local variables and cannot resume after process loss.
- `Tool.execute(argumentsJSON:) -> String` cannot express typed errors, progress, effects, approvals, deadlines,
  artifacts, or idempotency.
- the current schema model loses nested JSON Schema structure, especially for MCP tools;
- conversation persistence stores only the final message and a flattened tool history, not an execution journal;
- app backgrounding currently unloads the resident model without a durable agent checkpoint protocol.

The migration must preserve current user data and ordinary chat behavior. It must not require a destructive
conversation migration.

## 6. Target package boundaries

The implementation should introduce three small MLX-free packages and keep platform implementations injectable.

### 6.1 `AgentContracts`

Owns the minimal versioned value vocabulary shared across runtime, sandbox API, and future execution clients:

- strongly typed run, step, request, artifact, event-cursor, and execution-handle identifiers;
- versioned request/result/event envelopes;
- capability grants, budgets, command envelopes, and redaction metadata;
- provider-neutral artifact references and typed failure classifications.

It contains no scheduler, persistence implementation, UI, model engine, tool implementation, or sandbox behavior.
This package prevents a dependency cycle between `AgentRuntime` and `AgentSandboxAPI` while keeping the private
sandbox implementation independent.

### 6.2 `AgentRuntime`

Owns public agent semantics and runtime coordination:

- `AgentExecutor`
- `AgentRunController`
- `AgentRunStateMachine`
- `ContextCompiler`
- `AgentModelProvider` and model capability types
- `ToolV2`, `ToolCatalog`, `ToolSelector`, and `ToolExecutor`
- `ApprovalPolicyEngine`
- `ResourceArbiter`
- `RunJournal` protocol and projections
- artifact references and budgets
- lifecycle event definitions

It depends on `AgentContracts` and may depend on `LLMCore`, `AppRuntime`, and the protocol-only `AgentSandboxAPI`, but
not SwiftUI, MobileLLMUI, MLX, llama.cpp, EventKit, CoreLocation, or the future private sandbox implementation.

### 6.3 `AgentSandboxAPI`

Owns only versioned, implementation-neutral sandbox contracts. It may depend on `AgentContracts`; it must not depend
on `AgentRuntime`, SwiftUI, a model engine, or a concrete sandbox.

### 6.4 Existing packages

- `MobileLLMUI` sends runtime commands and renders runtime projections. It does not implement orchestration.
- `LLMCore` continues to own model, catalog, dialect, and existing tool-domain primitives during migration.
- platform tools remain in their appropriate package and adapt to `ToolV2`.
- concrete local engines remain unchanged behind model-provider adapters unless capability negotiation requires a
  narrowly scoped protocol extension.

## 7. Core terminology and identity

- **Conversation:** persistent user-visible chat history and per-conversation preferences.
- **Agent run:** execution initiated by one user turn or an explicit resume action.
- **Step:** one stable execution boundary, such as context compilation, a model attempt, an approval, a tool
  invocation, or finalization.
- **Attempt:** one try of a retryable step.
- **Invocation:** one normalized call to one tool.
- **Artifact:** durable content referenced by metadata rather than embedded in run events.
- **Capability grant:** immutable authority available to a run.
- **Approval receipt:** durable evidence that the user approved a bounded action or action class.
- **Projection:** UI-oriented state derived from journal events.

All durable entities use stable opaque identifiers from `AgentContracts`. At minimum:

```swift
struct AgentRunID: Hashable, Codable, Sendable
struct AgentStepID: Hashable, Codable, Sendable
struct ToolInvocationID: Hashable, Codable, Sendable
struct ApprovalID: Hashable, Codable, Sendable
struct ArtifactID: Hashable, Codable, Sendable
```

Raw UUID strings must not be used interchangeably across entity types.

## 8. Run lifecycle and state machine

One accepted user send creates one `AgentRun`. The run snapshots all execution-defining inputs before the first model
pass:

- conversation and user-turn identifiers;
- model, variant, provider, and capability versions;
- sampling and context limits;
- active system-prompt and Skill versions;
- relevant Memory record identifiers;
- user-allowed and runtime-advertised tool sets;
- tool schema hashes;
- capability grant and approval policy version;
- budgets and lifecycle policy.

Before each model attempt, `ContextCompiler` commits an immutable `CompiledRequestManifest`. It records exact source
revisions or content hashes, selected and truncated ranges, rendered prompt hash, serialized advertised tool schemas
and hashes, artifact excerpt hashes, tokenizer or estimator identity, and policy versions. Sensitive bodies may live
in a protected artifact referenced by hash. Recovery reuses this manifest; it does not reread mutable Memory, Skill,
or conversation records and then claim the request is unchanged.

Required states:

```text
created
preparing
waitingForModel
generating
validatingAction
waitingForApproval
executingTools
waitingForUser
synthesizing
pausing
paused
waitingForForeground
waitingForReconciliation
completed
failed
cancelled
```

Every transition is validated by a pure state machine and recorded before its projection is shown as committed UI.
Invalid transitions fail closed and produce a diagnostic event; they must never be silently coerced.

`waitingForUser` is backed by a durable `InteractionRequestRecord` containing a stable request ID, prompt, optional
response schema, creation state version, disposition, and eventual response. Responses carry the request ID and
expected run-state version; duplicate responses are idempotent and stale responses fail closed.

`waitingForReconciliation` is nonterminal. It represents a boundary-crossing action whose outcome cannot be proven.
The run cannot replay that action or continue past it until the user or a tool-provided reconciliation operation marks
it succeeded, failed, or abandoned. Only an explicit decision to abandon unresolved work terminates the run with
`externalResultUncertain`.

The first release processes multiple proposed tool calls serially in the model-provided order. Each invocation has
its own state machine (`proposed`, `prepared`, `waitingForApproval`, `authorized`, `executing`, `completed`, `failed`,
`waitingForReconciliation`, `cancelled`). A deterministic barrier appends results in proposal order and starts the
next model pass only after every invocation in the batch reaches a usable outcome. Parallel tool batches are deferred.

### 8.1 Stable boundaries

Durable checkpoints occur after:

- run-input snapshot creation;
- context compilation;
- a completed model attempt;
- normalized action validation;
- approval grant or denial;
- tool intent recording;
- tool outcome recording;
- artifact commit;
- final answer commit;
- pause, cancellation, or failure finalization.

Token-by-token output is not a stable recovery boundary. The UI may receive ephemeral token events, and the runtime
may persist a rate-limited incomplete draft for user visibility. After interruption, an incomplete model attempt is
discarded as authoritative state and restarted from the preceding stable boundary.

### 8.2 Terminal semantics

A run terminates with exactly one reason:

```text
completed
cancelledByUser
budgetExceeded
noProgress
permissionDenied
toolUnavailable
modelUnavailable
contextUnsatisfiable
externalResultUncertain
internalFailure
```

Nonterminal waits (`waitingForApproval`, `waitingForUser`, `waitingForForeground`, `waitingForReconciliation`, and
`paused`) remain resumable. Background expiration normally transitions to `waitingForForeground`; it is not itself a
terminal failure.

## 9. Persistence and recovery

### 9.1 Source of truth

The agent runtime uses a transactional SQLite journal. WAL mode, schema migrations, foreign-key enforcement, and
transactional event sequence allocation are required. The specific Swift SQLite binding is an implementation choice
behind an internal storage adapter; storage semantics must not leak into the runtime APIs.

The journal is append-only for the lifetime of retained execution facts. "Append-only" does not override user
deletion: privacy deletion removes the complete retained run and its owned data.

For every new AgentRuntime turn, the journal is the canonical source for accepted user-turn payload, run lifecycle,
and committed assistant result. Conversation JSON remains a backward-compatible user-visible projection during
migration, not a second authority for those new messages.

A durable outbox in the same SQLite transaction as each canonical message/run event contains an idempotent projection
command keyed by stable `MessageID` and `RunID`. The projector applies that command to `ConversationStore`, then
records its acknowledgement. A crash before or during the JSON write replays the unacknowledged command; an already
applied command is a no-op. The JSON store must never create a new-runtime message that lacks a corresponding
canonical journal event.

Send acceptance uses this order:

1. atomically commit required attachment artifacts;
2. transactionally record the accepted user message, `RunCreated`, and projection outbox command;
3. clear the composer and begin execution only after that transaction succeeds;
4. project to Conversation JSON idempotently.

Finalization transactionally records the final answer and its projection command before UI treats the answer as
committed. If projection lags, the runtime projection supplies the visible state and recovery reconciles JSON. This
ordering prevents ghost answers, duplicate messages, and executed-but-invisible tool turns.

### 9.2 Minimum records

- `AgentRunRecord`
- `AgentStepRecord`
- `RunEventRecord(sequence, payloadVersion)`
- `ModelAttemptRecord`
- `CompiledRequestManifestRecord`
- `ToolInvocationRecord`
- `ApprovalRecord`
- `InteractionRequestRecord`
- `ArtifactRecord`
- `UsageLedgerRecord`
- `ProjectionOutboxRecord`

Every record format is versioned. Migrations are forward-only, transactional, and tested against production-like
fixtures. A migration failure preserves the original database and blocks mutation with a recoverable error.

### 9.3 Concurrency and command consistency

Each run has a monotonically increasing state version and event sequence; every event also has a globally unique ID.
State-changing commands use a SQLite compare-and-swap transaction equivalent to
`append(runID, expectedRunVersion, commandID, events)`. Exactly one competing approval, cancellation, background
expiration, tool callback, or model callback may advance a given version. Duplicate command IDs and duplicate outcome
IDs return the original receipt without appending new events. A database uniqueness constraint permits at most one
terminal event per run.

All user and lifecycle commands carry `RunID`, stable request or command ID, and `expectedRunVersion`. Stale commands
fail closed with current-state information; UI destruction or stream cancellation never implies a run command.

### 9.4 Recovery algorithm

On explicit resume:

1. Load the latest materialized projection and replay later events.
2. Verify the pinned model, prompt, Skill, tool schemas, and capability grant are still available.
3. Classify the interrupted step as replayable, completed, uncertain, or incompatible.
4. Reuse completed artifacts and idempotent outcomes.
5. Restart an interrupted model attempt from its preceding stable boundary.
6. Never automatically replay a non-idempotent external action whose outcome is unknown.
7. Require user choice to migrate or restart when a pinned dependency is incompatible.
8. Replay unacknowledged ConversationStore projection commands and reconcile by stable message ID.

Opening the app lists recoverable runs but does not select their conversation, load their model, or resume them.

### 9.5 Deletion coordination

Deleting an active conversation first blocks new commands and quiesces its run. A deletion intent is committed to the
journal before cross-store removal. Soft delete retains run data only for the existing undo interval. Hard delete
removes conversation projections, run/step/model/tool/interaction events, approval receipts, security-scoped
bookmarks, artifacts with no remaining owner, projection outbox entries, snapshots, migration backups, and bounded
diagnostics for that conversation. Recovery replays an incomplete deletion intent until every owned store agrees.

`Delete All` closes the database, removes the database together with `-wal` and `-shm`, conversation projections,
artifacts, bookmarks, backups, and diagnostics, and only then creates a clean store. SQLite uses secure deletion and a
truncate checkpoint before ordinary row-level purges where possible, but the product does not claim forensic physical
erasure from flash media; protection relies additionally on platform encryption and key destruction.

## 10. Model-provider abstraction

The first implementation adapts the current local `LLMEngine` into `AgentModelProvider`.

```swift
protocol AgentModelProvider: Sendable {
    var descriptor: AgentModelProviderDescriptor { get }
    func capabilities(for model: AgentModelSelection) async -> AgentModelCapabilities
    func generate(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelEvent, Error>
}
```

Capabilities include:

- context and output limits;
- text-dialect versus native structured tool calling;
- JSON-schema or grammar-constrained output support;
- reasoning and vision support;
- multiple-tool-call support;
- cancellation granularity;
- provider concurrency and residency constraints;
- usage and cost reporting fields, even when local cost is zero.

The runtime consumes normalized events only:

```text
reasoningDelta
answerDelta
toolCalls
requestUserInput
usage
completed
failed
```

A provider stream emits no events after a terminal event. Successful completion contains exactly one terminal
`completed` event; a thrown transport or runtime error before that event is converted by `AgentRuntime` into one
durable failed attempt. Cancelling an attempt stream cancels only that model attempt, not the owning run. Mixed prose
and tool syntax is normalized to one action: prose emitted before `callTools` remains provisional and is discarded
from the final answer; an action cannot simultaneously be final text and a tool batch.

Token accounting uses the provider's tokenizer when available. Otherwise it uses a named, versioned conservative
estimator with a safety margin. "Deterministic recovery" means deterministic replay of recorded facts and compiled
request manifests; rerunning stochastic inference is not promised to reproduce identical text.

Tool dialect parsing is an adapter concern. The run state machine does not contain model-family conditionals.

Provider and model selection are pinned for the run. The first release must never fall back from a local model to an
online provider. A future online provider requires explicit setup, Keychain-backed credentials, provider-specific
data-egress consent, and a visible run snapshot of what may leave the device.

## 11. Single-model resource arbitration

The current invariant of at most one resident local engine remains authoritative.

`ResourceArbiter` grants a model lease before generation and coordinates:

- model loading and unloading;
- one active local decode lane;
- cancellation and draining before residency changes;
- foreground/background transitions;
- thermal and memory-pressure policy;
- expensive model switching;
- future independent provider lanes.

The first release executes tool invocations serially. Multiple local agents must not be presented as physically
parallel on iPhone. Future versions may add independent tool lanes and logically concurrent subagents, but every
local model pass remains queued through the single decode lane.

Across the app, only one root run may own the actively progressing execution slot. Waiting, paused, and reconciliation
runs own no model lease and may coexist durably. Starting or resuming another run either queues it or requires an
explicit user switch; it never silently preempts the current owner. Approving or responding to a waiting older run
makes that run eligible to continue but does not steal the slot from a newer owner.

Pause is durable quiescence, not indefinite suspension of an async task or resident multi-gigabyte model. It cancels
an unfinished model attempt at a stable boundary, records it as interrupted, releases the decode lease, and unloads
according to residency policy. Pause or Stop requested after a non-idempotent external write enters its noncancellable
critical section records a durable `pauseRequested` or `cancelRequested` command intent on that invocation; the
runtime waits for a confirmed outcome or moves to `waitingForReconciliation` before releasing ownership.

## 12. Agent action protocol and loop policy

Every model pass resolves to one normalized action:

```swift
enum AgentAction {
    case callTools([ProposedToolCall])
    case requestUserInput(UserInputRequest)
    case finalAnswer(AgentAnswer)
}
```

The runtime validates tool names, full schemas, argument sizes, capabilities, approval requirements, and budgets
before execution. A malformed structured action receives at most one bounded, non-thinking repair pass. Failure of
that repair ends the run with a precise user-visible error.

No mandatory planner pass is added to ordinary conversation. Complex behavior emerges from successive bounded
actions. This protects first-token latency and avoids asking small local models to create plans they cannot reliably
execute.

All calls in a proposed batch are normalized and validated before the first one executes. They then execute serially.
A denied, failed, or uncertain invocation stops the remaining batch unless the failure is explicitly typed as a safe,
nonessential miss by local trusted policy. The model and a remote descriptor cannot decide that classification.

Budgets are fixed by tested local policy rather than by the model. They cover:

- model-pass budget;
- tool-invocation budget;
- structured-repair budget;
- repeated-call budget;
- wall-clock deadline;
- token and context budgets;
- network-input and network-output budgets;
- artifact and persisted-output limits;
- thermal and memory policy.

The first-release default hard limits are six model attempts, three completed tool invocations, one structured repair,
one execution per identical normalized call fingerprint, two consecutive no-progress actions, and fifteen minutes of
active run time. Approval, user-input, paused, reconciliation, and foreground waits do not consume active-run time.
Default network limits are 2 MiB per response and 8 MiB per run; default newly generated artifact data is limited to
32 MiB per run, excluding already accepted user attachments. A trusted tool may declare a lower limit, never a higher
one without a user-visible policy change.

Before a model attempt or tool invocation starts, the usage ledger atomically reserves its maximum call count and
declared token, byte, and time allowance. Unused reservation is returned at the stable outcome boundary. Work does
not begin when the remaining hard budget cannot cover its reservation.

The model cannot increase budgets. Repeated normalized calls and two consecutive no-progress actions terminate the
run. There is no unbounded implementation-review loop.

## 13. Tool V2 contract

### 13.1 Descriptor

Every tool has a stable namespaced identity and complete descriptor:

```swift
struct AgentToolID {
    var provider: String
    var name: String
    var version: String
}

struct AgentToolDescriptor {
    var id: AgentToolID
    var title: String
    var summary: String
    var inputSchema: JSONSchema
    var outputSchema: JSONSchema?
    var effects: Set<ToolEffect>
    var requiredCapabilities: Set<AgentCapability>
    var timeoutPolicy: ToolTimeoutPolicy
    var retryPolicy: ToolRetryPolicy
    var idempotency: ToolIdempotency
    var supportsProgress: Bool
    var supportsCancellation: Bool
}
```

Schemas use JSON Schema Draft 2020-12. The local validator supports bounded object, array, scalar, `enum`, `const`,
`required`, `additionalProperties`, numeric/string/array bounds, composition, and local `$defs` references. Remote
references are forbidden. Encoded schemas are limited to 64 KiB, nesting depth 16, 1,024 resolved nodes, local
reference depth 16, and pattern length 256. Unsupported or unknown keywords are preserved for round-trip and display
but marked unenforced; they never silently pass as locally validated. A partially validated remote tool receives the
conservative external-effect and approval policy.

JSON arguments are normalized with RFC 8785 JSON Canonicalization Scheme semantics after schema validation. Tool
identity, descriptor version, trust mapping, normalized arguments, and schema hash all participate in invocation and
approval fingerprints.

### 13.2 Execution

```swift
protocol ToolV2: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func prepare(
        request: ToolExecutionRequest,
        context: ToolPreparationContext
    ) async throws -> PreparedToolInvocation
    func execute(
        prepared: AuthorizedToolInvocation,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error>
}
```

`prepare` is side-effect free and may not cross a filesystem, private-data, network, model-provider, or sandbox
boundary. It returns an immutable plan containing canonical arguments; concrete destinations and bounded redirect or
fallback rules; data categories or payload digest; maximum possible effects; timeout, retry, and idempotency semantics;
and the exact user preview. Local-pure tools return a plan with no external operations.

`ApprovalPolicyEngine` authorizes the immutable plan, producing `AuthorizedToolInvocation`. `execute` may perform only
the authorized plan. A redirect, fallback, resolved destination, payload, argument, or effect expansion outside that
plan stops execution and requires a new prepare/approval transaction. Runtime-observed behavior that is narrower than
the plan is allowed and recorded.

The execution context includes run, step, and invocation IDs; plan and schema hashes; deadline; cancellation;
idempotency key; capability grant; approval receipt; artifact writer; secret references; and redacted logger. A tool
stream has exactly one terminal outcome and no later events.

Results support text, structured JSON, image, resource links, and artifact references. Errors are typed and classify
retryability, uncertainty, user action, and whether any external effect may have occurred.

Existing tools are migrated through a V1 adapter. The adapter may conservatively declare limited capabilities, but
it must not fabricate idempotency or cancellation guarantees.

Remote descriptors are untrusted metadata. MCP servers cannot lower their locally assigned effect, retry, approval,
or idempotency classification. An MCP tool without a trusted local mapping is `unknownExternal`: exact approval is
required for every invocation, automatic retry is forbidden, and transport loss after intent becomes
`waitingForReconciliation`.

MCP `initialize`, `tools/list`, capability refresh, and future resource/prompt discovery are external reads. They may
run only from explicit server setup, refresh, or an already authorized bounded server session; they must never occur
silently during prompt compilation. Server identity is a stable random ID rather than its mutable URL.

## 14. Conversation-persistent intelligent tool selection

Tool availability has three independent layers:

1. **Allowed set:** explicitly selected by the user and persisted on the conversation.
2. **Advertised set:** the relevant subset selected by the runtime for one model pass.
3. **Approved invocation:** permission to perform one external action or a narrowly scoped class of actions.

Each conversation persists a versioned policy:

```swift
struct ConversationToolPolicy: Codable, Sendable {
    var masterEnabled: Bool
    var allowedToolIDs: Set<AgentToolID>
    var pinnedToolIDs: Set<AgentToolID>
    var selectionPolicyVersion: Int
    var materializedFromGlobalTemplate: Bool
}
```

A new conversation copies the current global tool template once at creation. A legacy conversation with no policy
materializes the current global template exactly once, on its first edit or first new AgentRuntime run, then persists
the marker. Later global changes affect new conversations only unless the user explicitly applies them to an existing
conversation or all conversations. Every run then freezes the conversation policy it actually used.

Logical tool identity is separate from descriptor/schema revision and hash. If a tool disappears, its trusted effect
mapping changes, or its schema changes incompatibly, the conversation keeps the user's logical selection but the run
marks the tool unavailable and requires inspection or renewed approval; it must not silently inherit an old receipt.

The selector:

- operates only inside the allowed set;
- honors user-pinned tools;
- filters unavailable capabilities and records why a tool is unavailable;
- ranks by the latest request, attachment types, active Skill, recent successful tool chain, and deterministic
  metadata;
- does not add another model inference pass;
- advertises a small configurable set appropriate for local 2B-8B models;
- includes an explicitly named allowed tool even if ranking would otherwise omit it;
- records its input, output, policy version, and rationale codes for testing and inspection.

The selector chooses what the model may consider. It does not invoke tools and does not bypass approval. If a user
asks for a capability that is not allowed, the app offers a visible enable action instead of silently running it.

## 15. Capability and approval model

### 15.1 Effect classes

At minimum:

```text
localPure
localRead
localWrite
privateDataRead
networkRead
unknownExternal
externalWrite
externalCommunication
destructive
financial
codeExecution
```

Examples:

- calculator and local date/time are `localPure`;
- app-owned Memory is `localRead`/`localWrite` and remains separately gated by the Memory setting;
- web, Wikipedia, webpage fetch, and remote MCP reads are `networkRead`;
- calendar, reminders, location, Photos, and user-selected documents cross a user/system data boundary;
- future online inference is a data-egress operation even if the model performs no tool call;
- deletion, publication, payment, and messages to third parties use the strongest applicable class.

### 15.2 Approval defaults

Every boundary-crossing operation, not only a tool call, uses `prepare -> authorize -> execute`. This includes MCP
discovery/calls, future online-model requests, private-data and user-file access, artifact export, security-scoped
bookmark creation, and future sandbox operations. The approval engine evaluates locally trusted policy plus the
prepared operation; model output and remote metadata cannot grant or reduce authority.

`ExternalOperationPlan` is a shared `AgentContracts` envelope. Tool, provider, file, artifact, and sandbox adapters
must all produce it rather than implementing parallel approval formats.

- External reads require approval on first use in a conversation for the exact tool and bounded destination/data
  scope. A receipt may authorize subsequent matching reads in that conversation.
- External writes require an exact invocation preview and approval by default.
- Reversible writes may offer an explicit conversation-scoped grant.
- Destructive, publication, financial, and third-party communication actions require exact approval every time.
- Changed normalized arguments invalidate an invocation-bound approval.
- Tool selection never implies external-access approval.
- Apple TCC authorization and agent approval are independent; both must succeed.
- The app never navigates into, clicks, or dismisses unrelated system account/configuration UI on the user's behalf.
- A background run that needs approval enters `waitingForApproval`; it does not attempt to present TCC or application
  approval UI while backgrounded.

Approval records contain the displayed preview, normalized scope, arguments hash, policy version, timestamp, expiry,
actual host/destination matcher, redirect/fallback bounds, data-category or payload digest, descriptor/schema/trust
hashes, and user decision. Capability grants are immutable for a running step. Future child agents may receive only a
subset of the parent's grant. Any time-of-check/time-of-use mismatch invalidates authorization before external I/O.

## 16. Context compiler, Memory, and Skills

`ContextCompiler` is deterministic for a frozen run snapshot. It composes and budgets:

1. base system policy;
2. active Skill instructions and version;
3. relevant canonical-English user Memory when Memory is enabled;
4. recent conversation turns;
5. current user request and attachments;
6. compact structured run state;
7. selected artifact excerpts;
8. advertised tool schemas;
9. untrusted tool-result frames.

Every source reports estimated tokens before compilation. The compiler records inclusions, omissions, truncations,
and policy versions. The latest user turn and system policy are never silently removed.

User Memory remains a long-term fact store, not an agent scratchpad or checkpoint system. Runtime state lives in the
journal. Large tool results live as artifacts and enter context only through bounded excerpts. Tool and external
content is untrusted data and cannot grant capabilities, alter approval policy, or redefine the workflow.

## 17. Artifact system

The first release generalizes the existing attachment store into a content-addressed artifact layer.

Each artifact records:

- content hash and byte size;
- MIME type and optional semantic type;
- source run, step, tool, and external provenance;
- creation time and retention policy;
- local file reference under a confined root;
- sensitivity/redaction classification;
- integrity verification status.

Artifacts are committed atomically before their reference event. Orphan cleanup and reference counting are
deterministic and tested. Run deletion removes run-owned artifacts unless another durable record references them.
Secrets and bearer tokens are never artifacts.

User-selected files use security-scoped access and the narrowest retained bookmark necessary. File access outside
the app container remains unavailable without explicit user selection and approval.

### 17.1 Data protection and backup

- The SQLite database, `-wal`, and `-shm` use `NSFileProtectionCompleteUntilFirstUserAuthentication` so an explicitly
  authorized background task can journal after first unlock.
- User-content artifacts and retained security-scoped bookmarks use `NSFileProtectionCompleteUnlessOpen`. If data is
  unavailable while locked, the run waits for foreground/unlock; it never copies content to a weaker temporary file.
- Migration and corrupt backups inherit the source's protection class. Diagnostics are redacted before the first
  write and contain no prompt, secret, approval payload, or raw external result by default.
- Agent journals, generated artifacts, diagnostics, and transient backups are excluded from device/cloud backup by
  default. User exports follow the protection and backup policy of the destination the user selected.
- Keychain secrets remain this-device-only and are referenced by opaque identifiers.

Store creation and migration verify the effective protection and backup attributes for every database sidecar and
artifact root. Failure blocks mutation with a recoverable data-protection error.

## 18. Retry, idempotency, and uncertainty

Every failure is typed as transient, permanent, permission-related, budget-related, cancelled, incompatible, or
potentially side-effecting.

- Pure reads may retry with bounded exponential backoff and jitter.
- Writes retry automatically only when the tool declares and honors an idempotency key or supplies a reliable
  reconciliation operation.
- A timeout or transport loss after a non-idempotent external intent produces `waitingForReconciliation`; the runtime
  must not claim success, continue the ordinary loop, or replay the action.
- Duplicate suppression uses tool ID, schema version, normalized arguments, and effect scope, not raw model text.
- Cancellation propagates from run to step to model/tool execution. Noncooperative implementations are detached only
  after the journal records uncertainty and resource ownership is made safe.

## 19. iOS lifecycle and background execution

### 19.1 iOS 17 baseline

On iOS 17-25, a lifecycle coordinator aggregates all connected-scene states rather than relying on one view's
`scenePhase`. Before quiescence it obtains finite best-effort drain time with `beginBackgroundTask`; its expiration
handler issues the same idempotent, versioned quiesce command. Recovery correctness never assumes that iOS grants
enough time or that the expiration handler completes.

Leaving the foreground initiates this bounded sequence:

1. stop admitting new actions;
2. finish or cancel at the nearest safe boundary within available background time;
3. record the interrupted attempt and resulting status;
4. drain generation safely;
5. unload local weights when required by memory policy;
6. enter `waitingForForeground` if work remains.

Returning to the app does not resume automatically. The relevant conversation shows a resumable run and requires an
explicit Resume action, which then loads the pinned model.

### 19.2 iOS 26 continued processing

Where available and entitled, a user may explicitly choose continued background execution for a finite run that has
a truthful bounded progress model. Ordinary open-ended chat runs are not submitted by default. An eligible run may
register a `BGContinuedProcessingTask`; the integration:

- uses availability guards and does not raise the deployment target;
- requests GPU resources only on supported devices and only for local engines that need them;
- reports real progress to the system UI;
- handles queueing, rejection, expiration, and user cancellation;
- uses the same journal and recovery semantics as foreground execution;
- never treats continued processing as guaranteed runtime.

Queueing or rejection leaves the run `waitingForForeground` with a diagnostic reason. Expiration and system
cancellation first attempt safe quiescence and then leave resumable work `waitingForForeground`; user cancellation
from system UI maps to the explicit cancellation policy. No case silently restarts inference or an external action.

An already-running, user-authorized continued task may keep executing when the app leaves the foreground. A normal
app launch must still not load a model or resume an unrelated run.

## 20. Unified UI and interaction model

There is one chat UI, with progressive disclosure:

- ordinary local answers render exactly like ordinary chat;
- the composer displays the conversation's allowed and pinned tool state;
- complex runs expose a compact activity row that expands into steps;
- approval cards show the tool, destination, exact action preview, data being sent/read, and grant scope;
- waiting states clearly distinguish user input, approval, foreground, model, and resource waits;
- submitting text to an active `InteractionRequestRecord` sends a Respond command and does not create a new root run;
- the user can Pause, Resume, or Stop the run;
- a neutral launch still exposes pending runs through conversation badges or a run inbox without navigating to one;
- partial output is visibly marked incomplete and never confused with a committed final answer;
- tool and model failures show a specific recovery action rather than an empty bubble;
- elapsed reasoning and activity time derive from runtime events, not disclosure visibility;
- opening the app starts at the normal neutral shell, not the prior conversation or an auto-loaded model.

The UI displays operational summaries, model-provided visible reasoning where supported and enabled, tool activity,
and evidence. It does not invent, request, or persist private hidden chain-of-thought.

Approval previews, destinations, data categories, and destructive warnings must remain fully accessible with
VoiceOver and at the largest Dynamic Type sizes; critical text may scroll but may not truncate. Primary approval and
denial actions require distinct labels, stable focus order, and protection against accidental double activation.

## 21. Agent Sandbox Runtime compatibility seam

### 21.1 Isolation from the private implementation

The open-source repository defines only `AgentSandboxAPI`. It must compile and function with no sandbox provider.
The future commercial runtime may be integrated as a private Swift package, binary XCFramework, or another adapter,
but the harness must not depend on its concrete types, implementation details, storage, or entitlements.

The public app uses an absent provider by default. When absent:

- sandbox-required tools are not advertised;
- existing agent behavior remains fully functional;
- the UI may describe the capability as unavailable but must not show a broken control.

### 21.2 Two-level integration

The sandbox is an execution environment, not merely one string-returning tool. Integration has two levels:

1. `AgentSandboxProvider` exposes versioned capabilities and durable execution handles.
2. tool adapters expose the operations a model may request within an authorized session.

This first version is explicitly an experimental compatibility contract. It freezes only the semantics that are
already required by the harness and future authority model:

```swift
protocol AgentSandboxProvider: Sendable {
    var descriptor: AgentSandboxProviderDescriptor { get }
    func capabilities() async throws -> SandboxCapabilities
    func start(
        _ request: SandboxExecutionRequest,
        idempotencyKey: String
    ) async throws -> SandboxExecutionHandleID
    func attach(to id: SandboxExecutionHandleID) async throws -> any SandboxExecutionHandle
}

protocol SandboxExecutionHandle: Sendable {
    var id: SandboxExecutionHandleID { get }
    func events(after cursor: AgentEventCursor?) -> AsyncThrowingStream<SandboxEventEnvelope, Error>
    func status() async throws -> SandboxExecutionStatus
    func result() async throws -> SandboxExecutionResult?
    func send(_ command: SandboxCommandEnvelope) async throws -> SandboxCommandReceipt
}
```

The versioned envelopes reserve:

- semantic protocol version and capability negotiation;
- opaque execution, artifact, optional workspace, and optional checkpoint handles;
- declarative filesystem, network, process, and code-execution requirements;
- immutable authority and resource-budget envelopes;
- secret references without plaintext persistence;
- resumable event cursors, structured progress, result, error, and artifact envelopes;
- typed failures and uncertain side-effect reporting;
- audit events and redaction metadata.

`start` is idempotent for its key. Ending an event subscription only detaches the observer; it never cancels execution.
Commands are explicitly targeted and idempotent. A sandbox execution receives an immutable capability subset and
cannot request broader authority. Its output and self-described capabilities are untrusted until checked against the
locally registered provider policy.

Mount representation, snapshot mechanics, process model, transport, resource accounting implementation, binary ABI,
and distribution remain deferred until the real private provider is integrated. The current contract fake verifies
versioning, authority attenuation, idempotent start/commands, detach/reattach, event cursors, and typed outcomes only;
no placeholder production sandbox is built.

## 22. Subagent compatibility seam

The root agent itself uses the future durable execution unit:

```swift
protocol AgentExecutor: Sendable {
    func submit(_ request: AgentRequest, commandID: AgentCommandID)
        async throws -> AgentExecutionHandleID
    func attach(to id: AgentExecutionHandleID) async throws -> any AgentExecutionHandle
}

protocol AgentExecutionHandle: Sendable {
    var id: AgentExecutionHandleID { get }
    func events(after cursor: AgentEventCursor?) -> AsyncThrowingStream<AgentEventEnvelope, Error>
    func status() async throws -> AgentRunStatus
    func result() async throws -> AgentResult?
    func send(_ command: AgentCommandEnvelope) async throws -> AgentCommandReceipt
}
```

`submit` is idempotent for `commandID`. Event cursors are durable and reconnectable. Ending an event subscription or
destroying a view only detaches observation; only an explicit versioned Pause, Resume, Cancel, Approve, Reconcile, or
Respond command changes the run. Commands carry target run/request IDs and expected state version.

`AgentRequest` reserves:

- run and optional parent-run ID;
- requesting step ID;
- role/instruction and output schema;
- model policy;
- capability grant;
- independent budget;
- context and artifact references;
- optional sandbox requirement;
- labels and provenance.

The first release has no `SubagentSpawner` implementation and advertises no spawn capability. Future subagents:

- inherit only a strict subset of parent capabilities;
- receive independent contexts and budgets;
- return structured results and artifacts rather than full transcripts;
- cannot approve their own external access;
- pass local model generation through the same single-resource arbiter;
- remain visible as child runs in the journal.

## 23. Dynamic Workflows compatibility seam

A future workflow runtime may create, sequence, branch, repeat, and verify `AgentRequest` values. It must be a separate
orchestrator above `AgentExecutor`.

The current harness reserves only what that orchestrator will need:

- stable run, step, parent, and artifact identities;
- structured inputs and outputs;
- immutable capability grants;
- independent budgets and usage ledgers;
- resumable execution events;
- provider-neutral model routing;
- sandbox requirements;
- explicit verification/evidence fields.

The future workflow script or graph must not receive direct filesystem, network, tool, or sandbox authority. It
coordinates agents; agents act through the same policy-controlled runtime. No workflow table, interpreter, general
dependency scheduler, or workflow UI is added in this release.

## 24. Security and privacy requirements

- Local inference remains local. Future online inference is opt-in and visibly classified as data egress.
- Capability grants are deny-by-default, immutable within a step, auditable, and attenuated for future child agents.
- External content is separated from control instructions and labeled untrusted.
- Tool names are namespaced; schema hashes prevent silent tool substitution during resume.
- Approval receipts bind normalized scope and policy version.
- Network tools retain scheme, public-address, redirect, and response-size protections.
- MCP credentials and future provider secrets live in Keychain and are exposed only by opaque references.
- Logs redact secrets, personal data, approval payloads where required, and large external content.
- Artifacts are root-confined, integrity-checked, and purged according to ownership and retention.
- User-selected file access uses security-scoped URLs and resists path traversal and symlink escape.
- Prompt injection cannot enable tools, increase budgets, grant approval, or alter the runtime state machine.
- No automated test or agent flow may click unrelated system setup, account, email, or permission UI.

## 25. Observability

Every run exposes a redacted event stream sufficient to answer:

- what is running and why;
- which model/provider/variant is pinned;
- which tools were allowed, advertised, proposed, approved, and executed;
- what external destination or private data was involved;
- current and cumulative tokens, duration, tool count, and network/artifact bytes;
- what is blocking progress;
- why a retry occurred;
- whether an external side effect is confirmed or uncertain;
- why and where the run terminated.

Operational logs and durable user history are separate. Verbose diagnostics are opt-in and locally retained with
bounded size. Production correctness must not depend on telemetry or a remote service.

## 26. Backward compatibility and rollout

- Existing conversations, Memory, Skills, downloaded models, MCP settings, and tool choices remain readable.
- Existing flattened `ToolRun` entries remain displayable as legacy history but are not reconstructed into fake agent
  journals.
- Conversation records gain optional run references plus the versioned `ConversationToolPolicy`. Legacy policy
  materialization is one-time and never silently expands after later global setting changes.
- New-runtime user and assistant messages project from the canonical journal through the durable outbox; startup and
  explicit resume reconcile any unacknowledged projection before accepting conflicting mutations.
- The current `ToolLoop` remains behind a compatibility adapter during migration, then is removed only after every
  supported model and tool passes the new runtime contract tests.
- The feature must be guarded by an internal rollout switch until recovery, approval, and real-device suites pass.
- Rollback must leave conversations and existing settings readable even if new resumable runs become unavailable.

## 27. Test strategy

### 27.1 Deterministic unit and property tests

- every legal and illegal state transition;
- event replay and projection determinism;
- schema migration fixtures;
- crash injection before and after every stable event boundary;
- duplicate and out-of-order event rejection;
- expected-version CAS races among approval, cancellation, lifecycle expiration, and tool/model callbacks;
- tool selection restricted to the conversation-allowed set;
- bounded Draft 2020-12 schema preservation, enforcement markers, canonicalization, and complexity limits;
- approval scope and arguments-hash binding;
- approval time-of-check/time-of-use expansion rejection;
- malicious remote descriptor attempts to downgrade effect, retry, or approval classification;
- budget enforcement and no-progress termination;
- retry, idempotency, and uncertain-result classification;
- context budget accounting and deterministic compilation;
- artifact integrity, confinement, reference counting, and cleanup;
- file-protection, backup-exclusion, device-lock, disk-full, WAL corruption, and migration-backup behavior;
- cross-store outbox crashes at send, final-answer, undo, and delete boundaries;
- cascade deletion of journal rows, approvals, bookmarks, sidecars, artifacts, backups, and diagnostics;
- cancellation propagation and noncooperative implementation handling;
- capability attenuation for reserved child and sandbox contracts;
- fuzzing of model tool-call syntax, MCP schemas/results, and persisted event envelopes.

Tests use a virtual clock, deterministic IDs, scripted model providers, fake tools, fake approval responders, faulting
storage, and a protocol-level fake sandbox provider. The fake sandbox validates the public API only and is not a
production sandbox implementation.

### 27.2 Integration tests

- pure chat performs exactly one model pass and no tool-selection pass;
- multi-tool chains produce one committed final answer;
- malformed tool output receives one repair and then terminates;
- an image question never enables or invokes Web Search unless that conversation allows it and approval succeeds;
- Memory save/recall remains canonical, durable, and independent of master tool availability where intended;
- MCP tool names, complete schemas, structured results, cancellation, and failure states survive adaptation;
- external read and write approval, denial, expiry, changed arguments, and background waiting;
- MCP setup/refresh approval before `initialize` or `tools/list`, stable server identity, and unknown-effect defaults;
- app termination during model generation, approval, pure read, idempotent write, and uncertain write;
- mixed multi-tool batches with denial, failure, and reconciliation in each ordinal position;
- stale or duplicate approve/respond/pause/resume/cancel commands from old UI projections;
- resume with missing model, changed tool schema, removed Skill, or revoked system permission;
- multi-scene foreground aggregation and iOS 17 background-task expiration;
- continued-processing submit success, queue, rejection, expiration, system cancellation, and user cancellation;
- VoiceOver, maximum Dynamic Type, untruncated approval scope, stable focus, and double-activation protection;
- stopping a run does not finalize a ghost answer or cancel a newer run;
- app launch does not select a conversation, load a model, or resume a run.

### 27.3 Real-device matrix

Real-device validation is mandatory for at least:

- Bonsai 8B 1-bit;
- Gemma 4 E2B in its installed supported variant;
- Apple Intelligence where available;
- one vision-capable GGUF model;
- iOS 17 baseline behavior on an available compatible device or dedicated device farm;
- iOS 26 continued-processing behavior on a supported device.

Each capable model is tested for ordinary chat, selected-tool calls, multi-step completion, memory, malformed calls,
duplicate suppression, stop, foreground/background transition, recovery, and final-answer conformance. Vision tests
verify that the image is used directly and that Web Search does not activate without the required user decisions.

The device harness must never interact with unrelated system dialogs. Unexpected system UI is captured as a test
failure with diagnostics.

### 27.4 Performance and resource gates

- no measurable extra model round trip for ordinary chat;
- tool selection completes without model inference;
- time-to-first-visible-output regression stays within an agreed threshold;
- journal writes do not occur per token and do not stall streaming;
- database and artifact storage remain bounded and recoverable;
- one resident local model invariant is maintained under cancellation, backgrounding, and switching;
- thermal and memory-pressure behavior remains safe on the smallest supported device tier;
- no run can exceed hard budgets through retries, repair, or resume.

## 28. Acceptance criteria

The first release is complete only when all of the following are true:

1. Ordinary chat, reasoning display, vision, Memory, Skills, built-in tools, and MCP run through `AgentRuntime` without
   behavior regression.
2. `ChatStore` no longer owns the agent loop or durable execution state.
3. Every run has a replayable journal and explicit terminal or waiting state.
4. Every external operation enforces `prepare -> authorize -> execute`; it cannot exceed the immutable authorized
   destination, data, argument, redirect/fallback, and effect plan.
5. Conversation-persistent intelligent tool selection cannot expand the allowed set.
6. No malformed output, duplicate call, retry, background transition, or resume path can create an infinite loop.
7. Non-idempotent uncertain actions are never silently replayed or reported as successful.
8. App launch remains neutral: no automatic model load, conversation navigation, or run resume.
9. The open-source build works with no sandbox provider and contains no private-runtime implementation dependency.
10. Journal/outbox recovery cannot produce a missing or duplicate accepted user message, final answer, or deletion.
11. `AgentExecutor` and experimental `AgentSandboxAPI` handles support idempotent start/commands, cursor-based
    detach/reattach, and subscription cancellation without cancelling execution.
12. Data protection, backup exclusion, device-lock behavior, and conversation/Delete All cascades pass fault tests.
13. All MLX-free package tests, app build tests, UI tests, fault-injection tests, and required physical-device scenarios
    pass.
14. One independent post-implementation audit finds no unresolved release-blocking correctness, persistence,
    permission, privacy, or lifecycle issue.

## 29. Implementation sequence

Implementation is one dependency-ordered program, followed by one consolidated independent audit:

1. Freeze value types, IDs, state machine, event envelope, Tool V2, model-provider, approval, `AgentExecutor`, and
   `AgentSandboxAPI` contracts with exhaustive contract tests.
2. Add the SQLite journal, projections, artifact store, deterministic context compiler, and recovery tests.
3. Adapt local models, existing tools, MCP, Memory, and Skills behind the new contracts.
4. Implement the runtime controller, resource arbiter, budgets, retries, approval engine, and iOS lifecycle behavior.
5. Replace ChatStore orchestration with commands/projections and add progressive activity/approval/resume UI.
6. Run the full simulator, fault-injection, and physical-device matrix.
7. Conduct one independent audit against this specification.
8. Address release-blocking findings in one bounded remediation pass, rerun the complete verification suite, and
   prepare the release decision.

No production implementation begins until this specification has completed independent review and its blocking
findings have been resolved.

## 30. Deferred decisions

These decisions are intentionally deferred because the corresponding capability is not implemented now:

- online provider vendors, authentication schemes, pricing UI, and routing policy;
- the private sandbox runtime's transport, packaging, entitlements, and binary distribution;
- subagent scheduling limits and local/remote concurrency;
- workflow definition language, interpreter, DAG semantics, saved-workflow locations, and workflow UX;
- distributed or cross-device execution.

Their future implementations must honor the contracts and authority boundaries established here.

## 31. Independent specification review

An independent read-only architecture review completed on 2026-08-01 with the verdict **approve with required
changes**. This revision incorporates its blocking findings:

- enforceable `prepare -> authorize -> execute` boundaries across all external access;
- one canonical journal plus durable idempotent ConversationStore projection;
- unambiguous final-answer, multi-tool, user-input, foreground, and reconciliation states;
- run ownership, versioned idempotent commands, database CAS, and durable pause semantics;
- one-time per-conversation tool-policy migration and conservative MCP trust mapping;
- explicit iOS 17 quiescence and bounded iOS 26 continued-processing eligibility;
- reconnectable durable AgentExecutor and minimal experimental sandbox handles;
- data protection, backup, deletion, accessibility, and corresponding fault-injection requirements.

The review found the Dynamic Workflows boundary correctly deferred. No production implementation may begin unless a
final consistency check confirms that this revision contains the listed changes.

## 32. References

- Current repository architecture: `docs/ARCHITECTURE.md`
- Historical product design: `docs/DESIGN.md`
- Security boundary: `SECURITY.md`
- Apple background execution strategies: <https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app>
- Apple continued processing: <https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/>
- Public Dynamic Workflows behavior: <https://code.claude.com/docs/en/workflows>
