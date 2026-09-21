# multi_agent_flow

A portable coordination layer for running several coding agents (opencode, Claude
Code, Hermes, Codex) in parallel on one repository, each in its own terminal.

It gives three things:

| Pillar | Implementation |
|---|---|
| Communication | Taskwarrior board + `coordination/` inbox, via the `coord` CLI |
| Resource control | `mkdir`-based locks (no `flock`; works on macOS and Linux) |
| Shared memory | graphify knowledge graph + Obsidian vault, served over MCP |

The whole layer is **CLI + files**, so every harness can use it identically and
nothing depends on a GUI or a vendor.

New here? Read **[GETTING_STARTED.md](GETTING_STARTED.md)** — a step-by-step
walkthrough for a first-time user.

## Fast path (agent-driven install)

1. Clone this repo anywhere.
2. Open any harness (opencode, Claude Code, Codex, Hermes) and paste:

   > Here is the multi-agent flow setup: `<path>/install.md`. Read it and implement it.

3. The agent asks which harnesses, which roles, and which model per role.
4. The agent generates the agent files and prints the session instructions.
5. Open one session per agent and start giving the project manager work (or
   the architect directly, if you skipped the `project-manager` role).

See **[install.md](install.md)** for the exact instruction the agent follows.

## Contents

```
multi_agent_flow/
  install.md                  # paste this to an agent to install the flow
  SKILL.md                    # portable skill: how an agent sets this up
  README.md                   # this file
  GETTING_STARTED.md          # first-time walkthrough
  scripts/
    flow.rb                   # generates harness-specific agent files
    check.rb                  # repo consistency checks
  templates/
    roles.yml                 # role definitions + model recommendations
    opencode.md.erb           # agent file templates
    claude.md.erb
    codex.md.erb
    hermes.md.erb
  assets/
    coord                     # the coordination CLI (Ruby)
    setup_agent               # worktree + harness launch, one command (Ruby)
    vault                     # graphify + Obsidian + MCP watcher control (Ruby)
    bootstrap.rb              # idempotent installer (Ruby)
    taskrc.append             # Taskwarrior UDA block
    agents-contract.md        # contract appended to AGENTS.md / CLAUDE.md
    gitignore.append          # marker-guarded ignore entries
    coordination/             # inbox / locks / exports skeleton
  test/
    coord_test.rb             # behavioral tests for the coord CLI
    installer_test.rb         # tests for bootstrap.rb, flow.rb, setup_agent
```

## Install into a project

```sh
./assets/bootstrap.rb /path/to/project --roles project-manager,architect,backend-developer,frontend-developer,reviewer,tester
```

Prerequisites: Ruby 3.x and `task` (Taskwarrior). Optional: `graphify`.
macOS: `brew install task`. No `jq` needed.

Flags: `--check` (preview), `--install-deps` (install missing required tools),
`--force` (overwrite a foreign `coord` or `setup_agent`).

The installer is **idempotent**: it compares contents and checks marker blocks, so
re-running skips everything already present and never duplicates blocks.

## Use as a skill

Copy or symlink this directory into a skills location so agents can discover it.
The skill loader matches the folder name to `name:` in the frontmatter, so the
installed folder must be `multi-agent-flow` (hyphen, not underscore):

```sh
cp -R "$PWD" ~/.config/opencode/skills/multi-agent-flow
# or, for Claude Code: ~/.claude/skills/multi-agent-flow
```

Restart the agent so it loads the skill, then ask it to set up the flow in a project.
You can also just hand `SKILL.md` plus `assets/` to any agent as context.

## Quick reference

```sh
./coord init
./coord add --agent backend-developer --scope "test/**" --title "fix reek in test/"
./coord next                       # unclaimed tasks for COORD_AGENT
./coord next --wait                # block until one appears (polls every 60s)
./coord claim <id>                 # atomic; uses COORD_WORKER
./coord unclaim <id>                # give it back without finishing it
./coord annotate <id> "started"
./coord msg --from backend-developer reviewer "review when free"
./coord inbox
./coord with-lock ollama -- opencode run --agent backend-developer "..."
./coord worktree backend-developer  # git worktree + branch; then `source coord-env.sh` in it
./coord status
./coord board        # coordination/exports/board.md (Obsidian kanban)
```

A task left claimed with no activity for `COORD_LEASE_TTL` seconds (default 4
hours, override via env) is treated as abandoned: `next`/`claim` reclaim it
without `--force`. `coord unclaim` releases one immediately.

## Run an agent

`setup_agent` wraps the manual per-agent setup (worktree, `coord-env.sh`,
`COORD_AGENT`/`COORD_WORKER`, role bootstrap) into one command:

