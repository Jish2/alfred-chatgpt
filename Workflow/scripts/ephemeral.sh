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

set -uo pipefail

typed_query="${1:-}"
# Trim leading/trailing whitespace (parameter expansion, no subshell).
typed_query="${typed_query#"${typed_query%%[![:space:]]*}"}"
typed_query="${typed_query%"${typed_query##*[![:space:]]}"}"

cache_dir="${alfred_workflow_cache:-/tmp/alfred-chatgpt-cache}"
mkdir -p "$cache_dir"

stream_file="$cache_dir/ephemeral-stream.txt"
pid_file="$cache_dir/ephemeral-pid.txt"

# Resolve `codex-query.sh` next to this script regardless of cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="$script_dir/codex-query.sh"

model="${codex_model:-gpt-5.4-mini}"
reasoning="${codex_reasoning:-low}"
system="${codex_system_ephemeral:-You are a helpful assistant. Be concise and direct. Prefer short answers and short code snippets when applicable.}"
timeout_s="${codex_timeout_seconds:-30}"

streaming_now="${streaming_now:-}"

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

pid_alive() { kill -0 "$1" 2>/dev/null; }

file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

start_stream() {
  : > "$stream_file"
  # `nohup` so the streamer survives this script's exit; `&` detaches.
  CODEX_MODEL="$model" CODEX_REASONING="$reasoning" CODEX_SYSTEM="$system" \
    nohup "$script_path" --no-newline -q "$typed_query" \
      >"$stream_file" 2>&1 </dev/null &
  echo $! > "$pid_file"
  disown 2>/dev/null || true
}

# `printf -v` writes straight into the variable so the trailing "\n\n" is
# preserved. (Plain `$(printf ...)` would strip trailing newlines.)
printf -v header '# You\n\n%s\n\n# Assistant\n\n' "$typed_query"

# First invocation: prompt-only state.
if [[ -z "$streaming_now" && -z "$typed_query" ]]; then
  jq -nc \
    --arg resp "Type a question and press Return." \
    --arg foot "Ephemeral · ↩ Submit · ⌘↩ Copy answer · Esc Discard" \
    '{response: $resp, footer: $foot}'
  exit 0
fi

# First invocation with a query: kick off the background streamer and emit
# the header + a placeholder so the user sees something immediately.
if [[ -z "$streaming_now" ]]; then
  rm -f "$stream_file" "$pid_file"
  start_stream
  jq -nc --arg resp "${header}…" '
    {
      rerun: 0.1,
      variables: {streaming_now: "1"},
      response: $resp,
      behaviour: {scroll: "end"}
    }'
  exit 0
fi

# Streaming-loop invocation.
content=""
[[ -f "$stream_file" ]] && content="$(cat "$stream_file")"
pid=0
[[ -f "$pid_file" ]] && pid="$(cat "$pid_file" 2>/dev/null || echo 0)"
[[ -z "$pid" ]] && pid=0

body="${content:-…}"

if [[ "$pid" -gt 0 ]] && pid_alive "$pid"; then
  now=$(date +%s)
  mtime=$(file_mtime "$stream_file")
  if [[ -f "$stream_file" ]] && (( now - mtime > timeout_s )); then
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$stream_file" "$pid_file"
    jq -nc \
      --arg resp "${header}${content}

[Connection stalled]" \
      --arg foot "codex did not produce output in time" '
      {
        response: $resp,
        footer: $foot,
        behaviour: {response: "replace", scroll: "end"}
      }'
    exit 0
  fi

  jq -nc --arg resp "${header}${body}" '
    {
      rerun: 0.1,
      variables: {streaming_now: "1"},
      response: $resp,
      behaviour: {response: "replace", scroll: "end"}
    }'
  exit 0
fi

# Background streamer has exited: emit the final frame and clean up.
final="${content:-[No response]}"

# Record the completed Q&A pair to the workflow's persistent history file.
# Best-effort: any failure is swallowed so it can't break the streaming UX.
if [[ -n "$typed_query" && -n "$content" ]]; then
  record_script="$script_dir/history-record.sh"
  if [[ -x "$record_script" ]]; then
    "$record_script" "$typed_query" "$stream_file" >/dev/null 2>&1 || true
  fi
fi

rm -f "$stream_file" "$pid_file"
jq -nc --arg resp "${header}${final}" '
  {
    response: $resp,
    behaviour: {response: "replace", scroll: "end"}
  }'
