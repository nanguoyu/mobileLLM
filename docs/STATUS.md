# Current implementation and validation status

Updated **2026-10-25** for the v5 collaboration runtime and app launch path on `main`. The dated model evaluations below
retain their original tested versions and outcomes; interface changes do not rerun or recertify them.
[spec.md](../spec.md) defines requirements, [ARCHITECTURE.md](ARCHITECTURE.md) describes the code,
and [CONTRIBUTING.md](../CONTRIBUTING.md) gives validation commands.

## Task workspaces and interface

Workflows now show stage-grouped worker tasks, their actual execution state, and public results read
from the verified value store. Coordination calls and source inspection live under Execution details.
Continuations share a logical task history; input links resolve by journal sequence so a later retry
cannot replace an earlier consumer's source. Missing metadata in older records remains explicit.

The initial planner and pending child tasks expose approval and question controls through isolated,
observer-only run stores. Opening a detail cannot submit another run or overwrite the main chat.
Workflow pause and reconciliation retain their existing command boundaries. Rejected commands show
their safe error. Completed history stays available, and final-answer replay uses the recorded end time
without bumping conversation activity on reads.

The composer has a Work with agents entry. Model options use progressive disclosure, settings explain
choices more briefly, and the chat header identifies the actual online model. Workflow cards use the
shared light/dark palette and support large text. Model searches dismiss their keyboard on submission
and interactive scrolling. [Current screenshots and clips](../assets/demo/README.md) show these surfaces.

Validation used focused contract, coordination, presentation, observer-command, title, and history
checks, plus one Simulator UI scenario. That scenario passed through the composer entry, Ask-mode
planning and child approvals, saved-output reading, copy feedback, exact call history, source inspection,
and final-answer projection. Early UI attempts found inherited accessibility identifiers; the view
scopes were fixed while retaining the invocation-count assertions. A later cold-relaunch check caught
the second history timestamp writer and now exercises a changed metadata snapshot, not a no-op save.

Two real `deepseek-v4-flash` tasks exercised the production Simulator app: a three-worker recipe-app plan
with source-result navigation, and an offline-note task whose initial planner, worker and subsequent
coordinator were approved through the actual UI. The latter includes manual waiting and is not a
latency measurement. Dark Mode, accessibility-extra-large text, completed-history access, model options,
tool settings and the search keyboard were inspected directly. iOS and macOS app builds and the static
verifier passed. The Mac desktop was locked, so native Mac visual inspection could not be completed.
No full repository suite or paid task matrix was rerun for the UI changes.

## Autonomous collaboration: current assessment

### Persistent task conversations

Task details now open a continuing agent conversation. Human updates are committed before acknowledgement,
included atomically with their model-request context, and retained through pause, cancellation and restart.
An update arriving during generation prevents the old answer from completing the run without incorporating
it. Later human turns use the shared executor with the task's frozen model and capability scope. The original
workflow result and its dependency links remain historical. Follow-up usage belongs to its own turns.

At `f2ef16d`, the production Simulator app made three real `deepseek-v4-flash` follow-ups to a saved storage
agent. It retained SQLite, accepted a project name and a 14-day retention requirement, then changed retention
to seven days. After app termination and relaunch, a question that omitted those values returned all three
correctly. The journal contains four activations including the earlier seed, three accepted inputs and three
request inclusions. [Public evidence](evaluations/evidence/2026-10-24-agent-sessions.json) preserves the original
inputs, outputs, model identities and usage. This is an interactive continuation case.

Focused checks cover commit interruption, stale writers, schema migration, steering, repeated turns,
cancelled-input retention and background quiescence. The existing Simulator workflow UI scenario now also
sends a follow-up, handles its approval, checks the visible reply and verifies that the original result is
unchanged. It passed at `c4b4597`; its controlled transport is UI integration evidence. The actual Simulator
interaction separately found and fixed missing automatic scrolling to new replies. Relevant runtime and
UI-store checks, iOS and macOS builds, and the static specification verifier passed. Evidence is retained under
`/tmp/mobilellm-harness-session-20261024/`, including `TaskSessionUI.xcresult`.

New app launches now use `collaborative-workflow-v5`. It reuses agent sessions under the shared workflow
budget, records actual sending coordinator identities, dispatches dependencies after individual results,
and persists versioned tasks and goal continuation. Reopening a source invalidates consumers without
replacing historical artifacts. Delivery cannot conceal required unfinished tasks. A blocked goal retains
partial results and requires explicit continuation; reading history cannot resume it. Saved v4 scripts
retain their original source and replay behavior.