```sh
./setup_agent HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
./setup_agent claude backend-developer_1
./setup_agent opencode reviewer_1 model:openrouter/deepseek-v3
```

It creates or reuses the worktree, exports `COORD_DIR`/`TASKRC`/`COORD_AGENT`/
`COORD_WORKER`, then execs the harness in that worktree. All worktrees live in
one sibling folder, `<project>.worktrees/<role>-<worker>`:

- `opencode`/`codex`: `--agent ROLE` (or the `.codex/prompts/ROLE.md` file)
  loads the role file automatically.
- `claude`: Claude Code does not auto-load `.claude/agents/*.md` into an
  interactive session (those files are subagent definitions, used via its
  Task tool). `setup_agent` instead passes an initial prompt telling the
  session to read and follow its role file.

`HARNESS:ROLE` must already exist in `.agent-flow.json` (add one with
`scripts/flow.rb --agent HARNESS:ROLE`). `WORKER` defaults to `1` if omitted.

## Consistency check

```sh
ruby scripts/check.rb
```

Verifies the repo is internally consistent:

- the Taskwarrior UDA block in `assets/coord` matches `assets/taskrc.append`
  (they are duplicated because `coord` is copied into projects and cannot read
  the append file at runtime);
- the `>>> multi-agent-flow >>>` marker is present in every generated/parsed file;
- the worktree path formula in `assets/coord` and `assets/setup_agent` matches;
- each installed script's signature string matches `assets/bootstrap.rb`;
- `assets/bootstrap.rb` does not define its own `TASKRC_BLOCK`.

Exit code is non-zero on failure. Run it after editing the UDA block or markers.

## Tests

```sh
ruby test/coord_test.rb
ruby test/installer_test.rb
```

Minitest, stdlib only. `coord_test.rb` covers the `coord` CLI: scope-overlap
tests are pure; the Taskwarrior and worktree tests run for real (a disposable,
project-local task database, never `~/.task`; a disposable git repo) and skip —
exit code still 0 — if `task` or `git` is missing. `installer_test.rb` covers
`bootstrap.rb`, `flow.rb`, and `setup_agent` against disposable project dirs and
needs no external tools. If wiring this into CI, make sure `task` and `git` are
installed there; a run with 0 failures but N > 0 skips is not full coverage.

## Design notes

- Taskwarrior is the single source of truth, in a project-local database
  (`coordination/taskdata`, via `coordination/taskrc`) — never the user's
  global `~/.task`, so two projects on this flow never share one board.
  `coord board`/`export` are read-only projections for humans.
- Agents never call `task` directly; `coord` keeps the protocol stable and lets the
  storage backend change later (e.g. an MCP server).
- The `ollama` lock is a hard requirement when one local model host serves several
  agents. It is exclusive only while the holding process is alive; a killed
  process's lock is reclaimed once its TTL elapses (default 3600s), never before.
- `agent` is a role (pool); `worker` is an instance. Set `COORD_WORKER` to run more
  than one instance per role. `claim` is atomic, so workers cannot take the same task.
- A claim is a lease: idle past `COORD_LEASE_TTL` seconds (default 4 hours), it
  becomes claimable again without `--force`. `coord unclaim` releases one on demand.
- Scope overlap is checked on `coord add` (warning) and `coord conflicts` (report).
  It is a path-prefix heuristic, not a full glob matcher. Scope itself is advisory:
  nothing but agent discipline stops a write outside it, except that roles whose
  duties say "never edit" also get a restricted tool grant where the harness
  supports one (Claude Code, opencode).
- Use `coord next --wait` / `coord inbox --wait` instead of a hand-rolled poll
  loop; both block at a fixed interval (default 60s) instead of leaving "don't
  spin" to agent self-discipline.
- The architect is a single decomposition point: fine for 3-5 workers, add a
  second tier before going wider. It does not merge worker branches; that stays
  a manual `git merge`/PR step. `coord worktree ROLE` only creates the worktree;
  it writes an untracked `coord-env.sh` that you `source` so the worktree shares
  the main project's `coordination/` dir and board.
- The optional `project-manager` role is that second tier for the user, not
  for scale: the user talks only to the project manager, which sends the
  architect one goal at a time and relays its report back. This keeps the
  user's conversation free while the architect dispatches tasks and watches
  worker progress. Without `project-manager`, the user talks to the architect
  directly, as before.
- UI is deliberately deferred: Obsidian (Kanban/Dataview) or `taskwarrior-tui` can
  read the same data with no agent changes.
