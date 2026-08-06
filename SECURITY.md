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

mobileLLM is an **on-device inference** application: generation and chat persistence run on the user's
hardware. It is not an offline-only application. Hugging Face discovery/downloads and network tools
(web search, webpage reading, Wikipedia, and user-configured MCP servers) make outbound requests when the
user invokes or enables them; **online models** (OpenAI-compatible Responses API services the user adds)
send conversation text to the configured endpoint after per-conversation approval. The app has no
account, analytics, or telemetry service.

**In scope** — issues in this repository's code, for example:

- memory-safety or crash issues in the app or the MLX-free packages,
- the resumable downloader and its on-disk handling (path handling, checksum verification, resume logic),
- outbound web-tool controls (URL scheme, DNS/IP and redirect validation, response-size enforcement),
- the agent runtime's `prepare → authorize → execute` boundary, capability ceilings, budgets, approval
  receipts, journal/recovery, and subagent attenuation,
- online-model configuration and per-conversation data-egress approval (including future server-side
  native tools such as a provider-hosted `web_search`, whose policy is fixed in spec §15.5),
- the MCP client's parsing of untrusted server responses (JSON-RPC / SSE),
- persistence and recovery (`DurableStore`, conversation/registry stores),
- anything that could cause data the app holds to leave the device unexpectedly.

**Out of scope / handled elsewhere:**

- **User-configured MCP servers.** MCP servers are remote endpoints the *user* adds (a URL and an optional
  token). Their trustworthiness, content, and TLS posture are the user's responsibility; a malicious or
  compromised server the user chose to connect is not a vulnerability in this app. Parsing bugs in how we
  *handle* a server's response, or requests sent to a different endpoint than the one configured, are in scope.
- **Model weights from Hugging Face.** Models are downloaded from Hugging Face repositories (curated in the
  catalog, or discovered live via the Explore tier). The content, behavior, and licensing of a third-party
  model are outside this project; model output is not verified and Explore models are surfaced as
  *Unverified*. Integrity issues in how we *download or store* weights are in scope.
- The MLX fork and llama.cpp themselves — report upstream — though wiring issues on our side are in scope.

## Security boundaries

- Master tool access is off by default. Only individually selected built-in tools and MCP servers are
  advertised to the model; a network-tool call sends its arguments to that service. Tool responses are
  framed as untrusted external data before being returned to the model. Every external operation —
  online-model inference and every tool call — passes an immutable `prepare → authorize → execute`
  boundary: a prepared plan (destination, data categories, argument digest, response ceiling) cannot be
  widened during execution, and the run's capability ceiling is frozen for its lifetime. Three
  per-conversation approval modes (Ask / Safe preset / Full access) control when the user is asked;
  approval receipts are durable and bound to the exact operation.
- Online-model API keys are stored in the platform Keychain with this-device-only accessibility and are
  never written to Settings or `UserDefaults`; the macOS/simulator DEBUG build reads the developer's
  `~/.mobilellm/openai.json` outside the repository to seed tests, and that file is never committed.
  Sending a conversation to an online service is data egress and asks for approval once per conversation
  under the active mode.
- Subagents and workflow children receive a strict subset of the parent run's capability ceiling and
  attenuated budgets; a child can never grant itself an authority the parent did not hold. Future
  server-side native tools (e.g. DeepSeek `web_search`) are provider-executed: the app advertises either
  the native tool or the local adapter for a capability, never both, and the provider's output item is
  treated as untrusted external data (spec §15.5).
- MCP bearer tokens are stored in the platform Keychain with this-device-only accessibility. They are not
  retained in the `UserDefaults` settings snapshot.
- Model files are confined to the app's model directory, downloaded from the variant's declared Hugging
  Face revision, checked against the Hub-reported size and LFS SHA-256 before being promoted from `.part`,
  and recorded in a revision-bearing manifest. Community model behavior and licensing are still
  **Unverified**; missing Hub family/license metadata is shown as unknown rather than inferred.
- The webpage reader accepts only HTTP(S), rejects non-public destinations before requests and redirects,
  and enforces its response-body limit while streaming rather than after buffering an arbitrary body.
  URLSession does not expose the peer IP or let the app pin a pre-resolved address while retaining normal
  TLS hostname validation, so a DNS rebinding race between validation and CFNetwork's connection remains a
  platform-level residual risk. Eliminating it would require a separately audited, IP-pinned HTTP/TLS
  transport rather than URLSession; the project does not claim that stronger guarantee.

## Supported versions

This is a pre-1.0 project under active development; fixes land on `main`. Please test against the latest
`main` before reporting.
