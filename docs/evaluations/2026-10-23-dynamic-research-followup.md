# Dynamic research follow-up, 2026-10-23

The earlier report ended before the application could deliver the requested research. That was premature.
This follow-up continues the same task with the production runtime, signed Simulator, online model and
DeepSeek Search/Fetch. The target remains 12–16 supported European Efficient AI teams, at least six
countries and eight HTTPS citation hosts. A passing UI check alone does not establish factual quality.

The [original evaluation](2026-10-22-dynamic-research.md) retains attempts 1–7. The
[maintainer-edited overview](2026-10-22-europe-efficient-ai.md) is a separate artifact and has not been
used as an answer fixture. No external coding-agent subagents supplied the application's research.

## Execution and evidence changes

Child admission now reserves the lesser of its normal share and the actual unreserved capacity.
`maxToolCalls` narrows that reservation before the request is frozen, including zero-call writers.
Reservations and construction are atomic, and cumulative usage remains charged across stages.
An oversized model-proposed batch executes nothing. One budgeted correction can propose a smaller
batch; authorization, argument validation, duplicate checks and the original tool ceiling still apply.

Malformed native-tool envelopes are rejected rather than delivered as research. Repair applies to the
next model attempt and consumes the fixed repair allowance. Successful progress ends that repair phase.
A locally classified DeepSeek page-read 404 remains failed evidence but allows other authorized reads.
Auth, quota, denial and uncertain-effect failures retain their existing handling.

Compiled requests exposed a DeepSeek failure mode when tools disappeared after earlier native tool
calls. Tool-free Chat Completions now use explicit `tools: []` and `tool_choice: none`, and project
previously executed observations into untrusted text evidence. Durable native identities remain intact
for recovery and active-tool continuation. Raw DSML is never executed as an unadvertised action.

`webEvidence()` exposes bounded current-workflow journal observations, source URLs, retrieval kinds,
truncation flags and content digests without repeating requests. Failed reads cannot become page-read
citations. `unique(strings)` compares whole values for country counts. Corrected rows belong to the
verification stage; the writer contributes explanation and recommendations without rewriting facts.

Generator instructions now state the exact evidence packet keys and require complete packet handoff.
Generated phase and parallel promises receive syntax checks, while actual ordering is checked in the
journal. Long test prompts use the native composer paste action and an exact inserted-text assertion.

The generator had also disabled reasoning in the frozen input inherited by every child. It now preserves
the conversation's choice. Chinese requests to retrieve official sources now select allowed web tools
without treating a request to retrieve local notes as web intent. A live failed run established that
this selection issue produced empty advertised-tool lists, not a provider outage.

Long model passes no longer strand active-time capacity. A subsequent attempt's timeout and reservation
shrink together to the remaining ledger allowance. A 287,813 ms remainder, for example, admits a
257,813 ms remote request plus 30,000 ms cancellation grace rather than reserving another full 330,000 ms.
The run's limit stays fixed. Existing model-boundary crash/reopen checks still pass.

The JavaScript bridge now removes outer prompt whitespace before host dispatch, hashing and admission.
Interior line breaks and indentation remain intact. Safe host errors are recorded even when a generated
catch returns a generic message. A candidate check also rejects the common missing-`await` pattern that
would prevent an asynchronous catch from seeing a rejected child promise.

Cancellation uses durable terminal results when acknowledgement or observation is lost. After observer
loss it may wait 350 ms for the terminal commit without resubmitting work. Cancelled usage remains
accounted. Truly uncertain results still stop for reconciliation.

## Retained follow-up outcomes

These are sequential debugging observations under changing code and prompts, not independent trials
or a success-rate estimate. The research cutoff stays 2026-10-22 even when the run occurred on October 23.
Local bundle names below have the prefix `EuropeEfficientAI-` and suffix `.xcresult`.

