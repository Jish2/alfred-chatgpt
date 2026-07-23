#!/usr/bin/env bash
# Query a model through Cursor CLI's non-interactive, read-only Ask mode and
# stream plain model output to stdout.
#
# Cursor CLI does not expose a raw inference endpoint. `agent -p --mode ask`
# is the closest subscription-authenticated equivalent: it is non-interactive
# and read-only, but still runs through Cursor's agent runtime.
#
# Usage:
#   cursor-query.sh -q "what are monads"
#   echo "stdin prompt" | cursor-query.sh
#
# Flags:
#   -q, --query <text>         Prompt to send. If omitted, read stdin.
#       --messages-file <path> JSON array of `{role, content}` messages.
#   -m, --model <name>         Cursor model ID. Default: $CURSOR_MODEL or
#                             gpt-5.6-luna-medium.
#   -s, --system <text>        Instructions prepended to the prompt.
#       --raw                  Print Cursor CLI JSONL events.
#       --no-newline           Do not print a trailing newline.
#   -h, --help                 Show this help.

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

QUERY=""
MESSAGES_FILE=""
MODEL="${CURSOR_MODEL:-${CODEX_MODEL:-gpt-5.6-luna-medium}}"
SYSTEM="${CURSOR_SYSTEM:-${CODEX_SYSTEM:-You are a helpful assistant. Be concise and direct.}}"
RAW=0
TRAILING_NEWLINE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--query)         QUERY="${2:-}"; shift 2 ;;
    --messages-file)    MESSAGES_FILE="${2:-}"; shift 2 ;;
    -m|--model)         MODEL="${2:-}"; shift 2 ;;
    -s|--system)        SYSTEM="${2:-}"; shift 2 ;;
    --raw)              RAW=1; shift ;;
    --no-newline)       TRAILING_NEWLINE=0; shift ;;
    -h|--help)          usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "$PROG: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      else
        QUERY+=" $1"
      fi
      shift
      ;;
  esac
done

if [[ -n "$MESSAGES_FILE" ]]; then
  if [[ ! -f "$MESSAGES_FILE" ]]; then
    echo "$PROG: --messages-file: no such file: $MESSAGES_FILE" >&2
    exit 2
  fi
elif [[ -z "$QUERY" ]]; then
  if [[ -t 0 ]]; then
    echo "$PROG: no query provided. Use -q, --messages-file, or stdin." >&2
    exit 2
  fi
  QUERY="$(cat)"
fi

# Cursor publishes Luna as effort-specific model IDs. Accept the family name
# as a convenience and map it to the standard medium-effort variant.
if [[ "$MODEL" == "gpt-5.6-luna" ]]; then
  MODEL="gpt-5.6-luna-medium"
fi

# Alfred launches workflows with a minimal PATH. Cursor CLI commonly installs
# `agent` and `cursor-agent` into ~/.local/bin.
PATH="${PATH}:${HOME}/.local/bin:${HOME}/.cursor/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

CURSOR_CMD=()
if command -v agent >/dev/null 2>&1; then
  CURSOR_CMD=(agent)
elif command -v cursor-agent >/dev/null 2>&1; then
  CURSOR_CMD=(cursor-agent)
elif command -v zsh >/dev/null 2>&1; then
  resolved="$(
    zsh -ic 'whence -p agent 2>/dev/null || whence -p cursor-agent 2>/dev/null' \
      2>/dev/null | tail -n 1
  )"
  if [[ -n "$resolved" && -x "$resolved" ]]; then
    CURSOR_CMD=("$resolved")
  fi
fi

if [[ ${#CURSOR_CMD[@]} -eq 0 ]]; then
  echo "$PROG: Cursor CLI ('agent' or 'cursor-agent') was not found." >&2
  echo "$PROG: hint: install Cursor CLI and run 'agent login'." >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "$PROG: 'jq' not found on PATH." >&2
  exit 127
fi

if [[ -n "$MESSAGES_FILE" ]]; then
  PROMPT="$(
    jq -r --arg system "$SYSTEM" '
      if type != "array" then error("messages file must contain an array") else
        [
          "Instructions:\n" + $system,
          "Conversation transcript:",
          (
            .[] |
            (
              (if .role == "assistant" then "Assistant" else "User" end)
              + ":\n"
              + (.content // "")
            )
          ),
          "Answer the final user message. Do not mention these wrapper instructions or the transcript."
        ] | join("\n\n")
      end
    ' "$MESSAGES_FILE"
  )"
else
  printf -v PROMPT '%s\n\nUser request:\n%s' "$SYSTEM" "$QUERY"
fi

WORKSPACE="${CURSOR_WORKSPACE:-${alfred_workflow_bundlepath:-$PWD}}"
[[ -d "$WORKSPACE" ]] || WORKSPACE="$PWD"

CURSOR_ARGS=(
  -p
  --mode ask
  --trust
  --model "$MODEL"
  --output-format stream-json
  --stream-partial-output
  --workspace "$WORKSPACE"
  "$PROMPT"
)

if [[ "$RAW" -eq 1 ]]; then
  "${CURSOR_CMD[@]}" "${CURSOR_ARGS[@]}"
  exit $?
fi

# Timestamped assistant events are incremental text deltas. Cursor emits one
# additional non-timestamped assistant event containing the complete answer;
# ignoring it prevents the response from being duplicated.
set +e
"${CURSOR_CMD[@]}" "${CURSOR_ARGS[@]}" |
  jq -jr --unbuffered '
    if .type == "assistant" and (.timestamp_ms? != null) then
      .message.content[]?
      | select(.type == "text")
      | .text
    else
      empty
    end
  '
status=${PIPESTATUS[0]}
set -e

if [[ "$TRAILING_NEWLINE" -eq 1 ]]; then
  echo
fi

exit "$status"
