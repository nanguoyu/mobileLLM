# Contributing to mobileLLM

Thanks for your interest. mobileLLM is a private, on-device LLM chat app for macOS + iOS, written in Swift.
This guide covers the development setup, the package layout, how to run the tests, and what a PR needs.

## Development setup

Universal SwiftUI app (macOS 14 / iOS 17), Swift 6, **Xcode 16 or newer**. The Xcode project is generated
from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The llama.cpp engine needs a
vendored XCFramework that isn't committed, so a fresh clone builds it first.

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

Ten Swift packages plus the app target. MLX and llama.cpp are quarantined to one package each — the other
eight are MLX-free and test under plain SwiftPM without any Metal toolchain or the vendored XCFramework.

| Package | What it holds | Toolchain |
|---|---|---|
| `AppUI` | Ink-wash design tokens + shared SwiftUI controls | MLX-free — `swift test` |
| `AppRuntime` | Resumable downloader, memory/thermal governors, `DurableStore` (Foundation + CryptoKit) | MLX-free — `swift test` |
| `LLMCore` | Catalog + schema, `RoutingEngine`, memory governor, context policy, tools/MCP, Explore, `ThinkSplitter`, the `LLMEngine` protocol + a mock | MLX-free — `swift test` |
| `AgentContracts` | Versioned run/step/request/approval/budget/workflow contracts shared by runtime, sandbox API, and UI | MLX-free — `swift test` |
| `AgentRuntime` | Durable agent executor, SQLite journal, approval policy, budgets, recovery, subagents, parallel tool batches, staged workflow orchestrator, online Responses API provider | MLX-free — `swift test` (links sqlite3) |
| `AgentSandboxAPI` | Protocol-only sandbox seam; no provider ships in the open-source build | MLX-free — `swift test` |
| `MobileLLMUI` | SwiftUI chat / models / settings + `@Observable` stores, agent run/approval/workflow UI (codes against `LLMEngine` + `AgentRuntime` contracts) | MLX-free — `swift test` |
| `LLMEngineApple` | The Apple Intelligence engine — weak-linked `FoundationModels`, no weights of ours | MLX-free — `swift test` |
| `LLMEngineMLX` | The MLX engine — resident weights, PrismML 1-bit fork | Metal — `xcodebuild` |
| `LLMEngineLlama` | The llama.cpp engine — mmap'd GGUF, vendored `llama.xcframework` | Metal — `xcodebuild` |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit and [docs/WIRING.md](docs/WIRING.md)
for the MLX-fork + llama.cpp dependency pins.

## Running the tests

The eight MLX-free packages are the fast inner loop and CI's first matrix. CI then performs the unsigned app
build and the three-engine `EngineTests` gate. Point local SwiftPM build output outside the source tree so
nothing stray lands in the repo:

```sh
swift test --package-path Packages/AppUI          --scratch-path /tmp/mllm-appui
swift test --package-path Packages/AppRuntime     --scratch-path /tmp/mllm-appruntime
swift test --package-path Packages/LLMCore        --scratch-path /tmp/mllm-llmcore
swift test --package-path Packages/AgentContracts --scratch-path /tmp/mllm-agent-contracts
swift test --package-path Packages/AgentRuntime   --scratch-path /tmp/mllm-agent-runtime
swift test --package-path Packages/AgentSandboxAPI --scratch-path /tmp/mllm-agent-sandbox
swift test --package-path Packages/MobileLLMUI    --scratch-path /tmp/mllm-ui
swift test --package-path Packages/LLMEngineApple --scratch-path /tmp/mllm-apple
```

`LLMEngineApple`'s suite runs on any macOS — it needs no Apple Intelligence. Two tests skip below macOS 26
(where the framework's types can't even be named); `APPLE_LLM_LIVE=1` adds one real round-trip on an
eligible machine.

The two local-weight engine packages (`LLMEngineMLX`, `LLMEngineLlama`) build and run via `xcodebuild` only
— the MLX package additionally needs `-skipMacroValidation` (see docs/WIRING.md). Their smoke executables
(`llm-smoke`, `llama-smoke`) run against real weights on a device.

```sh
# Unsigned app builds matching CI's two platform gates:
xcodebuild -project mobileLLM.xcodeproj -scheme mobileLLM \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project mobileLLM.xcodeproj -scheme mobileLLM \
  -destination 'generic/platform=iOS' -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' \
  CODE_SIGNING_ALLOWED=NO build

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

The simulator suite is currently a required manual/local command: CI validates discovery of both test plans but does
not yet execute `SimulatorUI.xctestplan`. Do not report simulator coverage as a CI gate until that job is added and
archives its `.xcresult` evidence.

Note the simulator runs **llama.cpp on CPU only and cannot run MLX at all** — activation refuses MLX
variants there by design; anything MLX is validated on real hardware.

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
  UI tests read those from launch-environment variables seeded by the DEBUG build.
- **Adding a model?** Prefer a catalog entry in `LLMCatalog` with the right `modelType` / `swiftModelClass`
  and verified figures from a Hugging Face primary source — the schema is built to grow that way.
- **Changing downloads or web access?** Pin every Hub request to the variant revision, preserve LFS
  integrity checks across fresh and resumed writes, validate every redirect target and resolved address,
  and enforce response limits while streaming. Add hostile-path tests, not only happy-path fixtures.
- Keep PRs focused, describe the *why*, and confirm the MLX-free suites pass before requesting review.

By contributing you agree your contributions are licensed under the [MIT License](LICENSE). Please also
follow our [Code of Conduct](CODE_OF_CONDUCT.md).
