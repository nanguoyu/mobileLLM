#!/bin/bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  reset-agent-test-container.sh --platform simulator --udid <simulator-udid> --bundle-id <bundle-id>
  reset-agent-test-container.sh --platform device    --udid <device-udid>    --bundle-id <bundle-id>

Uninstalls exactly one app so the next test starts with a clean app container.
There are no inferred devices, default bundle identifiers, globs, or direct filesystem deletions.
USAGE
}

fail() {
    echo "reset-agent-test-container: $*" >&2
    exit 2
}

platform=""
device_udid=""
bundle_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            [[ $# -ge 2 ]] || fail "--platform requires simulator or device"
            platform="$2"
            shift 2
            ;;
        --udid)
            [[ $# -ge 2 ]] || fail "--udid requires an explicit device identifier"
            device_udid="$2"
            shift 2
            ;;
        --bundle-id)
            [[ $# -ge 2 ]] || fail "--bundle-id requires an exact bundle identifier"
            bundle_id="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ "$platform" == "simulator" || "$platform" == "device" ]] \
    || fail "--platform must be exactly simulator or device"
[[ -n "$device_udid" ]] || fail "--udid is required; refusing to infer a target"
[[ -n "$bundle_id" ]] || fail "--bundle-id is required; refusing to infer an app"

# Accept a CoreDevice UUID, a modern iOS UDID, or a legacy 40-hex UDID. Names, ECIDs,
# serial numbers, shell expansions, and broad aliases such as "booted" are intentionally rejected.
if [[ ! "$device_udid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ \
      && ! "$device_udid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{16}$ \
      && ! "$device_udid" =~ ^[[:xdigit:]]{40}$ ]]; then
    fail "--udid is not an explicit simulator/device UDID: $device_udid"
fi

# Bundle identifiers are passed as a single exact argument. Reject wildcard/path syntax and
# Apple-owned identifiers so this test helper cannot be widened into a general deletion utility.
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    fail "--bundle-id is not an exact reverse-DNS bundle identifier: $bundle_id"
fi
[[ "$bundle_id" != com.apple.* ]] || fail "refusing to uninstall an Apple-owned bundle identifier"

if [[ "$platform" == "simulator" ]]; then
    # bootstatus proves that the exact simulator exists and is usable. A failed container lookup
    # after that means the exact app is already absent, which is a successful idempotent reset.
    xcrun simctl bootstatus "$device_udid" -b >/dev/null
    if ! xcrun simctl get_app_container "$device_udid" "$bundle_id" app >/dev/null 2>&1; then
        echo "Already reset: $bundle_id is not installed on simulator $device_udid"
        exit 0
    fi
    xcrun simctl uninstall "$device_udid" "$bundle_id"
else
    # devicectl's JSON file is its only supported scripting interface. Inspect the exact bundle-id
    # result before uninstalling; the only removed application data is what devicectl owns for that app.
    device_info_json="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/mobileLLM-device-apps.XXXXXX")"
    cleanup() {
        /bin/rm -f -- "$device_info_json"
    }
    trap cleanup EXIT

    xcrun devicectl device info apps \
        --device "$device_udid" \
        --bundle-id "$bundle_id" \
        --json-output "$device_info_json" \
        --quiet

    apps_json="$(/usr/bin/plutil -extract result.apps json -o - "$device_info_json")" \
        || fail "devicectl returned no result.apps array"
    if [[ "$apps_json" == "[]" ]]; then
        echo "Already reset: $bundle_id is not installed on device $device_udid"
        exit 0
    fi
    # Search only the extracted apps array. Quoting the value makes this an exact JSON string match
    # while remaining independent of plutil's whitespace/pretty-print choices.
    if ! /usr/bin/grep -Fq "\"$bundle_id\"" <<<"$apps_json"; then
        fail "devicectl did not return the exact requested bundle identifier"
    fi

    xcrun devicectl device uninstall app \
        --device "$device_udid" \
        --timeout 60 \
        "$bundle_id"
fi

echo "Reset complete: uninstalled $bundle_id from $platform $device_udid"
