#!/bin/bash
# Alfred Script Filter for the ephemeral chat history.
#
# Reads `$alfred_workflow_data/ephemeral-history.jsonl` (newest entry last,
# as written by `history-record.sh`) and emits Alfred items in reverse order
# (newest first). Selecting an item forwards the rendered markdown to the
# downstream Text View via `arg`; ⌘C / Universal Action copies just the
# answer text via `text.copy`.
#
# `alfredfiltersresults` is enabled on the upstream object so Alfred fuzzy
# matches against each item's `match` string (query + response).

set -uo pipefail

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

data_dir="${alfred_workflow_data:-/tmp/alfred-chatgpt-data}"
file="$data_dir/ephemeral-history.jsonl"

empty_state() {
  local title="$1"
  local subtitle="$2"
  jq -nc \
    --arg t "$title" \
    --arg s "$subtitle" \
    '{items: [{title: $t, subtitle: $s, valid: false}]}'
}

if ! command -v jq >/dev/null 2>&1; then
  empty_state "jq is required for history" "Install jq (e.g. brew install jq) and try again."
  exit 0
fi

if [[ ! -s "$file" ]]; then
  empty_state \
    "No ephemeral history yet" \
    "Ask something with the ephemeral keyword to start populating this list."
  exit 0
fi

# Reverse so the most recent entry is first. `tail -r` is the BSD/macOS
# equivalent of GNU `tac`.
tail -r "$file" 2>/dev/null \
  | jq -sc '
      def truncate($n):
        if (. | length) > $n then (.[0:$n] + "…") else . end;

      def oneline:
        (. // "")
        | gsub("[\r\n\t]+"; " ")
        | gsub(" +"; " ")
        | sub("^ "; "")
        | sub(" $"; "");

      {
        items: (
          map(
            . as $e
            | ($e.query    // "" | tostring) as $q
            | ($e.response // "" | tostring) as $r
            | ($e.ts       // 0  | tonumber) as $ts
            | ($q | oneline)                      as $q1
            | ($r | oneline)                      as $r1
            | ($ts | strftime("%Y-%m-%d %H:%M"))  as $when
            | ("# You\n\n" + $q + "\n\n# Assistant\n\n" + $r) as $body
            | {
                title: ($q1 | truncate(120)),
                subtitle: ($when + "  ·  " + ($r1 | truncate(140))),
                arg: $body,
                match: ($q1 + " " + $r1),
                text: { copy: $r, largetype: $r },
                mods: {
                  cmd: { subtitle: "⌘↩ Copy answer to clipboard", arg: $r, valid: true }
                },
                valid: true
              }
          )
        )
      }
    '
