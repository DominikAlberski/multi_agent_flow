# User manual

This manual takes you from a fresh clone to a working multi-agent team in your
own project. Do the steps in order.

The example uses 3 harnesses and 6 roles:

| Role | Harness | Mode |
|---|---|---|
| project-manager | Claude Code | interactive (you talk to it) |
| architect | Claude Code | interactive |
| backend-developer | opencode | interactive |
| frontend-developer | opencode | dispatched |
| reviewer | Claude Code | dispatched |
| tester | Hermes | dispatched |

- **Interactive:** a terminal session stays open. You can watch the agent work.
- **Dispatched:** no session stays open. `./dispatcher` starts the agent only
  when there is work. The agent exits when the work is done. An idle dispatched
  agent costs no tokens.

Any role can use either mode. Any harness can use either mode.

---

## Option A — agent-driven install (fastest)

Open any AI coding agent in your **project** folder and say:

```
Here is the multi-agent flow setup: /path/to/multi_agent_flow/install.md. Read it and implement it.
```

Replace the path with the real path on your machine.

The agent asks which harnesses and roles to use, runs `maf add`, and prints
the `maf start` commands to start each session. This works with Claude Code,
opencode, Codex, and any other agent that can read files and run shell commands.

If you prefer to do the steps yourself, continue with Option B.

---

## Option B — manual install

### 0. Prerequisites (one time)

```sh
ruby -v             # need 3.0 or later
task --version      # Taskwarrior
git --version
```

If Ruby is older than 3.0:

```sh
brew install mise && mise install ruby
```

If `task` is missing:

```sh
brew install task
```

Optional: install `graphify` for the shared code-knowledge graph:

```sh
uv tool install graphify
```

### 1. Install the maf command

Link `bin/maf` from this repository into a folder on `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf ~/Projects/AI/multi_agent_flow/bin/maf ~/.local/bin/maf
maf help
```

If `maf help` fails, add `~/.local/bin` to `PATH`. Run every `maf` command in
the project root. `maf` uses the current directory as the project.

Run `maf` without a command to use the interactive menu. The menu does the
steps below and asks for each value. The steps below use the commands.

### 2. Confirm the project has at least one commit

```sh
export PROJECT=~/Projects/my-app
cd "$PROJECT" && git log --oneline -1
```

The command prints one commit. If it prints nothing, make a first commit.

### 3. List the available roles

```sh
maf roles
```

Each role has a description and a model hint. The model hint is a recommendation
only.

### 4. Preview the install

```sh
maf add claude:project-manager claude:architect \
  opencode:backend-developer opencode:frontend-developer \
  claude:reviewer hermes:tester --check
```

Expected output: a list of `create ...` lines, then `--check: no changes made.`
Nothing is written.

Add `--model ROLE=MODEL` to pin a model per role. Use the model name the harness
CLI accepts:

- Claude Code: a full model ID (e.g., `claude-opus-5-5`) or an alias (`opus`, `sonnet`)
- opencode and Hermes: `provider/model` (e.g., `openrouter/deepseek-v3`)

If you do not pin a model, every `claude` role gets `claude-opus-5-5`.
The other harnesses have no default. Their CLI picks the model.

### 5. Install

Remove `--check` from step 4 and run again.

Expected output:

- `Generated role files:` with one line per role:
  - `.claude/agents/<role>.md`
  - `.opencode/agents/<role>.md`
  - `~/.hermes/skills/my-app-tester/SKILL.md`
- New files in the project: `coord`, `dispatcher`, `vault`,
  `dashboard`, `AGENTS.md`, `.gitignore`, `.agent-flow.json`, `coordination/`.
- If the project had a `CLAUDE.md` or `.claude/CLAUDE.md`, `maf add` moves its
  text into `AGENTS.md` and deletes the file. Claude Code reads `AGENTS.md`
  only when no `CLAUDE.md` exists.

### 6. Commit the installed files

Each agent works in its own git worktree. A worktree contains only committed
files, so commit before starting any agent.

