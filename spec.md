# iOS Agent Harness Specification

**Status:** Draft for independent review

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

The implementation should introduce two MLX-free packages and keep platform implementations injectable.

### 6.1 `AgentRuntime`

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

It may depend on `LLMCore` and `AppRuntime`, but not SwiftUI, MobileLLMUI, MLX, llama.cpp, EventKit, CoreLocation,
or the future private sandbox implementation.

### 6.2 `AgentSandboxAPI`

Owns only versioned, implementation-neutral sandbox contracts and Codable value types. It must not depend on
`AgentRuntime` implementation details, SwiftUI, a model engine, or a concrete sandbox.

### 6.3 Existing packages

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

All durable entities use stable opaque identifiers. At minimum:

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
uncertain
completed
failed
cancelled
```

Every transition is validated by a pure state machine and recorded before its projection is shown as committed UI.
Invalid transitions fail closed and produce a diagnostic event; they must never be silently coerced.

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
backgroundExpired
internalFailure
```

Nonterminal waits (`waitingForApproval`, `waitingForUser`, `waitingForForeground`, and `paused`) remain resumable.

## 9. Persistence and recovery

### 9.1 Source of truth

The agent runtime uses a transactional SQLite journal. WAL mode, schema migrations, foreign-key enforcement, and
transactional event sequence allocation are required. The specific Swift SQLite binding is an implementation choice
behind an internal storage adapter; storage semantics must not leak into the runtime APIs.

The journal is append-only for execution facts. Mutable projections and compact snapshots may be rebuilt from events.
Conversation JSON remains the user-visible chat store during migration; the agent journal references conversation and
message IDs rather than embedding duplicate conversation history.

### 9.2 Minimum records

- `AgentRunRecord`
- `AgentStepRecord`
- `RunEventRecord(sequence, payloadVersion)`
- `ModelAttemptRecord`
- `ToolInvocationRecord`
- `ApprovalRecord`
- `ArtifactRecord`
- `UsageLedgerRecord`

Every record format is versioned. Migrations are forward-only, transactional, and tested against production-like
fixtures. A migration failure preserves the original database and blocks mutation with a recoverable error.

### 9.3 Recovery algorithm

On explicit resume:

1. Load the latest materialized projection and replay later events.
2. Verify the pinned model, prompt, Skill, tool schemas, and capability grant are still available.
3. Classify the interrupted step as replayable, completed, uncertain, or incompatible.
4. Reuse completed artifacts and idempotent outcomes.
5. Restart an interrupted model attempt from its preceding stable boundary.
6. Never automatically replay a non-idempotent external action whose outcome is unknown.
7. Require user choice to migrate or restart when a pinned dependency is incompatible.

Opening the app lists recoverable runs but does not select their conversation, load their model, or resume them.

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

Tool execution may be concurrent only when the tools declare compatible resource and effect metadata. Multiple local
agents must not be presented as physically parallel on iPhone. Future subagents may be logically concurrent while
their local model passes are queued through the single decode lane.

## 12. Agent action protocol and loop policy

Every model pass resolves to one normalized action:

```swift
enum AgentAction {
    case answer(AgentAnswer)
    case callTools([ProposedToolCall])
    case requestUserInput(UserInputRequest)
    case finish(AgentAnswer)
}
```

The runtime validates tool names, full schemas, argument sizes, capabilities, approval requirements, and budgets
before execution. A malformed structured action receives at most one bounded, non-thinking repair pass. Failure of
that repair ends the run with a precise user-visible error.

No mandatory planner pass is added to ordinary conversation. Complex behavior emerges from successive bounded
actions. This protects first-token latency and avoids asking small local models to create plans they cannot reliably
execute.

Default budgets remain deliberately small and configurable by tested policy rather than by the model. At minimum:

