#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
state_root=${SYMPHONY_QUANT_STATE_ROOT:-"$HOME/.local/share/symphony-quant"}
workflow_path=${LOOPHONY_WORKFLOW_PATH:-"$script_dir/WORKFLOW.md"}

export SYMPHONY_QUANT_WORKSPACE_ROOT=${SYMPHONY_QUANT_WORKSPACE_ROOT:-"$state_root/workspaces"}
export SYMPHONY_LOOP_DB_PATH=${SYMPHONY_LOOP_DB_PATH:-"$state_root/loop/symphony-loop.sqlite3"}

load_keychain_secret() {
  variable_name=$1
  account=$2
  current_value=$(printenv "$variable_name" 2>/dev/null || true)

  if [ -z "$current_value" ] && command -v security >/dev/null 2>&1; then
    current_value=$(security find-generic-password -s symphony-quant -a "$account" -w 2>/dev/null || true)
  fi

  if [ -n "$current_value" ]; then
    export "$variable_name=$current_value"
  fi
}

load_keychain_secret LINEAR_API_KEY linear-api-token
load_keychain_secret APCA_API_KEY_ID alpaca-api-key-id
load_keychain_secret APCA_API_SECRET_KEY alpaca-api-secret-key

: "${LINEAR_API_KEY:?Store Linear auth in Keychain account linear-api-token or export LINEAR_API_KEY}"
: "${QUANT_RESEARCH_REPO_URL:?Set QUANT_RESEARCH_REPO_URL to the research repository clone URL}"

if [ ! -f "$workflow_path" ]; then
  echo "Loophony workflow not found: $workflow_path" >&2
  exit 1
fi

mkdir -p "$state_root/logs" "$state_root/loop" "$SYMPHONY_QUANT_WORKSPACE_ROOT"

cd "$repo_root/elixir"

if ! command -v mise >/dev/null 2>&1; then
  echo "mise is required; install it and run: mise trust && mise install" >&2
  exit 1
fi

if [ ! -x ./bin/symphony ]; then
  mise trust
  mise exec -- mix setup
  mise exec -- mix build
fi

exec mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$state_root/logs" \
  "$workflow_path"
