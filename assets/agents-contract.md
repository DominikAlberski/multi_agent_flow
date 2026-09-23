<!-- >>> multi-agent-flow >>> -->
## Multi-agent coordination

This project uses a shared coordination layer for multiple coding agents
(opencode, Claude Code, Hermes, ...). Use the `coord` wrapper; do not call
`task` directly.

### Board and tasks

```
./coord init                                  # create coordination/ dirs
./coord add --agent ROLE --scope S --title T  # architect: add a task (prints id)
./coord annotate ID "Goal: ... Inputs: ... Acceptance: ..."  # architect: add the task's spec, right after `add`
./coord next [ROLE] [--wait [--interval S]]   # list unclaimed tasks (or block until one appears)
./coord next --mine                           # list your in-progress tasks
./coord conflicts                             # list pending tasks with overlapping scopes
./coord claim ID [--force]                    # atomically claim for COORD_WORKER
./coord unclaim ID                            # release a claim without finishing it
./coord done ID                               # complete
./coord annotate ID TEXT                      # task-scoped update
./coord status                                # per-role summary
./coord board                                 # regenerate Obsidian kanban
./coord worktree ROLE [WORKER]                # git worktree in <project>.worktrees/ + branch
                                              # in it: `source coord-env.sh` to share this board
```

A claim with no activity for `COORD_LEASE_TTL` seconds (default 4 hours) is
presumed abandoned: `next` and `claim` treat it as unclaimed again, no
`--force` needed. If you stop work on a claimed task without finishing it,
run `coord unclaim ID` instead of leaving it to expire.

### Roles and workers

- `agent` is the **role** (pool): `backend-developer`.
- `worker` is the **instance**: `backend-1`, `backend-2`.
- Set `COORD_AGENT` to the role and `COORD_WORKER` to a unique instance id.
- `claim` is atomic (per-task lock). Two workers racing one task → exactly one wins.
- The architect creates tasks for a role and does not need to know how many
  instances exist. Run one instance per role unless you set `COORD_WORKER`.
- Hierarchy (if `project-manager` is one of the installed roles): the user
  talks to the project manager. The project manager sends one goal at a time
  to the architect (`coord msg --from project-manager architect "..."`). The
  architect decomposes the goal into tasks, dispatches them, and reports the
  outcome back to the project manager. Workers and the architect never talk
  to the user directly.

`add` prints a warning on stderr when the new scope overlaps a pending task
owned by another agent. Fix the overlap before work starts. Run `coord conflicts`
to see all overlaps. The check is a path-prefix heuristic: it understands
`dir/**` and exact paths, not `{}` alternation or mid-path globs.

`claim` refuses to steal an active (non-expired) task owned by another agent.
Use `--force` only if you must take over sooner than the lease. Either way,
the task's prior holder gets a message in their inbox naming who took it.

### Messaging

```
./coord msg --from A TO "text"                # leave a message for another agent
./coord broadcast --from A "text"            # send to every known role except the sender
./coord inbox [AGENT]                         # read your messages (marks them read)
./coord inbox --peek                          # read without marking read
./coord inbox --all                           # include already-read messages
./coord log [N]                               # show last N coordination events
```

Read messages move to `coordination/inbox/<agent>/read/`.
`coord broadcast` reaches every role that owns a pending task or is listed in
`.agent-flow.json`, except the sender.
`coord msg` and `coord broadcast` fire a per-role hook at
`coordination/hooks/<role>.sh` if one is installed. The hook is a plain shell
script. It gets `COORD_AGENT`, `COORD_FROM`, and `COORD_MSG_FILE` in its
environment, and the message file path as `$1`. It runs in the background and
logs to `coordination/hooks/<role>.log`. Use it to poke a running agent
session, start a one-shot run, or send a notification. `coord` does not know
which harness the agent runs in.
`coord log` shows claims, completions, unclaims, messages, and broadcasts from
`coordination/events.log`. Any agent can read this shared history without
opening individual inboxes.
If a `./dispatcher` serves your role, the dispatcher gives you your messages
in the prompt. Do not run `coord inbox` in that case.

### Resource locks

Only one local-model generation may run at a time on the shared Ollama host.

```
./coord with-lock ollama -- <command>         # hard mutual exclusion
./coord lock ollama --ttl 3600                # advisory, long-running
./coord unlock ollama
```

### Rules

1. Work in your own git worktree or branch (`coord worktree ROLE` creates one).
   In a worktree, run `source coord-env.sh` once so `COORD_DIR`/`TASKRC` point at
   the main project and every worktree shares one board.
   Never edit outside your task scope.
2. One writer per path. The task `scope` defines the paths you own. This is a
   convention `coord add`/`conflicts` warns about, not a lock the filesystem
   enforces — a role whose duties say "never edit" (reviewer, architect,
   project manager) also gets a read-only tool grant where the harness
   supports one; other roles rely on scope discipline.
3. Acquire the `ollama` lock before any local generation.
4. Before you report, run the tests. Check the task's acceptance criteria.
   Report with `coord annotate ID "STATUS: done or blocked. FILES: <paths>.
   TESTS: <one-line result>. NOTES: <assumptions or risks>"`. Ask other
   agents with `coord msg`.
5. If you cannot finish a task, keep the claim. Annotate the blocker.
   Message the architect. Stop. Do not retry a failing approach. Do not
   `unclaim` a blocked task — that returns it to the pool for another worker
   to hit the same wall.
6. The architect inspects a done task's diff and reruns its tests in the
   worker's worktree (`git -C ../<project>.worktrees/<role>-<worker> diff`)
   before trusting it. A bad result gets a new fix task, not a silent
   re-close.
7. Prefer the shared knowledge graph over grep when `graphify-out/` exists
   (query it via MCP or `graphify query "..."`).
8. If no task is available, use `coord next --wait` (or `coord inbox --wait`)
   instead of a manual poll loop.
9. Write `coord msg`, `coord annotate`, and task titles in Simplified
   Technical English: one instruction per sentence, active voice, name the
   subject, max 20 words per sentence, no idioms.
10. Never write ad-hoc verification scripts. The test suite is the
    verification.

### Shared memory

- `./vault status` / `./vault stop` control the graphify watcher; `./vault export`
  regenerates the Obsidian vault once. Bootstrap starts the watcher
  automatically when `graphify` is on PATH.
- `obsidian/` is the Obsidian knowledge base: graphify's regenerated code graph
  plus any notes you add there. It is gitignored and rebuilt, so nothing you
  need to keep permanently belongs there. MCP is served by the separate
  `graphify-mcp` process (`./vault mcp`), not by the watcher.
- `docs/decisions/` holds architecture decisions (ADRs) and is the durable,
  git-tracked record. Append, never rewrite history.
- Containerized agents (e.g. `coi`) need `coordination/`, `coord`, and
  `coordination/taskrc` mounted from the host; they do not share state with
  the host or each other unless that filesystem is shared.
<!-- <<< multi-agent-flow <<< -->