- model-pass budget;
- tool-invocation budget;
- structured-repair budget;
- repeated-call budget;
- wall-clock deadline;
- token and context budgets;
- network-input and network-output budgets;
- artifact and persisted-output limits;
- thermal and memory policy.

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

The schema representation must preserve nested objects, arrays, enums, unions, required fields, bounds, and MCP
extensions instead of flattening them to string/number/boolean parameters.

### 13.2 Execution

```swift
protocol ToolV2: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func execute(
        request: ToolExecutionRequest,
        context: ToolExecutionContext
    ) -> AsyncThrowingStream<ToolExecutionEvent, Error>
}
```

The context includes run, step, and invocation IDs; normalized argument and schema hashes; deadline; cancellation;
idempotency key; capability grant; approval receipt; artifact writer; secret references; and redacted logger.

Results support text, structured JSON, image, resource links, and artifact references. Errors are typed and classify
retryability, uncertainty, user action, and whether any external effect may have occurred.

Existing tools are migrated through a V1 adapter. The adapter may conservatively declare limited capabilities, but
it must not fabricate idempotency or cancellation guarantees.

## 14. Conversation-persistent intelligent tool selection

Tool availability has three independent layers:

1. **Allowed set:** explicitly selected by the user and persisted on the conversation.
2. **Advertised set:** the relevant subset selected by the runtime for one model pass.
3. **Approved invocation:** permission to perform one external action or a narrowly scoped class of actions.

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
and user decision. Capability grants are immutable for a running step. Future child agents may receive only a subset
of the parent's grant.

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

## 18. Retry, idempotency, and uncertainty

Every failure is typed as transient, permanent, permission-related, budget-related, cancelled, incompatible, or
potentially side-effecting.

- Pure reads may retry with bounded exponential backoff and jitter.
- Writes retry automatically only when the tool declares and honors an idempotency key or supplies a reliable
  reconciliation operation.
- A timeout or transport loss after a non-idempotent external intent produces `uncertain`; the runtime must not claim
  success or replay the action.
- Duplicate suppression uses tool ID, schema version, normalized arguments, and effect scope, not raw model text.
- Cancellation propagates from run to step to model/tool execution. Noncooperative implementations are detached only
  after the journal records uncertainty and resource ownership is made safe.

## 19. iOS lifecycle and background execution

### 19.1 iOS 17 baseline

On iOS 17-25, leaving the foreground initiates a bounded quiescence sequence:

1. stop admitting new actions;
2. finish or cancel at the nearest safe boundary within available background time;
3. record the interrupted attempt and resulting status;
4. drain generation safely;
5. unload local weights when required by memory policy;
6. enter `waitingForForeground` if work remains.

Returning to the app does not resume automatically. The relevant conversation shows a resumable run and requires an
explicit Resume action, which then loads the pinned model.

### 19.2 iOS 26 continued processing

Where available and entitled, a user-initiated long run may register a `BGContinuedProcessingTask`. The integration:

- uses availability guards and does not raise the deployment target;
- requests GPU resources only on supported devices and only for local engines that need them;
- reports real progress to the system UI;
- handles queueing, rejection, expiration, and user cancellation;
- uses the same journal and recovery semantics as foreground execution;
- never treats continued processing as guaranteed runtime.

An already-running, user-authorized continued task may keep executing when the app leaves the foreground. A normal
app launch must still not load a model or resume an unrelated run.

## 20. Unified UI and interaction model

There is one chat UI, with progressive disclosure:

- ordinary local answers render exactly like ordinary chat;
- the composer displays the conversation's allowed and pinned tool state;
- complex runs expose a compact activity row that expands into steps;
- approval cards show the tool, destination, exact action preview, data being sent/read, and grant scope;
- waiting states clearly distinguish user input, approval, foreground, model, and resource waits;
- the user can Pause, Resume, or Stop the run;
- partial output is visibly marked incomplete and never confused with a committed final answer;
- tool and model failures show a specific recovery action rather than an empty bubble;
- elapsed reasoning and activity time derive from runtime events, not disclosure visibility;
- opening the app starts at the normal neutral shell, not the prior conversation or an auto-loaded model.

