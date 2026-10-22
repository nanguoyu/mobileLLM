# Contributing to mobileLLM

mobileLLM is a local-first agent chat app for macOS + iOS, written in Swift, with optional online models.
This guide covers the development setup, the package layout, how to run the tests, and what a PR needs.

## Development setup

The app deploys to macOS 14 / iOS 17 and uses Swift 6. Its availability-guarded platform bridges
require SDKs containing iOS 26 / macOS 26 APIs. The pinned MLX macro stack targets Swift 6.2; consult
[WIRING.md](docs/WIRING.md#toolchain-compatibility) before selecting a toolchain. The project is
generated from `project.yml` with XcodeGen, and a fresh clone must build the gitignored llama.cpp XCFramework.

```sh
# 1. Tooling (Homebrew)
brew install xcodegen cmake

# 2. Build the llama.cpp XCFramework — REQUIRED (it's gitignored). Needs Xcode + CMake; produces a
#    ~355 MB artifact at Packages/LLMEngineLlama/Vendor/llama.xcframework, ~15–25 min the first time.
./scripts/build-llama-xcframework.sh

# 3. Signing — copy the template and add your Apple Developer Team ID (Signing.xcconfig is gitignored;
#    never commit a Team ID). The app bundle identifier is versioned in project.yml.
cp Signing.xcconfig.example Signing.xcconfig

# 4. Generate and open the project.
xcodegen generate
open mobileLLM.xcodeproj
```

Build the app with **Xcode / `xcodebuild`** — MLX's Metal kernels require it, and SwiftPM can't compile the
fork's Metal. Inference (the 1-bit MLX kernels and GGUF Metal) is validated on **real devices**; the
simulator has no Metal path for it.

## Package map

Ten product packages plus the app target, and a separate `Tools/AgentHarnessVerification` package.
MLX and llama.cpp are quarantined to one package each; the other
eight are MLX-free and test under plain SwiftPM without any Metal toolchain or the vendored XCFramework.

| Package | What it holds | Toolchain |
|---|---|---|
| `AppUI` | Ink-wash design tokens + shared SwiftUI controls | MLX-free — `swift test` |
| `AppRuntime` | Resumable downloader, memory/thermal governors, `DurableStore` (Foundation + CryptoKit) | MLX-free — `swift test` |
| `LLMCore` | Catalog + schema, `RoutingEngine`, memory governor, context policy, tools/MCP, Explore, `ThinkSplitter`, the `LLMEngine` protocol + a mock | MLX-free — `swift test` |
| `AgentContracts` | Versioned run/step/request/approval/budget/workflow contracts shared by runtime, sandbox API, and UI | MLX-free — `swift test` |
| `AgentRuntime` | Durable agent executor, SQLite journal, approval policy, budgets, recovery, subagents, parallel tools, dynamic workflows, legacy staged recovery, online provider | MLX-free — `swift test` (links sqlite3 and JavaScriptCore) |
| `AgentSandboxAPI` | Protocol-only sandbox seam; no provider ships in the open-source build | MLX-free — `swift test` |
| `MobileLLMUI` | SwiftUI chat / models / settings + `@Observable` stores, agent run/approval/workflow UI (codes against `LLMEngine` + `AgentRuntime` contracts) | MLX-free — `swift test` |
| `LLMEngineApple` | The Apple Intelligence engine — weak-linked `FoundationModels`, no weights of ours | MLX-free — `swift test` |
| `LLMEngineMLX` | The MLX engine — resident weights, PrismML 1-bit fork | Metal — `xcodebuild` |
| `LLMEngineLlama` | The llama.cpp engine — mmap'd GGUF, vendored `llama.xcframework` | Metal — `xcodebuild` |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit and [docs/WIRING.md](docs/WIRING.md)
for the MLX-fork + llama.cpp dependency pins.

## Running the tests

The eight MLX-free packages are the fast inner loop. Point local SwiftPM build output outside the source
tree so nothing stray lands in the repo:

```sh
swift test --package-path Packages/AppUI          --scratch-path /tmp/mllm-appui
swift test --package-path Packages/AppRuntime     --scratch-path /tmp/mllm-appruntime
swift test --package-path Packages/LLMCore        --scratch-path /tmp/mllm-llmcore
swift test --package-path Packages/AgentContracts --scratch-path /tmp/mllm-agent-contracts
swift test --package-path Packages/AgentRuntime   --scratch-path /tmp/mllm-agent-runtime \
  --skip LiveOnlineProviderSmokeTests
swift test --package-path Packages/AgentSandboxAPI --scratch-path /tmp/mllm-agent-sandbox
swift test --package-path Packages/MobileLLMUI    --scratch-path /tmp/mllm-ui
swift test --package-path Packages/LLMEngineApple --scratch-path /tmp/mllm-apple
```

Most tests use deterministic providers and transports. Live checks have different activation rules:

- `LiveOnlineProviderSmokeTests` automatically reads `~/.mobilellm/openai.json` and makes real API
  requests when usable credentials and a model exist. The command above skips it explicitly. Run it
  intentionally with `--filter LiveOnlineProviderSmokeTests` when validating the configured service.
- `MCP_LIVE=1` enables the live MCP test. `APPLE_LLM_LIVE=1` enables real Apple-model inference.
  Other Apple-model tests may skip when the OS/framework or an eligible system model is unavailable.
- Keychain tests can skip when the execution environment denies access. Record these skips; they
  are not proof that credential storage was tested.

`run-behavior-tests.sh` runs all eight packages plus the verification tool and static gate. It does not
exclude the online smoke class, so a developer configuration can cause real requests during that run.
Use the explicit commands above for an offline pass. Keep outputs outside the checkout; in a restricted
runner, point `CLANG_MODULE_CACHE_PATH`, `SWIFTPM_MODULECACHE_OVERRIDE`, and SwiftPM's `--cache-path`,
`--config-path`, and `--security-path` at writable temporary directories. An outer process sandbox may
also require SwiftPM's `--disable-sandbox` for manifest evaluation. These build flags do not grant
Keychain, network, or file-protection access to the test process.

The checked-in `EngineTests` Xcode scheme covers both local-weight engines. MLX needs the Xcode
Metal resource build and `-skipMacroValidation`; llama.cpp uses the prebuilt XCFramework. The
`llm-smoke` executable checks the MLX 1-bit kernel, while `llm-decode` and `llama-smoke` exercise
model decoding with weights. See [WIRING.md](docs/WIRING.md) for dependency and execution details.

```sh
# Unsigned app builds for both shipped platforms:
xcodebuild -project mobileLLM.xcodeproj -scheme mobileLLM \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project mobileLLM.xcodeproj -scheme mobileLLM \
  -destination 'generic/platform=iOS' -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO build

# App-module Tool V2 and snapshot integration tests:
xcodebuild -project mobileLLM.xcodeproj -scheme mobileLLMUnitTests \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' test

# Engine unit tests (macOS destination; SwiftPM can't build the MLX package's macros):
xcodebuild -skipMacroValidation -scheme EngineTests \
  -destination 'platform=macOS,arch=arm64' \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' test

# iOS simulator UI suite (XCUITest). The checked-in plans live in
# Verification/AgentHarness/TestPlans: SimulatorUI.xctestplan (keyboard/composer geometry, agent-run
# UI, workflow E2E) and DeviceE2E.xctestplan (physical-device matrix). Online-model scenarios need
# ~/.mobilellm/openai.json and the simulator's hardware keyboard disabled:
# defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
xcodebuild -skipMacroValidation -scheme UITests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:mobileLLMUITests/WorkflowUITests test
```

### What runs where

**Hosted CI runs two Linux jobs.** In `.github/workflows/ci.yml`, `verification-documents` checks that
every `Verification/**` JSON and `.xctestplan` must parse, every `scripts/verification/*.sh` must pass
`bash -n`, and the `spec.md` SHA-256 recorded in `Verification/AgentHarness/requirements.v1.json` and the
four semantic registries must match the checked-in `spec.md`. The separate `portable-swift` job uses the pinned Swift 6.2.4 container to compile and test `AgentContracts`, `AgentSandboxAPI`, and
`AgentHarnessVerification`, then runs the semantic/architecture verifier. Apple platforms keep CryptoKit;
Linux uses Apple's pinned Swift Crypto 4.5.2 implementation. Pushes to `codex/**` run the same gates.

Paid macOS runners remain disabled. A maintainer can enable the `macos-behavior` job by registering a
trusted self-hosted macOS runner and setting `MOBILELLM_SELF_HOSTED_MAC=true` in repository variables.
It runs only on main or manual dispatch, never on pull-request code. The same local gate is
`bash scripts/verification/run-behavior-tests.sh`; set `MOBILELLM_TEST_OUTPUT` to retain logs at a chosen path.

**Apple-platform and release-evidence gates run on a maintainer Mac.** The local commands below
also include the portable verifier for use before pushing:

```sh
# Static traceability + spec/registry/schema/architecture gates (agent-harness-verify):
swift test --package-path Tools/AgentHarnessVerification --scratch-path /tmp/mllm-verify
swift run  --package-path Tools/AgentHarnessVerification --scratch-path /tmp/mllm-verify \
  agent-harness-verify static --repo-root "$PWD"

# Package coverage evidence for the three agent packages (one report each), then the freshness gate:
for p in AgentContracts AgentRuntime AgentSandboxAPI; do
  bash scripts/verification/run-agent-package-coverage.sh --package "$p" \
    --base-ref "$(git rev-parse HEAD^)" --output-dir /tmp/mllm-evidence/"$p"
done
swift run --package-path Tools/AgentHarnessVerification --scratch-path /tmp/mllm-verify \
  agent-harness-verify freshness \
  --expected-source-commit "$(git rev-parse HEAD)" \
  --expected-spec-sha256 "$(shasum -a 256 spec.md | awk '{print $1}')" \
  $(find /tmp/mllm-evidence -name coverage-report.v1.json | sed 's/^/--report /' | tr '\n' ' ')

# The six curated source mutants (each must be killed by its sentinel test):
bash scripts/verification/run-agent-mutation-gates.sh

# Model-free simulator gate + engine tests + Xcode coverage evidence:
xcodebuild test -project mobileLLM.xcodeproj -scheme SimulatorCI \
  -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO \
  -enableCodeCoverage YES -resultBundlePath /tmp/mllm-evidence/SimulatorCI.xcresult \
  -skipMacroValidation MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project mobileLLM.xcodeproj -scheme EngineTests \
  -destination 'platform=macOS,arch=arm64' -enableCodeCoverage YES \
  -resultBundlePath /tmp/mllm-evidence/EngineTests.xcresult \
  -skipMacroValidation MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO
xcrun xccov view --report --json /tmp/mllm-evidence/SimulatorCI.xcresult > /tmp/mllm-evidence/SimulatorCI.xccov.json
xcrun xccov view --report --json /tmp/mllm-evidence/EngineTests.xcresult > /tmp/mllm-evidence/EngineTests.xccov.json
bash scripts/verification/verify-xcode-coverage.sh --base-ref "$(git rev-parse HEAD^)" \
  --report /tmp/mllm-evidence/SimulatorCI.xccov.json --report /tmp/mllm-evidence/EngineTests.xccov.json \
  --output /tmp/mllm-evidence/xcode-coverage-report.v1.json
```

The full `SimulatorUI.xctestplan` (keyboard geometry, agent-run UI, workflow E2E) and the `DeviceE2E` plan
remain manual gates. Hosted CI covers the two Linux jobs above; it does not run the Apple-framework
packages, app/engine builds, simulator, coverage, mutations, or physical-device scenarios. See
[Current status](docs/STATUS.md) for the latest recorded results and outstanding release evidence.

Note the simulator runs **llama.cpp on CPU only and cannot run MLX at all** — activation refuses MLX
variants there by design; anything MLX is validated on real hardware.

## Updating documentation and verification metadata

`spec.md` defines requirements. `docs/ARCHITECTURE.md` describes the implementation, and
`docs/STATUS.md` records dated evidence and open work. Keep normative requirements when an
implementation falls short and record the gap in spec §33 instead of redefining success.

After changing `spec.md`, update affected `specAnchors` headings and line ranges in
`Verification/AgentHarness/requirements.v1.json`. Recompute `sourceSpecification.sha256` in that manifest and all four
`Verification/AgentHarness/Registries/*.json` files. Update their source line ranges and the requirement
manifest's capture timestamp.
Run the verification-tool tests and `agent-harness-verify static` after those updates. Historical
coverage, device, and audit records keep their original capture dates and outcomes; new documentation
cannot make old evidence fresh. The `release` verifier also requires planned requirements/tests to
become active, so it is expected to reject the currently incomplete release matrix.

`docs/DESIGN.md` is an archived design. Update its navigation/status preface when needed, while
preserving the dated body. Regenerate the ignored Xcode project after any `project.yml` change.

## Pull requests

- **Tests stay green.** Add or update tests for the behavior you change; existing tests are pinned behavior
  — don't weaken or delete one unless the behavior changed by design, and say so if it did.
- **No signing secrets.** Never commit `Signing.xcconfig`, a Development Team ID, or any token/key.
  The app bundle identifier is intentionally versioned in `project.yml`; change it there rather than in
  the generated `.xcodeproj`. Keep both `Signing.xcconfig` and the generated project gitignored.
- **Match the existing idiom.** 4-space indent; `// SPDX-License-Identifier: MIT` as the first line of every
  new Swift file; comments state non-obvious constraints rather than narrating the code.
- **Keep the MLX-free packages MLX-free.** Anything touching MLX belongs in `LLMEngineMLX`; anything touching
  llama.cpp belongs in `LLMEngineLlama`; anything touching `FoundationModels` belongs in `LLMEngineApple`.
  Don't add MLX (or the fork) as a dependency of the other eight.
- **Agent runtime changes need journal/approval/recovery tests.** The `AgentRuntime` suite is large on
  purpose (persistence, approval, tool-boundary, subagent, parallel-batch, and workflow contract tests);
  keep it that way. Never commit an API key, a `~/.mobilellm/openai.json`, or any online-service secret —
  DEBUG app/test bundles may contain seeded credentials; keep those bundles private as described in
  [SECURITY.md](SECURITY.md).
- **Adding a model?** Prefer a catalog entry in `LLMCatalog` with the right `modelType` / `swiftModelClass`
  and verified figures from a Hugging Face primary source — the schema is built to grow that way.
- **Changing downloads or web access?** Pin every Hub request to the variant revision, preserve LFS
  integrity checks across fresh and resumed writes, validate every redirect target and resolved address,
  and enforce response limits while streaming. Add hostile-path tests, not only happy-path fixtures.
- Keep PRs focused, describe the *why*, and confirm the MLX-free suites pass before requesting review.

By contributing you agree your contributions are licensed under the [MIT License](LICENSE). Please also
follow our [Code of Conduct](CODE_OF_CONDUCT.md).
