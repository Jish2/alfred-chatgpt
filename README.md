# <img src='Workflow/icon.png' width='45' align='center' alt='icon'> Alfred ChatGPT (codex)

Three lightweight ChatGPT prompt modes for Alfred, all powered by the local
[`codex`](https://github.com/openai/codex) CLI. Uses your **ChatGPT
subscription** through the OpenAI Responses API — **no API key required**.

> Forked from [`alfredapp/openai-workflow`](https://github.com/alfredapp/openai-workflow).
> The original API-key + chat-history + DALL·E machinery has been removed in
> favor of three focused modes wired through `codex`.

## Modes

| Keyword (default) | Mode | Behavior |
|---|---|---|
| `g  <query>` | **Ephemeral** | Streams a one-shot answer into Alfred's text view. Nothing is saved. |
| `gg <query>` | **Persistent** | Opens [`chatgpt.com/?prompt=…`](https://chatgpt.com/) and auto-presses Return so the prompt is sent in your real ChatGPT conversation history. |
| `gt <query>` | **Terminal command** | Generates a single shell command and pastes it at the cursor of your frontmost terminal — like Cursor's <kbd>⌘</kbd><kbd>K</kbd>. |

## Requirements

1. **macOS Alfred** with the Powerpack.
2. [`codex`](https://github.com/openai/codex) CLI on `PATH`, signed in to your
   ChatGPT account (`codex login`). Tested with `codex-cli` ≥ 0.122.
3. `jq` and `python3`. Both ship with macOS / Homebrew defaults; the workflow
   adds `/opt/homebrew/bin` to `PATH` automatically when launched from Alfred.

The workflow shells out to `codex responses` (the raw Responses API), bypassing
the Codex agent loop entirely — no shell, `apply_patch`, or MCP. It's just an
LLM call.

## Install

```sh
git clone https://github.com/Jish2/alfred-chatgpt.git
open Workflow   # double-click info.plist or drag the Workflow folder into Alfred
```

Alfred will import the bundle and surface the configurable variables under
**Workflow → Configure Workflow…**.

## Configuration

All settings live in the workflow's **Configuration** sheet:

- **Ephemeral / Persistent / Terminal Keyword** — defaults `g`, `gg`, `gt`.
- **Codex Model** — passed straight to `codex responses`. Defaults to
  `gpt-5.4-mini`. Examples: `gpt-5.4-mini`, `gpt-5.4`, `gpt-5.2`,
  `gpt-5.2-mini`, `gpt-4o`, `o3`. Whatever `codex` lets you query is fair game.
- **Reasoning Effort** — `none` / `low` / `medium` / `high` / `xhigh`. Lower is
  faster. Note: `gpt-5.2` does **not** accept `minimal`.
- **Ephemeral System Prompt** — instructions for the ephemeral mode. Default
  asks for short, direct answers.
- **Terminal System Prompt** — strict instructions to emit a single shell
  command with no fences or prose.
- **Persistent Submit Delay (ms)** — how long to wait after opening
  `chatgpt.com` before pressing Return. Bump this up if your browser is slow.
- **Browser Bundle ID** *(optional)* — focus a specific browser before pressing
  Return. Examples: `com.google.Chrome`, `com.apple.Safari`,
  `company.thebrowser.Browser` (Arc). Leave blank to skip.
- **ChatGPT Base URL** — defaults to `https://chatgpt.com/`. Override if you
  use a custom host.

## How each mode works

### 1. Ephemeral (`g`)

```
Script Filter (g <query>) ──► Text View
```

`scripts/ephemeral.js` (JXA) launches `scripts/codex-query.sh` as a background
`NSTask`, streaming stdout into a temp file. Alfred's `rerun: 0.1` polls the
file and appends new content to the text view, so you see tokens as they
arrive. When the codex process exits, the workflow tears down the temp files.

### 2. Persistent (`gg`)

```
Keyword (gg <query>) ──► Run Script (open URL + ⏎)
```

`scripts/persistent.sh`:

1. URL-encodes the prompt with `python3`.
2. `open https://chatgpt.com/?prompt=<encoded>` in your default browser.
3. Sleeps for `submit_delay_ms`.
4. Optionally activates `browser_bundle_id`.
5. Sends `key code 36` (Return) via System Events.

> macOS will ask for **Accessibility** permission for `osascript` the first
> time, since simulating Return counts as a synthetic event. Grant it under
> *System Settings → Privacy & Security → Accessibility*.

### 3. Terminal command (`gt`)

```
Keyword (gt <query>) ──► Run Script ──► Copy to Clipboard (auto-paste)
```

`scripts/terminal-cmd.sh` calls `codex-query.sh` with a strict system prompt
that forbids prose and code fences, then post-processes the output to strip
any stray fences or `$`/`sh ` prefixes. The clipboard output node is set to
**transient** + **auto-paste**, so the command lands at your terminal cursor
and isn't kept on the clipboard afterward.

## Repository layout

```
Workflow/
├── icon.png
├── info.plist                 # Alfred workflow definition
└── scripts/
    ├── codex-query.sh         # shared `codex responses` wrapper (streams text)
    ├── ephemeral.js           # JXA Script Filter for streaming text view
    ├── persistent.sh          # opens chatgpt.com and auto-submits
    └── terminal-cmd.sh        # generates a single shell command
```

## License

Original workflow scaffolding © Vítor Galvão / Alfred App, MIT licensed (see
[`LICENSE`](LICENSE)). New scripts and `info.plist` are also MIT.
