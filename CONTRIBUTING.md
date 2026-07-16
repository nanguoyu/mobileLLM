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
#    never commit a Team ID or bundle identifier).
cp Signing.xcconfig.example Signing.xcconfig

# 4. Generate and open the project.
xcodegen generate
open mobileLLM.xcodeproj
```

Build the app with **Xcode / `xcodebuild`** — MLX's Metal kernels require it, and SwiftPM can't compile the
fork's Metal. Inference (the 1-bit MLX kernels and GGUF Metal) is validated on **real devices**; the
simulator has no Metal path for it.

## Package map

Six Swift packages plus the app target. MLX and llama.cpp are quarantined to one package each — the other
four are MLX-free and test under plain SwiftPM without any Metal toolchain or the vendored XCFramework.

| Package | What it holds | Toolchain |
|---|---|---|
| `AppUI` | Ink-wash design tokens + shared SwiftUI controls | MLX-free — `swift test` |
| `AppRuntime` | Resumable downloader, memory/thermal governors, `DurableStore` (Foundation + CryptoKit) | MLX-free — `swift test` |
| `LLMCore` | Catalog + schema, `RoutingEngine`, memory governor, context policy, tools/MCP, Explore, `ThinkSplitter`, the `LLMEngine` protocol + a mock | MLX-free — `swift test` |
| `MobileLLMUI` | SwiftUI chat / models / settings + `@Observable` stores (codes against the `LLMEngine` protocol) | MLX-free — `swift test` |
| `LLMEngineMLX` | The MLX engine — resident weights, PrismML 1-bit fork | Metal — `xcodebuild` |
| `LLMEngineLlama` | The llama.cpp engine — mmap'd GGUF, vendored `llama.xcframework` | Metal — `xcodebuild` |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit and [docs/WIRING.md](docs/WIRING.md)
for the MLX-fork + llama.cpp dependency pins.

## Running the tests

The four MLX-free packages are the fast inner loop and the same suites CI runs. Point the build output
outside the source tree so nothing stray lands in the repo:

```sh
swift test --package-path Packages/AppUI       --scratch-path /tmp/mllm-appui
swift test --package-path Packages/AppRuntime  --scratch-path /tmp/mllm-appruntime
swift test --package-path Packages/LLMCore     --scratch-path /tmp/mllm-llmcore
swift test --package-path Packages/MobileLLMUI --scratch-path /tmp/mllm-ui
```

The two engine packages (`LLMEngineMLX`, `LLMEngineLlama`) build and run via `xcodebuild` only — the MLX
package additionally needs `-skipMacroValidation` (see docs/WIRING.md). Their smoke executables
(`llm-smoke`, `llama-smoke`) run against real weights on a device.

```sh
# Engine unit tests (macOS destination; SwiftPM can't build the MLX package's macros):
xcodebuild -skipMacroValidation -scheme EngineTests -destination platform=macOS test

# Keyboard/composer geometry (XCUITest, iOS simulator). Prerequisites: seed a small GGUF into the sim
# app container (see the header of UITests/KeyboardUITests.swift) and disable the hardware keyboard
# (defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false):
xcodebuild -skipMacroValidation -scheme UITests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

Note the simulator runs **llama.cpp on CPU only and cannot run MLX at all** — activation refuses MLX
variants there by design; anything MLX is validated on real hardware.

## Pull requests

- **Tests stay green.** Add or update tests for the behavior you change; existing tests are pinned behavior
  — don't weaken or delete one unless the behavior changed by design, and say so if it did.
- **No signing identifiers or secrets.** Never commit `Signing.xcconfig`, a Development Team ID, a real
  bundle identifier, or any token/key. `Signing.xcconfig` and the generated `.xcodeproj` are gitignored;
  keep it that way.
- **Match the existing idiom.** 4-space indent; `// SPDX-License-Identifier: MIT` as the first line of every
  new Swift file; comments state non-obvious constraints rather than narrating the code.
- **Keep the MLX-free packages MLX-free.** Anything touching MLX belongs in `LLMEngineMLX`; anything touching
  llama.cpp belongs in `LLMEngineLlama`. Don't add MLX (or the fork) as a dependency of the other four.
- **Adding a model?** Prefer a catalog entry in `LLMCatalog` with the right `modelType` / `swiftModelClass`
  and verified figures from a Hugging Face primary source — the schema is built to grow that way.
- Keep PRs focused, describe the *why*, and confirm the MLX-free suites pass before requesting review.

By contributing you agree your contributions are licensed under the [MIT License](LICENSE). Please also
follow our [Code of Conduct](CODE_OF_CONDUCT.md).
