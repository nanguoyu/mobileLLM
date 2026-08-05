#!/bin/bash
# One-time per-build preparation for simulator/device UI tests: reads the OpenAI-compatible service
# config from ~/.mobilellm/openai.json (OUTSIDE the repository, never committed) and injects it into
# the xctestrun produced by `xcodebuild build-for-testing`. On-device UI test bundles run on the phone,
# so they cannot read the Mac file themselves; this is the seam that forwards the same config the
# macOS DEBUG app reads directly.
#
# Usage:
#   xcodebuild ... build-for-testing -derivedDataPath "$DD"
#   scripts/prepare-device-e2e-xctestrun.sh "$DD/Build/Products/DeviceE2E_*.xctestrun" \
#       /tmp/mobilellm-device-e2e.xctestrun
#   xcodebuild ... test-without-building -xctestrun /tmp/mobilellm-device-e2e.xctestrun ...
set -euo pipefail

src="${1:?path to the built .xctestrun}"
dst="${2:?output .xctestrun path}"

file="$HOME/.mobilellm/openai.json"
if [[ ! -r "$file" ]]; then
  echo "error: $file is missing; run scripts/setup-openai-config.sh" >&2
  exit 1
fi

# Python does the read + plist patch so the key is never echoed to a terminal or a shell variable.
python3 - "$src" "$dst" "$file" <<'PY'
import json
import os
import plistlib
import sys

src, dst, config_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

key = os.environ.get("MOBILELLM_OPENAI_API_KEY", "").strip() or str(config.get("apiKey", "")).strip()
base_url = os.environ.get("MOBILELLM_OPENAI_BASE_URL", "").strip() or str(config.get("baseURL", "")).strip()
model = os.environ.get("MOBILELLM_OPENAI_MODEL", "").strip() or str(config.get("model", "") or "").strip()

if not key:
    print("error: no API key in config", file=sys.stderr)
    sys.exit(1)
if not base_url.startswith("https://"):
    print("error: baseURL must be https", file=sys.stderr)
    sys.exit(1)

with open(src, "rb") as f:
    run = plistlib.load(f)

injected = {
    "MOBILELLM_OPENAI_API_KEY": key,
    "MOBILELLM_OPENAI_BASE_URL": base_url,
    "MOBILELLM_OPENAI_MODEL": model,
}

targets = [
    target
    for config in run.get("TestConfigurations", [])
    for target in config.get("TestTargets", [])
]
if not targets:
    print("error: no TestTargets in xctestrun", file=sys.stderr)
    sys.exit(1)

for target in targets:
    # Test bundle process only. DeviceE2ETestSupport reads these and forwards them into the app's
    # launchEnvironment itself, so the key never rides a second xctestrun channel and the app's normal
    # DEBUG seeding path stays the single consumer.
    target_env = target.setdefault("EnvironmentVariables", {})
    target_env.update(injected)

with open(dst, "wb") as f:
    plistlib.dump(run, f, sort_keys=False)

print("patched %s -> %s (model=%s)" % (src, dst, model))
PY
