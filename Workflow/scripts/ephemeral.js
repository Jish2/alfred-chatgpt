#!/usr/bin/osascript -l JavaScript

// Ephemeral ChatGPT prompt for Alfred.
//
// Streams a single-shot answer from the local `codex` CLI into Alfred's
// streaming Text View. Nothing is persisted: no chat history, no follow-ups.
//
// Designed to be wired as a Script Filter -> Text View, with `rerun` driving
// the streaming loop (same pattern as the upstream chatgpt script).

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

function startStream(workflowDir, scriptPath, query, model, reasoning, system, streamFile, pidFile) {
  // Empty stream file so we can append to it.
  $.NSFileManager.defaultManager.createFileAtPathContentsAttributes(streamFile, undefined, undefined)

  const task = $.NSTask.alloc.init
  task.executableURL = $.NSURL.fileURLWithPath("/bin/bash")

  // Build env: pass model/reasoning/system through CODEX_* vars used by codex-query.sh.
  // Also extend PATH so codex/jq are discoverable from Alfred's minimal env.
  const env = $.NSProcessInfo.processInfo.environment.mutableCopy
  env.setObjectForKey(model, "CODEX_MODEL")
  env.setObjectForKey(reasoning, "CODEX_REASONING")
  env.setObjectForKey(system, "CODEX_SYSTEM")
  const existingPath = envVar("PATH")
  env.setObjectForKey(`${existingPath}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, "PATH")
  task.environment = env

  // Single-quote-escape the query for bash.
  const escaped = query.replace(/'/g, "'\\''")
  task.arguments = [
    "-c",
    `'${scriptPath}' --no-newline -q '${escaped}' > '${streamFile}' 2>&1`
  ]

  task.launchAndReturnError(false)
  writeFile(pidFile, task.processIdentifier.toString())
}

function run(argv) {
  const typedQuery = (argv[0] || "").trim()

  const workflowDir = envVar("alfred_preferences") // unused; kept for reference
  const cacheDir = envVar("alfred_workflow_cache") || "/tmp/alfred-chatgpt-cache"
  ensureDir(cacheDir)

  const streamFile = `${cacheDir}/ephemeral-stream.txt`
  const pidFile = `${cacheDir}/ephemeral-pid.txt`

  // Find the codex-query.sh script next to this file.
  // Alfred passes the workflow dir as alfred_workflow_data's parent... Easier:
  // resolve relative to the workflow bundle via $PWD when launched by Alfred.
  const pwd = envVar("PWD") || "."
  const scriptPath = `${pwd}/scripts/codex-query.sh`

  const model = envVar("codex_model") || "gpt-5.4-mini"
  const reasoning = envVar("codex_reasoning") || "low"
  const system = envVar("codex_system_ephemeral") ||
    "You are a helpful assistant. Be concise and direct. Prefer short answers and short code snippets when applicable."
  const timeoutSeconds = parseInt(envVar("codex_timeout_seconds") || "30", 10)

  const streamingNow = envVar("streaming_now") === "1"
  const streamMarker = envVar("stream_marker") === "1"

  // First call: kick off the stream.
  if (!streamingNow) {
    if (typedQuery.length === 0) {
      return JSON.stringify({
        response: "Type a question and press Return.",
        footer: "Ephemeral · ↩ Submit · ⌘↩ Copy answer · Esc Discard"
      })
    }

    // Clean any leftover state from a previous run.
    if (fileExists(streamFile)) deleteFile(streamFile)
    if (fileExists(pidFile)) deleteFile(pidFile)

    startStream(workflowDir, scriptPath, typedQuery, model, reasoning, system, streamFile, pidFile)

    return JSON.stringify({
      rerun: 0.1,
      variables: { streaming_now: "1", stream_marker: "1" },
      response: `# You\n\n${typedQuery}\n\n# Assistant\n\n`,
      behaviour: { scroll: "end" }
    })
  }

  // Streaming loop.
  if (streamMarker) {
    // First poll after launch: drop a marker so subsequent updates `replacelast`.
    return JSON.stringify({
      rerun: 0.1,
      variables: { streaming_now: "1" },
      response: "…",
      behaviour: { response: "append" }
    })
  }

  const content = readFile(streamFile)
  const pidStr = readFile(pidFile).trim()
  const pid = pidStr ? parseInt(pidStr, 10) : 0
  const alive = pid > 0 ? pidAlive(pid) : false

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
        response: `${content}\n\n[Connection stalled]`,
        footer: "codex did not produce output in time",
        behaviour: { response: "replacelast", scroll: "end" }
      })
    }

    return JSON.stringify({
      rerun: 0.1,
      variables: { streaming_now: "1" },
      response: content,
      behaviour: { response: "replacelast", scroll: "end" }
    })
  }

  // Process exited: read the final content and clean up.
  const finalText = content.length > 0 ? content : "[No response]"
  if (fileExists(streamFile)) deleteFile(streamFile)
  if (fileExists(pidFile)) deleteFile(pidFile)

  return JSON.stringify({
    response: finalText,
    behaviour: { response: "replacelast", scroll: "end" }
  })
}
