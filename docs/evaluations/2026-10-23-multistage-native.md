# Independent multi-stage collaboration across engineering tasks

mobileLLM completed three different engineering tasks through real online agents: a transactional SQLite
migration, a constrained maintenance plan with outage adaptation, and evidence-bounded incident recovery.
Each accepted run contains at least three completed worker waves and two verified dependent handoffs.
The original task was the only external input during each run. The coordinator assigned and continued
work using actual earlier results, then produced the final artifact.

These cases test the general workflow mechanism. The production coordinator contains no branch for these
tasks, their markers, their expected answers or ELSS. Task definitions and answer oracles are in the app-unit
test target. The earlier Europe result remains a coverage failure in the historical evaluation.

## Results

All runs used the configured `deepseek-v4-pro` service on the signed iPhone 17 / iOS 27 Simulator. Native
task time includes initial planning, agent execution and result checks; it excludes Xcode build and app
installation. Child invocations include worker runs and supervisor continuations, but not initial planning.

| Task | Tested code | Worker waves | Child invocations | Dependent workers | Native task time | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| SQLite migration | `89104d3` | 3 | 7 | 2 | 715.926 s | Passed executable migration and handoff checks |
| Maintenance/outage plan | `8e9bd6a` | 4 | 10 | 2 | 301.529 s | Passed schedule, optimum, cost, minimal-change and handoff checks |
| Incident recovery | `8e9bd6a` | 3 | 7 | 2 | 212.512 s | Passed evidence classification, safe recovery and handoff checks |

The maintenance run also demonstrates recovery inside the application. Its first scheduling artifact
contained an expression instead of a schedule, and its cost worker failed with
`execution.tool-budget-repair-exhausted`. The supervisor identified both problems, assigned replacement
work, obtained the baseline and cost, then delegated outage adaptation and verification. No maintainer
correction was sent. Four successful Calculator operations are recorded.
The incomplete first artifact was a standalone XML `tool_calls` block, not a native invocation.
The online adapter now rejects that envelope through the existing bounded format-repair path. A focused
regression uses the captured block and preserves legitimate quoted or fenced examples. The repair
integration check passed; these were offline checks, without rerunning the accepted live tasks.

The SQL task used two analysis workers, an implementation worker and an independent inspector. The
application generated the script. The evaluator executed the original script in isolated in-memory SQLite
databases and checked three data sets, each with 150 contacts and 350 tickets. Checks cover latest-row
selection with tie breaking, tenant isolation, NULL/empty/all-space identities, full ticket preservation,
foreign-key remapping, normalized uniqueness for future inserts and updates, repeatability and rollback
when index creation fails. It does not infer correctness from a model-written review. The final SQL also
repoints tickets before deleting losing contacts, as requested.

The planning task has independent baseline and cost work, then adaptation using the settled baseline,
followed by verification. The evaluator checks all durations, resource assignments, dependencies and
non-overlap. It independently requires the 13-hour baseline optimum, 14-hour outage optimum, the minimal
changed-start set and EUR 1,680 labor cost. These answers are not supplied in the task prompt.

The incident task separates observed sends from unconfirmed effects. Its output correctly rejects
lease-expiry and local-fencing guarantees, preserves uncertainty about external writes, and selects safe
recovery for valid keys, expired deduplication, conflicting payloads and known results. The final prose
also addresses an unknown alternate-key attempt rather than treating the original key alone as sufficient.

## General changes that enabled the workflow

- `budget.snapshot()` reports actual usage from settled calls reached by replay. Unused tool allowances
  return to later stages. The durable ledger remains authoritative for every admission.
- `inputRanges` passes original middle or tail sections to dependent workers. Handoffs are checked against
  the exact earlier output bytes and journal settlement order, not just against task IDs or call counts.
- The supervisor protocol distinguishes host delegation from tools available inside a worker. An empty
  worker tool list still permits reasoning agents. Explicit requests for collaboration and dependent
  stages take precedence over the default preference for a small team.
- Format repair preserves the current role and response protocol. It no longer tells a structured
  controller to substitute the overall user's final answer when native tools are absent.
- Chat and native evaluation share `prepareCoordinatedWorkflow`. Capability cases do not repeatedly drive
  UI navigation or maintain another orchestration implementation. The app-unit target supports both
  Simulator and Mac, with the appropriate test-host executable path.

The native evaluator rejects a local-model path and provides no fixed model response. Live calls require
an explicit environment opt-in; ordinary tests skip them before reading credentials. UI tests remain for
UI integration. Public evidence contains final artifacts, provider identity, source hashes, actual usage,
call sequences and outcomes. Raw provider journals remain local.

## Failures and test corrections retained

The [evidence bundle](evidence/2026-10-23-multistage-native.json) preserves seven task attempts and identifies
the tested commit for each. No aggregate reliability percentage is computed from these evolving revisions.

The first three native runs returned acceptable domain artifacts but skipped the requested collaboration.
The planning fixture also used the display name `Calculator` instead of its canonical tool ID, so it had no
calculator capability. This is recorded as a fixture defect, not as failure of the production calculator.
The fixture now verifies the actual selected capability before making a model call. Only the planning run
used structured-output repair; the other two cannot be attributed to that repair prompt.

The next migration run completed three worker waves but was rejected by an overly restrictive evaluator
rule for the harmless `busy_timeout=5000` setting. Allowing a bounded connection timeout exposed an input
and coverage gap: the task had not separately named empty strings, and the original corpus contained
NULL/all-space values but no empty values. The script treated empty strings as valid identities. The
revised task defines missing precisely as NULL or `trim(email)=''`, and the stronger corpus includes empty
strings. Offline evaluation rejects the unchanged earlier script on that corpus. Only the migration task
was rerun; the two accepted tasks were not regenerated. The final migration passes all checks.

A Simulator build initially rejected a macOS-only configuration fallback before any model call. That build
failure and its platform-guard fix are separate from task results. The migration oracle is itself checked
with a correct script and counterexamples for data loss, non-atomicity, weak uniqueness, wrong winners and
incorrect empty-identity merging.

## Scope and next measurements

These results establish autonomous staged execution, exact artifact handoffs, real tool use and one
observed subagent-failure recovery for the supplied tasks. The SQL took nearly twelve minutes with this
model profile; latency is still a practical constraint. Open-ended research coverage, repeated-run
reliability and other tool environments need separate measurements. Logical worker continuation uses
recorded context in new durable child runs. Native persistent worker conversations, asynchronous peer
messaging and production terminal/SQL execution are not implemented by this change.
