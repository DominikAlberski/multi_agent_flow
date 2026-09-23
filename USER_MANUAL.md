# User manual

This manual takes you from a fresh clone of this repository to a working
multi-agent team in your own project. Do the steps in order.

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
  when there is work. The agent exits when the work is done. An idle
  dispatched agent costs no tokens.

Any role can use either mode. Any harness can use either mode.

---

## Quick install via an agent

If you have any AI coding agent open in your **project** folder, you can
install the flow without following the steps below manually.

Say to the agent:

```
install workflow from /path/to/multi_agent_flow
```

Replace `/path/to/multi_agent_flow` with the real path to this repository.

The agent reads `install.md` from that path and runs the generator for you.
It asks you which harnesses and roles to use, then runs the generator,
verifies the result, and tells you what to start next.

This works in Claude Code, opencode, Codex, and any other agent that can
read files and run shell commands.

If you prefer to do the steps yourself, continue below.

---

## 0. Prerequisites (one time)

Check the tools:

```sh
ruby -v             # need 3.0 or later
task --version      # Taskwarrior
git --version
claude --version; opencode --version; hermes --version
```

If Ruby is older than 3.0, install a new Ruby:

```sh
brew install mise && mise install ruby
```

If `task` is missing, install it:

```sh
brew install task
```

Optional: install `graphify` for the shared code knowledge graph:

```sh
uv tool install graphifyy
```

## 1. Set a variable for this repository

```sh
export FLOW=~/Projects/AI/multi_agent_flow
```

This repository is only the installer. You do not work in it. You work in
your own project.

## 2. Select the project

The project must be a git repository with at least one commit.

```sh
export PROJECT=~/Projects/my-app
cd "$PROJECT" && git log --oneline -1
```

**Expected result:** the command prints one commit. If it prints nothing,
make a first commit.

## 3. List the roles

```sh
ruby "$FLOW/scripts/flow.rb" --list-roles
```

**Expected result:** 6 roles. Each role has a description and a model hint.
The model hint is only a recommendation.

## 4. Preview the installation

```sh
ruby "$FLOW/scripts/flow.rb" --project "$PROJECT" \
  --agent claude:project-manager \
  --agent claude:architect \
  --agent claude:reviewer \
  --agent opencode:backend-developer \
  --agent opencode:frontend-developer \
  --agent hermes:tester \
  --check
```

**Expected result:** a list of `create ...` lines, then
`--check: no changes made.` The command writes nothing.

Optional: add one `--model ROLE=MODEL` flag per role. Use the model name
that the harness CLI accepts:

- Claude Code: `opus` or `sonnet`.
- opencode and Hermes: `provider/model`.

If you do not set a model, the harness uses its default model.

## 5. Install

Run the same command without `--check`.

**Expected result:**

- The output shows `Generated agent files:` with one line per role:
  - `.claude/agents/<role>.md`
  - `.opencode/agents/<role>.md`
  - `~/.hermes/skills/my-app-tester/SKILL.md`
- The project has these new files:
  - Scripts: `coord`, `setup_agent`, `dispatcher`, `vault`.
  - `AGENTS.md`, `CLAUDE.md`, `.gitignore`, `.agent-flow.json`.
  - `coordination/`: the task board, inboxes, sessions, and locks.
- If `graphify` is installed, the vault watcher starts in the background.

## 6. Commit the installed files

This step is important. Each agent works in its own git worktree. A worktree
contains only committed files.

```sh
cd "$PROJECT"
git add coord setup_agent dispatcher vault AGENTS.md CLAUDE.md .gitignore \
        .agent-flow.json .claude .opencode coordination
git commit -m "Add multi-agent flow"
```

The `.gitignore` rules already exclude the runtime state: the task database,
messages, sessions, handoff notes, and logs.

## 7. Verify the installation

```sh
./coord init
./coord status
```

**Expected result:**

- `./coord init` prints `coordination/ ready (coordination)`.
- `./coord status` prints `no tasks`.

## 8. Start the interactive agents

Open one terminal per interactive agent. In each terminal, run
`cd "$PROJECT"` first.

```sh
./setup_agent claude project-manager          # terminal 1
./setup_agent claude architect                # terminal 2
./setup_agent opencode backend-developer_1    # terminal 3
```

**Expected result for each terminal:**

- The script creates a worktree at `../my-app.worktrees/<role>-1` on its own
  `agent/...` branch.
- The terminal moves into the worktree.
- The harness starts with the role loaded.
- An idle worker waits with `./coord next --wait`. The wait costs no tokens.

To run 2 instances of one role, start `backend-developer_2` too. A claim is
atomic, so 2 workers never take the same task.

## 9. Start the dispatched agents

Open one terminal per dispatched agent. In each terminal, run `cd "$PROJECT"`
first. Then add `--dispatch` to the `setup_agent` command:

```sh
./setup_agent hermes tester --dispatch --model openrouter/deepseek-v3   # terminal 4
./setup_agent claude reviewer --dispatch --model sonnet                 # terminal 5
./setup_agent opencode frontend-developer --dispatch                    # terminal 6
```

