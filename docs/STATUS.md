# Current implementation and validation status

Reviewed **2026-10-22** against code commit
[`82933a0`](https://github.com/nanguoyu/mobileLLM/commit/82933a03203cc3447817da49d4d8893a93482d05).
This is the implementation/evidence snapshot. [spec.md](../spec.md) remains the requirements source,
[ARCHITECTURE.md](ARCHITECTURE.md) describes the code, and [CONTRIBUTING.md](../CONTRIBUTING.md)
provides the validation commands.

## Implemented foundation

Normal app sends use frozen inputs and `DurableAgentExecutor`, with SQLite journal/CAS, budgets,
authorization, explicit recovery, content-addressed artifacts, and an idempotent conversation outbox.
Three local engines and an optional online provider share run semantics. New `/workflow` launches
use analyzed JavaScript and durable subagents; the staged orchestrator remains for old records.
Online siblings can overlap requests within one admitted root family; local decoding remains serial.

[PR #6](https://github.com/nanguoyu/mobileLLM/pull/6), merged 2026-09-06, added credential-free MCP
discovery persistence, coordinated runtime erasure, rejection of stale UI work after erasure,
append-only model registration, bounded online response/retry accounting, workflow checkpoints,
lifecycle wiring, online sibling lanes, and portable Swift CI. Those implementations should not
be listed as outstanding based on older August notes.

## Open implementation items

**Production Memory composition remains incomplete.** Static inspection follows
`App/mobileLLMApp.swift:makeAgentSnapshot` to `App/AgentRunInputs.swift:AppFrozenInputBuilder` and the
runtime context compiler. That path forwards cached canonical Memory facts without applying the
Memory switch, query ranking, or the legacy path's refresh before each send. The existing injection
tests construct ChatStore without the production AgentRunStore. A disabled Memory UI therefore does
not currently guarantee exclusion from model context, including online-provider context.

`AH-CONTEXT-002` is planned pending correction and `AHT-CONTEXT-APP-001` production assembly tests
for Memory off, relevant-only selection, and facts saved during the preceding turn. This finding is
from source tracing; the review did not run a device reproduction. The required Memory semantics
in spec §16 remain unchanged.

Other incomplete or intentionally unavailable surfaces:

- `stallMs` is decoded and stored but does not drive a runtime stall timeout.
- Tool pinning exists in the contract but has no product control; app-created policies have no pins.
- Files and Terminal show explicit empty states. `AgentSandboxAPI` has no production provider.
- The workflow JavaScriptCore realm has cooperative limits, not a hard heap limit or OS isolation.
  It does not expose the Gallery's general-purpose `run_js` tool.
- Provider-executed native tools are specified in §15.5 but not implemented.

## Release acceptance still pending

The requirement manifest now has **70 requirements: 66 active and four planned**. The test manifest
has **75 entries: 71 active and four planned**; these are traceability entries, not XCTest counts.
The planned requirements are production Memory semantics (`AH-CONTEXT-002`), the physical-device
model matrix (`AH-TEST-003`), matched latency/resource baselines (`AH-PERF-001`), and the consolidated
independent release audit (`AH-AUDIT-001`).

[device-matrix.v1.json](../Verification/AgentHarness/device-matrix.v1.json) retains 29 historical
scenarios, with 23 pass and six pending. Pending work includes memory/web reruns, every built-in
adapter, iOS continued-processing outcomes with the required provisioning capabilities, full dynamic
workflow delivery, and the five-shape real-model exploratory matrix. Existing passes and archived
coverage percentages are not fresh release-candidate evidence. The August implementation review
and September hardening review do not close the final independent audit requirement.

`DynamicWorkflowExplorationUITests` defines five complex scenarios and an ad-hoc goal entry point.
Its source location and real-model intent do not mean those scenarios have passed on the current
candidate. The checked-in DeviceE2E target is configured for physical iOS; the model-free
`WorkflowUITests` simulator fixture tests mechanics rather than real-model answer quality.

## Recorded verification on 2026-10-22

The host reported **Xcode 27.1 / Swift 6.4**. Eight MLX-free product packages plus the verification
tool were compiled and tested. No implementation changed during this run.

| Package | Tests discovered | Initial outcome |
| --- | ---: | --- |
| AppUI | 4 | Passed |
| AppRuntime | 106 | Passed with four Keychain-environment skips |
| LLMCore | 365 | Passed with one opt-in live MCP skip |
| AgentContracts | 97 | Passed |
| AgentRuntime | 505 | Six failures |
| AgentSandboxAPI | 29 | Passed |
| MobileLLMUI | 412 | Passed with three Keychain-environment skips |
| LLMEngineApple | 41 | Passed with two system-model/live availability skips |
| AgentHarnessVerification | 38 | Passed |

The initial aggregate was **1,597 tests: 1,581 passed, 10 skipped, six failed**. One failure,
`ContentAddressedArtifactStoreTests/testCoverageClosureFileProtectionIOAndAtomicFailureSurfaces`,
passed when rerun outside the process sandbox. The first-attempt failure remains part of the record.
The other five failures were `LiveOnlineProviderSmokeTests` against the configured online service
in the restricted environment; they were not rerun with unrestricted network access and remain
unresolved by this pass. The test class automatically uses a local developer configuration unless
explicitly excluded; see the offline commands in CONTRIBUTING.md.

Static `agent-harness-verify` passed on the code baseline. This review did not rerun app/Metal builds,
app-module units, simulator/physical-device tests, source mutations, measured coverage/freshness, or
thermal/performance gates. The local package results above predate this documentation refresh and
are a dated summary, not a replacement for commit/spec-bound release evidence bundles.

The September PR records earlier successful app/engine builds, app tests, simulator checks, six
mutation kills, and Linux CI. Keep that evidence tied to its original source and toolchain.
The newer host toolchain still needs a full macro/Metal compatibility check before an engine build;
see [WIRING.md](WIRING.md#toolchain-compatibility).

## CI and documentation maintenance

Hosted CI has two Linux jobs: verification documents/scripts/digests, and portable Swift
contract/API/verifier behavior. Paid hosted macOS runners are disabled. A trusted self-hosted Mac
can run the Apple package job when explicitly enabled; the remaining Apple and release-evidence
gates run through maintainer commands.

`docs/DESIGN.md`, historical device results, and earlier audit findings retain their original dates.
When changing the implementation, update this status, the architecture reference, relevant spec
conformance items, and requirement/test mappings together. A spec change must also refresh all five
recorded spec digests and requirement line anchors. Keep successful old evidence separate from new
required runs, and preserve failures and skips rather than promoting a documentation edit to a pass.
