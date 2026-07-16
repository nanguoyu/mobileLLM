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
- [ ] Docs / CI / tooling

## Testing

<!-- Which suites you ran, and any on-device check (platform, engine, model, quant). -->
- [ ] `swift test` passes for the four MLX-free packages (`AppUI`, `AppRuntime`, `LLMCore`, `MobileLLMUI`)
- [ ] Tested on device (if it touches inference) — platform / engine / model / quant:

## Checklist

- [ ] Tests added or updated for the changed behavior; existing tests not weakened without reason
- [ ] No signing identifiers or secrets committed (no `Signing.xcconfig`, Team ID, real bundle id, tokens/keys)
- [ ] The four MLX-free packages stay MLX-free (MLX code in `LLMEngineMLX`, llama.cpp in `LLMEngineLlama`)
- [ ] New Swift files start with `// SPDX-License-Identifier: MIT`; 4-space indent, existing idiom
- [ ] Docs updated if behavior or the catalog changed
