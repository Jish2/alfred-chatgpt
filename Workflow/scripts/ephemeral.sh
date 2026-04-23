#!/bin/bash
# Ephemeral ChatGPT prompt for Alfred — bash port of `ephemeral.js`.
#
# Drives the Text View streaming loop: each `rerun: 0.1` re-invokes this
# script, which re-reads the cache file `codex-query.sh` is appending to and
# emits a single JSON frame for Alfred's Text View.
#
# Why bash instead of JXA: `osascript` cold-start is ~150–400 ms on macOS,
# which dominates the 100 ms rerun cadence and makes streaming look chunky.
# Bash starts in ~5 ms, so polling at rerun=0.1 is actually live.
#
# Threads: when the user submits a follow-up in the text view's input field
# (rather than dismissing and re-running `g` from Alfred), this script
# continues the existing conversation instead of starting a new one. State is
# kept in `$alfred_workflow_cache/ephemeral-thread.json` (a JSON array of
# {role, content} messages) and the active thread is identified by the
# `thread_id` workflow variable, which Alfred carries across reruns and
# subsequent text-view submissions. Pressing Esc and triggering `g` again
# starts the next call without `thread_id` set, so a fresh thread begins.

set -uo pipefail

typed_query="${1:-}"
# Trim leading/trailing whitespace (parameter expansion, no subshell).
typed_query="${typed_query#"${typed_query%%[![:space:]]*}"}"
typed_query="${typed_query%"${typed_query##*[![:space:]]}"}"

cache_dir="${alfred_workflow_cache:-/tmp/alfred-chatgpt-cache}"
mkdir -p "$cache_dir"

stream_file="$cache_dir/ephemeral-stream.txt"
pid_file="$cache_dir/ephemeral-pid.txt"
thread_file="$cache_dir/ephemeral-thread.json"
messages_file="$cache_dir/ephemeral-messages.json"

# Resolve `codex-query.sh` next to this script regardless of cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="$script_dir/codex-query.sh"

model="${codex_model:-gpt-5.4-mini}"
reasoning="${codex_reasoning:-low}"
system="${codex_system_ephemeral:-You are a helpful assistant. Be concise and direct. Prefer short answers and short code snippets when applicable.}"
timeout_s="${codex_timeout_seconds:-30}"

streaming_now="${streaming_now:-}"
thread_id="${thread_id:-}"

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

pid_alive() { kill -0 "$1" 2>/dev/null; }

file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# Render the current `thread_file` (which is the source of truth for the
# conversation, including the in-flight user turn) as Alfred-friendly markdown.
# Each entry becomes a `# You` / `# Assistant` block separated by a blank line.
# Falls back to an empty string if the file is missing/unreadable so callers
# can safely concatenate.
render_thread_md() {
  if [[ ! -s "$thread_file" ]]; then
    return 0
  fi
  jq -r '
    map(
      if .role == "user" then "# You\n\n" + .content
      elif .role == "assistant" then "# Assistant\n\n" + .content
      else empty end
    ) | join("\n\n")
  ' "$thread_file" 2>/dev/null || true
}

append_message() {
  local role="$1" content="$2" tmp
  tmp="$(mktemp "$thread_file.tmp.XXXXXX")"
  if [[ -s "$thread_file" ]]; then
    jq --arg r "$role" --arg c "$content" \
       '. + [{role: $r, content: $c}]' "$thread_file" > "$tmp"
  else
    jq -n --arg r "$role" --arg c "$content" \
       '[{role: $r, content: $c}]' > "$tmp"
  fi
  mv "$tmp" "$thread_file"
}

reset_thread() {
  printf '[]\n' > "$thread_file"
}

start_stream() {
  : > "$stream_file"
  # Snapshot the thread *before* launching codex so an in-flight assistant
  # turn (which we'll append later) doesn't accidentally get fed back as
  # context if the user fires another follow-up before this one finishes.
  cp "$thread_file" "$messages_file"
  # `nohup` so the streamer survives this script's exit; `&` detaches.
  CODEX_MODEL="$model" CODEX_REASONING="$reasoning" CODEX_SYSTEM="$system" \
    nohup "$script_path" --no-newline --messages-file "$messages_file" \
      >"$stream_file" 2>&1 </dev/null &
  echo $! > "$pid_file"
  disown 2>/dev/null || true
}

# Build a JSON-friendly snippet for Alfred's `variables` field. Always include
# `thread_id` so it survives across rerun cycles *and* across the user typing
# the next follow-up into the text view's input.
thread_vars_json() {
  local extra="${1:-}"
  [[ -z "$extra" ]] && extra='{}'
  jq -nc \
    --arg tid "$thread_id" \
    --argjson extra "$extra" \
    '({thread_id: $tid} + $extra)'
}

# Empty submission: re-render whatever conversation we already have (or the
# bare prompt if the thread is empty too). Always preserve `thread_id` so the
# user can immediately type a real follow-up without losing context.
if [[ -z "$streaming_now" && -z "$typed_query" ]]; then
  history_md="$(render_thread_md)"
  if [[ -n "$thread_id" && -n "$history_md" ]]; then
    resp_text="$history_md"
    foot_text="Ephemeral · type a follow-up to continue · Esc Discard"
  else
    resp_text="Type a question and press Return."
    foot_text="Ephemeral · ↩ Submit · ⌘↩ Copy answer · Esc Discard"
  fi
  jq -nc \
    --arg resp "$resp_text" \
    --arg foot "$foot_text" \
    --arg tid  "$thread_id" \
    '
    {response: $resp, footer: $foot}
    + (if $tid == "" then {} else {variables: {thread_id: $tid}} end)
    '
  exit 0
fi

# First invocation with a query: kick off the background streamer, append the
# user turn to the thread, and emit an immediate header so the user has
# something to look at while codex spins up.
if [[ -z "$streaming_now" ]]; then
  rm -f "$stream_file" "$pid_file"

  # No `thread_id` carried over => Alfred re-launched us from the keyword
  # (or this is the very first run). Either way, start a new conversation.
  if [[ -z "$thread_id" || ! -s "$thread_file" ]]; then
    thread_id="$(date +%s)-$$"
    reset_thread
  fi

  append_message "user" "$typed_query"
  start_stream

  history_md="$(render_thread_md)"
  printf -v header '%s\n\n# Assistant\n\n' "$history_md"

  vars="$(thread_vars_json '{"streaming_now":"1"}')"
  jq -nc \
    --arg resp "${header}…" \
    --argjson vars "$vars" '
    {
      rerun: 0.1,
      variables: $vars,
      response: $resp,
      behaviour: {scroll: "end"}
    }'
  exit 0
fi

# Streaming-loop invocation. Re-render the conversation header on every frame
# so Alfred's text view shows the full chat (prior turns + the in-flight
# assistant reply being appended live).
content=""
[[ -f "$stream_file" ]] && content="$(cat "$stream_file")"
pid=0
[[ -f "$pid_file" ]] && pid="$(cat "$pid_file" 2>/dev/null || echo 0)"
[[ -z "$pid" ]] && pid=0

body="${content:-…}"
history_md="$(render_thread_md)"
printf -v header '%s\n\n# Assistant\n\n' "$history_md"

if [[ "$pid" -gt 0 ]] && pid_alive "$pid"; then
  now=$(date +%s)
  mtime=$(file_mtime "$stream_file")
  if [[ -f "$stream_file" ]] && (( now - mtime > timeout_s )); then
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$stream_file" "$pid_file"
    vars="$(thread_vars_json)"
    jq -nc \
      --arg resp "${header}${content}

[Connection stalled]" \
      --arg foot "codex did not produce output in time" \
      --argjson vars "$vars" '
      {
        response: $resp,
        footer: $foot,
        variables: $vars,
        behaviour: {response: "replace", scroll: "end"}
      }'
    exit 0
  fi

  vars="$(thread_vars_json '{"streaming_now":"1"}')"
  jq -nc \
    --arg resp "${header}${body}" \
    --argjson vars "$vars" '
    {
      rerun: 0.1,
      variables: $vars,
      response: $resp,
      behaviour: {response: "replace", scroll: "end"}
    }'
  exit 0
fi

# Background streamer has exited: persist the assistant turn, record history,
# and emit the final frame with `thread_id` preserved so the next follow-up
# the user types into the input box continues this same thread.
if [[ -n "$content" ]]; then
  append_message "assistant" "$content"
fi

# Snapshot the completed thread to the workflow's persistent data dir so the
# `gl` keyword (last-view.sh) can reopen the *entire* conversation — not just
# the final Q&A pair from `ephemeral-history.jsonl` — and continue it with a
# follow-up. Best-effort: any failure is swallowed so it can't break the UX.
if [[ -s "$thread_file" ]]; then
  data_dir="${alfred_workflow_data:-/tmp/alfred-chatgpt-data}"
  mkdir -p "$data_dir" 2>/dev/null || true
  cp "$thread_file" "$data_dir/last-thread.json" 2>/dev/null || true
fi

# Re-render now that the assistant turn is in the thread file. If codex
# produced nothing at all, fall back to a `[No response]` placeholder so the
# user sees *something* under the trailing `# Assistant` heading.
history_md="$(render_thread_md)"
if [[ -z "$content" ]]; then
  printf -v history_md '%s\n\n# Assistant\n\n[No response]' "$history_md"
fi

# Pull the most recent user query out of the thread file so history-record
# logs the right Q in case multi-turn rendering has shifted things.
last_user_query=""
if [[ -s "$thread_file" ]]; then
  last_user_query="$(jq -r '
    [.[] | select(.role == "user")] | last // empty | .content // empty
  ' "$thread_file" 2>/dev/null || true)"
fi
[[ -z "$last_user_query" ]] && last_user_query="$typed_query"

# Record the completed Q&A pair to the workflow's persistent history file.
# Best-effort: any failure is swallowed so it can't break the streaming UX.
if [[ -n "$last_user_query" && -n "$content" ]]; then
  record_script="$script_dir/history-record.sh"
  if [[ -x "$record_script" ]]; then
    "$record_script" "$last_user_query" "$stream_file" >/dev/null 2>&1 || true
  fi
fi

rm -f "$stream_file" "$pid_file" "$messages_file"

vars="$(thread_vars_json)"
jq -nc \
  --arg resp "${history_md}" \
  --argjson vars "$vars" '
  {
    response: $resp,
    variables: $vars,
    behaviour: {response: "replace", scroll: "end"}
  }'
