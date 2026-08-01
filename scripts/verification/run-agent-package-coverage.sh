#!/bin/bash
# SPDX-License-Identifier: MIT
# Agent Harness SwiftPM coverage evidence runner, format version 1.

set -euo pipefail

usage() {
    /bin/cat <<'USAGE'
Usage:
  run-agent-package-coverage.sh \
    --package AgentContracts|AgentSandboxAPI|AgentRuntime \
    --base-ref <git-commit-or-ref> \
    --output-dir <directory>

Runs the exact package test suite with coverage and structured xUnit output, exports the raw LLVM
coverage JSON, compares changed executable lines/functions from BASE through the staged and working
tree state, and writes coverage-report.v1.json.
An absent package, missing/empty result, failed/error/skipped test, malformed coverage export, or failed
coverage gate exits nonzero. Future package names are rejected until their evidence policy is versioned.
USAGE
}

fail() {
    echo "run-agent-package-coverage: $*" >&2
    exit 2
}

package_name=""
base_ref=""
output_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package)
            [[ $# -ge 2 ]] || fail "--package requires a value"
            package_name="$2"
            shift 2
            ;;
        --base-ref)
            [[ $# -ge 2 ]] || fail "--base-ref requires a value"
            base_ref="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail "--output-dir requires a value"
            output_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

[[ -n "$package_name" ]] || fail "--package is required"
[[ -n "$base_ref" ]] || fail "--base-ref is required"
[[ -n "$output_dir" ]] || fail "--output-dir is required"

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
package_dir="$repo_root/Packages/$package_name"
source_root="Packages/$package_name/Sources/$package_name"

case "$package_name" in
    AgentContracts)
        critical_sources=(
            "$source_root/ArtifactsAndFailures.swift"
            "$source_root/Authority.swift"
            "$source_root/Budgets.swift"
            "$source_root/ContractPrimitives.swift"
            "$source_root/ExternalOperations.swift"
            "$source_root/ToolContracts.swift"
            "$source_root/WireValidation.swift"
        )
        ;;
    AgentSandboxAPI)
        # The experimental public API is itself the security boundary; all of it is critical.
        critical_sources=("$source_root")
        ;;
    AgentRuntime)
        # Refine this list only when a versioned component inventory lands. Until then the conservative
        # choice is to hold every production runtime function to the critical-source gate.
        critical_sources=("$source_root")
        ;;
    *) fail "unsupported package '$package_name'; refusing to invent an evidence policy" ;;
esac

[[ -f "$package_dir/Package.swift" ]] \
    || fail "required package is absent: Packages/$package_name/Package.swift"
[[ -d "$repo_root/$source_root" ]] \
    || fail "required production source root is absent: $source_root"
[[ -d "$package_dir/Tests/${package_name}Tests" ]] \
    || fail "required test target is absent: Packages/$package_name/Tests/${package_name}Tests"
git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 \
    || fail "--base-ref does not resolve to a commit: $base_ref"
comparison_base="$(git -C "$repo_root" merge-base "$base_ref" HEAD)" \
    || fail "--base-ref and HEAD have no merge base: $base_ref"
[[ -n "$comparison_base" ]] \
    || fail "git returned an empty merge base for: $base_ref"

untracked_swift_sources=()
while IFS= read -r -d '' candidate; do
    if [[ "$candidate" == *.swift ]]; then
        untracked_swift_sources+=("$candidate")
    fi
done < <(git -C "$repo_root" ls-files --others --exclude-standard -z -- "$source_root")
if [[ ${#untracked_swift_sources[@]} -gt 0 ]]; then
    fail "untracked Swift production source must be staged before coverage collection: ${untracked_swift_sources[0]}"
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
scratch_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mobilellm-agent-coverage.XXXXXX")"
cleanup() {
    /bin/rm -rf -- "$scratch_root"
}
trap cleanup EXIT

scratch_path="$scratch_root/swiftpm"
xunit_path="$output_dir/tests.xunit.xml"
test_log="$output_dir/swift-test.log"
raw_coverage="$output_dir/llvm-cov-export.json"
changed_diff="$output_dir/changed-lines.diff"
report_path="$output_dir/coverage-report.v1.json"

git -C "$repo_root" -c core.quotePath=false diff \
    --unified=0 --no-color --no-ext-diff "$comparison_base" -- "$source_root" \
    >"$changed_diff"

coverage_arguments=(
    coverage
    --repo-root "$repo_root"
    --scope "$package_name"
    --source-root "$source_root"
    --llvm-cov "$raw_coverage"
    --xunit "$xunit_path"
    --changed-diff "$changed_diff"
    --report-schema "$repo_root/Verification/AgentHarness/Schemas/coverage-report.schema.json"
    --output "$report_path"
)
for critical_source in "${critical_sources[@]}"; do
    coverage_arguments+=(--critical-source "$critical_source")
done

# A reused output directory must never let stale evidence make a failed collection appear valid.
/bin/rm -f -- "$xunit_path" "$test_log" "$raw_coverage" \
    "$output_dir/default.profdata" "$report_path"

write_report() {
    swift run --package-path "$repo_root/Tools/AgentHarnessVerification" \
        agent-harness-verify "${coverage_arguments[@]}"
}

# SwiftPM 6.2 emits XCTest xUnit only through its parallel runner. One worker preserves deterministic
# serialization while still producing structured per-test evidence; each discovered test runs once.
set +e
swift test \
    --package-path "$package_dir" \
    --scratch-path "$scratch_path" \
    --enable-code-coverage \
    --enable-xctest \
    --disable-swift-testing \
    --parallel \
    --num-workers 1 \
    --xunit-output "$xunit_path" \
    2>&1 | /usr/bin/tee "$test_log"
test_status=${PIPESTATUS[0]}
set -e
if [[ $test_status -ne 0 ]]; then
    write_report || true
    exit "$test_status"
fi

bin_path="$(swift build \
    --package-path "$package_dir" \
    --scratch-path "$scratch_path" \
    --show-bin-path)"
profile_path="$bin_path/codecov/default.profdata"
[[ -s "$profile_path" ]] || {
    write_report || true
    fail "SwiftPM produced no nonempty instrumentation profile: $profile_path"
}
test_binary="$bin_path/${package_name}PackageTests.xctest/Contents/MacOS/${package_name}PackageTests"
[[ -x "$test_binary" ]] || {
    write_report || true
    fail "SwiftPM test executable is missing: $test_binary"
}

if ! xcrun llvm-cov export \
    "$test_binary" \
    -instr-profile="$profile_path" \
    -format=text \
    >"$raw_coverage"; then
    write_report || true
    fail "llvm-cov export failed"
fi
[[ -s "$raw_coverage" ]] || {
    write_report || true
    fail "llvm-cov export produced empty evidence"
}

/bin/cp "$profile_path" "$output_dir/default.profdata"
write_report
echo "Agent package coverage evidence: $report_path"
