---
name: multi-agent-flow
description: Use when setting up or running multiple coding agents (opencode, Claude Code, Hermes, Codex) on one project and they need shared task state, messaging, resource locks, and a shared knowledge base. Installs a Taskwarrior-backed `coord` CLI, a .maf/coordination/ directory, a coordination contract in each role file, and a graphify/Obsidian knowledge base. Nothing of it goes into the project's git.
---

# Multi-agent flow

Portable coordination layer for running several coding agents in parallel on one
repository, each in its own terminal, without them colliding.

For a first-time user, read `GETTING_STARTED.md` first. It is a step-by-step
walkthrough with a full worked example.

For the fastest setup, run `maf guide` and implement the output (`install.md`). It asks the user which
harnesses and roles to use, then runs `maf add` to generate the agent files
and the coordination layer.

Three pillars:

1. **Agents** — independent terminals (Warp panes, Kepler, `coi` containers).
   A container only shares state with the host if `.maf/coordination/`, `coord`,
   and `.maf/coordination/taskrc` are mounted into it; nothing shares automatically.
2. **Communication** — Taskwarrior task board + `.maf/coordination/` inbox, driven by the
   `coord` wrapper. Works from any harness because it is only CLI + files.
3. **Shared memory** — a graphify knowledge graph + Obsidian vault, queryable over MCP.

## Prerequisites

- Ruby 3.0+ (the `coord` CLI and the installer are Ruby scripts using endless
  method definitions; they will not parse under Ruby 2.x).
  macOS: `brew install mise && mise install ruby`.
- `task` (Taskwarrior) on PATH. macOS: `brew install task`.
- The maf gem: `gem install maf`.
- Optional: `graphify` for the knowledge base (`uv tool install graphifyy`).
- Git (worktrees recommended; one branch/worktree per agent).

No `jq` needed: `coord` parses the Taskwarrior JSON itself.

## Install into a project

Install the maf gem once:

```sh
gem install maf
```

In a clone of the repository, you can link `exe/maf` into a folder on `PATH` instead:

```sh
ln -sf "$PWD/exe/maf" ~/.local/bin/maf
```

Then run `maf` in the project root. The project is the current directory.

```sh
maf roles                                           # list the roles and their source
maf role add NAME                                   # add a stub role to .maf/roles.yml
maf add claude:architect opencode:backend-developer # add agents, install the flow
maf add opencode:tester                             # add one more agent later
maf remove opencode:tester                          # remove an agent
maf agents                                          # list the current agents
maf update                                          # regenerate the current agents
maf prepare claude reviewer_2 --dispatch            # add a worker (the architect is dispatched by default)
maf worker restart reviewer_2                       # status|stop|start|restart one worker
maf retire reviewer_2                               # remove a worker
maf untrack                                         # remove an older install from git
maf                                                 # interactive menu (in a terminal)
```

Flags for `maf add`: `--check` (preview, write nothing), `--force` (overwrite a
foreign `coord`), `--model ROLE=MODEL`. `maf add` keeps the current agents in
`.maf/config.json`.

It creates and never destroys:

- `.maf/coordination/{inbox,locks,exports,message-hooks,harness-hooks,taskdata}/`
- `coord`, `dispatcher`, `dashboard`, `analyst`, `vault`, and `doc-graph-refresh`
  (executable) in `.maf/bin/`, and
  `.maf/env.sh` (puts `.maf/bin` on `PATH`); `vault`
  is also started automatically if `graphify` is on PATH (see Shared memory)
- `.maf/coordination/taskrc`: a project-local Taskwarrior config (own database,
  under `.maf/coordination/taskdata`) plus the UDA block — never the user's
  global `~/.taskrc`, so two projects never share one board
- the "Multi-agent coordination" contract at the end of each role file; the
  project's `AGENTS.md` and `CLAUDE.md` stay as they are
- a marked block in `.git/info/exclude` that lists `.maf/` and each link maf
  creates: the flow is a tool, not a part of the project, so nothing of it goes
  into git, and the code, the decisions, and `GLOSSARY.md` stay after `maf uninstall`

Re-running is safe: the installer is idempotent. It compares file contents and
checks marker blocks, so it skips anything already present, updates `coord` only
when it changed, and never duplicates the exclude or `.taskrc` blocks. An install
of an older maf version that git tracks moves to this layout with `maf untrack`. Dependencies are detected, not blindly installed. If it finds an
older, global `~/.taskrc` install, it prints a one-time migration note instead
of silently stranding those tasks.

