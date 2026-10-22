#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
test_root="${MOBILELLM_TEST_OUTPUT:-}"
if [[ -z "$test_root" ]]; then test_root="$(mktemp -d "${TMPDIR:-/tmp}/mobilellm-behavior.XXXXXX")"; fi
mkdir -p "$test_root"
build_cache="${MOBILELLM_BUILD_CACHE:-$repo_root/.build/verification}"
mkdir -p "$build_cache"
scope="$test_root/check-scope.json"
python3 "$repo_root/scripts/verification/changed-checks.py" "$@" > "$scope"
while IFS= read -r package; do
    if [[ "$package" == AgentHarnessVerification ]]; then
        package_path="$repo_root/Tools/$package"
    else
        package_path="$repo_root/Packages/$package"
    fi
    swift test --package-path "$package_path" --scratch-path "$build_cache" \
        --skip LiveOnlineProviderSmokeTests 2>&1 | tee "$test_root/$package.log"
done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["packages"]))' "$scope" | sed '/^$/d')
if [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["static"])' "$scope")" == True ]]; then
    swift run --package-path "$repo_root/Tools/AgentHarnessVerification" --scratch-path "$build_cache" \
        agent-harness-verify static --repo-root "$repo_root"
fi
cat "$scope"
echo "Selected-check logs: $test_root (use --all for the full package baseline)"