At `a93f042`, 68 focused runtime, graph, replay and script-boundary checks passed. The v5 production-engine
case starts a dependent worker before an unrelated slow worker ends and hands off an exact later source
range. The app cutover then passed the existing Simulator interaction scenario with controlled transport:
planning and child approvals, three worker results, six actual workflow calls, saved follow-up and source
inspection. Its xcresult is `/tmp/mobilellm-harness-20261025/V5Cutover.xcresult`. These checks establish
runtime and interaction behavior. Peer messages and artifact reads now cross the ordinary Tool V2 authorization boundary and use actual
sender identities. The coordinator continues a durable session under shared reservations. Focused tests
cover model-authored message acceptance, later inclusion and the message/goal-completion race. The iOS
build passes. Long-context capability work, goal/task graph UI and new real-model qualification remain in progress under the [implementation plan](AGENT_HARNESS_PLAN.md).
The separate iOS sandbox remains optional; earlier autonomous outcome evidence retains its tested version.

### v5 development evaluation

The new production path completed the incident-evidence case with real `deepseek-v4-flash` on the iPhone
Simulator in 82.856 seconds. Four agent identities formed three dependency stages, with two dependent
workers receiving exact original artifacts. The coordinator used five activations in one durable session.
Independent evidence and recovery-choice checks passed without corrective prompts. The run used five
team-tool calls; two coordinator roster reads duplicated its task graph and prompted removal of that
coordinator permission. [Retained evidence](evaluations/evidence/2026-10-25-v5-incident-development.json)
records the result at runtime `7f9c76f` and evaluator `48fb944`. This is one development run, not the final
six-family qualification or a reliability estimate.

### Earlier autonomous engineering tasks

The general supervisor now completes independently checked multi-stage engineering tasks. Real online
runs on the iPhone 17 / iOS 27 Simulator passed three different task types:

| Task | Work and validation | Native time |
| --- | --- | ---: |
| SQLite migration | Three worker waves; generated script passes data, FK, normalized uniqueness, idempotency and rollback checks | 715.926 s |
| Maintenance/outage plan | Four worker waves; recovered from a failed worker, used Calculator, then adapted and verified the plan | 301.529 s |
| Incident recovery | Three worker waves; correct evidence classifications and recovery choices without unsupported effect claims | 212.512 s |

Every accepted run has at least two dependent workers receiving exact earlier artifacts after their source
settled. Only the original task was supplied during execution. The app produced the SQL; the evaluator
executed it unchanged in isolated databases. The [native evaluation](evaluations/2026-10-23-multistage-native.md)
records exact versions, all seven attempts, the actual failed-worker recovery and the strengthened migration
boundary cases. This is evidence of staged collaboration across task types, not an arbitrary-task success-rate estimate.

General fixes include actual settled-budget accounting, exact input ranges for dependent handoffs, retained
observations, and a clear distinction between host delegation and worker tools. Explicit collaboration
requirements are honored rather than replaced by a direct answer. Format repair preserves the assigned
role and output protocol. Native evaluations share the production preparation/execution path used by chat,
with live calls disabled unless explicitly opted in. Nine focused orchestration/replay checks, two repair
regressions and executable-oracle counterexamples passed. A final offline regression rejects standalone
XML tool-call envelopes while preserving quoted examples; it uses the existing repair path. No full suite
was repeated for prose.

The earlier [research evaluation](evaluations/2026-10-23-autonomous-coordination.md) remains historical:
its API comparison passed core checks, while the Europe answer missed ELSS. No ELSS-specific runtime rule
was added. Research coverage and broad repeated-run reliability remain open measurements. Autonomous session
reuse, asynchronous peer messaging and production code-execution tools remain separate gaps.

The [agent harness implementation plan](AGENT_HARNESS_PLAN.md) sequences persistent child sessions,
durable messaging, dynamic task dependencies, goal continuation and long-context work. The near-term
milestone uses available tools and does not depend on the owner's separate iOS sandbox project.
Production code execution and workspace qualification remain a later provider integration.

## DeepSeek Search and Fetch integration

