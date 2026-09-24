# multi_agent_flow

Coordination layer for running several AI coding agents (opencode, Claude Code,
Hermes, Codex) in parallel on one repository, each in its own terminal.

Three pillars:

| Pillar | Implementation |
|---|---|
| Communication | Taskwarrior task board + `coordination/` inbox, via the `coord` CLI |
| Resource control | `mkdir`-based locks — no `flock`, works on macOS and Linux |
| Shared memory | graphify knowledge graph + Obsidian vault, served over MCP |

The whole layer is **CLI + files**: every harness uses it identically; no GUI or
vendor dependency.

---

## Fast path — agent-driven

1. Clone this repo anywhere.
2. Open any AI coding agent in your project folder and say:

   > Here is the multi-agent flow setup: `<path>/install.md`. Read it and implement it.

The agent asks which harnesses and roles to use, runs the generator, and prints
the `setup_agent` commands to start each session.

See **[install.md](install.md)** for the exact instructions the agent follows.

---

## Documentation

| File | Audience | What it covers |
|---|---|---|
| **[GLOSSARY.md](GLOSSARY.md)** | Everyone | Domain terms: harness, role, worker, agent, task, message, claim, lock, hooks |
| **[GETTING_STARTED.md](GETTING_STARTED.md)** | First-time user | Concepts, prerequisites, manual install, basic workflow |
| **[USER_MANUAL.md](USER_MANUAL.md)** | Setting up a real team | Full install (flow.rb), all harnesses, dispatcher, monitoring |
| **[install.md](install.md)** | An AI coding agent | Interactive wizard: asks the user for harnesses/roles, runs the generator |
| **[SKILL.md](SKILL.md)** | Agent skill loader | Self-contained portable skill (frontmatter + full API reference) |

---

## Contents

```
multi_agent_flow/
  install.md                  # agent instruction: interactive setup wizard
  SKILL.md                    # portable skill for agent skill loaders
  README.md                   # this file
  GLOSSARY.md                 # domain terms
  GETTING_STARTED.md          # first-time walkthrough (concepts + manual setup)
  USER_MANUAL.md              # full team setup reference
  scripts/
    flow.rb                   # generates harness-specific role files + installs coordination layer
    uninstall.rb              # removes the flow from a project; keeps graphify-out/ and obsidian/
    check.rb                  # repo consistency check (UDA sync, marker blocks, worktree formula)
  templates/
    roles.yml                 # role definitions + model hints
    opencode.md.erb           # role file templates per harness
    claude.md.erb
    codex.md.erb
    hermes.md.erb
  assets/
    coord                     # coordination CLI (Ruby)
    setup_agent               # worktree + harness launch (Ruby)
    dispatcher                # polls task board + inbox, starts one-shot agents (Ruby)
    vault                     # graphify + Obsidian + MCP watcher control (Ruby)
    dashboard                 # web dashboard: stuck-detection UI (Ruby/Sinatra)
    bootstrap.rb              # idempotent coordination layer installer (Ruby)
    taskrc.append             # Taskwarrior UDA block
    agents-contract.md        # contract appended to AGENTS.md / CLAUDE.md
    gitignore.append          # marker-guarded ignore entries
    coordination/             # inbox / locks / exports skeleton
    harness-hooks/            # next-task + board-watch scripts run by harnesses
  test/
    coord_test.rb             # behavioral tests for the coord CLI
    installer_test.rb         # tests for bootstrap.rb, flow.rb, setup_agent
    dispatcher_test.rb        # tests for the dispatcher
    uninstaller_test.rb       # tests for uninstall.rb
```

---

## Use as a skill

Copy or symlink this directory into a skills location so agents can discover it.
The skill loader matches the folder name to `name:` in the frontmatter; the
installed folder must be `multi-agent-flow` (hyphen, not underscore):

```sh
cp -R "$PWD" ~/.config/opencode/skills/multi-agent-flow
# or, for Claude Code:
cp -R "$PWD" ~/.claude/skills/multi-agent-flow
```

Restart the agent to load the skill. You can also hand `SKILL.md` plus `assets/`
to any agent as direct context.

---

## Contributor reference

After editing the UDA block or the worktree-path formula:

```sh
ruby scripts/check.rb
```

Verifies: UDA block in `assets/coord` matches `assets/taskrc.append`; marker
blocks are present in all generated files; worktree path formula is identical in
`assets/coord` and `assets/setup_agent`.

```sh
ruby test/coord_test.rb      # covers the coord CLI
ruby test/installer_test.rb  # covers bootstrap.rb, flow.rb, setup_agent
ruby test/uninstaller_test.rb  # covers scripts/uninstall.rb
```

Minitest, stdlib only. Tests that require `task` or `git` skip (exit 0) when
those tools are absent. If wiring into CI, install both to get full coverage.

---

## Design notes

- **Taskwarrior is the single source of truth**, in a project-local database
  (`coordination/taskdata`, via `coordination/taskrc`) — never the user's
  global `~/.task`. Two projects on this flow never share one board.
  `coord board`/`export` are read-only projections.
- **Agents never call `task` directly.** `coord` keeps the protocol stable and
  lets the storage backend change later.
- **Terminology:** see [GLOSSARY.md](GLOSSARY.md). One role can run as several
  workers. `claim` is atomic, so two workers cannot take the same task.
- **A claim is a lease.** Idle past `COORD_LEASE_TTL` seconds (default 4 hours)
  it becomes claimable again without `--force`. `coord unclaim` releases one on
  demand.
- **Worktrees live inside the project** at `.worktrees/<role>-<worker_id>`.
  `.worktrees/` is gitignored. In each worktree, run `source coord-env.sh` so
  `COORD_DIR` and `TASKRC` point at the main project; every worktree shares one
  `coordination/` dir and one task board.
- **Scope overlap** is checked on `coord add` (warning) and `coord conflicts`
  (report). It is a path-prefix heuristic, not a full glob matcher. Scope is
  advisory: nothing but agent discipline stops a write outside it, except that
  roles whose duties say "never edit" also get a restricted tool grant where the
  harness supports one (Claude Code, opencode).
- **The `ollama` lock** is required when one local model host serves several
  agents. It is exclusive only while the holding process is alive; a killed
  process's lock is reclaimed once its TTL elapses (default 3600s).
- **The `project-manager` role** is the user's proxy: the user talks to it, it
  relays one goal at a time to the architect, and relays the report back. Without
  `project-manager`, the user talks to the architect directly.
- **UI is deliberately deferred**: Obsidian (Kanban/Dataview) or
  `taskwarrior-tui` can read the same data without any agent changes.
