<!-- Keep it focused. Describe the WHY, not just the what. -->

## Summary

<!-- What this changes and why. -->

## Area

<!-- Delete those that don't apply. -->
- [ ] Chat / UI (`MobileLLMUI`, `AppUI`)
- [ ] Core / catalog / governor / tools / MCP (`LLMCore`)
- [ ] Runtime — downloader / stores / governors (`AppRuntime`)
- [ ] MLX engine (`LLMEngineMLX`)
- [ ] llama.cpp engine (`LLMEngineLlama`)
- [ ] Apple Intelligence engine (`LLMEngineApple`)
- [ ] Docs / CI / tooling

## Testing

<!-- Which suites you ran, and any on-device check (platform, engine, model, quant). -->
- [ ] `swift test` passes for the five fast packages (`AppUI`, `AppRuntime`, `LLMCore`, `MobileLLMUI`, `LLMEngineApple`)
- [ ] `xcodebuild` macOS + iOS app builds and engine gates pass (required for engine/package/project wiring)
- [ ] Tested on device (if it touches inference) — platform / engine / model / quant:

## Checklist

- [ ] Tests added or updated for the changed behavior; existing tests not weakened without reason
- [ ] No signing identifiers or secrets committed (no `Signing.xcconfig`, Team ID, real bundle id, tokens/keys)
- [ ] The five fast packages stay free of MLX/vendored binaries (engine code remains in its engine package)
- [ ] Network changes validate redirects and resolved addresses, and enforce bounded response bodies
- [ ] New Swift files start with `// SPDX-License-Identifier: MIT`; 4-space indent, existing idiom
- [ ] Docs updated if behavior or the catalog changed