The UI displays operational summaries, model-provided visible reasoning where supported and enabled, tool activity,
and evidence. It does not invent, request, or persist private hidden chain-of-thought.

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

1. `AgentSandboxProvider` manages capabilities, sessions, resource policy, mounts, snapshots, and lifecycle.
2. tool adapters expose the operations a model may request within an authorized session.

Proposed contract shape:

```swift
protocol AgentSandboxProvider: Sendable {
    var descriptor: AgentSandboxProviderDescriptor { get }
    func capabilities() async throws -> SandboxCapabilities
    func createSession(_ specification: SandboxSessionSpecification)
        async throws -> any AgentSandboxSession
    func restoreSession(from snapshot: SandboxSnapshotReference)
        async throws -> any AgentSandboxSession
}

protocol AgentSandboxSession: Sendable {
    var id: SandboxSessionID { get }
    var events: AsyncStream<SandboxEvent> { get }
    func execute(_ request: SandboxRequest) async throws -> SandboxResult
    func snapshot() async throws -> SandboxSnapshotReference
    func cancel() async
    func close() async
}
```

The API reserves:

- semantic protocol version and capability negotiation;
- run-scoped session identity;
- workspace and artifact mounts;
- filesystem, network, process, and code-execution capabilities;
- resource budgets and deadlines;
- secret references without plaintext persistence;
- structured progress, logs, results, and artifacts;
- cancellation, expiration, snapshot, and restore;
- typed failures and uncertain side-effect reporting;
- audit events and redaction metadata.

A sandbox session receives an immutable capability subset and cannot request broader authority. Its output is
untrusted data. Restored sessions must revalidate provider version, capability grant, mounts, artifacts, and policy.

The exact private-runtime transport and binary distribution remain deferred until integration. The protocol and
behavioral tests are fixed now; no placeholder production sandbox is built.

## 22. Subagent compatibility seam

The root agent itself conforms to the future execution unit:

```swift
protocol AgentExecutor: Sendable {
    func run(_ request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>
}
```

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
- Conversation records gain only optional identifiers/preferences needed to reference new runs.
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
- tool selection restricted to the conversation-allowed set;
- full JSON Schema preservation and validation;
- approval scope and arguments-hash binding;
- budget enforcement and no-progress termination;
- retry, idempotency, and uncertain-result classification;
- context budget accounting and deterministic compilation;
- artifact integrity, confinement, reference counting, and cleanup;
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
- app termination during model generation, approval, pure read, idempotent write, and uncertain write;
- resume with missing model, changed tool schema, removed Skill, or revoked system permission;
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
4. External reads and writes cannot execute without a valid bounded approval receipt.
5. Conversation-persistent intelligent tool selection cannot expand the allowed set.
6. No malformed output, duplicate call, retry, background transition, or resume path can create an infinite loop.
7. Non-idempotent uncertain actions are never silently replayed or reported as successful.
8. App launch remains neutral: no automatic model load, conversation navigation, or run resume.
9. The open-source build works with no sandbox provider and contains no private-runtime implementation dependency.
10. The `AgentSandboxAPI` and `AgentExecutor` seams pass contract tests with fakes.
11. All MLX-free package tests, app build tests, UI tests, fault-injection tests, and required physical-device scenarios
    pass.
12. One independent post-implementation audit finds no unresolved release-blocking correctness, persistence,
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

## 31. References

- Current repository architecture: `docs/ARCHITECTURE.md`
- Historical product design: `docs/DESIGN.md`
- Security boundary: `SECURITY.md`
- Apple background execution strategies: <https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app>
- Apple continued processing: <https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/>
- Public Dynamic Workflows behavior: <https://code.claude.com/docs/en/workflows>
