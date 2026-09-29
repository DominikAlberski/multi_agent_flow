<!-- >>> multi-agent-flow >>> -->
## Multi-agent coordination

This project uses a shared coordination layer for multiple coding agents
(opencode, Claude Code, Hermes, ...). Use the `coord` wrapper; do not call
`task` directly.

### Board and tasks

```
./coord init                                  # create coordination/ dirs
./coord goal add --title T                    # create a goal, branch goal/<short-id> and its worktree
./coord goal list                             # open goals with their open task count
./coord goal show ID                          # one goal and its tasks
./coord goal done ID                          # close a goal (refused while a task is open)
./coord add --role ROLE --scope S --title T [--goal ID]  # architect: add a task (prints id)
./coord annotate ID "Goal: ... Inputs: ... Out of scope: ... Acceptance: ... Report format: ..."  # architect: add the task's spec, right after `add`
./coord next [ROLE] [--wait [--interval S]]   # list unclaimed tasks (or block until a task or message appears)
./coord next --mine                           # list your in-progress tasks
./coord conflicts                             # list pending tasks with overlapping scopes
./coord claim ID [--force]                    # atomically claim for COORD_WORKER (refused for lead roles)
./coord start-task ID                         # in your worktree: check out task/<short-id> from the goal branch
./coord unclaim ID                            # release a claim without finishing it
./coord done ID [--force]                     # complete (refused while the task branch lacks the goal head)
./coord annotate ID TEXT                      # task-scoped update
./coord status                                # per-role summary
./coord who                                   # each worker with its presence: live or gone
./coord board                                 # regenerate Obsidian kanban
./coord worktree ROLE [WORKER]                # git worktree in .worktrees/<role>-<worker> + branch
                                              # in it: `source coord-env.sh` to share this board
                                              # and to get this worktree's COORD_SLOT
```

A claim with no activity for `COORD_LEASE_TTL` seconds (default 4 hours) is
presumed abandoned: `next` and `claim` treat it as unclaimed again, no
`--force` needed. If you stop work on a claimed task without finishing it,
run `coord unclaim ID` instead of leaving it to expire.

### Roles and workers

- `role` is the project function: `backend-developer`. A task belongs to a role.
- `worker` is one instance of a role: `backend-1`, `backend-2`.
- An agent is one harness session that runs a role as a worker. See GLOSSARY.md.
- Set `COORD_ROLE` to the role and `COORD_WORKER` to a unique worker id.
- `claim` is atomic (per-task lock). Two workers racing one task → exactly one wins.
- The architect creates tasks for a role and does not need to know how many
  instances exist. Run one instance per role unless you set `COORD_WORKER`.
- Hierarchy (if `project-manager` is one of the installed roles): the user
  talks to the project manager. The project manager creates each goal with
  `coord goal add` and sends the goal id to the architect (`coord msg --from project-manager architect "..."`). The
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
./coord broadcast --from A "text"            # send to every worker role except the sender
./coord broadcast --from A --to all "text"   # also reach the project manager and the architect
./coord inbox [AGENT]                         # read your messages (marks them read)
./coord inbox --peek                          # read without marking read
./coord inbox --all                           # include already-read messages
./coord log [N]                               # show last N coordination events
```

Read messages move to `coordination/inbox/<agent>/read/`.
`coord broadcast` reaches every role that owns a pending task or is listed in
`.agent-flow.json`, except the sender. `--to` selects the group: `workers`
(default), `leads` (project manager and architect), or `all`.
`coord msg` and `coord broadcast` fire a per-role hook at
`coordination/message-hooks/<role>.sh` if one is installed. The hook is a plain shell
script. It gets `COORD_ROLE`, `COORD_FROM`, and `COORD_MSG_FILE` in its
environment, and the message file path as `$1`. It runs in the background and
logs to `coordination/message-hooks/<role>.log`. Use it to start a one-shot run
or to send a notification. `coord` does not know
which harness the agent runs in.
`coord log` shows claims, completions, unclaims, messages, and broadcasts from
`coordination/events.log`. Any agent can read this shared history without
opening individual inboxes.
If a `./dispatcher` serves your role, the dispatcher gives you your messages
in the prompt. Do not run `coord inbox` in that case.

`coord who` lists each worker from `coordination/presence/`. `maf start`
records the session pid. The dispatcher records its own pid. A worker is
live while its pid runs. If a receiver role has no live worker and no
message hook, `coord msg` prints a warning. The message then waits until a
session for that role starts. Start a dispatcher for that role, or add a hook.

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
   After a claim, run `coord start-task ID`. The command checks out branch
   `task/<short-id>` from the goal branch. Commit the work on that branch.
   Each goal starts from the base branch, never from another goal branch.
2. One writer per path. The task `scope` defines the paths you own. This is a
   convention `coord add`/`conflicts` warns about, not a lock the filesystem
   enforces. A role with `can_edit: false` (reviewer, architect, project
   manager) gets a read-only tool grant where the harness supports one.
   The git `pre-commit` hook refuses a commit by such a role.
3. Acquire the `ollama` lock before any local generation.
4. If the task has a goal, merge the goal branch into the task branch
   (`git merge goal/<goal-short-id>`). `coord done` refuses a task branch
   that lacks the goal branch head. Before you report, run the task tests (see "Tests and shared resources").
   Check the task's acceptance criteria.
   If the task spec has a Report format, use it. Otherwise report with
   `coord annotate ID "STATUS: done or blocked. FILES: <paths>.
   TESTS: <one-line result>. NOTES: <assumptions or risks>"`. Ask other
   agents with `coord msg`.