`setup_agent --dispatch` does these things:

1. It creates or reuses a worktree at `../my-app.worktrees/<role>-bot` on its
   own `agent/<role>-bot` branch.
2. It connects the worktree to the task board of the main project.
3. It starts `./dispatcher` in the worktree with the harness and the model.

The worker name defaults to `bot`. Thus a dispatched agent never shares a
worktree with an interactive agent of the same role (`<role>-1`).

Put more dispatcher flags after `--dispatch`. Example:
`./setup_agent claude reviewer --dispatch --cache-window 1500 --interval 30`.

**Expected result:** the dispatcher prints one start line:

```
dispatcher: started: role=tester harness=hermes interval=60s cache_window=3300s
```

Then the dispatcher is silent until there is work. When a message or a task
arrives, the dispatcher prints:

```
dispatching tester (session: new)
agent finished: <short reply>
```

The built-in harnesses are `hermes` (default), `claude`, `codex`, and
`opencode`. For any other harness, use a `--command` template. Refer to the
README.

> **Warning:** the dispatcher disables all permission prompts (hermes
> `--yolo`, claude `bypassPermissions`, codex bypass). The agent runs every
> tool call without approval. Always run a dispatcher in its own worktree.

## 10. How the dispatcher saves tokens

You do not have to do anything for this. The dispatcher does it
automatically.

- **Messages.** The dispatcher sends all waiting messages to one agent run.
  If a message fails 3 runs, it moves to `inbox/<role>/failed/`. The count
  stays correct after a restart.
- **Tasks.** The dispatcher does not retry the same unclaimed tasks every
  minute. The wait doubles after each run, up to 1 hour. A new task starts a
  run immediately.
- **Prompt cache.** LLM providers cache a conversation for a limited time
  after the last request. Claude Code uses a 1-hour cache. Check the cache
  time of your provider for the other harnesses.
  - If the last run ended less than 55 minutes ago, the dispatcher resumes
    the session. The provider reads the old context from the cache. This is
    cheap.
  - If the last run is older, the dispatcher starts a fresh session. The
    fresh session gets a short handoff note, not the full old context. The
    log shows `idle Nm, past the cache window; starting fresh with the
    handoff note`.
  - Each run ends with a handoff note in
    `coordination/sessions/<worker>.handoff.md`. The agent writes the note
    while the cache is still warm.
- **Cache window.** Set `--cache-window` to your provider's cache time minus
  a margin. Add it to the `setup_agent ... --dispatch` command. For a
  30-minute cache, use `--cache-window 1500`. To never
  resume a session, use `--cache-window 0`.

## 11. Give the team work

Talk only to the project manager (terminal 1). Example request: "Add a
/health endpoint that returns the app version. Add tests and a UI badge."

**Expected result:**

1. The project manager sends the goal to the architect.
2. The architect creates tasks with `./coord add` and `./coord annotate`.
3. Interactive workers take their tasks immediately. Dispatched workers
   start within about 60 seconds.
4. Each worker writes code in its worktree and runs the tests.
5. Each worker reports with `./coord annotate` and `./coord done`.
6. The tester and the reviewer check the work.
7. The architect reports to the project manager.
8. The project manager reports to you.

## 12. Monitor the progress

Run these commands from any terminal in the project:

```sh
./coord status                    # tasks per role
./coord log 20                    # last 20 events: claims, done, messages, broadcasts
./coord board                     # writes coordination/exports/board.md (Obsidian kanban)
ls coordination/sessions/         # one .session and one .handoff.md per dispatched worker
ls coordination/inbox/*/failed/   # messages that failed 3 times (must be empty)
```

## 13. Merge the results

Each agent commits on its own branch. You merge the branches into main.

```sh
git branch --list 'agent/*'
git diff main..agent/backend-developer-1
git merge agent/backend-developer-1
```

## 14. Stop the team

1. Exit each interactive session.
2. Press Ctrl-C in each dispatcher terminal.
3. If the vault watcher runs, run `./vault stop`.

The worktrees can stay for the next session. To remove a worktree, run:

```sh
git worktree remove ../my-app.worktrees/<name>
```

## Change the setup later

Run `flow.rb` again with the new `--agent` list. Then commit. The generator
skips unchanged files and updates old files in place.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Ruby syntax error, or `Ruby 3.0+ required` | Install Ruby 3.0 or later (step 0). |
| A worktree has no `./coord` | Do the commit in step 6. |
| A dispatcher logs `agent failed` | Read the last log lines. The usual causes are a missing CLI login or a model name that the harness does not accept. |
| Two dispatchers for one role share a session | Set a different `COORD_WORKER=...` for each dispatcher. |
| Hermes reports an unknown skill | Run `flow.rb` again with `--agent hermes:tester`. |

## Test status

- Claude Code dispatch: tested with real runs. A new session, a warm resume,
  and a cold restart with a handoff note work.
- Hermes: the flags and the "session not found" error are verified. A full
  dispatched run is not tested.
- Codex and opencode: the session ID output and the "session not found"
  errors are verified. A successful run is not tested.
