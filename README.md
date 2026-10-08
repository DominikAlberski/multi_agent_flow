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
The knowledge graph is the exception: it is project knowledge, not tooling, so it
lives in `graphify-out/` at the project root, where graphify looks by default.

```
.maf/
  bin/            coord, dispatcher, vault, dashboard, analyst, doc-graph-refresh
  lib/maf/shared/ code that the scripts in bin/ load (maf update replaces it)
  coordination/   task board, inbox, locks, presence, sessions, hooks, logs
  worktrees/      one git worktree per worker
  agents/         role files: claude/, opencode/, codex/
  claude/         settings.json: the Claude Code hooks (maf start passes --settings)
  mcp/            the graphify MCP server for Claude Code and opencode
  config.json     the agents and settings of the project
  roles.yml       project roles (you write it; maf role add NAME)
  workflow.md     stage instructions for the architect (you write it)
  env.sh          source it: puts .maf/bin on PATH
graphify-out/     knowledge graph (excluded from git; each worktree has a symlink to it)
  memory/         work memory notes: a worktree of the orphan branch maf/memory (ADR 0006)
  obsidian/       generated Obsidian vault
```

maf is a tool, not a part of the project. Nothing that runs maf goes into git:
`.maf/` and each link and plugin that maf creates are listed in `.git/info/exclude`,
which is local to the clone. maf never edits a file that the project tracks.

The project keeps what the agents make, also after `maf uninstall`:

| Path | What it is |
|---|---|
| the code | The work of the agents, landed on the goal branches. |
| `GLOSSARY.md` | The domain glossary. The project manager drafts it. A worker commits it on the architect's task. |
| `docs/decisions/` | ADRs. The architect decides them. A worker commits them. |

Local files that a harness or git reads outside `.maf/`:

| Path | Reason |
|---|---|
| `.git/hooks/*` | Git reads them there. |
| `.git/info/exclude` | Keeps the flow out of git in this clone. |
| `.claude/agents/`, `.opencode/agents/`, `.codex/prompts/` | Symlinks into `.maf/agents/<harness>/`. |
| `.opencode/plugins/board-watch.js` | opencode reads it there. |
| `.codex/hooks.json` | Codex reads it there. Excluded when the project does not track it. |
| `~/.hermes/skills/<project>-<role>/SKILL.md` | Hermes reads it there. |

Claude Code gets the hooks from `.maf/claude/settings.json` (`--settings`) and the
graphify MCP server from `.maf/mcp/claude.json` (`--mcp-config`). opencode gets the
server from `.maf/mcp/opencode.json` (`OPENCODE_CONFIG`). `maf start` and the
dispatcher pass these files. The project's `.claude/settings.json`, `.mcp.json`,
`opencode.json`, `AGENTS.md`, and `CLAUDE.md` stay as they are.

MAF installs Codex hooks in the project `.codex/hooks.json` file.
Hooks act only on sessions that `maf start` registers.
Each hook checks the launch token, process, worktree, role, worker, board, and harness session ID.
An independent session does not activate hooks, even with inherited coordination variables.
`maf update` disables the legacy global Codex hook and removes only its registration.
Other global hooks stay.
Restart workers with `maf start` after the update.

A project with the old layout runs `maf migrate` once. See the migration
section of [USER_MANUAL.md](USER_MANUAL.md).

---

## Documentation

