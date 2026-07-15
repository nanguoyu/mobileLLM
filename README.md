<div align="center">

<img src="assets/icon.png" width="104" alt="mobileLLM icon" />

# mobileLLM

**A private, open-source chat app that runs open-weight language models fully on your device** —
macOS + iOS, pure Swift + [MLX](https://github.com/ml-explore/mlx-swift). No account, no cloud;
nothing you type ever leaves the device.

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg" alt="Platforms: iOS | macOS" />
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6" />
  <img src="https://img.shields.io/badge/inference-100%25%20on--device-brightgreen.svg" alt="100% on-device" />
</p>

<img src="assets/screenshot.jpg" width="300" alt="mobileLLM running an on-device model on iPhone" />

</div>

## Features

- 🔒 **100% on-device.** Chats, prompts, and models stay on your device — no account, no server, no telemetry.
- 💬 **Streamed chat** with open-weight LLMs, token-by-token, plus a collapsible **reasoning** view for thinking-mode models.
- 📊 **Honest memory fit.** Every model shows a per-device fit badge (*Runs great* / *Tight* / *Experimental*) computed from your actual hardware — so you know before you download.
- ⬇️ **Resumable downloads** with live bytes/speed/ETA; one active model, with its memory reclaimed automatically when idle.
- 🧩 **Many model families.** Extend the catalog by adding an entry, not a rewrite — Bonsai (Qwen3.5 / Qwen3, 1-bit & ternary) is included first.
- ⚡ **Two engines, one protocol — you choose.** Switch between **MLX** (resident weights) and **llama.cpp** (memory-mapped GGUF) per model, or let Auto pick the best fit for your device.
- 🎨 **Native SwiftUI** on iPhone and Mac — tabs & sheets on iOS, sidebar & menu bar on macOS, Dynamic Type, dark mode, reduce-motion.

## Models

The catalog is designed to grow to **many open-weight families**. Each model shows its own provider
and license on its card in the app. The first family included is **Bonsai** (Qwen3.5 / Qwen3, 1-bit
and ternary quantizations) — more families are on the roadmap.

## Architecture

Two inference engines behind **one protocol** (`LLMEngine`), fronted by a `RoutingEngine` that keeps at
most one resident — so the UI, model manager, downloader, and memory/thermal governance are engine-agnostic:

- **MLX engine** — resident weights via the 1-bit MLX fork; the fastest path on Mac.
- **llama.cpp engine** — memory-mapped GGUF, so large models fit on memory-tight phones (mmap'd weight
  pages are clean/reclaimable and don't count like anonymous dirty memory against the iOS jetsam limit).

You pick the engine per model on its card, or set a global preference (Auto / MLX / llama.cpp) in
Settings; the memory-fit badge updates live for the engine you choose. The llama.cpp engine vendors a
prebuilt `llama.xcframework` (mainline llama.cpp, Metal embedded) — it isn't committed; regenerate it
with `scripts/build-llama-xcframework.sh`.

See **[docs/DESIGN.md](docs/DESIGN.md)** for the full architecture, model catalog, and roadmap, and
**[docs/WIRING.md](docs/WIRING.md)** for the 1-bit + llama.cpp dependency notes.

## Build

Universal SwiftUI app (macOS 14 / iOS 17). The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cp Signing.xcconfig.example Signing.xcconfig   # add your Apple Developer Team ID
xcodegen generate
open mobileLLM.xcodeproj
```

Build with **`xcodebuild`** (MLX's Metal kernels require it). The MLX-free packages
(`AppUI` / `AppRuntime` / `LLMCore`) also run a fast `swift test`.

## License

App source: **[MIT](LICENSE)**. Each model keeps its own license (shown in the app).