5. Finish the whole task. Report done only when each acceptance criterion
   passes. If you cannot finish a task, do the parts you can. Keep the claim.
   Annotate the blocker and the missing parts. Message the architect. Stop. Do not retry a failing approach. Do not
   `unclaim` a blocked task — that returns it to the pool for another worker
   to hit the same wall.
6. The architect inspects a done task's diff in the worker's worktree
   (`git -C .worktrees/<role>-<worker> diff`) and the TESTS line of the
   report before trusting it. The architect does not rerun the task tests.
   A bad result gets a new fix task, not a silent re-close.
7. Prefer the shared knowledge graph over grep when `graphify-out/` exists
   (query it via MCP or `graphify query "..."`).
8. Worker roles: if no task is available, use `coord next --wait` instead of
   a manual poll loop. Lead roles (project manager, architect) never claim a
   task. A lead role waits with `coord inbox --wait`. `coord claim` and
   `coord next --wait` refuse a lead role.
9. Write `coord msg`, `coord annotate`, and task titles in Simplified
   Technical English: one instruction per sentence, active voice, name the
   subject, max 20 words per sentence, no idioms.
10. Never write ad-hoc verification scripts. The test suite is the
    verification.
11. Do the work yourself. Start a subagent only for a large, independent
    search that you cannot finish in a few tool calls. Do not use subagents
    to verify your work.

### Tests and shared resources

- Task tests: the unit tests and the tests for the changed behavior.
  The worker runs the task tests before the report.
- Merge suite: the full suite, with system tests.
  The architect runs the merge suite one time per goal, after the merge and
  before the pull request. Nobody else runs the merge suite.
- The reviewer does not run tests. The reviewer reads the TESTS line.
- Run each command that needs a shared resource (browser, system tests,
  one fixed port) under one lock name:
  `./coord with-lock system-test -- <command>`. Do not invent other lock names.
- Each worktree has a unique `COORD_SLOT` in `coord-env.sh`. The main
  worktree is slot 0. If `coordination/worktree-env.rb` exists, `coord worktree`
  adds its `export` lines to `coord-env.sh`. Use this hook for a unique test
  database and server port per worktree. Do not share a test database.

### Shared memory

- The vault script controls the graphify watcher. It is named `./vault`,
  or `./vault-daemon` if a `vault/` directory already existed at install
  time. `status` / `stop` report or stop the watcher; `export` regenerates
  the Obsidian vault once. Bootstrap starts the watcher automatically when
  `graphify` is on PATH.
- `obsidian/` is the Obsidian knowledge base: graphify's regenerated code graph
  plus any notes you add there. It is gitignored and rebuilt, so nothing you
  need to keep permanently belongs there. MCP is served by the separate
  `graphify-mcp` process (vault script's `mcp` subcommand), not by the watcher.
- The decisions folder holds architecture decisions (ADRs) and is the durable,
  git-tracked record. Use `.agent/decisions/` if it exists, else `docs/decisions/`.
  Append, never rewrite history.
- Containerized agents (e.g. `coi`) need `coordination/`, `coord`, and
  `coordination/taskrc` mounted from the host; they do not share state with
  the host or each other unless that filesystem is shared.
<!-- <<< multi-agent-flow <<< -->