| File | Audience | What it covers |
|---|---|---|
| **[docs/flow-glossary.md](docs/flow-glossary.md)** | Everyone | Flow terms: harness, role, worker, agent, task, message, claim, lock, hooks. [docs/flow-cli-names.md](docs/flow-cli-names.md) lists their names in code and CLI |
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
  docs/flow-glossary.md       # flow terms
  docs/flow-cli-names.md      # code and CLI name of each flow term
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
    uninstall.rb              # removes the flow from a project; keeps graphify-out/
    migrate.rb                # maf migrate: moves an old-layout install into .maf/
    team.rb                   # maf prepare: adds or replaces one worker
    team_command.rb           # maf team: shows the team, or sets its budget
    retire.rb                 # maf retire: removes one worker and archives its state
    worker_control.rb         # maf worker: stops, starts, or restarts one worker
    flow/role_catalog.rb      # merges .maf/roles.yml over the built-in roles
    flow/workflow.rb          # reads .maf/workflow.md for the architect prompt
    flow/mcp_config.rb        # writes the graphify MCP server into .maf/mcp/
    untrack.rb                # maf untrack: removes an older install from git
    local_exclude.rb          # the flow block in .git/info/exclude
    shared/                   # stdlib-only code that the maf CLI and the scripts share (installed as .maf/lib/maf/shared/)
  scripts/
    check.rb                  # repo consistency check (UDA sync, markers, script signatures)
  templates/
    roles.yml                 # role definitions + model hints
    role-stub.yml.erb         # stub that maf role add writes
    workflows/                # default workflows: simple, plan-review, tdd, panel
    opencode.md.erb           # role file templates per harness
    claude.md.erb
    codex.md.erb
    hermes.md.erb
  assets/
    coord                     # coordination CLI (Ruby)
    dispatcher                # polls task board + inbox, starts one-shot agents (Ruby)
    vault                     # graphify + Obsidian + MCP watcher control, graph age (Ruby)
    dashboard                 # web dashboard: workers table with actions, alerts, board (Ruby/WEBrick)
    analyst                   # asks a small model for token hints about one worker (dashboard analyze button)
    doc-graph-refresh         # graphify rebuild runner called by the git hooks (Ruby)
    env.sh                    # shell environment: .maf/bin on PATH (installed as .maf/env.sh)
    git-hooks/                # pre-commit guard, post-commit/post-merge refresh blocks
    taskrc.append             # Taskwarrior UDA block
    agents-contract.md        # coordination contract at the end of each role prompt
    harness-hooks/            # next-task, board-watch, session-guard, and context-watch scripts, and the opencode plugin
  test/
    coord_test.rb             # behavioral tests for the coord CLI
    installer_test.rb         # tests for bootstrap.rb, flow.rb, setup_agent.rb
    maf_test.rb               # tests for the maf command
    dashboard_test.rb         # tests for the dashboard data
    dispatcher_test.rb        # tests for the dispatcher
    uninstaller_test.rb       # tests for uninstall.rb
    migrate_test.rb           # tests for migrate.rb
    roles_workflow_test.rb    # tests for project roles and the workflow
    graph_age_test.rb         # tests for vault age and the graph prompt rules
    mcp_test.rb               # tests for the MCP server wiring
    doc_graph_refresh_test.rb # tests for the doc-graph refresh script
    board_watch_test.rb       # tests for the board watcher
    context_watch_test.rb     # tests for the context-watch hook
    hook_session_test.rb      # tests for session isolation
    hook_config_test.rb       # tests for project hooks
    worker_control_test.rb    # tests for maf worker
    untrack_test.rb           # tests for maf untrack
    analyst_test.rb           # tests for the analyst
    shared_test.rb            # tests for lib/maf/shared/
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
`graphify export obsidian --dir graphify-out/obsidian`. The graph lives in `graphify-out/`
at the project root. It builds in a temp dir and swaps the derived files on
success, so a failed extract keeps the old graph. The swap never replaces
`graphify-out/memory/` or `graphify-out/obsidian/`. It then runs `graphify reflect` on the
saved notes. It needs `GEMINI_API_KEY`.
Without the key it logs a skip in `.maf/coordination/doc-graph.log` and exits. A
non-markdown commit makes no LLM call. A refresh started in a worktree writes
the shared graph in the main checkout.

---

## Contributor reference

After editing the UDA block or the worktree-path formula:

```sh
ruby scripts/check.rb
```

