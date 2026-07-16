<div align="center">

<img src="assets/icon.png" width="104" alt="mobileLLM icon" />

# mobileLLM

**A private, open-source chat app that runs open-weight language models fully on your device** —
macOS + iOS, native Swift + SwiftUI. Two inference engines — Apple [MLX](https://github.com/ml-explore/mlx-swift)
and [llama.cpp](https://github.com/ggml-org/llama.cpp) — sit behind one protocol. No account, no cloud;
nothing you type ever leaves the device.

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://github.com/nanguoyu/mobileLLM/actions/workflows/ci.yml"><img src="https://github.com/nanguoyu/mobileLLM/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg" alt="Platforms: iOS | macOS" />
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6" />
  <img src="https://img.shields.io/badge/inference-100%25%20on--device-brightgreen.svg" alt="100% on-device" />
</p>

<!-- Hero image. To refresh, replace assets/screenshot.jpg in place (same path/name) — nothing else
     references it. -->
<img src="assets/screenshot.jpg" width="300" alt="mobileLLM first launch on iPhone — ink-wash palette" />

</div>

## Features

- 🔒 **100% on-device.** Chats, prompts, and models stay on your device — no account, no server, no telemetry.
- 💬 **Streamed chat with thinking disclosure.** Tokens stream one by one; for reasoning models the `<think>`
  trace shows in a disclosure that auto-collapses to "Thought for Ns" when the answer starts (or always-expand / hidden).
- ⚡ **Two engines, one protocol.** **MLX** (resident weights) and **llama.cpp** (memory-mapped GGUF) both
  conform to a single `LLMEngine`; a `RoutingEngine` keeps at most one resident. Pick the engine per model,
  or let **Auto** choose the greenest fit for your device.
- 📊 **Honest memory fit + a model-aware context ladder.** Every model shows a per-device fit badge
  (*Runs great* / *Tight* / *Needs more memory*) from your actual RAM, and the context-length options are
  capped by what the model was trained for and re-scored per rung — a setting that buys memory, not capability.
- 🛠️ **Tool calling + MCP.** An on-device agent loop with a real toolbox: keyless **web search**
  (DuckDuckGo first, Bing fall-through — scraped result pages, no API key), a **webpage reader**
  (readable-text extraction with SSRF guards), **persistent memory** (`remember`/`recall` across chats),
  Wikipedia, calculator, clock — plus permission-gated **calendar, reminders and location** tools (off
  until you enable them; the system prompt appears on first use). Every tool has its own toggle in
  Settings → Manage tools, and any remote **MCP** server you configure layers on top (Streamable HTTP,
  per-server enable + per-tool mute). Tools are off by default.
- 🖼️ **Image input (vision GGUF models).** Attach photos (picker or paste, up to 3, downscaled to 1568 px
  JPEG on-device) and ask about them — Qwen3.5 and Gemma 4 run their official `mmproj` projector through
  llama.cpp's mtmd. The photo button appears only when the active model can actually see.
- 🎤 **Dictation.** A mic button in the composer transcribes speech into the draft via Apple's speech
  recognizer, on-device where supported; long-press to pick the recognition language (System / 中文 /
  English — one recognizer is bound to one language). A camera capture option sits beside the photo
  library and paste in the composer's [+] menu.
- 🧵 **Conversations remember their model.** Every send stamps the thread with the model that answered;
  reopening a thread (or relaunching the app) brings that model back. There is no "default model"
  setting to manage — a new chat starts on whatever you used last, and the empty-state title
  ("Chat with … ⌄") is itself the model picker.
- 🧭 **Explore — live Hugging Face browse.** Search `mlx-community` (MLX) and the GGUF orgs (bartowski,
  unsloth, ggml-org, lmstudio-community) by download count, pick a precision, and install. Community models
  load from their own chat template, so they're clearly flagged **Unverified**.
- 🧩 **Many model families.** 12 curated models across 5 families ship in the Featured catalog; adding one
  is a catalog entry, not a rewrite. Downloads are **resumable** with live bytes/speed/ETA.
- 🎨 **Native SwiftUI, ink-wash design.** Tabs & sheets on iOS, sidebar & menu bar on macOS; a warm
  rice-paper / cinnabar-seal (水墨) palette, Dynamic Type, dark mode, reduce-motion.

## Models

The **Featured** catalog ships **12 models across 5 families**, every size/layer/quant figure taken from a
Hugging Face primary source. Each model's own license shows on its card in the app. The **Explore** tier
adds hundreds more live from the Hub.

| Model | Family · Publisher | Params | Quantizations (on-disk) | Engine(s) | License |
|---|---|---|---|---|---|
| Bonsai 27B | Bonsai · Prism ML | 27B ᴴ | 1-bit 5.1 GB · ternary 8.5 GB · GGUF 3.8 GB | MLX + llama.cpp | Apache-2.0 |
| Bonsai 8B | Bonsai · Prism ML | 8B | 1-bit 1.3 GB · ternary 2.3 GB · GGUF 1.2 GB | MLX + llama.cpp | Apache-2.0 |
| Bonsai 4B | Bonsai · Prism ML | 4B | 1-bit 0.6 GB · ternary 1.1 GB · GGUF 0.6 GB | MLX + llama.cpp | Apache-2.0 |
| Bonsai 1.7B | Bonsai · Prism ML | 1.7B | 1-bit 0.3 GB · ternary 0.5 GB · GGUF 0.2 GB | MLX + llama.cpp | Apache-2.0 |
| Qwen3.5 4B | Qwen · Alibaba | 4B ᴴ | Q4_K_M 2.7 GB ᵛ | llama.cpp | Apache-2.0 |
| Qwen3.5 9B | Qwen · Alibaba | 9B ᴴ | Q4_K_M 5.7 GB ᵛ | llama.cpp | Apache-2.0 |
| Qwen3.6 27B | Qwen · Alibaba | 27B ᴴ | Q4_K_M 16.8 GB | llama.cpp | Apache-2.0 |
| Hunyuan 4B | Hunyuan · Tencent | 4B | Q4_K_M 2.6 GB | llama.cpp | Tencent Hunyuan Community |
| DeepSeek-R1 Qwen3 8B | DeepSeek | 8B | Q4_K_M 5.0 GB | llama.cpp | MIT |
| Gemma 4 E2B | Gemma · Google | ~2B ᴹ | Q4_K_M 3.1 GB ᵛ | llama.cpp | Gemma Terms of Use |
| Gemma 4 E4B | Gemma · Google | ~4B ᴹ | Q4_K_M 5.0 GB ᵛ | llama.cpp | Gemma Terms of Use |
| Gemma 4 12B | Gemma · Google | 12B | Q4_K_M 7.4 GB ᵛ | llama.cpp | Gemma Terms of Use |

<sub>Sizes are decimal GB (bytes ÷ 10⁹), rounded. **ᴴ** hybrid Gated-DeltaNet (qwen3_5) — only the
full-attention layers grow a KV cache, so memory stays near-constant as context grows. **ᴹ** Gemma
MatFormer "effective" size. **MLX 1-bit** needs the PrismML fork kernel; **ternary 2-bit** is upstream MLX;
**GGUF** runs on llama.cpp. **ᵛ** vision-capable: the app downloads the model's official `mmproj`
projector alongside the weights (adds 0.16–1 GB) and the composer accepts image attachments.</sub>

## Architecture

Six Swift packages, MLX quarantined to one of them:

```
mobileLLM.app  (Xcode target — build via xcodebuild)
├── MobileLLMUI      SwiftUI chat / models / settings + @Observable stores   (MLX-free)
├── LLMEngineMLX     the MLX engine — resident weights, PrismML 1-bit fork    (Metal)
├── LLMEngineLlama   the llama.cpp engine — mmap'd GGUF, vendored xcframework  (Metal)
├── LLMCore          catalog + schema, RoutingEngine, governor, tools/MCP,     (MLX-free)
│                    context policy, Explore, ThinkSplitter, LLMEngine protocol
├── AppRuntime       downloader, memory/thermal governors, durable store       (MLX-free)
└── AppUI            ink-wash design tokens + shared controls                   (MLX-free)
```

Two engines behind one `LLMEngine` protocol, fronted by a `RoutingEngine` that keeps at most one resident —
so the UI, downloader, and governance are engine-agnostic and unit-testable against a mock. The four MLX-free
packages keep a fast `swift test` loop; only the two engine packages need the Metal toolchain.

- **MLX engine** — resident weights via the PrismML 1-bit fork; the fastest path on Mac.
- **llama.cpp engine** — memory-mapped GGUF, so large models fit on memory-tight phones (clean, file-backed
  weight pages are reclaimable and don't count like anonymous dirty memory against the iOS jetsam limit).
  It vendors a prebuilt `llama.xcframework` (mainline llama.cpp, Metal embedded); it isn't committed —
  regenerate it with `scripts/build-llama-xcframework.sh`.

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for the current package graph, routing, governor,
tools/MCP, and design tokens, and **[docs/WIRING.md](docs/WIRING.md)** for the 1-bit fork + llama.cpp
dependency wiring. **[docs/DESIGN.md](docs/DESIGN.md)** is the original design record, kept for history.

## Build

Universal SwiftUI app (macOS 14 / iOS 17), Swift 6, **Xcode 16 or newer**. The Xcode project is generated
from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); the llama.cpp engine needs a
vendored XCFramework that isn't committed, so a fresh clone builds it first.

```sh
# 1. Tooling (Homebrew)
brew install xcodegen cmake

# 2. Build the llama.cpp XCFramework — REQUIRED (it's gitignored). Needs Xcode + CMake;
#    produces a ~355 MB artifact at Packages/LLMEngineLlama/Vendor/llama.xcframework and
#    takes ~15–25 min the first time (a full multi-platform llama.cpp build).
./scripts/build-llama-xcframework.sh

# 3. Signing — copy the template and add your Apple Developer Team ID (Signing.xcconfig is gitignored).
cp Signing.xcconfig.example Signing.xcconfig

# 4. Generate and open the project.
xcodegen generate
open mobileLLM.xcodeproj
```

Build the app with **Xcode / `xcodebuild`** (MLX's Metal kernels require it). Inference (the 1-bit MLX
kernels and GGUF Metal) is validated on **real devices** — the simulator has no Metal path for it.

For a fast inner loop, the four MLX-free packages need none of the above and run under plain SwiftPM:

```sh
swift test --package-path Packages/AppUI
swift test --package-path Packages/AppRuntime
swift test --package-path Packages/LLMCore
swift test --package-path Packages/MobileLLMUI
```

Two more xcodebuild-only suites: `-scheme EngineTests` runs the engine packages' unit tests (the MLX
package's macros can't build under plain SwiftPM), and `-scheme UITests` drives the keyboard/composer
geometry on an iOS simulator with XCUITest (needs a small GGUF seeded into the app container and the
simulator's hardware keyboard disabled — see `UITests/KeyboardUITests.swift`).

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full development setup and package map.

## License

App source: **[MIT](LICENSE)**. Each model keeps its own license (shown in the app). Model weights
downloaded at runtime are not part of this project.
