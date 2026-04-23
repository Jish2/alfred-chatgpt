#!/bin/bash
# Text View input for "open the last ephemeral chat" (the `gl` keyword).
#
# Bootstraps the most recent ephemeral thread into the cache thread file and
# then delegates to `ephemeral.sh`, which knows how to:
#   - render the full conversation in the text view,
#   - kick off a continuation when the user types a follow-up into the input,
#   - drive the streaming rerun loop.
#
# Source of truth for "the last thread" is
# `$alfred_workflow_data/last-thread.json`, written by `ephemeral.sh` after
# every completed assistant turn. As a backwards-compat fallback, when no
# thread file exists yet we synthesize a one-turn thread from the newest line
# of `ephemeral-history.jsonl` so legacy users can still reopen + continue
# their last Q&A pair.

set -uo pipefail

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

typed_query="${1:-}"
typed_query="${typed_query#"${typed_query%%[![:space:]]*}"}"
typed_query="${typed_query%"${typed_query##*[![:space:]]}"}"

cache_dir="${alfred_workflow_cache:-/tmp/alfred-chatgpt-cache}"
data_dir="${alfred_workflow_data:-/tmp/alfred-chatgpt-data}"
mkdir -p "$cache_dir"

cache_thread="$cache_dir/ephemeral-thread.json"
saved_thread="$data_dir/last-thread.json"
history_file="$data_dir/ephemeral-history.jsonl"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ephemeral_script="$script_dir/ephemeral.sh"

streaming_now="${streaming_now:-}"
thread_id="${thread_id:-}"

# Bootstrap fires only on the very first invocation of `gl` for a given
# Alfred session: no `thread_id` carried over, no streaming in flight, and
# no follow-up typed yet. As soon as we mint a `thread_id`, subsequent
# rerun frames and text-view input submissions skip this branch and fall
# straight through to `ephemeral.sh`.
if [[ -z "$thread_id" && -z "$streaming_now" && -z "$typed_query" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    body="# jq is required

Install jq (e.g. \`brew install jq\`) and try again."
    jq -nc --arg resp "$body" \
           --arg foot "Last ephemeral · ⌘C Copy · Esc Close" \
      '{response: $resp, footer: $foot, behaviour: {scroll: "start"}}' 2>/dev/null \
      || printf '{"response":%s,"footer":%s}\n' "\"$body\"" "\"missing jq\""
    exit 0
  fi

  bootstrapped=0
  if [[ -s "$saved_thread" ]]; then
    cp "$saved_thread" "$cache_thread"
    bootstrapped=1
  elif [[ -s "$history_file" ]]; then
    # Legacy fallback: assemble a single-turn thread from the newest entry
    # in `ephemeral-history.jsonl`. Pre-existing users haven't accumulated
    # any `last-thread.json` snapshots yet, so without this their first
    # `gl` after the upgrade would behave as if the workflow were brand new.
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)"
    if [[ -n "$last_line" ]]; then
      tmp="$(mktemp "$cache_thread.tmp.XXXXXX")"
      if jq -c '
            [ {role: "user",      content: (.query    // "" | tostring)},
              {role: "assistant", content: (.response // "" | tostring)} ]
          ' <<<"$last_line" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$cache_thread"
        bootstrapped=1
      else
        rm -f "$tmp"
      fi
    fi
  fi

  if [[ "$bootstrapped" -eq 1 ]]; then
    # Mint a fresh thread id so `ephemeral.sh` treats this as an active
    # conversation (and so a sibling `g` invocation, which arrives without
    # `thread_id` set, still starts cleanly from a brand new thread).
    export thread_id="last-$(date +%s)-$$"
  else
    jq -nc \
      --arg resp "# No ephemeral chats yet

Ask something with the ephemeral keyword to populate this view." \
      --arg foot "Last ephemeral · ⌘C Copy · Esc Close" \
      '{response: $resp, footer: $foot, behaviour: {scroll: "start"}}'
    exit 0
  fi
fi

# Hand off to the shared streaming/continuation logic. From here on,
# `ephemeral.sh` owns rendering (full thread, not just the last pair),
# the rerun loop, and writing back the updated `last-thread.json` snapshot
# whenever the user fires a follow-up from this view.
exec "$ephemeral_script" "$typed_query"