```sh
cd "$PROJECT"
git add coord dispatcher vault dashboard AGENTS.md \
        .gitignore .agent-flow.json .claude .opencode coordination
git rm --cached -q --ignore-unmatch CLAUDE.md .claude/CLAUDE.md   # maf add moved it into AGENTS.md
git add vault-daemon 2>/dev/null; true   # if maf add used vault-daemon instead of vault
git commit -m "Add multi-agent flow"
```

The `.gitignore` rules already exclude runtime state (task database, inboxes,
sessions, handoff notes, logs).

### 7. Verify

```sh
cd "$PROJECT"
./coord init
./coord status
```

Expected output:

- `./coord init` prints `coordination/ ready (coordination)`.
- `./coord status` prints `no tasks`.

---

## Start the interactive agents

Open one terminal per interactive agent. Run `cd "$PROJECT"` first in each.

```sh
maf start claude project-manager          # terminal 1
maf start claude architect                # terminal 2
maf start opencode backend-developer_1   # terminal 3
```

`maf start HARNESS ROLE[_WORKER]` does these things in one command:

1. Creates or reuses a worktree at `.worktrees/<role>-<worker_id>` on branch
   `worker/<role>-<worker_id>`.
2. Sources `coord-env.sh` so the worktree shares the main project's
   `coordination/` dir and task board.
3. Exports `COORD_ROLE`, `COORD_WORKER`, `COORD_DIR`, and `TASKRC`.
4. Launches the harness in that worktree with the role loaded.

Harness-specific notes:

- **opencode / codex**: loads the role file via `--agent ROLE`.
- **claude**: `.claude/agents/ROLE.md` is a subagent definition, not the session's
  persona. `maf start` passes an initial prompt telling the session to read and
  follow the role file.
- **hermes**: loads the role as a skill via `--skills <project>-<role>`. The skill
  file must exist at `~/.hermes/skills/<project>-<role>/SKILL.md` (generated by
  `maf add`).

`WORKER` defaults to `1`. To run two instances of one role, start
`backend-developer_2` too. Claims are atomic; two workers never take the same task.

### Let the project manager run the team

Give the project manager a budget. Example:

> "You have 6 worker slots. Use claude and opencode with deepseek-v4-flash.
> Manage your team in dispatch mode."

The project manager records the budget:

```sh
maf team set --max 6 --allow claude --allow opencode:deepseek-v4-flash
```

Then it adds workers itself, for example
`maf prepare opencode backend-developer_1 --dispatch`. With `--dispatch`,
`maf prepare` starts the dispatcher in the background. You run no commands.

- `maf team` shows the budget, each worker, its state, and the tasks by role.
- `maf prepare` refuses a harness or a model outside the budget, and a worker
  over `max_workers`. The project manager does not count.
- If only one model is allowed for a harness, `maf prepare` uses that model.
- `maf retire` sends TERM to a background dispatcher. A running agent run
  finishes first. Then the dispatcher exits.
- A task for a role without a worker sends a message to the project manager.
- Each done task sends a message to the architect, so a dispatched architect
  starts when there is work to check.
- Background dispatchers log to `coordination/sessions/<worker>.log`.
- A background dispatcher keeps running when the project manager's session
  ends. Run `maf retire` for each worker to stop the team.

### Isolate test databases and ports

Each worktree gets a unique number, `COORD_SLOT`, in its `coord-env.sh`.
The main worktree is slot 0. To give each worktree its own test database
and server port, add a project hook:

```bash
cp <multi_agent_flow>/assets/worktree-env.example.rb coordination/worktree-env.rb
git add coordination/worktree-env.rb
```

`coord worktree` runs the hook and adds its `export NAME=VALUE` lines to
`coord-env.sh`. The Rails example sets `TEST_ENV_NUMBER`, `PORT`, and
`CAPYBARA_SERVER_PORT`. Use `TEST_ENV_NUMBER` in `config/database.yml`.
Existing worktrees get the new variables on the next `coord worktree` or
`maf start` run.

