#!/bin/bash
# Text View input for the ephemeral history viewer.
#
# Receives the pre-rendered markdown body of a saved Q&A pair as `$1`
# (Alfred's `{query}`, set from the Script Filter's `arg` field by
# `history-filter.sh`) and emits the Text View JSON frame.

set -uo pipefail

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

body="${1:-}"

if [[ -z "$body" ]]; then
  body="# No entry selected

Open the history list and pick a saved answer."
fi

footer="Ephemeral history · ⌘C Copy · Esc Close"

jq -nc \
  --arg resp "$body" \
  --arg foot "$footer" \
  '{response: $resp, footer: $foot, behaviour: {scroll: "start"}}'
