# Current implementation and validation status

Updated **2026-10-22** for the DeepSeek web integration and dynamic research evaluation on
`codex/deepseek-search`, based on `main`
after [PR #7](https://github.com/nanguoyu/mobileLLM/pull/7)
merged as [`fa68377`](https://github.com/nanguoyu/mobileLLM/commit/fa68377078a69222dd016d87579a16fa53dba701).
The earlier merged audit branch was deleted locally and remotely.
[spec.md](../spec.md) defines requirements, [ARCHITECTURE.md](ARCHITECTURE.md) describes the code,
and [CONTRIBUTING.md](../CONTRIBUTING.md) gives validation commands.

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

## European Efficient AI research evaluation

The real seven-child research workflow demonstrated four parallel regional investigators, two parallel
verifiers, and a final writer, with all 14 required complete-output handoffs verified from durable
child requests. That run completed 18 successful **Search** calls and no Fetch calls; its child interval
was 51.857 seconds and its UI test took 157.683 seconds. Its research result still failed the goal:
only four groups in three countries and six actual HTTPS citation hosts, below the requested
12–16 groups, six countries and eight hosts. The generic UI gate did not cover those task-specific
thresholds. Claims of full-page reading and some reported counts were incorrect.

The task exposed and repaired lost delegated tools, fatal handling of invalid web arguments, inconsistent
cumulative model-token capacity, and empty structured responses bypassing bounded repair. Research
handoffs now prefer Markdown when the script does not need typed fields. Focused regressions passed;
no full repository suite was repeated for these edits.

The latest Pro run produced six child outputs, but ignored requested parallelism, returned raw tool
markup as the German brief, and failed before synthesis because a fixed six-call reservation would
exceed the 24-call workflow budget after 19 actual calls. Evidence attribution, task-level acceptance,
available-budget allocation and partial-result presentation remain open. **The research scenario is
not accepted end to end.** Changing to a larger model did not establish reliability.

The [research overview](evaluations/2026-10-22-europe-efficient-ai.md) provides 12 groups or specific
research teams in nine countries after maintainer source checks. Those additions are not app-generated
success evidence. The [evaluation](evaluations/2026-10-22-dynamic-research.md) retains every attempt's
outcome, timings, committed public evidence and the remaining failures. Full artifacts remain local
under `/tmp/mobilellm-europe-efficient-ai-20261022/`.

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
