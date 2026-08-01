#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

section="${1:-models}"
case "$section" in
  chat|models|settings) ;;
  *)
    echo "usage: $0 [chat|models|settings] [output.png]" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_path="${2:-/private/tmp/mobilellm-${section}-$(date +%s).png}"
if [[ "$output_path" != /* ]]; then
  output_path="$PWD/$output_path"
fi

derived_data="${MOBILELLM_SCREENSHOT_DERIVED_DATA:-/private/tmp/mobilellm-screenshot-derived}"
run_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/mobilellm-screenshot.XXXXXX")"
capture_path="$run_dir/window.png"
error_path="$run_dir/capture.error.txt"
app_log="$run_dir/app.log"
build_log="$run_dir/build.log"
app_pid=""
publish_tmp=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -n "$publish_tmp" ]]; then
    rm -f -- "$publish_tmp"
  fi
  rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

cd "$repo_root"
if ! xcodegen generate >"$build_log" 2>&1; then
  tail -80 "$build_log" >&2
  exit 1
fi
if ! xcodebuild \
    -project mobileLLM.xcodeproj \
    -scheme mobileLLM \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build >>"$build_log" 2>&1; then
  tail -120 "$build_log" >&2
  exit 1
fi

app_binary="$derived_data/Build/Products/Debug/mobileLLM.app/Contents/MacOS/mobileLLM"
if [[ ! -x "$app_binary" ]]; then
  echo "built app executable not found: $app_binary" >&2
  exit 1
fi

mkdir -p "$run_dir/home"
env \
  CFFIXED_USER_HOME="$run_dir/home" \
  MOBILELLM_MAC_SCREENSHOT_PATH="$capture_path" \
  MOBILELLM_MAC_SCREENSHOT_ERROR_PATH="$error_path" \
  MOBILELLM_MAC_SCREENSHOT_SECTION="$section" \
  MOBILELLM_MAC_SCREENSHOT_APPEARANCE="${MOBILELLM_MAC_SCREENSHOT_APPEARANCE:-light}" \
  "$app_binary" >"$app_log" 2>&1 &
app_pid=$!

for _ in $(seq 1 300); do
  if [[ -s "$capture_path" ]]; then
    output_dir="$(dirname "$output_path")"
    output_name="$(basename "$output_path")"
    mkdir -p "$output_dir"
    # Publish on the destination filesystem: observers see either the previous complete PNG or the new
    # complete PNG, never a partially copied file.
    publish_tmp="$(mktemp "$output_dir/.${output_name}.XXXXXX")"
    cp "$capture_path" "$publish_tmp"
    mv -f "$publish_tmp" "$output_path"
    publish_tmp=""
    echo "$output_path"
    exit 0
  fi
  if [[ -s "$error_path" ]]; then
    cat "$error_path" >&2
    exit 1
  fi
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "mobileLLM exited before producing a screenshot" >&2
    tail -80 "$app_log" >&2
    exit 1
  fi
  sleep 0.1
done

echo "timed out waiting for the in-process macOS window capture" >&2
tail -80 "$app_log" >&2
exit 1
