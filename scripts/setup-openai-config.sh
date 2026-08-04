#!/bin/zsh
# One-time local setup for an OpenAI-compatible service. Writes ~/.mobilellm/openai.json
# (chmod 600) — OUTSIDE the repository — so macOS unit/UI tests, simulator tests, and physical-device
# tests can all pick up the same key/base URL/model without anything secret ever being committed.
#
# Usage: scripts/setup-openai-config.sh
#        (optionally: OPENAI_API_KEY=... OPENAI_BASE_URL=... OPENAI_MODEL=... scripts/setup-openai-config.sh)
set -euo pipefail

dir="$HOME/.mobilellm"
file="$dir/openai.json"
mkdir -p "$dir"
chmod 700 "$dir"

api_key="${OPENAI_API_KEY:-}"
base_url="${OPENAI_BASE_URL:-}"
model="${OPENAI_MODEL:-}"

if [[ -z "$api_key" ]]; then
  read -r -s -p "OpenAI-compatible API key: " api_key; echo
fi
if [[ -z "$base_url" ]]; then
  read -r -p "Base URL [https://api.openai.com/v1]: " base_url
  base_url="${base_url:-https://api.openai.com/v1}"
fi
if [[ -z "$model" ]]; then
  read -r -p "Model id (optional, e.g. gpt-4o-mini): " model
fi

if [[ -z "$api_key" ]]; then
  echo "error: an API key is required" >&2
  exit 1
fi

cat > "$file" <<EOF
{
  "apiKey": "$api_key",
  "baseURL": "$base_url",
  "model": "$model"
}
EOF
chmod 600 "$file"
echo "Wrote $file (chmod 600). It is outside the repository and never committed."
