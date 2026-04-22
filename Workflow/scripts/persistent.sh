#!/usr/bin/env bash
# Persistent prompt: open chatgpt.com with the prompt prefilled, then press
# Return so ChatGPT actually sends it. The conversation lives in the browser
# and is therefore persisted in the user's ChatGPT account.
#
# Usage: persistent.sh "your prompt here"
#
# Tunable env vars (set via Alfred Workflow Configuration):
#   submit_delay_ms          ms to wait between opening the URL and pressing
#                            Return. Default: 1500. Increase if your browser is
#                            slow to load.
#   browser_bundle_id        Bundle id of the browser to focus before pressing
#                            Return. Default: empty (rely on the OS to focus the
#                            new window).
#   chatgpt_base_url         Override base URL. Default: https://chatgpt.com/
#   alfred_dismiss_timeout_ms
#                            Max ms to wait for Alfred's window to dismiss
#                            before pressing Return. If Alfred is still the
#                            frontmost app after this timeout, the script
#                            aborts WITHOUT pressing Return (otherwise the
#                            Return keystroke is delivered to Alfred, which
#                            re-runs the `gg` keyword and spams the browser
#                            with new tabs). Default: 2000.

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
ALFRED_DISMISS_TIMEOUT_MS="${alfred_dismiss_timeout_ms:-2000}"

# Returns 0 if the frontmost app is Alfred, 1 otherwise.
is_alfred_frontmost() {
  local front
  front="$(/usr/bin/osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)"
  case "$front" in
    com.runningwithcrayons.Alfred*) return 0 ;;
    *) return 1 ;;
  esac
}

# Poll until Alfred is no longer frontmost, or until the timeout expires.
# Returns 0 if Alfred dismissed in time, 1 if it did not.
wait_for_alfred_dismiss() {
  local timeout_ms="$1"
  local interval_ms=50
  local waited_ms=0
  while is_alfred_frontmost; do
    if (( waited_ms >= timeout_ms )); then
      return 1
    fi
    /bin/sleep "$(awk -v ms="$interval_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
    waited_ms=$(( waited_ms + interval_ms ))
  done
  return 0
}

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

# Bug guard: occasionally Alfred's window does not dismiss before this script
# fires its Return keystroke. When that happens the Return is delivered to
# Alfred, which re-runs the `gg` keyword with the same query — opening another
# tab, queueing another Return, and so on, spamming chatgpt.com. Wait briefly
# for Alfred to dismiss; if it refuses to, abort instead of pressing Return.
if ! wait_for_alfred_dismiss "$ALFRED_DISMISS_TIMEOUT_MS"; then
  echo "persistent.sh: Alfred is still frontmost after ${ALFRED_DISMISS_TIMEOUT_MS}ms; refusing to send Return to avoid a re-trigger loop." >&2
  exit 1
fi

# Press Return in the focused window.
/usr/bin/osascript -e 'tell application "System Events" to key code 36'
