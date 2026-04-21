#!/usr/bin/osascript -l JavaScript

// Script Filter for the ephemeral ChatGPT prompt.
//
// Returns a single Alfred Script Filter item that forwards the typed query to
// the downstream Text View, which is where `scripts/ephemeral.js` actually
// streams the answer from the local `codex` CLI.
//
// Kept intentionally tiny: a Script Filter MUST return `items` / `variables` /
// `rerun(after)`, so we cannot reuse `ephemeral.js` here (that script returns
// Text View JSON like `response` / `behaviour`, which Alfred rejects from a
// Script Filter with: "JSON is missing expected keys; items, variables or
// rerunafter").

function run(argv) {
  const query = (argv[0] || "").trim()

  if (query.length === 0) {
    return JSON.stringify({
      items: [{
        title: "Ask ChatGPT (ephemeral)",
        subtitle: "Type a question and press Return…",
        valid: false
      }]
    })
  }

  return JSON.stringify({
    items: [{
      title: query,
      subtitle: "Stream the answer in Alfred · ↩ Submit",
      arg: query,
      valid: true,
      mods: {
        cmd: {
          subtitle: "⌘↩ Copy answer once it streams in",
          arg: query,
          valid: true
        }
      }
    }]
  })
}
