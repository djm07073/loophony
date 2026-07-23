#!/bin/bash
set -u

lock_dir="/tmp/loophony-codex-continuity.lock"
log_dir="/Users/leojin/.local/share/loophony/logs"
prompt_file="/Users/leojin/dev/agents/loophony/plugins/loophony/prompts/continuity_maintenance.md"
codex_bin="/Applications/Codex.app/Contents/Resources/codex"

mkdir -p "$log_dir"
if ! mkdir "$lock_dir" 2>/dev/null; then
  printf '%s skipped: previous continuity task still running\n' "$(date -u +%FT%TZ)" >> "$log_dir/codex-continuity.stdout.log"
  exit 0
fi
trap 'rmdir "$lock_dir"' EXIT

"$codex_bin" exec \
  --cd /Users/leojin/dev/agents/loophony \
  --add-dir /Users/leojin/.local/share/loophony \
  --sandbox danger-full-access \
  --config 'approval_policy="never"' \
  "$(<"$prompt_file")"
