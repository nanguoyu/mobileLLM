# Agent harness implementation and evaluation

The sandbox-independent collaboration runtime is implemented on `main`. It keeps persistent agents,
routes durable messages, schedules dependent work, preserves original evidence, accepts human goal
updates, and resumes from saved work. Tests exposed failures in these paths, and the fixes below were
implemented and checked through the production executor.

Capability qualification remains open. The frozen diagnostic predates the later repairs, and no complete
six-family batch has been run on one version incorporating those repairs. The reference DSH runs also
have different budget/profile semantics. The evidence below supports the recorded implementation and
task outcomes; [remaining qualification](../AGENT_HARNESS_PLAN.md#remaining-capability-qualification)
is still required to assess the owner's DSH-level capability goal.

## What the runtime now does

An agent session can have successive activations under one goal budget. Messages distinguish acceptance
from inclusion. Actionable instructions prevent premature completion; informational notices remain
saved and unread until a later request needs them, without creating an acknowledgement loop. Human
instructions cannot be downgraded to notices. Reassignment preserves both the old agent's inbox and the
replacement's ownership.

A versioned task graph controls claims, dependencies, retries and immutable result versions. A ready
consumer starts without waiting for unrelated siblings. An already-declared dependency chain advances
without coordinator calls just to say “wait”. A failure, a new instruction, or a result without a planned
consumer returns control to the coordinator. Opening a view never starts or resumes work.

Original task output and tool observations can be read by reference within the authorized goal. Context
reduction keeps original material available. Agent profiles narrow tools, skills, model selection and
reasoning effort within the parent's scope. Initial planning, repairs and later activations share the
budget. Team messaging has its own authority and grants no file or canonical-memory writes.

Explicit collaboration cannot finish without a real worker result. New goals also check supported,
explicit final/worker text limits and JSON-only delivery requirements. Checks include appendices and
headings. Rejected originals remain available, automatic correction is bounded, and final publication
must match the exact accepted answer. These checks do not replace evaluation of factual or semantic
correctness.

## Frozen diagnostic: 18 real tasks

The checkpoint was `1c37dec`, using the requested API ID `deepseek-v4-flash`, low effort, a 32K context,
and the production Simulator assembly. Each of six held-out variants ran three times. Inputs, model
settings, oracles and budgets were fixed before this batch. Unattended cases received only the original
task. The interactive case additionally received its declared scripted human amendment.

| Family | Completed and passed outcome checks | Independent checks |
| --- | ---: | --- |
| Source research | 3/3 | Actual Search/Fetch use, correct facts, quoted text present on its cited retrieved page |
| Constrained planning | 2/3 | Resource/dependency feasibility, optimum makespan, minimal rescheduling, cost and actual Calculator use |
| Incident analysis | 3/3 | Supported versus unknown effects and safe recovery decisions |
| SQL artifact construction | 2/3 | Executed SQLite invariants, data/FK preservation, uniqueness, repeatability and rollback on failure |
| Interactive correction | 3/3 | Accepted and included amendment, changed values, retained requirements and actual team messaging |
| Long-context synthesis | 2/3 | Original-context reads, early facts, later corrections and source labels |

**15 of 18 completed. Three paused.** Two coordinator failures came from invalid tool arguments.
Another run recovered a failed reviewer but left its former inbox unconsumed after reassignment.
The paused attempts retained their partial results and are not successes.
[All original attempts and rechecks](evidence/2026-10-26-harness-qualification.json) remain available.

The original evaluator also produced formatting false negatives. It failed to render CommonMark escapes
before checking quotations, and assumed that a lower-bound proof had to be an integer even though the
prompt allowed an explanation. Saved answers and their original source bodies were rechecked. The
schedule's feasibility, exact optimum and cost checks stayed in place. No model run was repeated to
repair these evaluator errors, and the original check results remain in the evidence.

This is an initial diagnostic sample, not a general success-rate estimate. Reported model IDs identify
the requested API alias; a separate protocol check returned `deepseek-flash`. The service's underlying
weights were not pinned. Model-attempt counters describe harness generation steps. Provider protocol
retries consume recorded tokens within a step, so these counters are not raw HTTP-request counts.

## Failures repaired and checked

| Observed problem | Change and relevant evidence |
| --- | --- |
| Messaging inherited incompatible local-write rules | Separate `agent.message` authority; complete app builder/validator check and real UI goal update |
| Idle or reassigned agents retained mandatory inboxes | Budgeted continuation, preserved ownership and originals; deterministic late-input/reassignment cases |
| Invalid native arguments stopped coordination immediately | Entire batch rejected without execution; one existing, metered controller repair; usage and failure provenance retained |
| DeepSeek rejected a continuation after a non-thinking repair | Preserve native history and send an explicit empty reasoning field when none was returned; focused tests and one real protocol acceptance call |
| Resume retried a caught historical coordinator failure before its checkpoint | Replay the failed outcome up to the recorded pause, then continue through the explicit resume grant |
| Closing notices caused new work | Typed informational notices, durable unread state, and backward-compatible message schemas |
| A model bypassed requested collaboration | Preparation requires assignments or a blocker; delivery requires an actual worker result |
| Completed output exempted an appendix from its word limit | Native whole-output checks, retained rejected artifacts, bounded correction and answer-digest binding |

The first repair follow-up was not uniformly successful: two fresh planning cases passed, one exhausted
its budget on unnecessary messaging, one SQL answer skipped the requested team, and the initial resume
attempt exposed the replay defect. Those failures are retained. After the notice/admission fixes at
`c5835ae`, **three planning runs and one SQL run passed**. At `aaa4d84`, both paused argument-failure goals
were resumed from copies of their original journals and completed in about nine additional seconds each.
Their original allowances, preparation usage, settled results and handles were checked unchanged.
[Targeted follow-ups, including failures](evidence/2026-10-26-harness-followups.json) are separate from
the frozen batch.

After scheduling changes, a real SQL task at `44c0c2f` passed the existing executable oracle with four
workers, three dependency stages and one final coordinator activation. It took 260.7 seconds, with
81,760 input and 55,248 output tokens recorded. This is a new task run, not a controlled speed comparison
with the earlier held-out variant. Some SQL runs in this work took several minutes; latency remains a
practical limitation.

The original Museum Catalogue UI run exceeded its final word limit by excluding an appendix. After
native format checks were added at `9bc79be`, the same original task completed through the production
assembly in 38.9 seconds. Its four accepted worker outputs contained 87, 86, 87 and 88 words, and the final
answer passed the full-body limit. This run used real online responses and no corrective external prompt.
A subsequent real UI run completed in 73.7 seconds. Native checks rejected two worker outputs of 123
and 136 words against the 119-word maximum, retained those originals and obtained corrected versions.
Its complete final answer contained 123 words. [UI result and rejection records](evidence/2026-10-26-native-output-ui.json)
record the actual four-agent task; no intermediate answer was supplied by the maintainer.

## Simulator interaction and recovery

Controlled transport was used for the existing UI regression: initial and child approvals, task details,
copy feedback, agent follow-up, preserved original results, exact call history and final output. The
fixture has three independent leaf tasks and therefore retains its exact six-call assertion. A separate
runtime regression requires only one final coordinator for a predeclared dependency chain.

Real online UI checks covered a goal amendment and a cold relaunch. In the latter, work was paused with
two task results already reflected in the graph. The app was terminated and reopened. Call identities
and usage stayed unchanged until Resume was explicitly pressed. Existing submitted handles and settled
outcomes remained unchanged after completion. The content-format failure from that run is recorded
separately from the successful lifecycle interaction.
[Recovery evidence](evidence/2026-10-26-simulator-recovery.json) and
[the real goal-update recording](../../assets/demo/goal-update.gif) retain that distinction.

## Outstanding qualification

Research coverage needs its own outcome checks. The research family's three passing runs checked
source-backed facts and citations. They do not resolve the earlier
[Europe discovery failure](2026-10-23-autonomous-coordination.md), which omitted ELSS, or establish
complete coverage of an open research field. Expected groups must remain outside runtime prompts.

Native acceptance checks cover required work, supported output constraints and the exact accepted
answer. SQL execution and other task-specific semantic checks belong to the evaluator. Product-level
detection and correction of content errors require separate evaluation using the tools actually available
to agents. Efficiency at equal outcome quality and reliability over longer tasks also remain open;
the individual timings and token counts above are not a controlled comparison.

Current-version six-family evaluation, a matched DSH comparison, research coverage, semantic outcome
checks and efficiency measurements can proceed with Simulator and online models. No new task runs were
performed for this documentation clarification; all recorded outcomes keep their original revisions.

## Reference implementation and execution boundary

Design decisions were checked against DeepSeek Harness source at
[`22ddee3792402c3e70ec5f86a63c3e3e895a2f60`](https://github.com/deepseek-ai/deepseek-harness/tree/22ddee3792402c3e70ec5f86a63c3e3e895a2f60).
OpenMinis was a design reference; its sandbox and GPL source were not imported. The existing Swift
executor, authorization pipeline, journals and sandbox seam remain the production path.

A published `@deepseek-ai/dsh@0.2.1-rc.3` installation was also exercised on three incident and three SQL
variants using the same requested model and task text. Its default headless composition, HTTP-level
budget cap and history handling differ from this application's conditions. Its behavior also differs
from the pinned source checkout. These runs are retained as
[reference diagnostics](evidence/2026-10-26-dsh-reference-diagnostic.json), not as a matched benchmark.
They do not establish DSH parity or superiority.

The near-term implementation supports collaboration using available models and tools. Arbitrary shell
execution, package installation and workspace modification still require the owner's separate execution
provider. Physical-device local-inference and background scheduling remain distinct measurements.
The output-limit recognizer handles explicit supported directives, not every possible natural-language
condition. Open-ended research coverage and the correctness of unrestricted prose still require outcome
checks. No universal autonomous-task or SOTA claim follows from this sample.