| Attempt | Bundle name | Observed outcome |
| --- | --- | --- |
| 8 | Acceptance | Seven children and UI pass; 12 discovery calls, zero verifier calls. Claimed verification and reported counts were wrong. Quality failed. |
| 9 | ProAcceptance | Seven children, 18 calls, UI pass. Fifteen rows covered seven countries while the report claimed six; stale works and incorrect roles remained. Quality failed. |
| 10 | EvidenceCompletion | Cancelled during long UI text entry before model work. The native paste path replaced slow character entry. |
| 11 | EvidenceCompletion-Paste | Paste worked. Independent malformed responses exhausted repair incorrectly and cancellation acknowledgement was misclassified. No final report. |
| 12 | EvidenceCompletion-Repair | Native tool markup still leaked during tool-free continuation. Compiled contexts exposed the transition causing it. No final report. |
| 13 | VerifiedSources | Four researchers completed. A verifier reserved six calls, stranding the other verifier with two; it exceeded its allowance. No final report. |
| 14 | RoleCaps | Actual per-child limits were enforced. Explicit `tool_choice: none` alone did not prevent leaked tool markup. No final report. |
| 15 | ReadOnlySynthesis | Seven children and 22 calls completed. Twelve teams in nine countries, but stale project dates and a future paper remained. Quality failed. This run reused original application briefs, not the maintainer-edited overview. |
| 16 | FreshAcceptance | Started without a supplied list. Seven children and 22 calls completed. Thirteen rows actually covered ten countries; generated character-based deduplication claimed thirteen. Weak team identities and unsupported fields remained. Quality failed. |
| 17 | GroundedFresh | Four researchers completed 16 calls. The generated script serialized nonexistent `truncationFlag` instead of using the packet's `truncated` field. No final report. |
| 18 | GroundedContract | A researcher with one call remaining proposed two. The whole batch was rejected; workflow cleanup reported reconciliation before cancelled children settled. No final report. |
| 19 | BoundedReplan | Six children, zero tools. Chinese role prompts did not select the allowed web tools; reviewers received empty evidence and the identity response failed its schema. No final report. |
| 20 | ReasonedResearch | Four parallel investigators collected 13 candidates in nine countries. Six children completed 16 Search and six Fetch calls. The gap stage failed before inference because its duplicated input could not fit the context. The generated script also incorrectly required every citation to be a fetched page. No final report. |
| 21 | ResearchContinuation | Two investigators started with prior application material. One proposed an oversized batch containing an already executed query; admission rejected it, and the other investigator was cancelled. Four actual searches remain retained. No final report. |
| 22 | ResearchRecovery | Both investigators completed 12 calls and supplied their full briefs. Merge and recovery then failed because a full time reservation exceeded the remaining allowance after a long model pass. The writer returned an empty table despite 16 actual searches in this run. Script completion is not research acceptance. |
| 23 | FinalStages | A verifier call was prepared but never submitted. Its generated prompt ended with a newline that violated the child instruction contract. The script caught the error and returned a technical-error message. No research answer. |
| 24 | FinalCanonical | In progress using the same raw application material after prompt-boundary normalization. Acceptance has not yet been recorded. |

## Focused checks

The follow-up exercised budget admission and caps, malformed-action repair and accounting, native
provider continuation, trusted page misses, cancellation and observer recovery, bounded evidence
extraction, and complete-value deduplication. Tests check authority, rejected calls and recorded effects,
not just final text. Overlapping test runs are not added into an inflated suite total.

The latest specific checks passed: three batch/repeated-call regressions, three cancellation/reconciliation
regressions, all 16 selector checks, and the app freezer regression with reasoning enabled and disabled.
Two remaining-time tests, two existing model-boundary recovery checks, two prompt-boundary checks and
the generated-catch app check also passed. The static verifier passed after the time-budget selector was registered. Earlier focused
results and first failures remain in local logs. No full repository suite was rerun for prompt or prose edits.

Later stages were deliberately continued through new app UI submissions containing unedited prior
application output and journal excerpts. This transfer was performed by the maintainer. It is not
unattended continuation or restart of a terminal workflow. The current restart API accepts paused or
reconciling workflows; this evaluation did not mutate a terminal journal to bypass that contract.
No institution, paper or corrected answer from the maintainer's independent web checks was added to
those continuation inputs.

Artifacts remain under `/tmp/mobilellm-europe-efficient-ai-20261022/`: exact goals, generated sources,
raw application answers, consistent SQLite backups and xcresults. Debug products can contain local
provider configuration and are not publication artifacts. A final research acceptance requires checking
the unedited answer against those records and primary sources, not copying the separate edited overview.
