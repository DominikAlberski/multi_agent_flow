# multi_agent_flow

Coordination layer for running several AI coding agents (opencode, Claude Code,
Hermes, Codex) in parallel on one repository, each in its own terminal.

Three pillars:

| Pillar | Implementation |
|---|---|
| Communication | Taskwarrior task board + `.maf/coordination/` inbox, via the `coord` CLI |
| Resource control | `mkdir`-based locks — no `flock`, works on macOS and Linux |
| Shared memory | graphify knowledge graph + Obsidian vault, served over MCP |

The whole layer is **CLI + files**: every harness uses it identically; no GUI or
vendor dependency.

---

## Fast path — agent-driven

1. Clone this repo anywhere.
2. Open any AI coding agent in your project folder and say:

   > Here is the multi-agent flow setup: `<path>/install.md`. Read it and implement it.

The agent asks which harnesses and roles to use, runs `maf add`, and prints
the `maf start` commands to start each session.

See **[install.md](install.md)** for the exact instructions the agent follows.

## Manual path - the maf command

Link `bin/maf` into a folder on `PATH` once. Then run `maf` in the project root.

```sh
ln -sf "$PWD/bin/maf" ~/.local/bin/maf

cd ~/Projects/my-app
maf roles                                             # list the roles
maf add claude:architect opencode:backend-developer   # install the flow and add agents
maf start claude architect                            # start one agent in its worktree
maf help                                              # all commands
```

Run `maf` without a command to use the interactive menu. The menu asks for
each value: harness, roles, models, and the agent to start.

---

## Project layout

The flow keeps every file that it owns in one folder, `.maf/`, in the project.

```
.maf/
  bin/            coord, dispatcher, vault, dashboard, doc-graph-refresh
  coordination/   task board, inbox, locks, presence, sessions, hooks, logs
  worktrees/      one git worktree per worker
  graphify-out/   knowledge graph
  obsidian/       generated Obsidian vault
  agents/         role files: claude/, opencode/, codex/
  config.json     the agents and settings of the project
  roles.yml       project roles (you write it; maf role add NAME)
  workflow.md     stage instructions for the architect (you write it)
  env.sh          source it: puts .maf/bin on PATH
```

The project root keeps `.maf/` and `AGENTS.md`. These files must stay where
their tool reads them:

| Path | Reason |
|---|---|
| `AGENTS.md` | Every harness reads the contract there. |
| `.gitignore` | Git reads it there. |
| `.git/hooks/*` | Git reads them there. |
| `.claude/settings.json` | Claude Code reads it there. |
| `.opencode/plugins/board-watch.js` | opencode reads it there. |
| `~/.hermes/skills/<project>-<role>/SKILL.md` | Hermes reads it there. |

`.claude/agents/`, `.opencode/agents/`, and `.codex/prompts/` are relative
symlinks into `.maf/agents/<harness>/`. Git tracks the symlinks.

A project with the old layout runs `maf migrate` once. See the migration
section of [USER_MANUAL.md](USER_MANUAL.md).

---

## Documentation

| File | Audience | What it covers |
|---|---|---|
| **[GLOSSARY.md](GLOSSARY.md)** | Everyone | Domain terms: harness, role, worker, agent, task, message, claim, lock, hooks |
| **[GETTING_STARTED.md](GETTING_STARTED.md)** | First-time user | Concepts, prerequisites, manual install, basic workflow |
| **[USER_MANUAL.md](USER_MANUAL.md)** | Setting up a real team | Full install (maf), all harnesses, dispatcher, monitoring |
| **[install.md](install.md)** | An AI coding agent | Interactive wizard: asks the user for harnesses/roles, runs `maf add` |
| **[docs/out-of-scope.md](docs/out-of-scope.md)** | Contributor | Requests that the project rejects on purpose, with the reason |
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
  bin/
    maf                       # the maf command line tool; link it into PATH
  lib/maf/
    cli.rb                    # maf subcommands
    menu.rb                   # interactive menu (maf without a command)
    prompt.rb                 # numbered terminal questions for the menu
    flow.rb                   # generates harness-specific role files + installs coordination layer
    bootstrap.rb              # idempotent coordination layer installer
    setup_agent.rb            # maf start: worktree + harness launch
    uninstall.rb              # removes the flow from a project; keeps .maf/graphify-out/ and .maf/obsidian/
    migrate.rb                # maf migrate: moves an old-layout install into .maf/
    flow/role_catalog.rb      # merges .maf/roles.yml over the built-in roles
    flow/workflow.rb          # reads .maf/workflow.md for the architect prompt
  scripts/
    check.rb                  # repo consistency check (UDA sync, marker blocks, worktree formula)
  templates/
    roles.yml                 # role definitions + model hints
    role-stub.yml.erb         # stub that maf role add writes
    workflows/                # default workflows: simple, plan-review, tdd
    opencode.md.erb           # role file templates per harness
    claude.md.erb
    codex.md.erb
    hermes.md.erb
  assets/
    coord                     # coordination CLI (Ruby)
    dispatcher                # polls task board + inbox, starts one-shot agents (Ruby)
    vault                     # graphify + Obsidian + MCP watcher control (Ruby)
    dashboard                 # web dashboard: stuck-detection UI (Ruby/Sinatra)
    doc-graph-refresh         # graphify rebuild runner called by the git hooks (Ruby)
    env.sh                    # shell environment: .maf/bin on PATH (installed as .maf/env.sh)
    git-hooks/                # pre-commit guard, post-commit/post-merge refresh blocks
    taskrc.append             # Taskwarrior UDA block
    agents-contract.md        # contract appended to AGENTS.md
    gitignore.append          # marker-guarded ignore entries
    harness-hooks/            # next-task + board-watch scripts and the opencode plugin
  test/
    coord_test.rb             # behavioral tests for the coord CLI
    installer_test.rb         # tests for bootstrap.rb, flow.rb, setup_agent.rb
    maf_test.rb               # tests for the maf command
    dashboard_test.rb         # tests for the dashboard data
    dispatcher_test.rb        # tests for the dispatcher
    uninstaller_test.rb       # tests for uninstall.rb
    migrate_test.rb           # tests for migrate.rb
    roles_workflow_test.rb    # tests for project roles and the workflow
    doc_graph_refresh_test.rb # tests for the doc-graph refresh script
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

