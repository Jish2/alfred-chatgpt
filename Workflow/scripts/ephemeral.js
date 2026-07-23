#!/usr/bin/osascript -l JavaScript

// Ephemeral ChatGPT prompt for Alfred (JXA reference fallback).
//
// Streams an answer from Cursor CLI into Alfred's streaming Text
// View. Kept around as a slower JXA equivalent of `ephemeral.sh`; the bash
// version is what's wired into `info.plist`. Both implementations share the
// same on-disk thread file (`ephemeral-thread.json`) so they can be swapped
// without losing in-flight context.
//
// Threads: when the user types a follow-up into the text view's input field
// (instead of dismissing and re-running `g` from Alfred), this script
// continues the same conversation rather than starting a new one. The active
// thread is identified by the `thread_id` workflow variable that Alfred
// carries across reruns and text-view input submissions; opening a brand new
// `g` invocation arrives without `thread_id` set, which resets the thread.

ObjC.import("Foundation")

function envVar(varName) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey(varName)
  return value.isNil() ? "" : value.js
}

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath(path)
}

function fileModified(path) {
  return $.NSFileManager.defaultManager
    .attributesOfItemAtPathError(path, undefined)
    .js["NSFileModificationDate"].js
    .getTime()
}

function deleteFile(path) {
  $.NSFileManager.defaultManager.removeItemAtPathError(path, undefined)
}

function writeFile(path, text) {
  $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, undefined)
}

function readFile(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, undefined)
  return s.isNil() ? "" : s.js
}

function ensureDir(path) {
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
    path, true, undefined, undefined
  )
}

function pidAlive(pid) {
  // `kill -0 PID` succeeds when the process exists, fails otherwise.
  const task = $.NSTask.alloc.init
  task.executableURL = $.NSURL.fileURLWithPath("/bin/kill")
  task.arguments = ["-0", pid.toString()]
  task.standardOutput = $.NSPipe.pipe
  task.standardError = $.NSPipe.pipe
  task.launchAndReturnError(false)
  task.waitUntilExit
  return task.terminationStatus === 0
}

// Read the on-disk thread file and parse it as `[{role, content}, ...]`.
// Returns an empty array on any read/parse failure so callers can append
// without first having to special-case "fresh thread" themselves.
function readThread(path) {
  if (!fileExists(path)) return []
  const text = readFile(path)
  if (!text) return []
  try {
    const parsed = JSON.parse(text)
    return Array.isArray(parsed) ? parsed : []
  } catch (_e) {
    return []
  }
}

function writeThread(path, messages) {
  writeFile(path, JSON.stringify(messages, null, 2))
}

// Render the conversation as Alfred-friendly markdown: alternating
// `# You` / `# Assistant` blocks separated by a blank line. Mirrors the
// helper in `ephemeral.sh` so swapping implementations doesn't change what
// the user sees in the text view.
function renderThreadMd(messages) {
  return messages
    .map(m => {
      if (m.role === "user") return `# You\n\n${m.content}`
      if (m.role === "assistant") return `# Assistant\n\n${m.content}`
      return ""
    })
    .filter(Boolean)
    .join("\n\n")
}