Run the full suite with system tests under one lock:
`./coord with-lock system-test -- bin/rails test:all`.

### Keep interactive Claude Code agents awake

An idle Claude Code session does not poll the board by itself. `maf add`
adds two hooks to `.claude/settings.json`:

- `next-task.rb` (sync `Stop` hook): if unclaimed tasks exist when the agent
  stops, the hook continues the session at once.
- `board-watch.rb` (`asyncRewake` hook on `SessionStart` and `Stop`): the hook
  runs in the background and checks the board every 60 seconds.

`board-watch.rb` uses these rules:

1. If the session transcript changed in the last 120 seconds, the agent is
   running. The watcher does nothing.
2. If the agent is idle and the board has work for the role, the watcher pokes
   the agent. Work is unclaimed tasks, tasks that this worker claimed, and
   unread inbox messages. The poke wakes the session with a work prompt.
3. If the work did not change since the last poke, the next poke waits twice
   as long, up to 1 hour.

One watcher runs per worker. The lock is `coordination/locks/board-watch-<worker>.d`.
The watcher stops when its Claude Code process stops. The watcher does nothing
for the user's own sessions (no `COORD_ROLE`) and for dispatched agents
(`COORD_DISPATCHED=1`). To change the timing, set `BOARD_WATCH_INTERVAL` and
`BOARD_WATCH_IDLE` (seconds) before you run `maf start`.

Codex and opencode role files tell the agent to block in
`./coord next --wait --timeout 540` when it has no work. The command returns
when a task or a message arrives. Codex has no wake hook. Use `--dispatch` to
run Codex agents unattended.

### Keep interactive opencode agents awake

An opencode agent can end its turn and leave the wait loop. `maf add` installs
the plugin `.opencode/plugins/board-watch.js` for projects with opencode
agents. The plugin uses these rules:

1. When the top-level session goes idle, the plugin checks the board at once.
   Then the plugin checks the board every `BOARD_WATCH_INTERVAL` seconds.
2. Each check runs `coordination/harness-hooks/board-watch.rb --once`. The
   script applies the same work rules and backoff as the Claude Code watcher.
3. If the board has work, the plugin sends the work prompt to the session.
4. When the session is busy again, the checks stop.

The plugin does nothing without `COORD_ROLE` and for dispatched agents
(`COORD_DISPATCHED=1`). Subagent sessions do not start checks.

### Wake a Hermes agent at session end

Hermes runs `~/.hermes/agent-hooks/next-task.sh` when a session ends. The hook
resumes the session when the role has unclaimed tasks. `maf add` installs the
script. Two steps turn the hook on, because the flow never edits the Hermes
config:

```sh
hermes config set hooks.on_session_end '[{"command":"<script path>","timeout":30}]'
hermes chat --oneshot --accept-hooks -q ok
hermes hooks doctor
```

The first command replaces the whole `on_session_end` list. If entries exist
there already, read them with `hermes config get hooks.on_session_end` first.
Then set the list with your entries plus the new one.

The second command approves the hook one time. Hermes stores the consent for
this version of the script. An updated script needs a new approval.

`hermes hooks doctor` reports the state of the hook. All four checks must pass.

`maf add` and `maf update` report the state too. They print the steps that are
missing, or `hook ready` when the hook is active.

The hook does nothing outside this flow. It exits at once unless `COORD_ROLE` is
set, and `maf start` sets that variable.

---

## Start the dispatched agents

Open one terminal per dispatched agent. Run `cd "$PROJECT"` first in each.
Add `--dispatch` to the `maf start` command:

```sh
maf start hermes tester --dispatch --model openrouter/deepseek-v3   # terminal 4
maf start claude reviewer --dispatch --model sonnet                 # terminal 5
maf start opencode frontend-developer --dispatch                    # terminal 6
```

`--dispatch` runs `./dispatcher` in the worktree instead of an interactive session:

1. Creates or reuses a worktree at `.worktrees/<role>-bot` on branch
   `worker/<role>-bot`. The `-bot` worker id keeps dispatched workers separate
   from interactive workers of the same role.
