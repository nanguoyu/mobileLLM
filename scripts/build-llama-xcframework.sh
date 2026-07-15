#!/usr/bin/env bash
# Build the llama.cpp XCFramework that Packages/LLMEngineLlama vendors.
#
# The framework is NOT committed (~355 MB). This script clones mainline llama.cpp at a pinned commit,
# builds the official XCFramework (Metal embedded — no .metallib to ship), trims it to the iOS + macOS
# slices, and drops it at Packages/LLMEngineLlama/Vendor/llama.xcframework. Re-run after a fresh clone.
#
#   ./scripts/build-llama-xcframework.sh
#
# Requirements: Xcode + CMake. Takes ~15–25 min (a full multi-platform llama.cpp build).
set -euo pipefail

# Mainline ggml-org/llama.cpp — this commit has Q1_0 (1-bit) + the qwen3_5 hybrid (Gated-DeltaNet)
# kernels on Metal, so ONE framework serves every Bonsai size incl. the 27B.
LLAMA_COMMIT="956973c76466b6c791d7bdbe6eed3aa3235b2dc1"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/LLMEngineLlama/Vendor/llama.xcframework"
WORK="${LLAMA_CPP_DIR:-$ROOT/.llama-build}"

if [ ! -d "$WORK/.git" ]; then
    echo "Cloning llama.cpp into $WORK …"
    git clone https://github.com/ggml-org/llama.cpp "$WORK"
fi
git -C "$WORK" fetch --depth 1 origin "$LLAMA_COMMIT"
git -C "$WORK" checkout "$LLAMA_COMMIT"

echo "Building XCFramework (this is the slow part) …"
( cd "$WORK" && ./build-xcframework.sh )

echo "Trimming to iOS + macOS slices …"
BUILT="$WORK/build-apple/llama.xcframework"
rm -rf "$BUILT"/tvos-* "$BUILT"/xros-*
python3 - "$BUILT/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: d = plistlib.load(f)
keep = {"ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"}
d["AvailableLibraries"] = [l for l in d["AvailableLibraries"] if l["LibraryIdentifier"] in keep]
with open(p, "wb") as f: plistlib.dump(d, f)
PY

echo "Installing to $DEST …"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$BUILT" "$DEST"
echo "Done. $(du -sh "$DEST" | cut -f1) at $DEST"
