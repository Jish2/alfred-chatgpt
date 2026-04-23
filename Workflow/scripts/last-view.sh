#!/bin/bash
# Text View input for "open the last ephemeral chat".
#
# Reads the newest entry from `$alfred_workflow_data/ephemeral-history.jsonl`
# (appended by `history-record.sh`) and renders it as a Q&A markdown body in
# Alfred's Text View. No argument is taken from the upstream keyword — this is
# strictly a "show me the last one" shortcut.

set -uo pipefail

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

data_dir="${alfred_workflow_data:-/tmp/alfred-chatgpt-data}"
file="$data_dir/ephemeral-history.jsonl"

footer="Last ephemeral · ⌘C Copy · Esc Close"

empty_body="# No ephemeral chats yet

Ask something with the ephemeral keyword to populate this view."

if ! command -v jq >/dev/null 2>&1; then
  body="# jq is required

Install jq (e.g. \`brew install jq\`) and try again."
elif [[ ! -s "$file" ]]; then
  body="$empty_body"
else
  # `tail -n 1` is the most recent record (history-record.sh appends).
  last_line="$(tail -n 1 "$file" 2>/dev/null)"
  body="$(jq -r '
    "# You\n\n" + (.query // "" | tostring)
    + "\n\n# Assistant\n\n" + (.response // "" | tostring)
  ' <<<"$last_line" 2>/dev/null)"
  if [[ -z "$body" ]]; then
    body="$empty_body"
  fi
fi

jq -nc \
  --arg resp "$body" \
  --arg foot "$footer" \
  '{response: $resp, footer: $foot, behaviour: {scroll: "start"}}'
