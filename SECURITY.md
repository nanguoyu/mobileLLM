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

mobileLLM is a **local-first agent** application. Local inference and chat persistence run on the
user's hardware. Hugging Face discovery/downloads and network tools
(web search, webpage reading, Wikipedia, and user-configured MCP servers) make outbound requests when the
user invokes or enables them; **online models** (OpenAI-compatible Responses API services the user adds)
send compiled text context, including selected system/Skill content, conversation turns, Memory and
tool results, to the configured endpoint under the conversation's approval mode. The app has no
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

- Master tool access is off by default. The security contract permits only individually selected built-in tools and
  MCP servers to be advertised; a network-tool call sends its arguments to that service. Workflow roots and children
  inherit only the initiating conversation's allowed tool set — never force-enabled, never widened, and with no
  hard-coded dependency on web search or the page reader (spec §33 gap 1, closed 2026-08-08). Tool responses are
  framed as untrusted external data before being returned to the model. Every external operation —
  online-model inference and every tool call — passes an immutable `prepare → authorize → execute`
  boundary: a prepared plan (destination, data categories, argument digest, response ceiling) cannot be
  widened during execution, and the run's capability ceiling is frozen for its lifetime. Three
  per-conversation approval modes control presentation: Ask follows explicit approval policy, Safe preset
  auto-authorizes app-local work, bounded network/private reads and selected online-provider egress, and Full access
  auto-authorizes any prepared operation within the frozen ceiling. Receipts remain durable and operation-bound.
- Production online-model API keys are stored in the platform Keychain with this-device-only
  accessibility and are not written to Settings or `UserDefaults`. The developer configuration and
  DEBUG bundle exception are described below.
  Sending a conversation to an online service is data egress. Ask requests bounded conversation consent;
  Safe preset and Full access bind authorization without presenting a prompt, still inside the frozen ceiling.
- Subagents and workflow children receive a strict subset of the parent run's capability ceiling and
  attenuated budgets; a child can never grant itself an authority the parent did not hold. A dynamic
  workflow's model-written orchestration script is statically analyzed against a closed vocabulary, journaled
  and digest-bound before it may run, and executes in a JavaScriptCore realm with no filesystem, network,
  tool, model, secret, clock, or RNG access — its only effect is to request ordinary attenuated child runs.
  That realm is a logical boundary, not an OS sandbox (iOS JavaScriptCore has no public hard heap limit or
  pre-emptive interruption), which is why static rejection is conservative (spec §34.3). Future
  server-side native tools (e.g. DeepSeek `web_search`) are provider-executed: the app advertises either
  the native tool or the local adapter for a capability, never both, and the provider's output item is
  treated as untrusted external data (spec §15.5).
- MCP bearer tokens are stored in the platform Keychain with this-device-only accessibility. Neither
  the settings snapshot nor the discovery cache persists them. Opening an older discovery cache
  scrubs legacy inline tokens; invocation resolves the current credential. Endpoint edits invalidate
  prior discovery, and clearing the cache invalidates callbacks from older discovery generations.
- Model files are confined to the app's model directory, downloaded from the variant's declared Hugging
  Face revision, checked against the Hub-reported size and LFS SHA-256 before being promoted from `.part`,
  and recorded in a revision-bearing manifest. Community model behavior and licensing are still
  **Unverified**; missing Hub family/license metadata is shown as unknown rather than inferred.
- The production webpage adapter accepts HTTPS input URLs. Its shared HTTP(S) transport rejects
  non-public destinations before requests and redirects,
  and enforces its response-body limit while streaming rather than after buffering an arbitrary body.
  URLSession does not expose the peer IP or let the app pin a pre-resolved address while retaining normal
  TLS hostname validation, so a DNS rebinding race between validation and CFNetwork's connection remains a
  platform-level residual risk. Eliminating it would require a separately audited, IP-pinned HTTP/TLS
  transport rather than URLSession; the project does not claim that stronger guarantee.

## Developer configuration and DEBUG artifacts

`scripts/setup-openai-config.sh` writes `~/.mobilellm/openai.json` outside the repository with mode
`600`. The DEBUG app build phase copies this configuration into the built app, and the device-test
build phase copies it into the test bundle. macOS DEBUG launches prefer the home file; DEBUG launches
can fall back to the embedded configuration, with launch-environment overrides taking precedence.
A complete configuration seeds Keychain and automatically enables the developer's online service.
Release app builds do not embed the file. Do not publish a DEBUG app, test bundle, or build artifact
that contains it. The ordinary AgentRuntime test suite also makes real online requests when this
file is present unless `LiveOnlineProviderSmokeTests` is explicitly skipped.

## Data deletion and current integration limits

The app-level erase coordinator writes `<conversation-directory>.erase-pending` before deletion. It
blocks new actions, drains producers, suspends the outbox, and removes runtime journals, workflows,
artifacts, chats, and attachments. Full app erase also removes downloaded models, Memory, custom
Skills, online credentials, MCP credentials/discovery, and settings. The marker remains after failure,
and bootstrap completes pending erasure before opening stores. This coordinates logical deletion;
physical flash erasure is not a product guarantee.

Static review on 2026-10-22 identified an open Memory integration gap: the production snapshot forwards
cached canonical facts without applying the Memory switch, query ranking, or the legacy path's refresh
before each send. A saved fact can therefore enter model context even when the Memory UI is off,
including context sent to a selected online provider. See [Current status](docs/STATUS.md#open-implementation-items)
and spec §33 for the source trace and required regression scenarios. The existing legacy-path Memory
tests do not establish the production-path guarantee.

## Supported versions

This is a pre-1.0 project under active development; fixes land on `main`. Please test against the latest
`main` before reporting.
