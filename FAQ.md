# FAQ

### Where does my data go? Do I need an OpenAI API key?

No API key. The workflow shells out to the local `[codex](https://github.com/openai/codex)`
CLI, which talks to the OpenAI Responses API using your **ChatGPT
subscription** session. Make sure `codex login` has been run at least once.

### How do I switch models?

Edit **Configure Workflow… → Codex Model** in Alfred. Default is
`gpt-5.4-mini`. Whatever model name `codex responses` accepts will work —
`gpt-5.4-mini`, `gpt-5.4`, `gpt-5.2`, `gpt-5.2-mini`, `gpt-4o`, `o3`, etc.

### Why am I getting `Unsupported value: 'minimal' is not supported with…`?

Some models (e.g. `gpt-5.2`) don't accept the `minimal` reasoning level. Pick
`low`, `medium`, `high`, or `xhigh` in **Configuration → Reasoning Effort**, or
choose **None** to use the model's own default.

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
during the codex call, Alfred will follow you.

### `codex` not found from Alfred.

Alfred runs scripts with a minimal `PATH`. The scripts already prepend
`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`. If your `codex` is somewhere
else (e.g. `~/.local/bin`), add a Workflow Environment Variable named `PATH`
that includes that directory.

### How do I see what the model is actually being asked?

Open **Alfred → Workflows → this workflow → ⌘D** (debugger). Each script logs
its arguments and the codex stream is visible.

### Can I keep the old chat-history / DALL·E features from the upstream workflow?

Not in this fork. They depended on an OpenAI API key. Use the original
`[alfredapp/openai-workflow](https://github.com/alfredapp/openai-workflow)` if
you want them.