## Uninstall

```sh
maf uninstall --check   # preview
maf uninstall           # asks, then removes
```

Removes only files that carry the flow signature or marker. Keeps
`graphify-out/` (graph and Obsidian vault), `worker/*` branches, and dirty worktrees
(`--force` removes those worktrees).

## Verify

```sh
cd /path/to/project
source .maf/env.sh   # puts .maf/bin on PATH
coord init
coord add --role backend-developer --scope "test/**" --title "example task"
coord status
coord board          # writes .maf/coordination/exports/board.md
```

## Launch an agent

```sh
maf start HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
maf start claude architect
maf start opencode backend-developer_1 model:openrouter/deepseek-v3
maf start hermes tester --dispatch   # unattended: runs dispatcher in the worktree
```

One command: creates or reuses the agent's worktree, exports
`COORD_DIR`/`TASKRC`/`COORD_ROLE`/`COORD_WORKER`, then execs the harness
there. For `opencode`/`codex` this loads the role file automatically via
`--agent`/`.codex/prompts/<role>.md`; for `claude`, which does not auto-load
`.claude/agents/<role>.md` into an interactive session, it passes an initial
prompt telling the session to read and follow that file; for `hermes`, it
loads the role as a skill via `--skills <project>-<role>`. `HARNESS:ROLE` must
already be in `.maf/config.json` (`maf add HARNESS:ROLE` adds one); `WORKER` defaults to `1`.

## Wake a Hermes agent at session end

`maf add` installs `~/.hermes/agent-hooks/next-task.sh`. Hermes runs that script
when a session ends. The script resumes the session when the role has unclaimed
tasks. The hook stays inactive until the Hermes config declares it and the user
approves it:

```sh
hermes config set hooks.on_session_end '[{"command":"<script path>","timeout":30}]'
hermes chat --oneshot --accept-hooks -q ok
hermes hooks doctor
```

The flow never edits `~/.hermes/config.yaml`: the file is comment-rich, and
Hermes guards it as security-sensitive. Do not rewrite it by hand either.

The `hermes config set` command replaces the whole `on_session_end` list. If the
list is not empty, read it with `hermes config get hooks.on_session_end` first,
then set the existing entries plus the new entry.

The approval binds to the script version. Hermes records the script's mtime, so
an updated script needs a new approval.

`maf add` and `maf update` print the steps that are still missing, or
`hook ready` when the hook is active.

## How agents use it

Set `COORD_ROLE` and `COORD_WORKER` so claims, messages, and locks are attributed:

```sh
export COORD_ROLE=backend-developer COORD_WORKER=backend-developer-1
coord claim <id>
coord annotate <id> "working on it"
coord msg --from backend-developer reviewer "review test/foo.rb when free"
coord inbox backend-developer
coord done <id>
```

`coord msg` refuses a recipient that is no known role and no worker of one.

Main commands: `next, show, claim, start-task, annotate, done, msg, inbox,
escalate, goal, land, with-lock, status, who, log`. Run `coord help` for all
commands and flags.

A claim idle past `COORD_LEASE_TTL` seconds (default 4 hours) is treated as
abandoned: `next`/`claim` reclaim it without `--force`. Use `coord unclaim`
to release one on purpose. `coord next --wait` / `coord inbox --wait` block
at a fixed interval instead of a hand-rolled poll loop.

## Resource locks

A single local-model host can only serve one generation at a time. Serialize:

```sh
coord with-lock ollama -- opencode run --agent backend-developer "..."
coord lock ollama --ttl 3600   # advisory, for long interactive runs
coord unlock ollama
```

Locks are `mkdir`-based, so they work on macOS and Linux without `flock`.

## Shared memory

`maf add` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time:

```sh
vault           # start (no-op if already running); maf add runs this for you
vault export    # regenerate the Obsidian vault once
vault status
vault stop
vault mcp       # exec the stdio MCP server (for an MCP client config)
```

It runs the current graphify subcommands — `graphify update .` (incremental,
no LLM) and `graphify export obsidian --dir graphify-out/obsidian` — as a detached polling
watcher, with its pid in `.maf/coordination/vault.pid` and its output in
`.maf/coordination/vault.log`. graphify 0.9 removed the old
`--obsidian`/`--obsidian-dir`/`--watch`/`--mcp` flags; MCP is now the separate
`graphify-mcp` stdio binary that a client spawns, not a background flag. If
`graphify` was not installed yet, run `vault` by hand once it is.

