# Dynamic subagent research evaluation, 2026-10-22

This is the historical record of attempts 1–7. See the [October 23 follow-up](2026-10-23-dynamic-research-followup.md)
for subsequent repairs and current acceptance. The outcomes below retain their original scope.

**The runtime demonstrated real parallel delegation and complete result handoff, but the European
research task did not pass end-to-end acceptance.** One run completed all seven children and produced
a readable answer, yet retained only four groups in three countries. The later coverage run collected
more material but failed before final synthesis. The [edited research overview](2026-10-22-europe-efficient-ai.md)
contains 12 groups or specific research teams in nine countries after additional primary-source checks
by the maintainer. Those checks are not app execution evidence.

## Task and actual execution

The requested shape was four regional researchers, two independent verifiers, then one writer. Regional
research and verification each had to run in parallel. The initial target was 12–16 groups, at least six
countries and eight distinct HTTPS citation hosts, with 18 total tool calls. The follow-up carried forward
four findings and allowed 22 calls to investigate missing countries. Both tasks included training and
inference systems, compression, compilers, hardware and edge AI, including efficient computer vision.

The existing `DynamicWorkflowExplorationUITests/test99AdHocGoalFromEnvironment` entered the goal through
the app UI. It used an ad-hoc signed iPhone 17 / iOS 27.0 Simulator, Xcode 27.1 / Swift 6.4, production
runtime and transport, and the selected DeepSeek standalone web service. The requested model IDs were
`deepseek-v4-flash` and, for two later attempts, `deepseek-v4-pro`. These are provider aliases, not pinned
backend revisions. No fixed model response or external coding-agent subtask supplied the child answers.

In the completed Flash run at `425ba1e`, the durable workflow journal records the following intervals.
Time zero is the first child submission, so these durations exclude workflow generation and UI setup.

| Child responsibility | Submitted, seconds | Settled, seconds | Successful Search / Fetch calls |
| --- | ---: | ---: | ---: |
| UK and Ireland discovery | 0.000 | 11.296 | 3 / 0 |
| Germany, Austria and Switzerland discovery | 0.015 | 11.669 | 3 / 0 |
| France and Benelux discovery | 0.019 | 13.535 | 3 / 0 |
| Nordic, southern and central/eastern Europe discovery | 0.023 | 11.910 | 3 / 0 |
| Identity and activity verification | 13.588 | 32.653 | 3 / 0 |
| Efficiency evidence verification | 13.596 | 36.150 | 3 / 0 |
| Final synthesis | 36.218 | 51.857 | 0 / 0 |

The four discovery intervals overlap, both verifiers start after the discovery barrier, and synthesis
starts after both verifiers settle. Every discovery result's complete canonical serialization occurs
in both verifier prompts and the final writer's prompt; both verifier results also occur in the writer's
prompt. All 14 expected handoffs match. These checks use persisted child requests and answers, not just
the generated source or labels in the UI. The UI test took 157.683 seconds, which is not model latency.

All 18 tool invocations succeeded against `https://api.deepseek.com`, with no fallback destinations.
**All 18 were Search calls; none was Fetch.** Consequently, the answer's claims that official pages had
been read cannot be accepted as evidence of direct page retrieval. It also counted four countries where
its rows contain three, and claimed nine HTTPS source hosts where the answer contains six actual linked
HTTPS hosts. Its exclusion of efficient vision teams as insufficiently related to LLMs narrowed the
user's scope incorrectly.

The existing generic UI gate passed because it checked completion, seven children, a `parallel(` fan-out,
readable text, required concepts and at least two citation hosts. It did not assert this goal's 12-group,
six-country or eight-host thresholds. Manual goal-level evaluation therefore failed. A generic UI pass
must not be presented as research success.

## Outcomes retained across changes

These runs used evolving code, prompts and model aliases. They are a debugging sequence, not independent
samples from which a success rate or model comparison can be calculated.

| Attempt / local xcresult basename | Model request | Observed outcome |
| --- | --- | --- |
| 1. `EuropeEfficientAI` | Flash | Seven children completed with zero tools; generator tool suppression had erased the delegated catalog. Quality check failed. |
| 2. `EuropeEfficientAI-ToolsInherited` | Flash | Four discoveries completed 12 network calls. A verifier's HTTP URL failed during tool preparation and aborted the workflow. |
| 3. `EuropeEfficientAI-ArgumentRecovery` | Flash | 18 successful calls, then verification exhausted cumulative input capacity despite remaining model attempts. |
| 4. `EuropeEfficientAI-ConsistentBudget` | Flash | Seven children, actual parallel execution, 18 searches, complete handoff. UI gate passed; research coverage failed. Exact answer retained below. |
| 5. `EuropeEfficientAI-CoverageFollowup` | Flash | Revised geographic coverage failed on an empty provider response; no final report. |
| 6. `EuropeEfficientAI-CoveragePro` | Pro | Structured-output repair was exhausted for a child; other work was cancelled. Generic malformed-action diagnostics do not establish the precise schema mismatch. |
| 7. `EuropeEfficientAI-ResearchBriefs` | Pro | Six children settled, 18 successful calls and one failed Fetch; final writer was prepared but never submitted. Source ran independent work serially and the UI gate failed. |