2. Connects the worktree to the main project's task board.
3. Starts `./dispatcher` in the worktree.

Expected startup line:

```
dispatcher: started: role=tester harness=hermes interval=60s cache_window=3300s
```

The dispatcher is then silent until there is work. When a message or a task
arrives:

```
dispatching tester (session: new)
agent finished: <short reply>
```

Put dispatcher flags after `--dispatch`. Example:
`maf start claude reviewer --dispatch --cache-window 1500 --interval 30`.

> **Warning:** the dispatcher disables all permission prompts — hermes `--yolo`,
> claude `bypassPermissions`, codex and opencode bypass flags. The agent runs
> every tool call without approval. Always run a dispatcher in its own worktree.

The built-in harnesses are `hermes` (default), `claude`, `codex`, and `opencode`.
For any other harness, use `--command` with a template:

```sh
./dispatcher ROLE --command 'my-agent --role %{role} %{prompt}'
```

---

## How the dispatcher saves tokens

The dispatcher does this automatically — no action required.

**Messages.** All waiting messages go to one agent run. If a message fails 3
runs, it moves to `inbox/<role>/failed/`. The retry count stays correct after a
restart (stored in the file name: `.retry2.md`). Do not run `coord inbox` for a
role that a dispatcher serves.

**Tasks.** The dispatcher does not retry the same unclaimed tasks every minute.
The wait between runs doubles after each run, up to 1 hour. A new or changed
task starts a run immediately.

**Prompt cache.** LLM providers cache a conversation for a limited time after the
last request. Claude Code uses a 1-hour cache.

- If the last run ended less than `--cache-window` seconds ago (default: 3300 s,
  55 min), the dispatcher resumes the session. The provider reads the old context
  from the cache — cheap.
- If the last run is older, the dispatcher starts a fresh session. The fresh
  session gets a short handoff note (at most 300 words), not the full old context.
  The log shows: `idle Nm, past the cache window; starting fresh with the handoff note`.
- Each run ends with the handoff note in `coordination/sessions/<worker>.handoff.md`.
  The agent writes it while the cache is still warm.

Set `--cache-window` to your provider's cache time minus a margin. For a
30-minute cache: `--cache-window 1500`. To never resume: `--cache-window 0`.

---

## Give the team work

Talk to the project manager session (terminal 1). Example:

> "Add a /health endpoint that returns the app version. Add tests and a UI badge."

Expected sequence:

1. The project manager creates the goal with `./coord goal add`. The command
   creates branch `goal/<short-id>` from the base branch and the goal worktree
   `.worktrees/goal-<short-id>`.
2. The project manager sends the goal id to the architect.
3. The architect creates tasks with `./coord add --goal <id>` and assigns them to roles.
4. Interactive workers take their tasks immediately. Dispatched workers start
   within about 60 seconds.
5. Each worker runs `./coord start-task <id>`, writes code on branch
   `task/<short-id>`, runs the task tests, and commits.
6. Each worker reports with `./coord annotate` and `./coord done`.
7. The reviewer checks the diff. The architect merges each task branch into the goal branch.
8. The architect runs the full suite one time in the goal worktree and closes the goal.
9. The architect reports to the project manager. The project manager reports to you.

Check the goals at any time:

```sh
./coord goal list
./coord goal show <id>
```

Set the base branch in `.agent-flow.json` if it is not `main` or `origin/HEAD`:
`"base_branch": "AI_development"`. Goals never start from another goal branch,
so a defect in one goal does not block the others.

If you did not set up a `project-manager` role, talk to the architect session
directly.

---

## Monitor progress

Run from any terminal in the project:

```sh
./coord status                   # tasks per role, by state
./coord log 20                   # last 20 events: claims, done, messages
./coord board                    # writes coordination/exports/board.md
ls coordination/sessions/        # one .session + one .handoff.md per dispatched worker
ls coordination/inbox/*/failed/  # messages that failed 3 runs (should be empty)
```

