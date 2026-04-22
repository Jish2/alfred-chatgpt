#!/usr/bin/env bash
# Query the raw OpenAI Responses API through the local `codex` ChatGPT
# subscription. Skips the Codex agent loop entirely (no shell, apply_patch,
# MCP, etc.) and streams plain model output to stdout.
#
# Adapted from ~/github/scripts/query-chat-gpt-through-codex.sh
#
# Usage:
#   codex-query.sh -q "what are monads"
#   echo "stdin prompt" | codex-query.sh
#
# Flags:
#   -q, --query     <text>   Prompt to send. If omitted, prompt is read from stdin.
#   -m, --model     <name>   Model name. Default: $CODEX_MODEL or gpt-5.4-mini.
#   -s, --system    <text>   System / instructions. Default: $CODEX_SYSTEM or generic helper.
#   -r, --reasoning <level>  Reasoning effort: minimal | low | medium | high.
#                            Default: $CODEX_REASONING (unset = model default).
#       --raw                Print raw JSONL events instead of just text deltas.
#       --no-newline         Don't print a trailing newline after the response.
#   -h, --help               Show this help.

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

QUERY=""
MODEL="${CODEX_MODEL:-gpt-5.4-mini}"
SYSTEM="${CODEX_SYSTEM:-You are a helpful assistant. Be concise and direct.}"
REASONING="${CODEX_REASONING:-}"
RAW=0
TRAILING_NEWLINE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--query)     QUERY="${2:-}"; shift 2 ;;
    -m|--model)     MODEL="${2:-}"; shift 2 ;;
    -s|--system)    SYSTEM="${2:-}"; shift 2 ;;
    -r|--reasoning) REASONING="${2:-}"; shift 2 ;;
    --raw)          RAW=1; shift ;;
    --no-newline)   TRAILING_NEWLINE=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "$PROG: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"; shift
      else
        QUERY+=" $1"; shift
      fi
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  if [[ -t 0 ]]; then
    echo "$PROG: no query provided. Use -q \"...\" or pipe text on stdin." >&2
    exit 2
  fi
  QUERY="$(cat)"
fi

# Resolve `codex` and `jq` even when launched from Alfred (which has a minimal PATH).
PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Resolve `codex` into the array CODEX_CMD. Prefers a real binary on PATH, and
# falls back to an interactive zsh probe so aliases / functions defined in the
# user's ~/.zshrc (e.g. `alias codex='/opt/homebrew/bin/codex --foo'`) work too.
CODEX_CMD=()
resolve_codex() {
  if command -v codex >/dev/null 2>&1; then
    CODEX_CMD=(codex)
    return 0
  fi

  command -v zsh >/dev/null 2>&1 || return 1

  # Run an interactive zsh so ~/.zshrc is sourced. Print prefixed lines we can
  # grep out of any noisy startup output (p10k, motd, etc.). We export both the
  # codex resolution and zsh's PATH so binaries referenced by an alias body
  # (e.g. `alias codex='CODEX_HOME=… brodex'` where `brodex` lives somewhere
  # only zsh knows about) become reachable from this bash process.
  local probe probe_out
  probe='
    emulate -L zsh
    print -r -- "__CODEX_RESOLVE__PATHENV:$PATH"
    if (( ${+aliases[codex]} )); then
      print -r -- "__CODEX_RESOLVE__ALIAS:${aliases[codex]}"
    elif (( ${+functions[codex]} )); then
      print -r -- "__CODEX_RESOLVE__FUNC:codex"
    elif whence -p codex >/dev/null 2>&1; then
      print -r -- "__CODEX_RESOLVE__PATH:$(whence -p codex)"
    fi
  '
  probe_out="$(zsh -ic "$probe" 2>/dev/null | grep '^__CODEX_RESOLVE__')"

  # Merge zsh's PATH so any binaries referenced by the alias body resolve.
  local zsh_path
  zsh_path="$(printf '%s\n' "$probe_out" \
    | grep '^__CODEX_RESOLVE__PATHENV:' \
    | tail -n 1)"
  zsh_path="${zsh_path#__CODEX_RESOLVE__PATHENV:}"
  if [[ -n "$zsh_path" ]]; then
    PATH="${PATH}:${zsh_path}"
    export PATH
  fi

  local resolved
  resolved="$(printf '%s\n' "$probe_out" \
    | grep -E '^__CODEX_RESOLVE__(ALIAS|FUNC|PATH):' \
    | tail -n 1)"
  resolved="${resolved#__CODEX_RESOLVE__}"

  case "$resolved" in
    ALIAS:*)
      # Re-parse the alias body as shell words. Most aliases are simple
      # ("/path/to/codex --flag"), so bash word-splitting matches what zsh
      # would do at the call site.
      local def="${resolved#ALIAS:}"
      eval "CODEX_CMD=($def)" 2>/dev/null || return 1
      [[ ${#CODEX_CMD[@]} -gt 0 ]] || return 1
      return 0
      ;;
    FUNC:*)
      # Functions can't be invoked from bash directly. Re-enter zsh
      # interactively so the function (and its closure over ~/.zshrc) is
      # available when we run `codex responses`.
      CODEX_CMD=(zsh -ic 'codex "$@"' codex)
      return 0
      ;;
    PATH:*)
      CODEX_CMD=("${resolved#PATH:}")
      return 0
      ;;
  esac

  return 1
}

if ! resolve_codex; then
  echo "$PROG: 'codex' not found on PATH or as a zsh alias/function." >&2
  echo "$PROG: hint: install codex (https://github.com/openai/codex) or expose your alias to non-interactive shells." >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "$PROG: 'jq' not found on PATH." >&2
  exit 127
fi

PAYLOAD="$(
  jq -n \
    --arg model "$MODEL" \
    --arg sys   "$SYSTEM" \
    --arg user  "$QUERY" \
    --arg effort "$REASONING" \
    '{
      model: $model,
      stream: true,
      store: false,
      instructions: $sys,
      input: [ { role: "user", content: $user } ]
    }
    + (if $effort == "" then {} else { reasoning: { effort: $effort } } end)'
)"

# Use `env` so any leading `VAR=value` words coming from a zsh alias
# (e.g. `alias codex='CODEX_HOME=/path brodex'`) are applied as env
# assignments instead of being treated as the command name.
if [[ "$RAW" -eq 1 ]]; then
  printf '%s' "$PAYLOAD" | env "${CODEX_CMD[@]}" responses
  exit "${PIPESTATUS[1]}"
fi

set +e
printf '%s' "$PAYLOAD" \
  | env "${CODEX_CMD[@]}" responses \
  | jq -j --unbuffered '
      if .type == "response.output_text.delta" then .delta
      elif .type == "response.completed"       then ""
      else empty
      end
    '
status=${PIPESTATUS[1]}
set -e

if [[ "$TRAILING_NEWLINE" -eq 1 ]]; then
  echo
fi

exit "$status"
