# OpenSandbox execution

mobileLLM can use a configured OpenSandbox service for project files, commands, application servers,
browser interactions and source archives. The agents still plan, delegate, review and revise through
mobileLLM's production runtime. The separate on-device iOS sandbox project is not required.

The app is a client. Code executes in a Linux container on the OpenSandbox host. On iOS Simulator,
the development endpoint can be the Mac's loopback address. A physical phone needs an explicitly
configured reachable HTTPS deployment; the local setup below does not expose its ports to the LAN.

## Local setup

Prerequisites are an existing Docker runtime, Python and uv. On the development Mac the script reuses
OrbStack and its CLI plugin. It does not install Homebrew packages, a second VM, global Python/npm
packages, a launch agent or a shell configuration.

From the repository root:

    python3 scripts/opensandbox-dev.py up
    python3 scripts/opensandbox-dev.py status

The default directory is /private/tmp/mobilellm-opensandbox-dev. Use --root with another dedicated
temporary directory named mobilellm-opensandbox-* when needed. The first setup downloads several
gigabytes of container layers. Python packages, download caches, configuration, credentials, logs and
SQLite state stay under that directory. Docker image and build-cache identities are tracked in its
ownership record. Never commit or share client.json, server.toml or gateway.json.

The script prints the loopback gateway endpoint and private client-config path. In mobileLLM open
**Settings → Tools → Execution environment**, enter the endpoint and the API key from that file, and
choose **Check and connect**. Credentials go to Keychain. Enabling the environment affects new chats;
apply the current tool selection explicitly for an existing chat.

Choose **Work with agents** or /workflow for a team goal. Full Access allows authorized sandbox work
to proceed autonomously inside the conversation's frozen ceiling. Safe preset and Ask retain their
operation approvals. Configuring an environment does not silently change approval mode.

Use up --rebuild after changing the guest image. It closes this setup's old workspaces, retains its
previous gateway state, and rotates the environment identity and credentials. Reconnect in Settings.
An old goal cannot silently switch to the new environment.

## Tools and delivery

| Tool | Actual operation |
| --- | --- |
| sandbox_write_files / read_file / list_files | Goal-scoped file access; replacements check the original SHA-256 |
| sandbox_run | Bounded bash execution with errexit, pipefail, stdout, stderr and exit status |
| sandbox_start / process / stop | HTTP readiness check and durable service process identity |
| sandbox_browser | Chromium/Playwright assertions, page text, controls, bounded script output and a screenshot |
| sandbox_export | Immutable ZIP of current source, excluding dependencies, build caches and internal logs |

Node 24 LTS, Python, Python's SQLite library and Playwright are present in the guest. Runtime data
belongs in MOBILELLM_DATA_DIR, outside /workspace/project. Files persist within a goal. Workers must
coordinate file ownership; the gateway serializes commands in one workspace and isolates separate goals.

A known failed test retains diagnostics and permits correction within the original budget. Repeating
an unchanged command remains guarded; an observed source change permits a fresh test. A network
disconnect does not replay a command whose submission outcome is uncertain.

Executable delivery needs real tool receipts from the latest source version and independent acceptance
of the current task artifacts. A running application needs service startup and a browser check on the
same source and port. Reviewers reuse original successful evidence for unchanged source. Export the
final source once. Task details show verified screenshots and **Save project source**. These checks establish what ran; task-specific external assertions still determine whether
the result is correct.

## Limits of this development deployment

- At most two goal workspaces, each with 2 CPU, 2 GiB memory and a one-hour lifetime.
- Guest process limit 256; commands up to 120 seconds; service commands up to 30 minutes.
- No host mounts, Docker socket or model-provider keys enter the guest.
- Guest egress defaults to deny, with package access to npm and PyPI hosts. This is separate from
  mobileLLM's configured web-search tools.
- Lifecycle, gateway and published guest ports bind to loopback. The gateway requires its key and
  exact environment identity. OpenSandbox Docker does not support secureAccess; it is not enabled.
- Export limit 512 KiB compressed; text reads and source snapshots are bounded. This is a small-project
  development environment, not a production hosting service or a general desktop VM.
- Stop closes that goal's recorded workspace. Data erase closes this app's recorded scopes. Removing
  credentials or losing the server can prevent immediate cleanup; server lifetime limits remain.
- Checkpoint migration, on-device execution and public website publication are not supplied.

## Tests and cleanup

The opt-in native provider test uses MOBILELLM_LIVE_SANDBOX_CONFIG pointing at client.json. The app's
SandboxWorkflowLiveTests also requires MOBILELLM_LIVE_WORKFLOWS=1 and a configured online model.
Select the affected task, keep failed attempts, and do not run paid models for document changes.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the existing Simulator test scheme.

Save needed source artifacts and compact evaluation results, then:

    python3 scripts/opensandbox-dev.py down
    python3 scripts/opensandbox-dev.py down --remove-directory

Pass the same --root when using a custom location. Cleanup deletes only recorded task-owned
containers, volumes, image references and exact build-cache IDs. It preserves the initial Docker
inventory and restores OrbStack's prior stopped state when no new foreign container needs it.
It reports resources it could not safely remove. It never runs a global Docker prune.

## Dependency references

The gateway pins the [OpenSandbox 1.1.1 release](https://github.com/alibaba/OpenSandbox/releases/tag/release-1.1.1)
and official execd/egress image digests from that release's component manifest. The guest pins
[Playwright's official image](https://playwright.dev/python/docs/docker) by digest and verifies the
[Node 24.22.1](https://nodejs.org/dist/v24.22.1/SHASUMS256.txt) architecture-specific download checksum.
Python package pins are in Tools/OpenSandboxGateway/requirements.txt; deployment limits are in the
setup script and gateway.
