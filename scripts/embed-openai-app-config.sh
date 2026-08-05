#!/bin/bash
# DEBUG-only build phase for the app target: embeds ~/.mobilellm/openai.json into the compiled app
# bundle so a phone app launched BY HAND (no test-launch environment) still seeds the right base URL,
# model id, and Keychain key at startup.
#
# Security rules:
#   * Release builds embed nothing (this script exits immediately).
#   * The key only ever lands in the built app bundle inside DerivedData — never in Git.
#   * Nothing sensitive is printed; the file is read by Python and only presence is echoed.
set -euo pipefail

if [[ "${CONFIGURATION:-}" != "Debug" ]]; then
  exit 0
fi

source_file="$HOME/.mobilellm/openai.json"
if [[ ! -r "$source_file" ]]; then
  echo "warning: $source_file is missing; the online service will not be embedded"
  exit 0
fi

target_dir="${TARGET_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-}}"
resources_dir="${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
if [[ -z "$target_dir" || -z "$resources_dir" ]]; then
  echo "error: embed-openai-app-config.sh must run as an Xcode build phase" >&2
  exit 1
fi

python3 - "$source_file" "$target_dir/$resources_dir/openai-config.json" <<'PY'
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
print("embedded OpenAI app config")
PY
