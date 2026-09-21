<!-- >>> multi-agent-flow >>> -->
## Multi-agent coordination

This project uses a shared coordination layer for multiple coding agents
(opencode, Claude Code, Hermes, ...). Use the `coord` wrapper; do not call
`task` directly.

### Board and tasks

```
./coord init                                  # create coordination/ dirs
./coord add --agent ROLE --scope S --title T  # architect: add a task (prints id)
./coord next [ROLE] [--wait [--interval S]]   # list unclaimed tasks (or block until one appears)
./coord next --mine                           # list your in-progress tasks
./coord conflicts                             # list pending tasks with overlapping scopes
./coord claim ID [--force]                    # atomically claim for COORD_WORKER
./coord unclaim ID                            # release a claim without finishing it
./coord done ID                               # complete
./coord annotate ID TEXT                      # task-scoped update
./coord status                                # per-role summary
./coord board                                 # regenerate Obsidian kanban
./coord worktree ROLE [WORKER]                # create a git worktree + branch for a role
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
./coord inbox [AGENT]                         # read your messages (marks them read)
./coord inbox --peek                          # read without marking read
./coord inbox --all                           # include already-read messages
```

Read messages move to `coordination/inbox/<agent>/read/`.

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
   enforces — a role whose duties say "never edit" (reviewer, architect) also
   gets a read-only tool grant where the harness supports one; other roles
   rely on scope discipline.
3. Acquire the `ollama` lock before any local generation.
4. Report progress with `coord annotate`; ask other agents with `coord msg`.
5. Prefer the shared knowledge graph over grep when `graphify-out/` exists
   (query it via MCP or `graphify query "..."`).
6. If no task is available, use `coord next --wait` (or `coord inbox --wait`)
   instead of a manual poll loop.

### Shared memory

- `vault/` is the Obsidian knowledge base: graphify's regenerated code graph
  plus any notes you add there. It is gitignored and rebuilt, so nothing you
  need to keep permanently belongs there.
- `docs/decisions/` holds architecture decisions (ADRs) and is the durable,
  git-tracked record. Append, never rewrite history.
- Containerized agents (e.g. `coi`) need `coordination/`, `coord`, and
  `coordination/taskrc` mounted from the host; they do not share state with
  the host or each other unless that filesystem is shared.
<!-- <<< multi-agent-flow <<< -->
