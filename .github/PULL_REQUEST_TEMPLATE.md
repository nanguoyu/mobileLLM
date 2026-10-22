<!-- Keep it focused. Describe the WHY, not just the what. -->

## Summary

<!-- What this changes and why. -->

## Area

<!-- Delete those that don't apply. -->
- [ ] Chat / UI (`MobileLLMUI`, `AppUI`)
- [ ] Core / catalog / governor / tools / MCP (`LLMCore`)
- [ ] Runtime substrate: downloader / stores / governors (`AppRuntime`)
- [ ] Agent contracts / sandbox API (`AgentContracts`, `AgentSandboxAPI`)
- [ ] Agent execution / approvals / persistence / workflows (`AgentRuntime`, `App`)
- [ ] MLX engine (`LLMEngineMLX`)
- [ ] llama.cpp engine (`LLMEngineLlama`)
- [ ] Apple Intelligence engine (`LLMEngineApple`)
- [ ] Docs / CI / tooling

## Testing

<!-- Which suites you ran, and any on-device check (platform, engine, model, quant). -->
- [ ] Relevant MLX-free package suites and the verification-tool suite pass (see CONTRIBUTING.md)
- [ ] Live online tests, unavailable-environment skips, and any first-attempt failures are reported explicitly
- [ ] `agent-harness-verify static` passes when spec, contracts, verification data, or package boundaries change
- [ ] `xcodebuild` macOS + iOS app builds and engine gates pass (required for engine/package/project wiring)
- [ ] Tested on device (if it touches inference) — platform / engine / model / quant:

## Checklist

- [ ] Tests added or updated for the changed behavior; existing tests not weakened without reason
- [ ] No signing secrets committed (`Signing.xcconfig`, Team ID, tokens/keys); bundle-ID changes use `project.yml`
- [ ] The eight MLX-free product packages stay free of MLX/vendored engine binaries
- [ ] Agent changes cover journal/approval/recovery and the actual app assembly path
- [ ] Changes to spec.md update requirement anchors and all five recorded specification digests
- [ ] Network changes validate redirects and resolved addresses, and enforce bounded response bodies
- [ ] New Swift files start with `// SPDX-License-Identifier: MIT`; 4-space indent, existing idiom
- [ ] Docs updated if behavior or the catalog changed