### Obsidian kanban

`coord board` writes `coordination/exports/board.md`. Open it in Obsidian with
the Kanban plugin (mgmeyers/obsidian-kanban). Obsidian reloads the file
automatically. Keep it current while agents run:

```sh
watch -n 10 ./coord board
```

### Web dashboard

`./dashboard` starts a local server at `http://localhost:4567`. The page
auto-refreshes every 5 seconds. It shows everything `coord status` shows, plus
signals the kanban cannot: expired-lease claims (crashed workers), unread inbox
messages, stale locks, orphaned tasks, and scope conflicts. The Workers panel lists
each worker from `coordination/workers.json` with its harness, role, current task,
and last event. Each declared role has a card, also without tasks.

```sh
./dashboard           # default port 4567
./dashboard --port N  # custom port
```

---

## Shared knowledge base

`maf add` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time. Check:

```sh
./vault status
```

If `graphify` was installed after `maf add`, start the watcher by hand:

```sh
./vault
```

Commands:

```sh
./vault           # start (no-op if already running)
./vault export    # regenerate the Obsidian vault once
./vault status
./vault stop
./vault mcp       # exec the stdio MCP server (for an MCP client config)
```

The watcher runs `graphify update .` (incremental, no LLM) and
`graphify export obsidian --dir obsidian` every `VAULT_POLL` seconds (default 30).

A markdown commit or merge also refreshes the graph. `maf add` appends a flow
block to the `post-commit` and `post-merge` hooks. The block starts
`coordination/doc-graph-refresh` detached. The refresh runs
`graphify extract . --backend gemini` and re-exports `obsidian/`. It needs
`GEMINI_API_KEY` in the environment of the agent session. Without the key it
logs a skip in `coordination/doc-graph.log`. A non-markdown commit makes no LLM
call.

MCP: set `./vault mcp` as the command in your MCP client config. `graphify-mcp`
is a separate stdio binary; it is not a background flag.

Open the `obsidian/` folder in Obsidian to see the code graph. To see
`coordination/exports/board.md` as a kanban alongside the graph, open the project
root as the Obsidian vault.

---

## Message hooks

`coord msg` and `coord broadcast` fire a per-role hook at
`coordination/message-hooks/<role>.sh` when a message is delivered. The hook is a plain
shell script. If there is no hook, `coord` only writes the inbox file.
An agent does not need a hook to get a message. The board watcher (Claude Code)
and `coord next --wait` (other harnesses) wake the agent on an unread message.

```sh
# coordination/message-hooks/backend-developer.sh
#!/bin/sh
# Show a desktop notification (macOS)
osascript -e "display notification \"$COORD_FROM wrote to $COORD_ROLE\" with title \"coord\""
```

Hook environment variables:

- `COORD_ROLE`: the receiving role.
- `COORD_FROM`: the sender.
- `COORD_MSG_FILE` and `$1`: the message file path.

The hook runs in the background; a slow hook does not block the sender. Output
goes to `coordination/message-hooks/<role>.log`. `coord hooks [ROLE]` lists installed
hooks and their status.

---

## Merge the results

Each goal ends on its own branch `goal/<short-id>`. Open one pull request per goal:

```sh
git branch --list 'goal/*'
git diff main...goal/<short-id>
gh pr create --base main --head goal/<short-id>
```

---

## Stop the team

1. Exit each interactive session.
2. Press Ctrl-C in each dispatcher terminal.
3. If the vault watcher runs, run `./vault stop`.

### Change the team

Tell the project manager what to change. Example:

> "Replace backend developer 2 on claude with frontend developer 2 on opencode."

The project manager runs one command:

```sh
maf prepare opencode frontend-developer_2 --replace backend-developer_2
```

The command does these steps:

1. Checks that the old worker does not run and has no uncommitted work.
2. Adds the role file for the harness, if it is missing (`maf add`).
3. Creates the worktree and copies an uncommitted role file into it.
4. Registers the worker in `coordination/workers.json`. The dashboard shows it.
5. Returns the old worker's claimed tasks to the pool and removes its worktree.
   The task branches stay, so the next worker continues the committed work.