The optional web service uses DeepSeek's independent JSON APIs. Select the configured account in
Settings → Choose tools → Web service; keep Web search and Webpage reader enabled for the conversation.
The selection applies to local models, online models, and workflow children through the same frozen
tool catalog. Public search/direct page reading remain the default. Provider-hosted model tools in
spec §15.5 are still a separate future surface.

On 2026-10-22, the signed iPhone 17 / iOS 27 Simulator used the configured DeepSeek v4 flash model
to search for the official Search/Fetch documentation, read its guide, and answer with source links.
`test16DeepSeekSearchAndFetchThroughConfiguredWebService` passed in **70.798 seconds** including UI
navigation and polling. The SQLite journal contains exactly two completed tool invocations, both
bound to `https://api.deepseek.com` and the selected account, with no allowed fallbacks. The answer
reported both official POST endpoints and the guide's billing terms. This exercises the actual APIs.

Five client tests, 20 settings-persistence tests, and two new app adapter/account-binding regressions
passed. The existing ten app adapter regressions also passed during integration. The final static
verifier passed with updated spec anchors and all five digests. A first simulator build caught a
missing App-module import and was corrected before the successful live run. An intermediate test
fixture string delimiter was also corrected. No full repository suite was repeated for this feature.
Evidence is local under `/tmp/mobilellm-deepseek-search-20261022/`, including `DeepSeekWebLive.xcresult`,
`journal-evidence.json`, and `live-answer.txt`.

## Earlier supervised European Efficient AI research evaluation

The supervised application run delivered [12 research teams across ten countries](evaluations/2026-10-23-europe-efficient-ai-app.md),
with 14 HTTPS citation hosts, through supervised multi-stage continuation. Actual geographic investigation
ran in parallel; later agents checked evidence, corrected identities and sources, and wrote recommendations.
The final source verifier and writer both completed. The last stage used two searches and one page read,
then a zero-tool writer, with the complete verified result and all source URLs handed off.

The task repaired delegated tool loss, remaining-budget admission, per-role caps, provider continuation,
repair accounting, page-miss handling, cancellation races, country counting, evidence handoff, inherited
reasoning settings, Chinese web-tool selection, remaining-time reservations and prompt normalization.
Focused regressions and actual online execution cover these fixes. Earlier failed runs remain recorded.

The last UI run's only failure was a vocabulary check expecting 研究组 while the answer said 团队.
The original answer passed offline replay of the same checks with that semantic alternative included;
no model was rerun for wording. The readable export restores the already returned country codes in the
table and adds a legend; research facts and recommendations remain unchanged. The raw answer is retained.
Three PI fields remain explicitly unknown, and this result is evidence of supervised completion rather
than an unattended one-pass reliability measurement.

The [follow-up evaluation](evaluations/2026-10-23-dynamic-research-followup.md) links raw outputs, actual
child intervals, source checks and every later outcome. The [original evaluation](evaluations/2026-10-22-dynamic-research.md)
retains the first seven attempts. The earlier [maintainer-edited overview](evaluations/2026-10-22-europe-efficient-ai.md)
is separate and was not used as the application's answer. Full private artifacts remain local under
`/tmp/mobilellm-europe-efficient-ai-20261022/`.

## Corrections delivered

- Production Memory now applies the switch and relevance ranking to the latest durable snapshot.
  Disabling it also excludes its tools from new runs. Original Chinese user text supplies a bounded,
  authorization-bound retrieval alias, without trusting a model-supplied source field.
- Online function calls preserve provider call IDs, wire names, arguments, and bounded reasoning state
  through journal recovery and native call/result continuation. Shared local/online tool aliases avoid
  collisions and unsupported characters. Structured online requests include the full output schema.
- Webpage redirects cannot leave the approved scheme, host, or effective port. Existing public-address,
  response-size, symlink, and artifact-integrity checks remain enforced.
- Accepted-message payload v2 retains image references; projection restores their bytes and drains all
  pages. Resumed local-model requests resolve exact durable references without an in-memory allowlist.
  Artifact-root comparison no longer mistakes a directory URL hint for a confinement violation.
- A continued-processing exemption requires an actual unexpired OS grant. It preserves eligible work
  and weights, includes llama.cpp GPU eligibility, and reports the real terminal outcome.
- `stallMs` now enforces child inactivity, with resets on progress and cancellation on expiry. The
  conversation tool menu supports up to eight pins within the allowed set. New context policy 2 gives
  current state and recent tool results priority; old frozen policy-1 runs retain their order.
