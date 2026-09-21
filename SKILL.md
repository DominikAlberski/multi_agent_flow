---
name: multi-agent-flow
description: Use when setting up or running multiple coding agents (opencode, Claude Code, Hermes, Codex) on one project and they need shared task state, messaging, resource locks, and a shared knowledge base. Installs a Taskwarrior-backed `coord` CLI, a coordination/ directory, an agent contract, and a graphify/Obsidian knowledge base into a target project.
---

# Multi-agent flow

Portable coordination layer for running several coding agents in parallel on one
repository, each in its own terminal, without them colliding.

For a first-time user, read `GETTING_STARTED.md` first. It is a step-by-step
walkthrough with a full worked example.

For the fastest setup, read and implement `install.md`: it asks the user which
harnesses and roles to use, then runs `scripts/flow.rb` to generate the agent
files and the coordination layer.

Three pillars:

1. **Agents** — independent terminals (Warp panes, Kepler, `coi` containers).
   A container only shares state with the host if `coordination/`, `coord`,
   and `coordination/taskrc` are mounted into it; nothing shares automatically.
2. **Communication** — Taskwarrior task board + `coordination/` inbox, driven by the
   `coord` wrapper. Works from any harness because it is only CLI + files.
3. **Shared memory** — a graphify knowledge graph + Obsidian vault, queryable over MCP.

## Prerequisites

- Ruby 3.x (the `coord` CLI and the installer are Ruby scripts).
- `task` (Taskwarrior) on PATH. macOS: `brew install task`.
- Optional: `graphify` for the knowledge base.
- Git (worktrees recommended; one branch/worktree per agent).

No `jq` needed: `coord` parses the Taskwarrior JSON itself.

## Install into a project

Run the bundled bootstrap. Paths below are relative to this skill directory.

```sh
./assets/bootstrap.rb /path/to/project --roles architect,backend-developer,frontend-developer,reviewer,tester
```

Flags: `--check` (preview, write nothing), `--install-deps` (install missing
required tools), `--force` (overwrite a foreign `coord`).

It creates and never destroys:

- `coordination/{inbox,locks,exports,taskdata}/`
- `coord`, `setup_agent`, and `vault` (executable) at the project root; `vault`
  is also started automatically if `graphify` is on PATH (see Shared memory)
- `coordination/taskrc`: a project-local Taskwarrior config (own database,
  under `coordination/taskdata`) plus the UDA block — never the user's
  global `~/.taskrc`, so two projects never share one board
- a "Multi-agent coordination" contract appended to `AGENTS.md`, and to
  `CLAUDE.md` if that file exists (`scripts/flow.rb` creates it first when a
  `claude` agent was requested; bootstrap alone never invents it)
- `.gitignore` entries (marker-guarded)

Re-running is safe: the installer is idempotent. It compares file contents and
checks marker blocks, so it skips anything already present, updates `coord` only
when it changed, and never duplicates the contract, `.gitignore`, or `.taskrc`
blocks. Dependencies are detected, not blindly installed. If it finds an
older, global `~/.taskrc` install, it prints a one-time migration note instead
of silently stranding those tasks.

## Verify

```sh
cd /path/to/project
./coord init
./coord add --agent local --scope "test/**" --title "example task"
./coord status
./coord board          # writes coordination/exports/board.md
```

## Launch an agent

```sh
./setup_agent HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
./setup_agent claude architect
./setup_agent opencode backend-developer_1 model:openrouter/deepseek-v3
```

One command: creates or reuses the agent's worktree, exports
`COORD_DIR`/`TASKRC`/`COORD_AGENT`/`COORD_WORKER`, then execs the harness
there. For `opencode`/`codex` this loads the role file automatically via
`--agent`/`.codex/prompts/<role>.md`; for `claude`, which does not auto-load
`.claude/agents/<role>.md` into an interactive session, it passes an initial
prompt telling the session to read and follow that file. `HARNESS:ROLE` must
already be in `.agent-flow.json` (`scripts/flow.rb --agent HARNESS:ROLE`
adds one); `WORKER` defaults to `1`. No launcher yet for `hermes` — open its
session by hand (see Notes below).

