// board-watch-opencode.js - opencode plugin that wakes an idle session when the board has work.
//
// opencode loads this file from .opencode/plugins/board-watch.js. When a
// top-level session goes idle, the plugin checks the board at once and then
// every BOARD_WATCH_INTERVAL seconds (default 60). Each check runs
// .maf/coordination/harness-hooks/board-watch.rb --once. If the script exits 2,
// the plugin sends the script output to the session as a new prompt. When a
// session is busy again, the checks stop.
//
// board-watch.rb owns the board rules and the poke backoff.
// Required env: COORD_ROLE (set by maf start). COORD_DIR and TASKRC optional.
// The plugin does nothing if COORD_DISPATCHED is set: the dispatcher owns
// the loop for dispatched agents.
import { execFile } from "node:child_process"
import path from "node:path"

const WAKE = 2

const server = async ({ client, directory }) => {
  const role = process.env.COORD_ROLE || ""
  if (!role || role === "unknown" || process.env.COORD_DISPATCHED) return {}

  const script = path.join(directory, ".maf", "coordination", "harness-hooks", "board-watch.rb")
  // Same rule as board-watch.rb: a whole number of seconds, else 60.
  const raw = (process.env.BOARD_WATCH_INTERVAL || "").trim()
  const interval = (/^\d+$/.test(raw) ? Number(raw) : 60) * 1000
  let watched = null

  const log = (message) =>
    client.app.log({ body: { service: "board-watch", level: "error", message } }).catch(() => {})

  // Returns the poke prompt, or null when the board has no work that is due.
  // If ruby or the script fails, the plugin logs the error.
  const check = () =>
    new Promise((resolve) => {
      execFile("ruby", [script, "--once"], { cwd: directory }, (error, stdout, stderr) => {
        if (error && error.code !== WAKE) log(`${script} --once failed: ${stderr.trim() || error.message}`)
        resolve(error?.code === WAKE ? stdout.trim() : null)
      })
    })

  const stop = () => {
    clearTimeout(watched?.timer)
    watched = null
  }

  const poke = (id, text) =>
    client.session
      .promptAsync({ path: { id }, body: { agent: role, parts: [{ type: "text", text }] } })
      .catch(() => {})

  // Each watch gets a new entry. A check that ends after stop() or after a
  // new watch sees a different entry and does nothing.
  const tick = async (entry) => {
    const prompt = await check()
    if (watched !== entry) return
    if (!prompt) {
      entry.timer = setTimeout(() => tick(entry), interval)
      return
    }
    stop()
    await poke(entry.id, prompt)
  }

  // A subagent session (for example explore) has a parent. Only the
  // top-level session runs the work loop.
  const watch = async (id) => {
    const session = await client.session.get({ path: { id } }).catch(() => null)
    if (!session?.data || session.data.parentID) return
    stop()
    watched = { id, timer: null }
    tick(watched)
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") return watch(event.properties.sessionID)
      if (event.type === "session.status" && event.properties.status.type !== "idle") return stop()
      if (event.type === "session.deleted" && event.properties.info?.id === watched?.id) return stop()
    },
  }
}

export default { id: "multi-agent-flow-board-watch", server }
