#!/bin/bash
# Append a single ephemeral Q&A pair to the workflow history file.
#
# Called from `ephemeral.sh` once a stream completes. Storage format is
# JSON lines (one record per line) at:
#
#   $alfred_workflow_data/ephemeral-history.jsonl
#
# Each record looks like:
#
#   {"ts": 1700000000, "query": "...", "response": "..."}
#
# Usage:
#   history-record.sh <query> <response_file>
#
# Honoured environment variables:
#   history_enabled       — "0"/"false"/"no"/"off" disables recording.
#   history_max_entries   — integer; when >0, file is trimmed to last N lines.
#   alfred_workflow_data  — Alfred's persistent data dir for this workflow.

set -uo pipefail

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

case "${history_enabled:-1}" in
  0|false|no|off) exit 0 ;;
esac

query="${1:-}"
response_file="${2:-}"

if [[ -z "$query" || -z "$response_file" || ! -f "$response_file" ]]; then
  exit 0
fi

response="$(cat "$response_file")"

# Skip empty / placeholder responses so the history doesn't get polluted.
trimmed="${response//[$'\t\r\n ']/}"
if [[ -z "$trimmed" ]]; then
  exit 0
fi
case "$response" in
  "[No response]"|"…") exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  # No jq, no structured logging — fail silently so we never break the UX.
  exit 0
fi

data_dir="${alfred_workflow_data:-/tmp/alfred-chatgpt-data}"
mkdir -p "$data_dir"

file="$data_dir/ephemeral-history.jsonl"
ts="$(date +%s)"

jq -nc \
  --arg q "$query" \
  --arg r "$response" \
  --argjson t "$ts" \
  '{ts: $t, query: $q, response: $r}' >> "$file"

# Trim to the most recent N entries so the file doesn't grow unbounded.
max="${history_max_entries:-200}"
if [[ "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
  lines="$(wc -l < "$file" | tr -d ' ')"
  if (( lines > max )); then
    tmp="$file.tmp.$$"
    if tail -n "$max" "$file" > "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
    fi
  fi
fi
