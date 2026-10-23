# Autonomous collaboration: diagnosis and source comparison

As of 2026-10-23, mobileLLM has not demonstrated reliable completion of general open-ended,
multistage tasks. Three closed-data tasks passed exact checks on earlier revisions. The API-comparison
and autonomous Europe-research tasks failed. A model reviewer approved an incident analysis whose
claims exceeded its input. Runtime completion, UI checks and semantic correctness are different results.

## Why the previous approach was slow

The v1 coordinator saw artifact summaries and lengths, rather than the actual work. Reading an artifact
required commissioning another worker. Delivery always added a writer and reviewer. Rejections frequently
created more extraction, consolidation and audit tasks, while the reviewer sometimes introduced requirements
that the user had not requested. A 9,000-character worker wrapper also discarded usable work through schema
failure when the model exceeded that limit. Prompt additions did not remove these structural problems.

The last v1 Europe run at `7a89e1b` lasted **1,321.789 seconds** in the application, submitted **17 children**
and invoked **24 web tools**. It exhausted its fixed resource budget before producing any final answer.
Search receipts confirmed attributed page text was returned by the new DeepSeek Search adapter. Several
worker outputs included ELSS at TU Graz, but finding the group internally did not satisfy delivery.
The local evidence prefix is `europe-search-content` under `/tmp/mobilellm-coordination-20261023/`.

## Implementations inspected

The comparison uses repository source retrieved on 2026-10-23, rather than assuming similarly named
OpenCodex/OpenClaude projects share one implementation.

| Source | Observed mechanism | Implication for mobileLLM |
| --- | --- | --- |
| [OpenHands task executor](https://github.com/OpenHands/software-agent-sdk/blob/dd0892c80fffb1e59bac77242adafbd8b1168649/openhands-tools/openhands/tools/task/impl.py) and [task manager](https://github.com/OpenHands/software-agent-sdk/blob/dd0892c80fffb1e59bac77242adafbd8b1168649/openhands-tools/openhands/tools/task/manager.py) | The tool returns actual result text plus task ID and status. Resuming restores a child conversation and sends a new message. Non-finished runs surface errors and available partial output. | Return real work to the supervisor; preserve task identity and previous context. Avoid recruiting a new worker merely to read a result. |
| [OpenCode subagent completion](https://github.com/anomalyco/opencode/blob/24b5ed8bcc60aa9a20cf4e3edf1444470e0e6464/packages/core/src/session/subagent-completion.ts) and [job lifecycle](https://github.com/anomalyco/opencode/blob/24b5ed8bcc60aa9a20cf4e3edf1444470e0e6464/packages/core/src/session/subagent-job.ts) | Completion sends text, child session ID and state to the parent session. Jobs resume child sessions; observers are tracked per job generation. | Keep execution state distinct from result content, and return outcomes to the continuing parent. |

These mechanisms do not establish that either project solves every task correctly. Their relevant
advantage is a direct collaboration interface. Importing their Python or Node host runtime into the iOS
process would add another execution stack. The change here ports the interaction pattern into the existing
Swift/JavaScriptCore executor; it does not copy their implementation or claim SDK compatibility.

## Replacement policy

`CoordinatedWorkflow` v2 gives the supervisor actual worker outputs and four actions: work, read, deliver
and blocked. It carries working notes in its recorded decisions. Full outputs remain available; truncated
previews contain offsets, and the supervisor can read original ranges without another worker or web request.
A later invocation of the same logical task ID receives its earlier assignments and outputs, selected input
artifacts and relevant recorded web evidence. All evidence for a wave is read before dispatch.

The supervisor writes the final answer. Separate writing, reviewing and consolidation are no longer
mandatory. A useful independent check can still be delegated as ordinary work. The existing authority,
32-model-attempt envelope, 24-tool ceiling, cancellation, journal and replay mechanisms remain in force.
The policy caps worker invocations at 12 and supervisor continuations at 12. It stops repeated identical
actions instead of treating more activity as progress.

This is explicit context continuation across durable child runs. It does not yet provide native persistent
worker conversations, asynchronous peer messaging or provider KV reuse. A long worker result may need a
supervisor read before its missing portion can be handed to a dependent worker. Filesystem editing and
code execution still require a production sandbox capability that this build does not expose.

## Validation at this revision

Six focused runtime checks pass: actual parallel result delivery and task continuation, local reads beyond
a truncated preview, invalid-reference and failed-worker handling, repeated-read termination, analyzer/schema
compatibility, and redacted structured-repair diagnostics. These are control-flow checks, not model ability
scores. The existing opt-in UI fixture is updated to three workers plus one supervisor, with no writer or
reviewer. The original task answer and coverage oracles remain unchanged. Live v2 results follow below.

No full repository suite or paid model call was run for this document. Live task results belong in this
file and `STATUS.md` only after their original outputs have been checked.

## Retained task outcomes

[Compact evidence](evidence/2026-10-23-autonomous-coordination.json) retains 16 outcomes, exact accepted
JSON answers, source/output hashes and selected child timing records. The same code was not used for all
runs, so these are diagnostic outcomes rather than an aggregate reliability score.

| Task | Revision | Independent assessment |
| --- | --- | --- |
| Closed directory and aliases | `c0f3570` | Exact eligible set, exclusions and alias deduplication passed. |
| Procurement | `aac798f` | Exact optimum and all feasible pairs passed; 7 children, 247.837 application seconds. |
| Dependency schedule | `c0f3570` | Durations, dependencies, resources and matching 8-hour lower bound passed. |
| Incident analysis | `7451fdf`, `320992a` | UI passed, semantic quality failed. An attempted write was upgraded to a confirmed effect, and a local-state safeguard was overstated. |
| Official API comparison | Several v1 revisions | Failed through oversized context, missing handoff evidence, redundant audits and budget exhaustion. Individual outcomes remain in the evidence file. |
| Europe research | `00f1032`, `7a89e1b` | Failed autonomous delivery. Latest run found ELSS internally but returned no final answer. |
| Procurement with v2 supervisor | `2cf6b24` | Original exact oracle passed on the unedited answer. One initial model call, no children, 23.285 application seconds. UI failed only its minimum-child-count assertion. |

For the v2 procurement result, the exact oracle was replayed offline on the saved original JSON. The
closed-data scenarios now permit direct solutions, while the complex research scenarios still require
collaboration. No answer, source or coverage condition was relaxed, and no model was rerun for this test
correction. The original UI failure remains recorded. This single comparison does not estimate a general
speedup, and a direct solution is not evidence of multi-agent collaboration.

The initial supervisor call was previously absent from the displayed token counters. Presentation now
adds its journaled usage once, including after recovery. Old evidence keeps the original counters and
labels their scope. The Swift app harness compiled this change and its existing per-child budget regression
passed. Live API-comparison and Europe outcomes for v2 are still pending.