- Each role queries the graph when it starts a task or plans a goal (MCP, or
  `graphify query "..." --budget 800`). The graph is in `graphify-out/` at the project root;
  each worktree has a symlink to it.
  A missing or stale graph goes into the report. `vault age` shows the graph age:
  the commits since the build. `coord status` and the dashboard show it too.
- `maf add` writes the MCP server into `.maf/mcp/` (Claude Code and opencode); `maf start`
  passes the file. For Codex and Hermes, it prints the command that adds the server.
  Set `"mcp": false` in `.maf/config.json` to turn this off.
- The graph holds code knowledge. Plans and specs use artifacts, not the graph.
- Work memory: `coord done` saves a `graphify save-result` note in `graphify-out/memory/`,
  and `coord lesson ID dead_end|corrected TEXT` saves a failed approach or a correction.
  `graphify reflect` sums the notes up in `graphify-out/reflections/LESSONS.md`. The dispatcher
  adds the dead ends and corrections of the task files to each task prompt. `graphify-out/memory/` is a worktree of the
  orphan branch `maf/memory` (ADR 0006); each note is one commit, and `coord goal pr` pushes the branch.
- `graphify-out/obsidian/` is the human-facing Obsidian base (graph notes, canvas). It is
  regenerated and excluded from git — durable decisions belong in the decisions folder
  (`.agent/decisions/` if it exists, else `docs/decisions/`),
  not here.
- `coord board` regenerates `.maf/coordination/exports/board.md`. It is not part
  of the graphify export and is outside `graphify-out/obsidian/`. Open `.maf/coordination/exports/`
  as a second vault, or open the project root as the vault to see both.

## Operating rules (also in the contract of each role file)

Automatic hooks require a session that `maf start` registers.
Coordination environment variables alone do not activate hooks.
Codex hooks live in the project `.codex/hooks.json` file.
Run `maf update` to disable the legacy global Codex hook.
Restart workers with `maf start` after the update.

1. One writer per path; the task `scope` defines ownership. This is a
   convention `coord` warns about, not an enforced lock. Roles with
   `can_edit: false` get a restricted tool grant where the harness supports
   one, and the git `pre-commit` guard refuses their commits.
2. Work in a per-agent branch or git worktree (`coord worktree ROLE`, or
   `maf start HARNESS ROLE` which also does this). Worktrees live inside the
   project at `.maf/worktrees/<role>-<worker_id>` (excluded from git). In the worktree,
   run `source .maf/env.sh` so `COORD_DIR`/`TASKRC` point at the main project
   and every worktree shares one .maf/coordination/ dir and board.
3. Acquire the `ollama` lock before any local generation.
4. Record decisions in the decisions folder (`.agent/decisions/` or
   `docs/decisions/`); append, never rewrite. `graphify-out/obsidian/` is
   regenerated graphify output, not a durable store.
5. Report via `coord annotate`; coordinate via `coord msg`.
6. Worker roles: if no task is available, Claude Code and opencode agents stop.
   The board watcher wakes them. Codex agents run `coord await` and end the turn;
   the stop hook waits for work. Hermes agents use `coord next --wait`.
   Never poll by hand. Lead roles (project manager, architect) never claim a task.
   `coord msg --fyi` sends a note that wakes no one.
7. Before `coord done`, merge the goal branch into the task branch and rerun
   the task tests. `coord done` refuses a task branch without the goal head.
8. `coord who` shows which workers are live. `coord msg` warns when the
   receiver role has no live worker and no message hook.

## Notes

- Run `ruby scripts/check.rb` after editing the UDA block or markers. It keeps
  the duplicated UDA definition in `coord` and `taskrc.append` in sync.
- Run `ruby test/coord_test.rb` after changing `assets/coord`'s behavior.
- Taskwarrior is the source of truth, in a project-local database
  (`.maf/coordination/taskdata`); `coord board`/`export` are projections.
- Containerized agents (e.g. `coi`) need `.maf/coordination/`, `coord`, and
  `.maf/coordination/taskrc` mounted from the host — they share nothing across a
  container boundary on their own.
- Multi-machine sync (Taskserver) is optional and out of scope here.
- If a GUI is wanted later, point Obsidian (Kanban + Dataview) or `taskwarrior-tui`
  at the same data; no agent changes required.
