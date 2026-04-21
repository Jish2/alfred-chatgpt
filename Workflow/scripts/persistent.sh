#!/usr/bin/env bash
# Persistent prompt: open chatgpt.com with the prompt prefilled, then press
# Return so ChatGPT actually sends it. The conversation lives in the browser
# and is therefore persisted in the user's ChatGPT account.
#
# Usage: persistent.sh "your prompt here"
#
# Tunable env vars (set via Alfred Workflow Configuration):
#   submit_delay_ms     ms to wait between opening the URL and pressing Return.
#                       Default: 1500. Increase if your browser is slow to load.
#   browser_bundle_id   Bundle id of the browser to focus before pressing Return.
#                       Default: empty (rely on the OS to focus the new window).
#   chatgpt_base_url    Override base URL. Default: https://chatgpt.com/

set -euo pipefail

PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

QUERY="${1:-}"
if [[ -z "$QUERY" ]]; then
  echo "persistent.sh: no prompt provided" >&2
  exit 2
fi

BASE_URL="${chatgpt_base_url:-https://chatgpt.com/}"
DELAY_MS="${submit_delay_ms:-1500}"
BROWSER_BUNDLE_ID="${browser_bundle_id:-}"

# URL-encode the prompt with python (always present on macOS).
ENCODED="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$QUERY")"

# Strip a single trailing slash so we can safely append `?prompt=`.
TRIMMED="${BASE_URL%/}"
URL="${TRIMMED}/?prompt=${ENCODED}"

# Open in the user's default browser.
/usr/bin/open "$URL"

# Wait for the page to load enough that the input is focused.
DELAY_S="$(awk -v ms="$DELAY_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
sleep "$DELAY_S"

# Optionally focus a specific browser before pressing Return. This guards
# against accidentally sending the keystroke to whatever app was frontmost
# (e.g. if the user clicked away while the page was loading).
if [[ -n "$BROWSER_BUNDLE_ID" ]]; then
  /usr/bin/osascript <<APPLESCRIPT
tell application id "$BROWSER_BUNDLE_ID" to activate
delay 0.2
APPLESCRIPT
fi

# Press Return in the focused window.
/usr/bin/osascript -e 'tell application "System Events" to key code 36'
