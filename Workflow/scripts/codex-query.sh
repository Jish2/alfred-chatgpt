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

if ! command -v codex >/dev/null 2>&1; then
  echo "$PROG: 'codex' not found on PATH." >&2
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

if [[ "$RAW" -eq 1 ]]; then
  printf '%s' "$PAYLOAD" | codex responses
  exit "${PIPESTATUS[1]}"
fi

set +e
printf '%s' "$PAYLOAD" \
  | codex responses \
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
