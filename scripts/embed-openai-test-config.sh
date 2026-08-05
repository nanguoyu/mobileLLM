#!/bin/bash
# Build phase for the device/simulator UI test target: embeds the OpenAI-compatible service config
# (~/.mobilellm/openai.json, OUTSIDE the repository) into the built .xctest bundle so the on-device
# test process can read it and forward it through XCUIApplication.launchEnvironment.
#
# The key ends up only in DerivedData build products — never in Git, never in the app's own bundle.
# Environment variables win over the file so one-off runs can override without editing it.
set -euo pipefail

source_file="$HOME/.mobilellm/openai.json"
if [[ ! -r "$source_file" ]]; then
  echo "warning: $source_file is missing; online-model UI tests will report the key as missing"
  exit 0
fi

target_dir="${TARGET_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-}}"
wrapper="${WRAPPER_NAME:-}"
if [[ -z "$target_dir" || -z "$wrapper" ]]; then
  echo "error: embed-openai-test-config.sh must run as an Xcode build phase" >&2
  exit 1
fi

python3 - "$source_file" "$target_dir/$wrapper/openai-config.json" <<'PY'
import json
import os
import sys

source, destination = sys.argv[1], sys.argv[2]
with open(source, "r", encoding="utf-8") as f:
    config = json.load(f)

key = os.environ.get("MOBILELLM_OPENAI_API_KEY", "").strip() or str(config.get("apiKey", "")).strip()
base_url = os.environ.get("MOBILELLM_OPENAI_BASE_URL", "").strip() or str(config.get("baseURL", "")).strip()
model = os.environ.get("MOBILELLM_OPENAI_MODEL", "").strip() or str(config.get("model", "") or "").strip()

os.makedirs(os.path.dirname(destination), exist_ok=True)
with open(destination, "w", encoding="utf-8") as f:
    json.dump({"apiKey": key, "baseURL": base_url, "model": model}, f)
print("embedded OpenAI test config")
PY