function startStream(scriptPath, messagesFile, model, system, streamFile, pidFile) {
  // Empty stream file so we can append to it.
  $.NSFileManager.defaultManager.createFileAtPathContentsAttributes(streamFile, undefined, undefined)

  const task = $.NSTask.alloc.init
  task.executableURL = $.NSURL.fileURLWithPath("/bin/bash")

  // Pass model/system through CURSOR_* vars used by cursor-query.sh.
  // Also extend PATH so Cursor CLI and jq are discoverable from Alfred.
  const env = $.NSProcessInfo.processInfo.environment.mutableCopy
  env.setObjectForKey(model, "CURSOR_MODEL")
  env.setObjectForKey(system, "CURSOR_SYSTEM")
  const existingPath = envVar("PATH")
  const home = envVar("HOME")
  env.setObjectForKey(
    `${existingPath}:${home}/.local/bin:${home}/.cursor/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
    "PATH"
  )
  task.environment = env

  // Single-quote-escape both paths for bash.
  const escScript = scriptPath.replace(/'/g, "'\\''")
  const escMsgs = messagesFile.replace(/'/g, "'\\''")
  const escStream = streamFile.replace(/'/g, "'\\''")
  task.arguments = [
    "-c",
    `'${escScript}' --no-newline --messages-file '${escMsgs}' > '${escStream}' 2>&1`
  ]

  task.launchAndReturnError(false)
  writeFile(pidFile, task.processIdentifier.toString())
}

function buildVars(threadId, extra) {
  const out = { thread_id: threadId }
  if (extra) Object.assign(out, extra)
  return out
}

function run(argv) {
  const typedQuery = (argv[0] || "").trim()

  const cacheDir = envVar("alfred_workflow_cache") || "/tmp/alfred-chatgpt-cache"
  ensureDir(cacheDir)

  const streamFile = `${cacheDir}/ephemeral-stream.txt`
  const pidFile = `${cacheDir}/ephemeral-pid.txt`
  const threadFile = `${cacheDir}/ephemeral-thread.json`
  const messagesFile = `${cacheDir}/ephemeral-messages.json`

  // Resolve the cursor-query.sh script next to this file.
  const pwd = envVar("PWD") || "."
  const scriptPath = `${pwd}/scripts/cursor-query.sh`

  const model = envVar("cursor_model") || envVar("codex_model") || "gpt-5.6-luna-medium"
  const system = envVar("cursor_system_ephemeral") || envVar("codex_system_ephemeral") ||
    "You are a helpful assistant. Be concise and direct. Prefer short answers and short code snippets when applicable."
  const timeoutSeconds = parseInt(envVar("cursor_timeout_seconds") || envVar("codex_timeout_seconds") || "30", 10)

  const streamingNow = envVar("streaming_now") === "1"
  let threadId = envVar("thread_id")

  // Empty submission: re-render whatever conversation we already have (or the
  // bare prompt if the thread is empty), preserving thread_id so the next
  // follow-up the user types continues the same conversation.
  if (!streamingNow && typedQuery.length === 0) {
    const existing = renderThreadMd(readThread(threadFile))
    if (threadId && existing) {
      return JSON.stringify({
        response: existing,
        footer: "Ephemeral · type a follow-up to continue · Esc Discard",
        variables: { thread_id: threadId }
      })
    }
    return JSON.stringify({
      response: "Type a question and press Return.",
      footer: "Ephemeral · ↩ Submit · ⌘↩ Copy answer · Esc Discard",
      ...(threadId ? { variables: { thread_id: threadId } } : {})
    })
  }

  // First call (new turn): kick off the stream.
  if (!streamingNow) {
    if (fileExists(streamFile)) deleteFile(streamFile)
    if (fileExists(pidFile)) deleteFile(pidFile)

    // No thread_id => Alfred re-launched us from the keyword (or this is
    // the very first run). Either way, start a fresh conversation.
    let messages
    if (!threadId || !fileExists(threadFile)) {
      threadId = `${Math.floor(Date.now() / 1000)}-${Math.floor(Math.random() * 1e6)}`
      messages = []
    } else {
      messages = readThread(threadFile)
    }

    messages.push({ role: "user", content: typedQuery })
    writeThread(threadFile, messages)

    // Snapshot the messages we'll feed to Cursor *before* the assistant
    // turn lands, so a racing follow-up can't poison context.
    writeThread(messagesFile, messages)
    startStream(scriptPath, messagesFile, model, system, streamFile, pidFile)

    const header = `${renderThreadMd(messages)}\n\n# Assistant\n\n`
    return JSON.stringify({
      rerun: 0.1,
      variables: buildVars(threadId, { streaming_now: "1" }),
      response: `${header}…`,
      behaviour: { scroll: "end" }
    })
  }

  // Streaming loop.
  const messages = readThread(threadFile)
  const historyMd = renderThreadMd(messages)
  const header = `${historyMd}\n\n# Assistant\n\n`

  const content = readFile(streamFile)
  const pidStr = readFile(pidFile).trim()
  const pid = pidStr ? parseInt(pidStr, 10) : 0
  const alive = pid > 0 ? pidAlive(pid) : false
  const body = content.length > 0 ? content : "…"

  if (alive) {
    // Detect stalled writes (no file mtime change for `timeoutSeconds`).
    const stalled = fileExists(streamFile) &&
      (new Date().getTime() - fileModified(streamFile)) > timeoutSeconds * 1000

    if (stalled) {
      // Best-effort kill.
      const kill = $.NSTask.alloc.init
      kill.executableURL = $.NSURL.fileURLWithPath("/bin/kill")
      kill.arguments = ["-TERM", pid.toString()]
      kill.launchAndReturnError(false)
      kill.waitUntilExit
      deleteFile(streamFile)
      deleteFile(pidFile)
      return JSON.stringify({
        response: `${header}${content}\n\n[Connection stalled]`,
        footer: "Cursor did not produce output in time",
        variables: buildVars(threadId),
        behaviour: { response: "replace", scroll: "end" }
      })
    }

    return JSON.stringify({
      rerun: 0.1,
      variables: buildVars(threadId, { streaming_now: "1" }),
      response: `${header}${body}`,
      behaviour: { response: "replace", scroll: "end" }
    })
  }

  // Process exited: persist the assistant turn, render final frame, clean up.
  if (content.length > 0) {
    messages.push({ role: "assistant", content })
    writeThread(threadFile, messages)
  }

  // Snapshot the completed thread to the workflow's persistent data dir so
  // the `gl` keyword (last-view.sh) can reopen the entire conversation — not
  // just the final Q&A pair from `ephemeral-history.jsonl` — and continue it
  // with a follow-up. Best-effort: any failure is swallowed.
  if (messages.length > 0) {
    const dataDir = envVar("alfred_workflow_data") || "/tmp/alfred-chatgpt-data"
    ensureDir(dataDir)
    try { writeThread(`${dataDir}/last-thread.json`, messages) } catch (_e) { /* noop */ }
  }

  let finalMd = renderThreadMd(messages)
  if (content.length === 0) {
    finalMd = `${finalMd}\n\n# Assistant\n\n[No response]`
  }

  if (fileExists(streamFile)) deleteFile(streamFile)
  if (fileExists(pidFile)) deleteFile(pidFile)
  if (fileExists(messagesFile)) deleteFile(messagesFile)

  return JSON.stringify({
    response: finalMd,
    variables: buildVars(threadId),
    behaviour: { response: "replace", scroll: "end" }
  })
}