Attempt 7 used Markdown briefs instead of schemas. All four complete discovery outputs reached both
verifiers, including the defective German output. The 19 actual calls comprised 11 Search and eight
Fetch calls, one Fetch failing. Six child intervals span 150.325 seconds. The final writer's default
reservation required six tool calls after 19 had been consumed, causing
`budgetExceeded(toolInvocations, limit: 24, requested: 25)`. The prompt requested a writer with no more
web calls, but a prompt instruction does not change its frozen tool budget. No allowance was increased
to make this outcome pass. The tool wrapper timed out after 300 seconds; the underlying XCTest continued
and recorded its actual failure at 320.514 seconds.

## Repairs made and focused verification

- `f6716b6` preserves the full frozen catalog and policy for children while suppressing tools only in
  the generator's model request. The regression covers freezer round-trip and user-disabled tools;
  33 existing execution, tool-selection and durability checks also passed.
- `51330e6` moves invalid DeepSeek URL handling inside authorized execution, producing an ordinary
  failed tool result without reading credentials or making a network request. HTTPS restrictions
  remain enforced. Three focused DeepSeek adapter cases passed. Workflow failure diagnostics now
  retain runtime and UI attachments.
- `425ba1e` aligns cumulative input/output token capacity with the already admitted model-pass count
  and keeps per-pass ceilings. The new ledger test consumes every admitted pass and rejects an extra
  one. It and the generator regression passed.
- `c87c2c7` routes an empty structured provider response through the existing single journaled repair
  instead of the unrelated permanent empty-answer error. The provider and repair integration checks
  passed; two existing checks confirm repair failure still terminates without an extra attempt.
- `1016caf` prefers readable research briefs when a downstream agent only reads the result. Schemas
  remain appropriate when the script actually computes or branches on fields. Attempt 7 is the live
  outcome of this prompt change; it is not recorded as a successful fix of overall research quality.

The app-specific regressions used the temporary SwiftPM harness containing the exact current App
sources and the test-module import substitution. Simulator runs built and executed the actual App.
Overlapping targeted runs are not summed into a new suite count. No full repository suite was repeated
for prompt or documentation changes.

## Remaining problems exposed by this task

1. **Planning requirements are not semantic acceptance conditions.** The latest generator ignored the
   explicit parallel requirement. Analyzer acceptance proves allowed syntax and effects, not adherence
   to the user's phase/concurrency plan. `meta.phases` alone also did not create executed phase events.
2. **Valid remaining budget can be stranded.** A fixed quarter-share reservation can reject a final
   synthesis child even when it intends no more tool calls. Any improvement must attenuate and durably
   account available capacity, including concurrent admission and recovery; merely raising the total
   or trusting a prompt's stated tool limit would not solve the policy problem.
3. **A completed child can return a tool envelope as its answer.** The German brief was literal
   `<｜｜DSML｜｜tool_calls>` markup. Identity verification correctly flagged the missing brief. The runtime
   nevertheless treated the child's text as completed. This requires provider-output handling and a
   useful-answer check, not treating the serialized markup as a successful tool invocation.
4. **Evidence attribution is unreliable.** Verifiers sometimes called search summaries page reads,
   overstated responsible roles, or supplied an incorrect project year. The latest identity verifier
   made zero new tool calls, so its work was comparison of supplied briefs, not external verification.
   Evidence grades should be checked against actual tool observations, not a model's self-description.
5. **Failure presentation loses useful progress.** The failed workflow projection had zero aggregate
   counters despite six settled children. The journal retained their results, but automatic partial
   delivery did not produce a final answer. This evaluation did not demonstrate recovery from a
   terminal failed workflow or resumption at an individual failed child.

The next acceptance run should follow fixes to these specific failures and check the actual research
requirements. Repeating the full prompt unchanged until a green run would not establish reliability.
Physical hardware is unnecessary for these online orchestration issues. This task did not measure
local-weight residency, warm-up, thermal behavior or GPU performance.

## Reviewable evidence

- [Compact journal-derived metrics and exact public tool arguments](evidence/2026-10-22-dynamic-research.json),
  including source/prompt/answer hashes, child intervals and handoff checks.
- [Unedited app answer from attempt 4](evidence/2026-10-22-app-answer-original.txt). Its incorrect counts,
  exclusions and source-read claims are retained as observed output.
- [Unedited child briefs from attempt 7](evidence/2026-10-22-app-briefs-original.json), including raw markup
  and conflicting verification claims. They are evidence of behavior, not authoritative research facts.

Full xcresults, SQLite backups, generated scripts, prompts, logs and input goals remain local under
`/tmp/mobilellm-europe-efficient-ai-20261022/`. Debug test products may contain local provider configuration
and are not publication artifacts. The committed evidence contains public research queries/results
and derived metrics only, with no provider credentials.