## How agents use it

Set `COORD_AGENT` so messages and locks are attributed:

```sh
export COORD_AGENT=local
./coord claim <id> local
./coord annotate <id> "working on it"
./coord msg --from local deepseek "review test/foo.rb when free"
./coord inbox local
./coord done <id>
```

Commands: `init, add, claim, unclaim, done, annotate, msg, inbox, lock, unlock,
with-lock, worktree, status, board, export`.

A claim idle past `COORD_LEASE_TTL` seconds (default 4 hours) is treated as
abandoned: `next`/`claim` reclaim it without `--force`. Use `coord unclaim`
to release one on purpose. `coord next --wait` / `coord inbox --wait` block
at a fixed interval instead of a hand-rolled poll loop.

## Resource locks

A single local-model host can only serve one generation at a time. Serialize:

```sh
./coord with-lock ollama -- opencode run --agent local "..."
./coord lock ollama --ttl 3600   # advisory, for long interactive runs
./coord unlock ollama
```

Locks are `mkdir`-based, so they work on macOS and Linux without `flock`.

## Shared memory

`bootstrap.rb` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time:

```sh
./vault           # start (no-op if already running); bootstrap.rb runs this for you
./vault status
./vault stop
```

It wraps `graphify . --obsidian --obsidian-dir vault --watch --mcp`, run as a
detached background process, with its pid in `coordination/vault.pid` and its
output in `coordination/vault.log`. If `graphify` was not installed yet, run
`./vault` by hand once it is.

- Agents query the graph over MCP or `graphify query "..."` instead of grepping.
- `vault/` is the human-facing Obsidian base (graph notes, the board). It is
  regenerated and gitignored — durable decisions belong in `docs/decisions/`,
  not here.
- `./coord board` regenerates `coordination/exports/board.md`; open the vault to see
  the task board and the code graph together.

## Operating rules (also written into the project contract)

1. One writer per path; the task `scope` defines ownership. This is a
   convention `coord` warns about, not an enforced lock; roles whose duties
   say "never edit" also get a restricted tool grant where the harness
   supports one.
2. Work in a per-agent branch or git worktree (`coord worktree ROLE`, or
   `setup_agent HARNESS ROLE` which also does this). Worktrees live under one
   sibling folder, `<project>.worktrees/<role>`. In the worktree, run
   `source coord-env.sh` so `COORD_DIR`/`TASKRC` point at the main project
   and every worktree shares one coordination/ dir and board.
3. Acquire the `ollama` lock before any local generation.
4. Record decisions in `docs/decisions/`; append, never rewrite. `vault/` is
   regenerated graphify output, not a durable store.
5. Report via `coord annotate`; coordinate via `coord msg`.
6. If no task is available, use `coord next --wait` instead of polling by hand.

## Notes

- Run `ruby scripts/check.rb` after editing the UDA block or markers. It keeps
  the duplicated UDA definition in `coord` and `taskrc.append` in sync.
- Run `ruby test/coord_test.rb` after changing `assets/coord`'s behavior.
- Taskwarrior is the source of truth, in a project-local database
  (`coordination/taskdata`); `coord board`/`export` are projections.
- Containerized agents (e.g. `coi`) need `coordination/`, `coord`, and
  `coordination/taskrc` mounted from the host — they share nothing across a
  container boundary on their own.
- Multi-machine sync (Taskserver) is optional and out of scope here.
- Hermes has no `setup_agent` launcher yet: open its session by hand, set
  `COORD_AGENT`/`COORD_WORKER`, and paste the work loop from "How agents use it".
- If a GUI is wanted later, point Obsidian (Kanban + Dataview) or `taskwarrior-tui`
  at the same data; no agent changes required.
