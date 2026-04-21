#!/usr/bin/env bash
# Generate a single shell command from a natural-language description, using
# the local `codex` CLI. The output is meant to be pasted at the cursor of the
# frontmost terminal (Alfred's "Copy to Clipboard" action with auto-paste).
#
# Output contract: ONLY the command, on a single line, no fences, no prose.
#
# Usage: terminal-cmd.sh "list files larger than 100MB under cwd"

set -euo pipefail

PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

QUERY="${1:-}"
if [[ -z "$QUERY" ]]; then
  echo "terminal-cmd.sh: no prompt provided" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_SYSTEM='You generate POSIX shell commands for macOS (zsh).
Rules:
- Output ONLY the command, with no surrounding prose, explanations, or comments.
- Do NOT wrap the command in markdown code fences or backticks.
- Output a single line when possible. If multiple commands are required, join
  them with `&&` on one line. Never include a trailing newline of explanation.
- Prefer commands available by default on macOS, then standard Homebrew tools.
- If the request is ambiguous, pick the most common interpretation; do not ask
  clarifying questions.'

SYSTEM_PROMPT="${codex_system_terminal:-$DEFAULT_SYSTEM}"
MODEL="${codex_model:-gpt-5.4-mini}"
REASONING="${codex_reasoning_terminal:-${codex_reasoning:-low}}"

OUT="$(
  CODEX_MODEL="$MODEL" \
  CODEX_REASONING="$REASONING" \
  CODEX_SYSTEM="$SYSTEM_PROMPT" \
  "$SCRIPT_DIR/codex-query.sh" --no-newline -q "$QUERY"
)"

# Defensive cleanup in case the model still wraps the output in a fence or
# adds a leading "$ " prompt.
OUT="${OUT#\`\`\`*$'\n'}"
OUT="${OUT%$'\n'\`\`\`}"
OUT="${OUT#\`}"; OUT="${OUT%\`}"
OUT="${OUT#\$ }"
OUT="${OUT#sh }"
OUT="${OUT#bash }"

# Trim trailing whitespace / newlines.
OUT="$(printf '%s' "$OUT" | sed -e 's/[[:space:]]*$//')"

printf '%s' "$OUT"
