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

The agent asks which harnesses and roles to use, runs the generator, and prints
the `setup_agent` commands to start each session. This works with Claude Code,
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

### 1. Set variables

```sh
export FLOW=~/Projects/AI/multi_agent_flow
export PROJECT=~/Projects/my-app
```

`FLOW` is this repository (the installer). `PROJECT` is your project.

### 2. Confirm the project has at least one commit

```sh
cd "$PROJECT" && git log --oneline -1
```

The command prints one commit. If it prints nothing, make a first commit.

### 3. List the available roles

```sh
ruby "$FLOW/scripts/flow.rb" --list-roles
```

Each role has a description and a model hint. The model hint is a recommendation
only.

### 4. Preview the install

```sh
ruby "$FLOW/scripts/flow.rb" --project "$PROJECT" \
  --agent claude:project-manager \
  --agent claude:architect \
  --agent opencode:backend-developer \
  --agent opencode:frontend-developer \
  --agent claude:reviewer \
  --agent hermes:tester \
  --check
```

Expected output: a list of `create ...` lines, then `--check: no changes made.`
Nothing is written.

Add `--model ROLE=MODEL` to pin a model per role. Use the model name the harness
CLI accepts:

- Claude Code: `opus` or `sonnet`
- opencode and Hermes: `provider/model` (e.g., `openrouter/deepseek-v3`)

### 5. Install

Remove `--check` from step 4 and run again.

Expected output:

- `Generated agent files:` with one line per role:
  - `.claude/agents/<role>.md`
  - `.opencode/agents/<role>.md`
  - `~/.hermes/skills/my-app-tester/SKILL.md`
- New files in the project: `coord`, `setup_agent`, `dispatcher`, `vault`,
  `dashboard`, `AGENTS.md`, `CLAUDE.md`, `.gitignore`, `.agent-flow.json`,
  `coordination/`.

### 6. Commit the installed files

Each agent works in its own git worktree. A worktree contains only committed
files, so commit before starting any agent.

```sh
cd "$PROJECT"
git add coord setup_agent dispatcher vault dashboard AGENTS.md CLAUDE.md \
        .gitignore .agent-flow.json .claude .opencode coordination
git add vault-daemon 2>/dev/null; true   # if bootstrap.rb used vault-daemon instead of vault
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
./setup_agent claude project-manager          # terminal 1
./setup_agent claude architect                # terminal 2
./setup_agent opencode backend-developer_1   # terminal 3
```

`setup_agent HARNESS ROLE[_WORKER]` does these things in one command:

1. Creates or reuses a worktree at `.worktrees/<role>-<worker_id>` on branch
   `agent/<role>-<worker_id>`.
2. Sources `coord-env.sh` so the worktree shares the main project's
   `coordination/` dir and task board.
3. Exports `COORD_AGENT`, `COORD_WORKER`, `COORD_DIR`, and `TASKRC`.
4. Launches the harness in that worktree with the role loaded.

Harness-specific notes:

- **opencode / codex**: loads the role file via `--agent ROLE`.
- **claude**: `.claude/agents/ROLE.md` is a subagent definition, not the session's
  persona. `setup_agent` passes an initial prompt telling the session to read and
  follow the role file.
- **hermes**: loads the role as a skill via `--skills <project>-<role>`. The skill
  file must exist at `~/.hermes/skills/<project>-<role>/SKILL.md` (generated by
  `flow.rb`).

`WORKER` defaults to `1`. To run two instances of one role, start
`backend-developer_2` too. Claims are atomic; two workers never take the same task.

---

## Start the dispatched agents

Open one terminal per dispatched agent. Run `cd "$PROJECT"` first in each.
Add `--dispatch` to the `setup_agent` command:

```sh
./setup_agent hermes tester --dispatch --model openrouter/deepseek-v3   # terminal 4
./setup_agent claude reviewer --dispatch --model sonnet                 # terminal 5
./setup_agent opencode frontend-developer --dispatch                    # terminal 6
```

`--dispatch` runs `./dispatcher` in the worktree instead of an interactive session:

1. Creates or reuses a worktree at `.worktrees/<role>-bot` on branch
   `agent/<role>-bot`. The `-bot` worker id keeps dispatched workers separate
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
`./setup_agent claude reviewer --dispatch --cache-window 1500 --interval 30`.

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

1. The project manager sends the goal to the architect.
2. The architect creates tasks with `./coord add` and assigns them to roles.
3. Interactive workers take their tasks immediately. Dispatched workers start
   within about 60 seconds.
4. Each worker writes code in its worktree and runs the tests.
5. Each worker reports with `./coord annotate` and `./coord done`.
6. The tester and the reviewer check the work.
7. The architect reports to the project manager.
8. The project manager reports to you.

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
messages, stale locks, orphaned tasks, and scope conflicts.