- llama.cpp reuses exact compatible text-prompt KV prefixes and invalidates them when replacing context,
  changing model/KV settings, handling vision, or failing/cancelling. MLX uses completion-token metrics
  and forwards native tool calls. No measured local-weight speedup is claimed.
- Workflow analysis distinguishes pure literal schema fields such as `test` from executable operations.
  Generated workflows request readable final answers and Markdown research briefs; intermediate schemas
  are reserved for results whose fields the script needs to inspect.
- Live UI tests use isolated real stores, preferences, and Keychain services. Fixed-response fixtures
  live separately. Hidden prompt retries, answer-containing calculator prompts, fake child-detail
  padding, automatic live API calls in ordinary suites, and default thermal bypasses were removed.
- Test selection follows changed files and reverse package dependencies. Prose-only changes select no
  Swift suites. Full offline baselines and coverage instrumentation are explicit choices.

## Direct simulator and online results

Host: **Xcode 27.1 / Swift 6.4**. Simulator: **iPhone 17 / iOS 27.0**, ad-hoc signed so Keychain works.
Service: **api.deepseek.com / deepseek-v4-flash**, using actual production transport and runtime.
No local weights or fixed-response fixture were used for these four flows.

| Flow | Observed result | Result bundle |
| --- | --- | --- |
| Calculator | Actual tool invocation returned `9449772114007`; the prompt did not contain the answer | `CalculatorRuntime.xcresult` |
| Multi-turn context | Correctly reused information from the earlier turn | `LiveCoreFlows.xcresult` |
| Chinese Memory across conversations | Saved through the actual tool, then recalled the exact token in a new conversation without opening Memory Settings or invoking recall | `LiveCoreFlows.xcresult` |
| Incident-analysis workflow | Three investigators plus synthesis completed; final output was readable analysis with containment, durable fixes, migration concerns, and crash-boundary tests | `WorkflowReadable.xcresult` |

The final workflow journal records investigator submissions at offsets **0, 15, and 21 ms**, with
settlement at **7,891, 8,223, and 7,356 ms**. Their in-flight intervals overlap by about **7.3 seconds**;
synthesis starts at **8,269 ms**, after all three settle. This is direct execution evidence, not an
inference from the generated script containing `parallel(...)`.

The four UI test durations were 63.587, 34.697, 73.978, and 107.846 seconds respectively. These include
UI navigation and polling and must not be reported as model latency. A separate explicitly enabled
live-provider request also passed. Artifacts and logs for this maintainer session are under
`/tmp/mobilellm-fixes-20261022/`; they are local evidence, not a committed release bundle.

First outcomes are retained. Unsigned simulator attempts could not seed Keychain; the subsequent
runtime startup failure exposed the artifact-directory bug. The workflow first failed with HTTP 400
because its JSON contract was missing from the prompt, then exposed the schema-field false rejection.
After those fixes it completed, but manual review found raw JSON displayed in chat. The final delivery
correction passed the strengthened readable-answer check. None of these failures was erased by retries.

Manual review found the final analysis useful and substantially more readable, but it still assigned
high confidence to some unsupported hypotheses, including missing provider idempotency. The user had
not supplied provider logs or keys. Functional success therefore does not establish factual accuracy
across complex tasks. The remaining exploratory scenario shapes and repeated provider-quality
measurements remain necessary before making broad reliability or SOTA claims.

### Follow-up swarm and warm-path check on main

A focused run passed **58/58** existing checks for dynamic ordering, parallel barriers, prefix reuse,
SQLite recovery, pause/resume without duplicate child submission, cancellation, authority limits,
and local-model residency. The residency-driver test verifies that loading the same selection twice
loads its engine once; online inference bypasses local residency entirely. These are control-path
checks, not measured local-weight warm-up or GPU-speed results.

The actual online untrusted-template scenario completed three independent reviewers and one
synthesis child, each on its first attempt. The durable journal records submission offsets of
**0, 3, and 8 ms**, and settlement at **5,685, 8,933, and 9,508 ms**. All three overlap for about
**5.7 seconds**; synthesis starts afterward at **9,545 ms**. The run completed and recorded **zero
tool invocations**, despite the quoted template asking for `fetch`, added tools, and blanket approval.