6. Tells the architect about the change.

Then run the two printed commands in a new terminal:

```sh
cd .worktrees/frontend-developer-2
maf start
```

If the old worker still runs in a terminal, `maf prepare` stops without
changes. Stop that session, then ask the project manager again. A background
dispatcher is different: `maf` stops it for you (see below). Without `--replace`, the command
adds a worker. `maf retire backend-developer_2` removes a worker.

Worktrees can stay for the next session. To remove a worktree:

```sh
git worktree remove .worktrees/<name>
```

---

## Change the setup later

`maf` keeps the agents in `.agent-flow.json`. Give only the changes:

```sh
maf add opencode:frontend-developer   # add an agent
maf remove claude:architect           # remove an agent
maf agents                            # list the current agents
maf update                            # regenerate the current agents
```

`maf remove` does not delete the generated role file.
The generator skips unchanged files and updates changed files in place. Then commit.

---

## Uninstall

Stop the team first (see above). Then preview what the uninstaller removes:

```sh
maf uninstall --check
```

Remove it. The uninstaller shows the list and asks for confirmation. Add
`--yes` to skip the question.

```sh
maf uninstall
```

The uninstaller removes:

- `coord`, `dispatcher`, `dashboard`, `vault` (or `vault-daemon`), and `setup_agent` from older installs.
- `coordination/`, with the task board, messages, locks, and message hooks.
- Clean worktrees in `.worktrees/`.
- Generated role files in `.claude/agents/`, `.opencode/agents/`, `.codex/prompts/`,
  and the project's Hermes skills.
- The flow hooks in `.claude/settings.json`.
- The flow blocks in the `post-commit` and `post-merge` git hooks.
- The marked blocks in `AGENTS.md` and `.gitignore`.
- `.agent-flow.json`.

The uninstaller keeps:

- `graphify-out/` and `obsidian/`. A rebuild costs many agent runs. Delete them
  by hand. `.gitignore` keeps their ignore rules.
- Files that do not carry the flow signature or marker, and text outside the
  marked blocks.
- `worker/*` branches. Merge or delete them with `git branch -D`.
- Worktrees with uncommitted changes. Add `--force` to remove them.
- The global Codex and Hermes hooks. Other projects can use them.

Commit the result.

---

## Upgrade from a version before GLOSSARY.md

This version renames terms (see [GLOSSARY.md](GLOSSARY.md)). It does not read
the old names. Old task boards and worktrees do not work with it.

| Old | New |
|---|---|
| `COORD_AGENT` | `COORD_ROLE` |
| `coord add --agent ROLE` | `coord add --role ROLE` |
| `coord lock NAME --agent A` | `coord lock NAME --worker W` |
| task field `agent` | task field `role` |
| branch `agent/<worker>` | branch `worker/<worker>` |
| `coordination/hooks/<role>.sh` (message hooks) | `coordination/message-hooks/<role>.sh` |
| `coordination/hooks/next-task.rb` and other harness hooks | `coordination/harness-hooks/` |
| dispatcher default worker `<role>-dispatcher` | `<role>-bot` |

Do these steps in the project:

1. Stop the team (see above).
2. Finish or write down the open tasks. The reset deletes them.
3. Remove the worktrees: `git worktree remove .worktrees/<name>` for each one.
4. Delete the old branches after you merge them: `git branch -D agent/<worker>`.
5. Delete `coordination/taskdata/` and `coordination/taskrc`.
6. Move your message hooks from `coordination/hooks/` to `coordination/message-hooks/`.
7. Delete the rest of `coordination/hooks/`.
8. In `.claude/settings.json`, delete the hook entries that point to `coordination/hooks/`.
9. Run `maf update`, then `./coord init`.
10. Commit.

---

## Command reference