## Doc-graph refresh

A commit or merge that changes a markdown file refreshes the shared knowledge
graph. `maf add` appends a flow block to the `post-commit` and `post-merge`
hooks. The block starts `.maf/bin/doc-graph-refresh` detached, so the commit
returns at once.

The refresh runs `graphify extract . --backend gemini` and then
`graphify export obsidian --dir .maf/obsidian`. The graph lives in `.maf/graphify-out/`
(`GRAPHIFY_OUT` points there). It builds in a temp dir and swaps on
success, so a failed extract keeps the old graph. It needs `GEMINI_API_KEY`.
Without the key it logs a skip in `.maf/coordination/doc-graph.log` and exits. A
non-markdown commit makes no LLM call. A refresh started in a worktree writes
the shared graph in the main checkout.

---

## Contributor reference

After editing the UDA block or the worktree-path formula:

```sh
ruby scripts/check.rb
```

Verifies: UDA block in `assets/coord` matches `assets/taskrc.append`; marker
blocks are present in all generated files; worktree path formula is identical in
`assets/coord` and `lib/maf/setup_agent.rb`.

An agent session exports `TASKRC` and `COORD_DIR` for the shared board. Unset
them before the tests, so a test never writes to that board:

```sh
env -u TASKRC -u COORD_DIR -u COORD_ROLE -u COORD_WORKER ruby test/coord_test.rb
```

```sh
ruby test/coord_test.rb      # covers the coord CLI
ruby test/installer_test.rb  # covers bootstrap.rb, flow.rb, setup_agent.rb
ruby test/uninstaller_test.rb  # covers uninstall.rb
ruby test/migrate_test.rb    # covers migrate.rb
ruby test/roles_workflow_test.rb  # covers project roles and the workflow
ruby test/maf_test.rb        # covers the maf command
ruby test/dashboard_test.rb  # covers the dashboard data
ruby test/doc_graph_refresh_test.rb  # covers the doc-graph refresh
```

Minitest, stdlib only. Tests that require `task` or `git` skip (exit 0) when
those tools are absent. If wiring into CI, install both to get full coverage.

---

## Design notes

- **Taskwarrior is the single source of truth**, in a project-local database
  (`.maf/coordination/taskdata`, via `.maf/coordination/taskrc`) — never the user's
  global `~/.task`. Two projects on this flow never share one board.
  `coord board`/`export` are read-only projections.
- **Agents never call `task` directly.** `coord` keeps the protocol stable and
  lets the storage backend change later.
- **Terminology:** see [GLOSSARY.md](GLOSSARY.md). One role can run as several
  workers. `claim` is atomic, so two workers cannot take the same task.
- **A claim is a lease.** Idle past `COORD_LEASE_TTL` seconds (default 4 hours)
  it becomes claimable again without `--force`. `coord unclaim` releases one on
  demand.
- **Worktrees live inside the project** at `.maf/worktrees/<role>-<worker_id>`.
  `.maf/worktrees/` is gitignored. In each worktree, run `source .maf/env.sh` so
  `COORD_DIR` and `TASKRC` point at the main project; every worktree shares one
  `.maf/coordination/` dir and one task board.
- **Scope overlap** is checked on `coord add` (warning) and `coord conflicts`
  (report). It is a path-prefix heuristic, not a full glob matcher. Scope is
  advisory: nothing but agent discipline stops a write outside it, except that
  roles with `can_edit: false` get a restricted tool grant where the harness
  supports one (Claude Code, opencode, Hermes), and the git `pre-commit` guard
  refuses their commits.
- **The `ollama` lock** is required when one local model host serves several
  agents. Exclusion is TTL-based: coord stores no pid. A lock is reclaimed once its
  TTL elapses (default 3600s), even if the holder is still alive. A killed
  holder keeps the lock until the TTL elapses.
- **The `project-manager` role** is the user's proxy: the user talks to it, it
  creates goals (`coord goal add`), sends them to the architect, and relays the report back. Without
  `project-manager`, the user talks to the architect directly.
- **Rejected requests are logged.** When you reject a request on purpose, add
  an entry to [docs/out-of-scope.md](docs/out-of-scope.md): the request, the
  date, the source, and the reason. Read the log before you propose a feature.
- **UI is deliberately deferred**: Obsidian (Kanban/Dataview) or
  `taskwarrior-tui` can read the same data without any agent changes.
