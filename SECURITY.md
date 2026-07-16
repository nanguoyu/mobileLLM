# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue.

Use GitHub's private vulnerability reporting: open the repository's **Security → Advisories → Report a
vulnerability** ([new advisory form](https://github.com/nanguoyu/mobileLLM/security/advisories/new)). This
keeps the report between you and the maintainers until a fix is ready.

Please include, as far as you can:

- the affected platform (iOS / macOS) and app version,
- the model and quantization involved (e.g. `Bonsai 8B`, MLX 1-bit / GGUF Q4_K_M), if relevant,
- steps to reproduce, and the impact you observed.

We aim to acknowledge a report within a few days and to keep you updated as we investigate. There is no bug
bounty program.

## Scope

mobileLLM is an **on-device** application: inference runs entirely on the user's own hardware, and chats,
prompts, and models never leave the device. That shapes what is and isn't in scope.

**In scope** — issues in this repository's code, for example:

- memory-safety or crash issues in the app or the MLX-free packages,
- the resumable downloader and its on-disk handling (path handling, checksum verification, resume logic),
- the MCP client's parsing of untrusted server responses (JSON-RPC / SSE),
- persistence and recovery (`DurableStore`, conversation/registry stores),
- anything that could cause data the app holds to leave the device unexpectedly.

**Out of scope / handled elsewhere:**

- **User-configured MCP servers.** MCP servers are remote endpoints the *user* adds (a URL and an optional
  token). Their trustworthiness, content, and TLS posture are the user's responsibility; a malicious or
  compromised server the user chose to connect is not a vulnerability in this app. Parsing bugs in how we
  *handle* a server's response, however, are in scope.
- **Model weights from Hugging Face.** Models are downloaded from Hugging Face repositories (curated in the
  catalog, or discovered live via the Explore tier). The content, behavior, and licensing of a third-party
  model are outside this project; model output is not verified and Explore models are surfaced as
  *Unverified*. Integrity issues in how we *download or store* weights are in scope.
- The MLX fork and llama.cpp themselves — report upstream — though wiring issues on our side are in scope.

## Supported versions

This is a pre-1.0 project under active development; fixes land on `main`. Please test against the latest
`main` before reporting.