```sh
./dashboard           # default port 4567
./dashboard --port N  # custom port
```

---

## Shared knowledge base

`bootstrap.rb` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time. Check:

```sh
./vault status
```

If `graphify` was installed after bootstrap, start the watcher by hand:

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

MCP: set `./vault mcp` as the command in your MCP client config. `graphify-mcp`
is a separate stdio binary; it is not a background flag.

Open the `obsidian/` folder in Obsidian to see the code graph. To see
`coordination/exports/board.md` as a kanban alongside the graph, open the project
root as the Obsidian vault.

---

## Message hooks

`coord msg` and `coord broadcast` fire a per-role hook at
`coordination/hooks/<role>.sh` when a message is delivered. The hook is a plain
shell script. If there is no hook, `coord` only writes the inbox file.

```sh
# coordination/hooks/backend-developer.sh
#!/bin/sh
# Poke a running tmux session to check its inbox
tmux send-keys -t backend './coord inbox' Enter
```

Hook environment variables:

- `COORD_AGENT`: the receiving role.
- `COORD_FROM`: the sender.
- `COORD_MSG_FILE` and `$1`: the message file path.

The hook runs in the background; a slow hook does not block the sender. Output
goes to `coordination/hooks/<role>.log`. `coord hooks [ROLE]` lists installed
hooks and their status.

---

## Merge the results

Each agent commits on its own branch. You merge the branches into main.

```sh
git branch --list 'agent/*'
git diff main..agent/backend-developer-1
git merge agent/backend-developer-1
```

---

## Stop the team

1. Exit each interactive session.
2. Press Ctrl-C in each dispatcher terminal.
3. If the vault watcher runs, run `./vault stop`.

Worktrees can stay for the next session. To remove a worktree:

```sh
git worktree remove .worktrees/<name>
```

---

## Change the setup later

Run `scripts/flow.rb` again with the new `--agent` list. The generator skips
unchanged files and updates changed files in place. Then commit.

---

## Command reference

| Command | What it does |
|---|---|
| `./coord init` | Create the `coordination/` folders. |
| `./coord add --agent ROLE --scope S --title T` | Create a task for a role. Prints the ID. |
| `./coord next [ROLE]` | List unclaimed tasks for a role (defaults to `$COORD_AGENT`). |
| `./coord next --wait` | Block (polls every 60s) until a task appears. |
| `./coord next --mine` | List the tasks this worker has claimed. |
| `./coord conflicts` | List pending tasks whose scopes overlap. |
| `./coord claim ID` | Atomically claim a task for `$COORD_WORKER`. Refuses to steal an active claim. |
| `./coord unclaim ID` | Release a claim without finishing it. |
| `./coord done ID` | Complete a task. |
| `./coord annotate ID TEXT` | Add a note to a task (permanent). |
| `./coord msg --from A TO TEXT` | Send a message to a role. |
| `./coord broadcast --from A TEXT` | Send a message to every known role except the sender. |
| `./coord inbox [ROLE]` | Read messages (marks them read; `--peek` keeps them; `--wait` blocks). |
| `./coord log [N]` | Show the last N coordination events. |
| `./coord lock NAME --ttl S` | Take an advisory lock. |
| `./coord unlock NAME` | Release a lock. |
| `./coord with-lock NAME -- CMD` | Run a command under a lock. |
| `./coord worktree ROLE [WORKER]` | Create a git worktree + branch for a role. Source `coord-env.sh` inside it. |
| `./coord hooks [ROLE]` | List installed message hooks and their status. |
| `./coord status` | Show tasks by role and state. |
| `./coord board` | Write the Obsidian board file. |
| `./coord export` | Write the raw tasks JSON. |
| `./setup_agent HARNESS ROLE[_WORKER]` | Worktree + env + role + launch the harness, in one command. |
| `./setup_agent HARNESS ROLE --dispatch [FLAGS]` | Same setup, then run `./dispatcher`. |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Ruby 3.0+ required` or syntax error | Install Ruby 3.0 or later (step 0). |
| A worktree has no `./coord` | Do the commit (step 6) before running `setup_agent`. |
| A dispatcher logs `agent failed` | Read the last log lines. Usual causes: missing CLI login, or a model name the harness does not accept. |
| Two dispatchers for one role share a session | Set a different `COORD_WORKER` for each dispatcher. |
| Hermes reports an unknown skill | Run `scripts/flow.rb --agent hermes:ROLE` to generate the skill file. |

---

## Test status

- Claude Code dispatch: tested with real runs. New session, warm resume, and cold
  restart with handoff note all work.
- Hermes: flags and the "session not found" error verified. A full dispatched run
  is not tested.
- Codex and opencode: session ID output and "session not found" errors verified.
  A successful run is not tested.
