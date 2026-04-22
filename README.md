# <img src='Workflow/icon.png' width='45' align='center' alt='icon'> Alfred ChatGPT (codex)

Four lightweight ChatGPT modes for Alfred, all powered by the local
[`codex`](https://github.com/openai/codex) CLI. Uses your **ChatGPT
subscription** through the OpenAI Responses API — **no API key required**.

> Forked from [`alfredapp/openai-workflow`](https://github.com/alfredapp/openai-workflow).
> The original API-key + chat-history + DALL·E machinery has been removed in
> favor of focused modes wired through `codex`.

## Modes

| Keyword (default) | Mode | Behavior |
|---|---|---|
| `g  <query>` | **Ephemeral** | Streams a one-shot answer into Alfred's text view. The completed Q&A is also appended to a local history file (toggleable). |
| `gg <query>` | **Persistent** | Opens [`chatgpt.com/?prompt=…`](https://chatgpt.com/) and auto-presses Return so the prompt is sent in your real ChatGPT conversation history. |
| `gt <query>` | **Terminal command** | Generates a single shell command and pastes it at the cursor of your frontmost terminal — like Cursor's <kbd>⌘</kbd><kbd>K</kbd>. |
| `gh [query]` | **History** | Browse past ephemeral Q&A pairs. Fuzzy-search by question or answer; <kbd>↩</kbd> opens the saved markdown in a Text View, <kbd>⌘</kbd><kbd>↩</kbd> copies just the answer. |

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

- **Ephemeral / Persistent / Terminal / History Keyword** — defaults `g`, `gg`, `gt`, `gh`.
- **Enable Ephemeral History** — when on (default), every completed ephemeral
  answer is appended to `$alfred_workflow_data/ephemeral-history.jsonl`. Turn
  it off to keep ephemeral truly ephemeral.
- **History Max Entries** — defaults to `200`. Older entries are pruned in
  FIFO order. Set `0` to keep everything (and manage the file yourself).
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
- **Open iTerm Floating Window (gt)** *(optional)* — when enabled, the terminal
  command generator simulates <kbd>⇧</kbd><kbd>Esc</kbd> just before Alfred
  pastes, popping iTerm's floating hotkey window so the command lands there
  instead of whatever app was previously frontmost. Configure the matching
  hotkey under *iTerm → Settings → Keys → Hotkey → Show/hide all windows with a
  system-wide hotkey* (set it to <kbd>⇧</kbd><kbd>Esc</kbd>).
- **iTerm Floating Window Delay (s)** — seconds to wait after triggering the
  hotkey before pasting. Defaults to `0.18`. Bump up if the floating window
  animation is slow on your machine.

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

### 3. History (`gh`)

```
Script Filter (gh [query]) ──► Text View
```

`scripts/history-filter.sh` reads
`$alfred_workflow_data/ephemeral-history.jsonl` (newest line last, written by
`scripts/history-record.sh`), reverses it so the most recent answer is on
top, and emits one Alfred item per Q&A pair. Alfred fuzzy-matches your typed
text against the question + answer (`alfredfiltersresults: true`).

Selecting an item forwards a pre-rendered markdown body via `arg` to
`scripts/history-view.sh`, which echoes it back into the Text View. ⌘↩ on a
result copies just the answer; ⌘L pops it in Large Type via the `text`
field.

History is appended automatically by `scripts/ephemeral.sh` once the
streaming `codex` process exits cleanly. Disable via the **Enable Ephemeral
History** checkbox if you prefer the old "nothing is saved" behaviour. To
nuke the history manually:

```sh
rm -f "$(osascript -e 'tell application "Alfred" to get path to workflow data folder for "com.jgoon.alfred-chatgpt"')/ephemeral-history.jsonl"
```

### 4. Terminal command (`gt`)

```
Keyword (gt <query>) ──► Run Script ──► Copy to Clipboard (auto-paste)
```

`scripts/terminal-cmd.sh` calls `codex-query.sh` with a strict system prompt
that forbids prose and code fences, then post-processes the output to strip
any stray fences or `$`/`sh ` prefixes. The clipboard output node is set to
**transient** + **auto-paste**, so the command lands at your terminal cursor
and isn't kept on the clipboard afterward.

If **Open iTerm Floating Window (gt)** is enabled, the script also fires
<kbd>⇧</kbd><kbd>Esc</kbd> via System Events (`key code 53 using {shift down}`)
and sleeps for `iterm_floating_delay_sec` seconds before returning, giving
iTerm's hotkey window time to come forward and grab focus before Alfred's
auto-paste lands.

## Repository layout

```
Workflow/
├── icon.png
├── info.plist                 # Alfred workflow definition
└── scripts/
    ├── codex-query.sh         # shared `codex responses` wrapper (streams text)
    ├── ephemeral-filter.js    # JXA Script Filter (returns the items JSON)
    ├── ephemeral.sh           # bash Text View input (streams the answer; live polling)
    ├── ephemeral.js           # JXA Text View input (kept as reference fallback)
    ├── history-record.sh      # appends completed ephemeral Q&A pairs to JSONL
    ├── history-filter.sh      # Script Filter listing past ephemeral entries
    ├── history-view.sh        # Text View input: renders a saved entry
    ├── persistent.sh          # opens chatgpt.com and auto-submits
    └── terminal-cmd.sh        # generates a single shell command
```

## License

Original workflow scaffolding © 2024 Running with Crayons Ltd (Alfred App),
BSD 3-Clause licensed (see [`LICENSE`](LICENSE)). Modifications and new
scripts in this fork are © 2026 jgoon and released under the same BSD
3-Clause license.