| Command | What it does |
|---|---|
| `maf prepare HARNESS ROLE[_WORKER] [--replace W]` | Prepare a worker: role file, worktree, registry. Prints the two start commands. |
| `maf retire ROLE[_WORKER]` | Remove a worker. Stops its background dispatcher. Its claimed tasks return to the pool. |
| `maf team` | Show the budget, the workers, and the tasks by role. |
| `maf team set --max N --allow HARNESS[:MODEL]` | Set the team budget in `.agent-flow.json`. |
| `maf start ... --dispatch --detach` | Start a dispatcher in the background. |
| `maf start` (in a prepared worktree) | Start the worker that `maf prepare` made. |
| `./coord init` | Create the `coordination/` folders. |
| `./coord goal add --title T [--base B]` | Create a goal, its branch `goal/<short-id>`, and its worktree. Prints the ID. |
| `./coord goal list` / `goal show ID` | List open goals, or show one goal and its tasks. |
| `./coord goal done ID` | Close a goal. Refused while a task of the goal is open. |
| `./coord add --role ROLE --scope S --title T [--goal ID]` | Create a task for a role. Prints the ID. |
| `./coord next [ROLE]` | List unclaimed tasks for a role (defaults to `$COORD_ROLE`). |
| `./coord next --wait` | Block (polls every 60s) until a task or an unread message appears. Refused for lead roles. |
| `./coord next --mine` | List the tasks this worker has claimed. |
| `./coord conflicts` | List pending tasks whose scopes overlap. |
| `./coord claim ID` | Atomically claim a task for `$COORD_WORKER`. Refuses to steal an active claim. Refused for lead roles. |
| `./coord start-task ID` | In a worker worktree: check out `task/<short-id>` from the goal branch. |
| `./coord unclaim ID` | Release a claim without finishing it. |
| `./coord done ID [--force]` | Complete a task. Refused while the task branch has own commits and lacks the goal branch head. |
| `./coord annotate ID TEXT` | Add a note to a task (permanent). |
| `./coord msg --from A TO TEXT` | Send a message to a role. |
| `./coord broadcast --from A [--to workers\|leads\|all] TEXT` | Send a message to a group of roles. Default: workers. |
| `./coord inbox [ROLE]` | Read messages (marks them read; `--peek` keeps them; `--wait` blocks). |
| `./coord log [N]` | Show the last N coordination events. |
| `./coord lock NAME --ttl S` | Take an advisory lock. |
| `./coord unlock NAME` | Release a lock. |
| `./coord with-lock NAME -- CMD` | Run a command under a lock. |
| `./coord worktree ROLE [WORKER]` | Create a git worktree + branch for a role. Source `coord-env.sh` inside it. Warns if a harness has no file for the role. |
| `./coord hooks [ROLE]` | List installed message hooks and their status. |
| `./coord status` | Show tasks by role and state. |
| `./coord who` | List each worker with its presence (live or gone) from `coordination/presence/`. |
| `./coord board` | Write the Obsidian board file. |
| `./coord export` | Write the raw tasks JSON. |
| `maf start HARNESS ROLE[_WORKER]` | Worktree + env + role + launch the harness, in one command. |
| `maf start HARNESS ROLE --dispatch [FLAGS]` | Same setup, then run `./dispatcher`. |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Ruby 3.0+ required` or syntax error | Install Ruby 3.0 or later (step 0). |
| A worktree has no `./coord` | Do the commit (step 6) before running `maf start`. |
| A dispatcher logs `agent failed` | Read the last log lines. Usual causes: missing CLI login, or a model name the harness does not accept. |
| Two dispatchers for one role share a session | Set a different `COORD_WORKER` for each dispatcher. |
| Hermes reports an unknown skill | Run `maf add hermes:ROLE` to generate the skill file. |

---

## Test status

- Claude Code dispatch: tested with real runs. New session, warm resume, and cold
  restart with handoff note all work.
- Hermes: flags and the "session not found" error verified. A full dispatched run
  is not tested.
- Codex and opencode: session ID output and "session not found" errors verified.
  A successful run is not tested.