The initial UI test failed three English-only concept assertions because the final answer was in
Chinese. Inspection found the corresponding parser, rejection, and audit concepts in that exact
answer. The test now includes equivalent Chinese terms. Its unchanged `containsAny` matcher was
replayed against the saved answer and all six concept groups passed; an unrelated-text control was
rejected. No second model request was made just to retest translated assertion vocabulary, and the
original failing xcresult remains retained. Logs, the answer, and timing evidence are under
`/tmp/mobilellm-main-check-20261022/`, including `SwarmAuthority.xcresult` and
`swarm-journal-check.json`. Runtime execution and semantic spot checks succeeded; the captured
xcresult still records the original language-matching failure.

## Final scoped offline verification

One dependency-selected baseline ran **1,599 tests across eight affected packages**, excluding live
online requests. AppUI was unchanged and was not rerun. The initial baseline had **two failing test
cases**: one verifier coverage-policy mismatch, and one outbox-v1 expectation with four failed
assertions after the deliberate v2 format migration. Both were corrected and passed targeted reruns.

| Package | Discovered | Initial baseline result |
| --- | ---: | --- |
| AgentContracts | 97 | Passed |
| AgentHarnessVerification | 38 | One case failed; corrected verifier suite passed 10/10 |
| AgentRuntime | 508 | One case failed; corrected outbox case passed |
| AgentSandboxAPI | 29 | Passed |
| AppRuntime | 106 | Passed |
| LLMCore | 366 | Passed; one opt-in live MCP skip |
| LLMEngineApple | 41 | Passed; two OS/system-model availability skips |
| MobileLLMUI | 414 | Passed |

The final static verifier passed. JSON/test-plan parsing, shell syntax, all five spec digests, and
prose-only check selection also passed. Overlapping targeted runs are not added to the baseline count.

Xcode engine tests passed **56/56**: eight MLX mapping/governance tests and 48 llama.cpp tests.
The actual macOS App module passed **16/16** assembly/adapter regressions. Its first ad-hoc-signed
host stalled in `_libsecinit_appsandbox` before XCTest started; a process sample was retained and
that run was stopped. The tests then passed with signing and App Sandbox disabled only for the test
command. Production signing/entitlement settings were unchanged. This result proves App-module
behavior, not macOS sandbox launch or distribution acceptance.

The current toolchain built simulator and macOS app/engine targets after installing Apple's Metal
Toolchain component. Local-weight inference, matched resource/latency measurements, new source-mutant
runs, and release coverage/freshness bundles were not performed in this repair pass.

## Remaining product boundaries and release work

The manifest has **70 requirements: 67 active and three planned**, and **75 test entries: 72 active
and three planned**. These are traceability entries, not XCTest counts. Production Memory conformance
is active. The planned gates are the physical-device/model matrix, matched performance baselines,
and the consolidated independent release audit.

Simulator plus online models are sufficient for functional app and online-task validation. Physical
hardware is needed for local GPU/MLX performance, thermal and memory-pressure behavior, and OS
background scheduling. The historical physical-device matrix remains **23 pass / six pending**;
those dated outcomes were not promoted by simulator results. Continued-processing device outcomes,
clean-install/upgrade acceptance, and the complete real-model exploratory matrix remain open.

Files and Terminal deliberately show empty states. `AgentSandboxAPI` has no production provider,
and the JavaScriptCore workflow realm has cooperative limits rather than an OS sandbox or hard heap
limit. General-purpose `run_js` and provider-hosted native tools in spec §15.5 remain unavailable.
The legacy ToolLoop is still used by compatibility paths, previews, tests, and smoke executables;
WorkflowOrchestrator remains necessary for old records. Removing them wholesale would break those uses.

## Historical baseline retained

The initial 2026-10-22 review at code `82933a0`, before implementation changes, discovered **1,597
tests: 1,581 passed, 10 skipped, six failed**. Its file-protection failure passed outside the process
sandbox; five automatic live-provider cases failed in the restricted environment. That historical
record is separate from the explicit live request and simulator evidence above. Earlier August and
September device, mutation, coverage, and audit records retain their original dates and scope.

Hosted Linux CI selects document checks and portable Swift suites by impact. Pull requests and main
pushes trigger validation; feature-branch pushes do not duplicate a pull-request run. Paid hosted macOS
runners remain disabled; a trusted self-hosted Mac is opt-in. The implementation review in this task
was performed by the repairing agent and does not close the independent release-audit requirement.