Verifies: the UDA block in `assets/coord` matches `assets/taskrc.append`; the
markers are present; the worktree path formula is identical in `assets/coord`
and `lib/maf/setup_agent/worktree.rb`; each script carries its signature; and the
literals that the standalone scripts share (lead roles, read-only toolsets,
the report format, the presence start time) are identical.

Run the checks and all tests:

```sh
rake                               # scripts/check.rb, RuboCop, then all tests
rake lint                          # RuboCop only
rake test TEST=test/coord_test.rb  # one test file
```

RuboCop (`gem install rubocop -v 1.91.0`) uses `.rubocop.yml`. It sets the
size rules: a class at most 100 lines, a method at most 5 lines and 4
parameters, a line at most 120 characters. `.rubocop_todo.yml` lists the code
that broke a rule before the config existed. Fix an entry, then delete it.
Do not add new entries.

`rake test` runs each test file in its own process, in parallel, and prints the
output of a failed file only. It unsets the variables below for each test.

An agent session exports `TASKRC` and `COORD_DIR` for the shared board. Unset
them when you run a test file directly, so a test never writes to that board:

```sh
env -u TASKRC -u COORD_DIR -u COORD_ROLE -u COORD_WORKER ruby test/coord_test.rb
```

```sh
ruby test/coord_test.rb      # covers the coord CLI
ruby test/installer_test.rb  # covers bootstrap.rb, flow.rb, setup_agent.rb
ruby test/uninstaller_test.rb  # covers uninstall.rb
ruby test/migrate_test.rb    # covers migrate.rb
ruby test/roles_workflow_test.rb  # covers project roles and the workflow
ruby test/graph_age_test.rb  # covers vault age and the graph prompt rules
ruby test/mcp_test.rb        # covers the MCP server wiring
ruby test/maf_test.rb        # covers the maf command
ruby test/dashboard_test.rb  # covers the dashboard data
ruby test/doc_graph_refresh_test.rb  # covers the doc-graph refresh
ruby test/hook_session_test.rb       # covers session isolation
ruby test/hook_config_test.rb        # covers project hooks and legacy hook removal
ruby test/dispatcher_test.rb         # covers the dispatcher
ruby test/board_watch_test.rb        # covers the board watcher
ruby test/context_watch_test.rb      # covers the context-watch hook
ruby test/worker_control_test.rb     # covers maf worker
ruby test/untrack_test.rb            # covers maf untrack
ruby test/analyst_test.rb            # covers the analyst
ruby test/shared_test.rb             # covers lib/maf/shared/
```

Minitest, stdlib only. Tests that require `task`, `git`, or `node` skip (exit 0)
when those tools are absent. The dashboard tests need the `webrick` gem.
CI (`.github/workflows/test.yml`) installs all of them and runs the checks and
tests on Linux and macOS, and RuboCop, for each push to `main` and each pull
request.

---

## Design notes

- **Taskwarrior is the single source of truth**, in a project-local database
  (`.maf/coordination/taskdata`, via `.maf/coordination/taskrc`) — never the user's
  global `~/.task`. Two projects on this flow never share one board.
  `coord board`/`export` are read-only projections.
- **Agents never call `task` directly.** `coord` keeps the protocol stable and
  lets the storage backend change later.
- **Terminology:** see [docs/flow-glossary.md](docs/flow-glossary.md). One role can run as several
  workers. `claim` is atomic, so two workers cannot take the same task.
- **A claim is a lease.** Idle past `COORD_LEASE_TTL` seconds (default 4 hours)
  it becomes claimable again without `--force`. `coord unclaim` releases one on
  demand.
- **Worktrees live inside the project** at `.maf/worktrees/<role>-<worker_id>`.
  `.maf/worktrees/` is excluded from git. In each worktree, run `source .maf/env.sh` so
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

---

## Acknowledgements

- The `panel` workflow and the `skeptic` and `auditor` roles come from
  [shipyard](https://github.com/esse/shipyard) by Piotr Szmielew. Shipyard sends
  a plan and a branch to adversarial reviewers from different model families.
  The rules for critical findings and cited lines also come from shipyard.
