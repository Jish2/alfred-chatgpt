# FAQ

### Where does my data go? Do I need an API key?

No separate API key. The workflow shells out to Cursor CLI in non-interactive,
read-only Ask mode and uses your existing Cursor login. Run `agent login` once
if Cursor CLI is not already authenticated.

### How do I switch models?

Edit **Configure Workflow… → Cursor Model** in Alfred. The default is
`gpt-5.6-luna-medium`. Run `agent --list-models` to list model IDs available
to your account. `gpt-5.6-luna` is accepted as shorthand for the medium-effort
variant.

### Is this a direct inference call?

Not quite. Cursor CLI does not currently expose a raw inference command like
the removed `codex responses` path. The workflow uses
`agent -p --mode ask`, which is non-interactive and read-only but still runs
through Cursor's agent runtime.

### The `gg` (persistent) mode opens chatgpt.com but doesn't press Send.

Two likely causes:

1. **Accessibility permission.** The script presses Return via
  `osascript -e 'tell application "System Events" to key code 36'`. macOS
   needs to allow `osascript` (or `Alfred`) under *System Settings → Privacy &
   Security → Accessibility*. You'll be prompted on first run.
2. **Browser too slow.** Increase **Persistent Submit Delay (ms)**, or set
  **Browser Bundle ID** so the script focuses your browser before pressing
   Return (e.g. `com.google.Chrome`, `com.apple.Safari`,
   `company.thebrowser.Browser` for Arc).

### The terminal command `gt` pastes into the wrong window.

Alfred pastes into whatever app is frontmost when the workflow returns. Make
sure your terminal was the active window before invoking Alfred. If you alt-tab
during the Cursor call, Alfred will follow you.

### Cursor CLI not found from Alfred

Alfred runs scripts with a minimal `PATH`. The scripts already prepend
`~/.local/bin`, `~/.cursor/bin`, and common Homebrew paths. If `agent` or
`cursor-agent` is somewhere else, add a Workflow Environment Variable named
`PATH` that includes that directory.

### How do I see what the model is actually being asked?

Open **Alfred → Workflows → this workflow → ⌘D** (debugger). Each script logs
its arguments and the Cursor stream is visible.

### Can I keep the old chat-history / DALL·E features from the upstream workflow?

Not in this fork. They depended on an OpenAI API key. Use the original
`[alfredapp/openai-workflow](https://github.com/alfredapp/openai-workflow)` if
you want them.