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
harnesses and roles to use, then runs `maf add` to generate the agent files
and the coordination layer.

Three pillars:

1. **Agents** — independent terminals (Warp panes, Kepler, `coi` containers).
   A container only shares state with the host if `coordination/`, `coord`,
   and `coordination/taskrc` are mounted into it; nothing shares automatically.
2. **Communication** — Taskwarrior task board + `coordination/` inbox, driven by the
   `coord` wrapper. Works from any harness because it is only CLI + files.
3. **Shared memory** — a graphify knowledge graph + Obsidian vault, queryable over MCP.

## Prerequisites

- Ruby 3.0+ (the `coord` CLI and the installer are Ruby scripts using endless
  method definitions; they will not parse under Ruby 2.x).
  macOS: `brew install mise && mise install ruby`.
- `task` (Taskwarrior) on PATH. macOS: `brew install task`.
- Optional: `graphify` for the knowledge base.
- Git (worktrees recommended; one branch/worktree per agent).

No `jq` needed: `coord` parses the Taskwarrior JSON itself.

## Install into a project

Link `bin/maf` from this skill directory into a folder on `PATH` once:

```sh
ln -sf "$PWD/bin/maf" ~/.local/bin/maf
```

Then run `maf` in the project root. The project is the current directory.

```sh
maf roles                                           # list the roles
maf add claude:architect opencode:backend-developer # add agents, install the flow
maf add opencode:tester                             # add one more agent later
maf remove opencode:tester                          # remove an agent
maf agents                                          # list the current agents
maf update                                          # regenerate the current agents
```

Flags for `maf add`: `--check` (preview, write nothing), `--force` (overwrite a
foreign `coord`), `--model ROLE=MODEL`. `maf add` keeps the current agents in
`.agent-flow.json`.

It creates and never destroys:

- `coordination/{inbox,locks,exports,taskdata}/`
- `coord`, `dispatcher`, and `vault` (executable) at the project root; `vault`
  is also started automatically if `graphify` is on PATH (see Shared memory)
- `coordination/taskrc`: a project-local Taskwarrior config (own database,
  under `coordination/taskdata`) plus the UDA block — never the user's
  global `~/.taskrc`, so two projects never share one board
- a "Multi-agent coordination" contract appended to `AGENTS.md`, the only
  instruction file; `maf add` moves the text of an existing `CLAUDE.md` or
  `.claude/CLAUDE.md` into `AGENTS.md` and deletes that file, because Claude
  Code reads `AGENTS.md` only when no `CLAUDE.md` exists
- `.gitignore` entries (marker-guarded)

Re-running is safe: the installer is idempotent. It compares file contents and
checks marker blocks, so it skips anything already present, updates `coord` only
when it changed, and never duplicates the contract, `.gitignore`, or `.taskrc`
blocks. Dependencies are detected, not blindly installed. If it finds an
older, global `~/.taskrc` install, it prints a one-time migration note instead
of silently stranding those tasks.

## Uninstall

```sh
maf uninstall --check   # preview
maf uninstall           # asks, then removes
```

Removes only files that carry the flow signature or marker. Keeps
`graphify-out/`, `obsidian/`, `worker/*` branches, and dirty worktrees
(`--force` removes those worktrees).

## Verify

```sh
cd /path/to/project
./coord init
./coord add --role local --scope "test/**" --title "example task"
./coord status
./coord board          # writes coordination/exports/board.md
```

## Launch an agent

```sh
maf start HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
maf start claude architect
maf start opencode backend-developer_1 model:openrouter/deepseek-v3
maf start hermes tester --dispatch   # unattended: runs ./dispatcher in the worktree
```

One command: creates or reuses the agent's worktree, exports
`COORD_DIR`/`TASKRC`/`COORD_ROLE`/`COORD_WORKER`, then execs the harness
there. For `opencode`/`codex` this loads the role file automatically via
`--agent`/`.codex/prompts/<role>.md`; for `claude`, which does not auto-load
`.claude/agents/<role>.md` into an interactive session, it passes an initial
prompt telling the session to read and follow that file; for `hermes`, it
loads the role as a skill via `--skills <project>-<role>`. `HARNESS:ROLE` must
already be in `.agent-flow.json` (`maf add HARNESS:ROLE` adds one); `WORKER` defaults to `1`.

## How agents use it

Set `COORD_ROLE` so messages and locks are attributed:

```sh
export COORD_ROLE=local
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

`maf add` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time:

```sh
./vault           # start (no-op if already running); maf add runs this for you
./vault export    # regenerate the Obsidian vault once
./vault status
./vault stop
./vault mcp       # exec the stdio MCP server (for an MCP client config)
```

It runs the current graphify subcommands — `graphify update .` (incremental,
no LLM) and `graphify export obsidian --dir obsidian` — as a detached polling
watcher, with its pid in `coordination/vault.pid` and its output in
`coordination/vault.log`. graphify 0.9 removed the old
`--obsidian`/`--obsidian-dir`/`--watch`/`--mcp` flags; MCP is now the separate
`graphify-mcp` stdio binary that a client spawns, not a background flag. If
`graphify` was not installed yet, run `./vault` by hand once it is.

- Agents query the graph over MCP or `graphify query "..."` instead of grepping.
- `obsidian/` is the human-facing Obsidian base (graph notes, canvas). It is
  regenerated and gitignored — durable decisions belong in `docs/decisions/`,
  not here.
- `./coord board` regenerates `coordination/exports/board.md`. It is not part
  of the graphify export and is outside `obsidian/`. Open `coordination/exports/`
  as a second vault, or open the project root as the vault to see both.

## Operating rules (also written into the project contract)

1. One writer per path; the task `scope` defines ownership. This is a
   convention `coord` warns about, not an enforced lock; roles whose duties
   say "never edit" also get a restricted tool grant where the harness
   supports one.
2. Work in a per-agent branch or git worktree (`coord worktree ROLE`, or
   `maf start HARNESS ROLE` which also does this). Worktrees live inside the
   project at `.worktrees/<role>-<worker_id>` (gitignored). In the worktree,
   run `source coord-env.sh` so `COORD_DIR`/`TASKRC` point at the main project
   and every worktree shares one coordination/ dir and board.
3. Acquire the `ollama` lock before any local generation.
4. Record decisions in `docs/decisions/`; append, never rewrite. `obsidian/` is
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
- If a GUI is wanted later, point Obsidian (Kanban + Dataview) or `taskwarrior-tui`
  at the same data; no agent changes required.
