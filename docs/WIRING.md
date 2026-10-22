# mobileLLM dependency wiring

Reviewed 2026-10-22 against code commit `82933a0`. Package manifests and
`scripts/build-llama-xcframework.sh` are the source of truth for dependency pins.
[ARCHITECTURE.md](ARCHITECTURE.md) describes runtime composition; [STATUS.md](STATUS.md) records
validation and remaining work.

## Dependency isolation

`LLMEngineMLX` is the only package importing MLX and its PrismML fork. `LLMEngineLlama` alone imports
the vendored `llama` binary target. `LLMEngineApple` weak-links FoundationModels and owns no weight
files. The other eight product packages use their protocols without importing either local-weight
engine. The optional online provider lives in `AgentRuntime` and does not enter `RoutingEngine`.

## Pinned MLX stack

| Dependency | Declared pin | Purpose |
| --- | --- | --- |
| `PrismML-Eng/mlx-swift` | `e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230` | Affine 1-bit kernel used by the shipped MLX variants |
| `nanguoyu/mlx-swift-lm` | `ab016139837f58646f1b984ebfbadd8bacf866d5` | Model loaders and generation using the selected MLX fork |
| `huggingface/swift-transformers` | from `1.3.3` | Tokenizer dependency used by the load macros |
| `huggingface/swift-huggingface` | from `0.9.0` | Hugging Face loader support |
| `swiftlang/swift-syntax` | `602.0.0 ..< 603.0.0` | Macro implementation for the Swift 6.2 toolchain family |

The two revision-pinned forks preserve the repository's known 1-bit execution path. The July 2026 kernel investigation
referenced [mlx#3161](https://github.com/ml-explore/mlx/pull/3161); the exact revisions above define
the current dependency stack.
`Package.resolved` is ignored, so range-based dependencies can resolve differently on a fresh build.
Record their resolved revisions with any new build evidence.

The consumer target directly depends on and imports `Tokenizers` and `HuggingFace` because the
`MLXHuggingFace` loader macros expand into references to them. Build with `-skipMacroValidation`.
`LLMCore` must not acquire those engine dependencies.

## Toolchain compatibility

The deployment floors remain iOS 17 and macOS 14. The app's platform bridges name iOS 26 / macOS 26
APIs behind availability guards, so the SDK must contain those declarations. Deployment targets
and SDK/compiler versions are separate constraints.

The reference engine setup recorded with this dependency stack is Xcode 26.3 / Swift 6.2.4. The
SwiftSyntax range above is intentionally tied to the 602 family. As of the 2026-10-22 review, the
maintainer host is Xcode 27.1 / Swift 6.4: the eight MLX-free product packages and verification tool
compiled there, but the complete app/Metal/macro build was not rerun. That package result does not
establish compatibility of the pinned macros with Swift 6.4. Select a compatible Xcode toolchain
or validate a dependency/toolchain migration before using a newer compiler for the full app.

Use Xcode to build MLX executables so their Metal resource bundle is present:

```sh
xcodebuild -scheme llm-smoke -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/mobilellm-mlx-build -skipMacroValidation \
  MTL_COMPILER_FLAGS='$(inherited) -Wno-c++17-extensions -Wno-c++20-extensions' build
DYLD_FALLBACK_LIBRARY_PATH=/usr/lib /tmp/mobilellm-mlx-build/Build/Products/Debug/llm-smoke
```

A plain SwiftPM compile does not establish that `default.metallib` is packaged for execution. The
smoke targets also carry a libc++ runpath to `/usr/lib`. MLX activation is rejected in the simulator;
use real Apple hardware for its inference tests. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the
app, app-unit, engine-unit, simulator, and device schemes.

## llama.cpp framework

`scripts/build-llama-xcframework.sh` builds mainline `ggml-org/llama.cpp` at
`956973c76466b6c791d7bdbe6eed3aa3235b2dc1`. It uses the upstream XCFramework build, retains iOS device,
iOS simulator, and macOS slices, and installs the result at
`Packages/LLMEngineLlama/Vendor/llama.xcframework`. The framework is gitignored and must be generated
on a fresh checkout. The historical build occupied about 355 MB and took 15–25 minutes.

```sh
./scripts/build-llama-xcframework.sh
xcodegen generate
```

The binary module is `llama`; it includes `llama.h`, GGML Metal headers, and `mtmd`/`mtmd-helper`
for vision. Metal is embedded. The llama.cpp package targets have explicit source paths in Package.swift.

`LlamaEngine` uses mmap, disables Metal residency sets on iOS, and unloads/drains the prior model
before replacing it. Simulator text decoding uses CPU (`n_gpu_layers = 0`). Context and KV width
are allocated per generation; quantized KV enables Flash Attention. Vision projector paths are
resolved during model load and the encoder is allocated only for an image-bearing generation.

Curated prompt builders cover ChatML, DeepSeek, Hunyuan, and Gemma. Explore GGUFs use embedded chat
templates with a ChatML fallback. BOS insertion belongs to tokenization. Decode output passes
through UTF-8 piece decoding, reasoning splitting, and answer-wrapper stripping.

## Apple and portable packages

`LLMEngineApple` uses `#if canImport(FoundationModels)` and availability checks while retaining the
same deployment floor. It creates a fresh session for each full-history request and differences
cumulative response snapshots. Availability determines whether the system model is usable; no
model directory or download is involved. Its deterministic mapping tests run without real inference.

`AgentContracts` and `Tools/AgentHarnessVerification` conditionally use Apple's Swift Crypto,
exactly `4.5.2`, on Linux and CryptoKit on Apple platforms. Hosted Linux also tests `AgentSandboxAPI`.
`AgentRuntime` links sqlite3 and JavaScriptCore and remains an Apple-platform package.

## Historical inference evidence

These observations were recorded on 2026-07-15, before the durable agent migration:

- The 1-bit Metal kernel matched dequantize-plus-matmul with maximum difference `3.05e-05`.
- Bonsai 8B decoded through MLX; this completed the follow-up gate that older wiring notes still
  described as pending.
- Mainline llama.cpp decoded Bonsai 27B Q1_0 using Metal hybrid-attention kernels. The recorded Mac
  rate was 11.2 tokens/s; the 8B engine smoke recorded 23.6 tokens/s in Release.

These are dated integration observations, not current iPhone performance baselines. A new model
family, quantization format, or fork replacement needs its own loader/kernel, prompt, tool, memory,
and device verification. A catalog entry alone cannot add support for a format absent from the
pinned engines. Before retiring the MLX fork, verify compatible upstream kernels and checkpoint
loading and rerun matched model outputs and the app/engine gates.
