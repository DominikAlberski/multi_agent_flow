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
- **Dispatched:** no session stays open. `dispatcher` starts the agent only
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

### 3b. Add a project role

A project can own a role. Run:

```sh
maf role add data-engineer
```

The command writes a stub role into `.maf/roles.yml`. Replace each `TODO` line.
The stub has four duty parts: focus, checks, done condition, and avoid.
Write them in Simplified Technical English.

The file `.maf/roles.yml` merges over the built-in roles. A role with a new
name adds a role. A role with the name of a built-in role replaces it.
`maf roles` shows the source of each role: `built-in` or `project`.
If the role exists already, `maf role add` changes nothing.

### 3c. Choose a workflow

A workflow is a list of stages in words. The architect reads it. The architect
creates the tasks of one stage at a time. The other roles do not see it.

Write the stages to `.maf/workflow.md`. Three examples are in
`templates/workflows/`: `simple`, `plan-review`, and `tdd`. Example:

```sh
cp templates/workflows/tdd.md .maf/workflow.md
maf update
```

`maf uninstall` keeps `.maf/roles.yml` and `.maf/workflow.md`, because you wrote them.

`maf update` splices the text into the architect role file under the heading
`Workflow:`. If `.maf/workflow.md` does not exist, the architect role file does
not change.

The architect does not create the task of the next stage before the gate of the
current stage passes. A task that does not exist cannot be claimed.
Task dependencies are not needed.

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
  - `.maf/agents/claude/<role>.md`
  - `.maf/agents/opencode/<role>.md`
  - `~/.hermes/skills/my-app-tester/SKILL.md`
- New files in the project: the folder `.maf/` (with `bin/`, `coordination/`,
  `agents/`, `claude/`, `mcp/`, `config.json`, and `env.sh`).
  The folders `.claude/agents/`, `.opencode/agents/`, and `.codex/prompts/`
  are symlinks into `.maf/agents/`.
- maf does not change `AGENTS.md`, `CLAUDE.md`, `.gitignore`, `.mcp.json`,
  `opencode.json`, or `.claude/settings.json`. These files belong to the project.

### 6. Nothing to commit

maf is a tool, not a part of the project. It lists `.maf/` and each link and
plugin that it creates in `.git/info/exclude`. That file is local to your
clone, so `git status` shows no maf file and nothing goes into git.

The project keeps what the agents make: the code, the decisions in
`docs/decisions/`, and `GLOSSARY.md`. If you remove maf, these stay.

Each agent works in its own git worktree. `coord worktree` and `maf start`
copy the flow files from the main project into each worktree.

The project needs at least one commit, because a worktree starts from a commit.

If an older maf version committed its files, run `maf untrack` one time (see
"Remove maf files from git").

### 7. Verify

```sh
cd "$PROJECT"
source .maf/env.sh
coord init
coord status
```

`source .maf/env.sh` puts `.maf/bin` on `PATH`. Run it in each new shell.

Expected output:

- `coord init` prints `.maf/coordination/ ready (.maf/coordination)`.
- `coord status` prints `no tasks`.

---

## Start the interactive agents

Open one terminal per interactive agent. Run `cd "$PROJECT"` first in each.

```sh
maf start claude project-manager          # terminal 1
maf start claude architect                # terminal 2
maf start opencode backend-developer_1   # terminal 3
```

`maf start HARNESS ROLE[_WORKER]` does these things in one command:

1. Creates or reuses a worktree at `.maf/worktrees/<role>-<worker_id>` on branch
   `worker/<role>-<worker_id>`.
2. Sources `.maf/env.sh` so the worktree shares the main project's
   `.maf/coordination/` dir and task board.
3. Exports `COORD_ROLE`, `COORD_WORKER`, `COORD_DIR`, and `TASKRC`.
4. Launches the harness in that worktree with the role loaded.

Harness-specific notes:

- **opencode**: loads the role file via `--agent ROLE`. `OPENCODE_CONFIG` adds the
  graphify server from `.maf/mcp/opencode.json`.
- **codex**: passes the role file `.codex/prompts/ROLE.md` as the first prompt, and
  `--add-dir .maf/coordination` so coord commands need no approval.
- **claude**: `.claude/agents/ROLE.md` is a subagent definition, not the session's
  persona. `maf start` passes an initial prompt telling the session to read and
  follow the role file. It also passes `--settings .maf/claude/settings.json` (the
  hooks) and `--mcp-config .maf/mcp/claude.json` (the graphify server).
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
`maf prepare` dispatches the architect by default: the architect never talks to you,
and a dispatched session stays small. Add `--interactive` for an architect in a terminal.

- `maf team` shows the budget, each worker, its state, and the tasks by role.
- `maf prepare` refuses a harness or a model outside the budget, and a worker
  over `max_workers`. The project manager does not count.
- If only one model is allowed for a harness, `maf prepare` uses that model.
- `maf retire` sends TERM to a background dispatcher. A running agent run
  finishes first. Then the dispatcher exits.
- Retirement moves the state of the worker into `.maf/coordination/archive/workers/<worker>-<timestamp>-<suffix>/`:
  the inbox as `inbox/` (also read messages), `usage.json`, `status.json`, and the session files
  (session id, handoff note, logs) as `sessions/`. Each retirement creates a separate archive.
  A reused worker ID starts clean: no old session to resume, no old handoff note, empty usage totals.
- A task for a role without a worker sends a message to the project manager.
- Each done task sends a message to the architect, so a dispatched architect
  starts when there is work to check.
- Background dispatchers log to `.maf/coordination/sessions/<worker>.log`.
- A background dispatcher keeps running when the project manager's session
  ends. Run `maf retire` for each worker to stop the team.

### Isolate test databases and ports

Each worktree gets a unique number, `COORD_SLOT`, in its `.maf/env.sh`.
The main worktree is slot 0. To give each worktree its own test database
and server port, add a project hook:

```bash
cp <multi_agent_flow>/assets/worktree-env.example.rb .maf/coordination/worktree-env.rb
```

`coord worktree` runs the hook and adds its `export NAME=VALUE` lines to
`.maf/env.sh`. The Rails example sets `TEST_ENV_NUMBER`, `PORT`, and
`CAPYBARA_SERVER_PORT`. Use `TEST_ENV_NUMBER` in `config/database.yml`.
Existing worktrees get the new variables on the next `coord worktree` or
`maf start` run.

Run the full suite with system tests under one lock:
`coord with-lock system-test -- bin/rails test:all`.

### Keep interactive Claude Code agents awake

An idle Claude Code session does not poll the board by itself. `maf add`
writes the hooks of the flow to `.maf/claude/settings.json`. `maf start` passes the
file with `claude --settings`. Claude Code runs these hooks next to the project's own
hooks, and `.claude/settings.json` stays as it is:

- `next-task.rb` registers the harness session ID on `SessionStart`.
  Its synchronous `Stop` hook continues a registered session when unclaimed tasks exist.
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

One watcher runs per worker. The lock is `.maf/coordination/locks/board-watch-<worker>.d`.
The watcher stops when its Claude Code process stops.
The watcher checks the launch token, process, worktree, worker, board, and registered harness session ID.
Inherited `COORD_ROLE` and `COORD_DIR` values do not activate an independent session.
The watcher does nothing for dispatched agents (`COORD_DISPATCHED=1`).
To change the timing, set `BOARD_WATCH_INTERVAL` and
`BOARD_WATCH_IDLE` (seconds) before you run `maf start`.

Messages often come in a group: each done task sends one to the architect.
The watcher wakes an agent for messages only when the oldest unread message is
`BOARD_WATCH_BATCH` seconds old (default: 120). One turn then reads the whole group.
A task wakes the agent at once.

### Restart a long interactive session

Each model call sends the whole session context again. A long session costs
more on every call. The `context-watch.rb` hook watches interactive Claude Code
and Codex sessions:

1. At each stop, the hook reads the context size from the session transcript.
2. If the context is over the limit, the hook asks the agent one time to write a
   handoff note to `.maf/coordination/sessions/<worker>.handoff.md`.
3. Then the hook shows: `Context: 162k tokens (limit 150k) ... Type /clear to restart.`
4. Type `/clear`. The new session gets the role file text and the handoff note as context.

The default limit is 150000 tokens. Set `"team": {"context_limit": 200000}` in
`.maf/config.json`, or `MAF_CONTEXT_LIMIT` before `maf start`.

The hook also writes the model and the context size to
`.maf/coordination/status/<worker>.json`, and adds the token usage of the session
to `.maf/coordination/usage/<worker>.json`. For an interactive worker, `runs`
counts the turns. The dispatcher writes the same status file for a dispatched worker.

Hermes role files tell the agent to block in
`coord next --wait --timeout 540` when it has no work. The command returns
when a task or a message arrives. Each timeout costs one model call, so use
`--dispatch` for idle Hermes agents.

Codex returns a long tool call to the model about every 30 seconds. A wait in a
tool call, or a `sleep` loop, costs one model call over the whole context per
return. So Codex role files use `coord await` instead. The agent runs
`coord await` and ends its turn. The stop hook (`next-task.rb`) then waits for a
waking message or a task without model calls, for up to 55 minutes. When work
arrives, the hook continues the session. Press Esc in Codex to end the wait.
Codex uses project hooks in `.codex/hooks.json` for `SessionStart` and `Stop`.
Codex runs the hooks only after you trust them, and each worktree needs its own trust.
`maf start` prints a warning when Codex does not trust the hooks of the worktree.
Without the hooks, the session records no token usage, and `coord await` cannot wake it.
Use `--dispatch` to run Codex agents unattended.

`maf update` disables the legacy global Codex hook and removes its registration from `~/.codex/hooks.json`.
Other global hooks stay.
Restart workers with `maf start` after the update.
Review the new project hook definitions when Codex requests hook trust.

### Keep interactive opencode agents awake

An opencode agent stops when it has no work. It does not wait in a loop:
each return of a wait costs one model call over the whole context. `maf add` installs
the plugin `.opencode/plugins/board-watch.js` for projects with opencode
agents. The plugin uses these rules:

1. When the top-level session goes idle, the plugin checks the board at once.
   Then the plugin checks the board every `BOARD_WATCH_INTERVAL` seconds.
2. Each check runs `.maf/coordination/harness-hooks/board-watch.rb --once`. The
   script applies the same work rules and backoff as the Claude Code watcher.
3. If the board has work, the plugin sends the work prompt to the session.
4. When the session is busy again, the checks stop.

The plugin requires a registered `maf start` session.
The plugin does nothing for dispatched agents (`COORD_DISPATCHED=1`).
Subagent sessions do not start checks.

### Wake a Hermes agent at session end

Hermes runs `~/.hermes/agent-hooks/next-task.sh` when a session ends. The hook
resumes the session when the role has unclaimed tasks. `maf add` installs the
script and its session guard. The guard rejects independent sessions and mismatched projects.
Two steps turn the hook on, because the flow never edits the Hermes
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

`--dispatch` runs `dispatcher` in the worktree instead of an interactive session:

1. Creates or reuses a worktree at `.maf/worktrees/<role>-bot` on branch
   `worker/<role>-bot`. The `-bot` worker id keeps dispatched workers separate
   from interactive workers of the same role.
2. Connects the worktree to the main project's task board.
3. Starts `dispatcher` in the worktree.

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

> **Warning:** the dispatcher disables the permission prompts — hermes `--yolo`,
> claude `bypassPermissions`, codex `--dangerously-bypass-approvals-and-sandbox`.
> opencode uses the permissions of its role file. The agent runs these tool calls
> without approval. Always run a dispatcher in its own worktree.

The built-in harnesses are `hermes` (default), `claude`, `codex`, and `opencode`.
For any other harness, use `--command` with a template:

```sh
dispatcher ROLE --command 'my-agent --role %{role} %{prompt}'
```

### The report block

The dispatcher asks each agent to end its final reply with a report block:

```
<report>{"status":"<done|blocked|needs_review>","tests":"<pass|fail>","next":"<next>"}</report>
```

- Status `done` is success. The dispatcher moves the messages to `read/`.
- Status `blocked` or `needs_review` means the run waits for someone else.
  The dispatcher logs the status and the `next` field. The session stays.
  The agent handled the messages, so the dispatcher moves them to `read/`.
  The dashboard shows the run as `waiting`.
- If the block is missing or invalid, the dispatcher resumes the session one
  time with the error. If the block is still invalid, the run failed. The
  messages go back to the inbox.
- If the block is still missing, the exit status decides, as before. A
  `--command` harness has no session, so the dispatcher does not resume it.

### Run limits

- `--timeout S` is the hard wall-clock limit of a run. Without the flag, the dispatcher
  reads `team.timeouts.<role>` in `.maf/config.json`, else it uses 1500 s:
  `"team": { "timeouts": { "reviewer": 2400 } }`.
  After a timeout, the dispatcher sends a message to the architect. The claims stay.
- In the next cycle, the dispatcher starts a resume run for the claimed tasks of its worker.
  It resumes claimed tasks before it takes new tasks.
- `--idle-timeout S` fails a run that prints no output for S seconds. Default: 0 (off).
  Claude Code prints its JSON only at the end. Keep this flag off for `--harness claude`.
- `--completion-signal TEXT` tells the agent to print TEXT when the work is complete.
  The run is a success. If the agent does not exit, the dispatcher stops it after the grace window.
- `--abort-signal TEXT` tells the agent to print TEXT when it gives up. The run is a failure.
- `--grace S` is the grace window (default: 5 s).

Choose signal texts that the harness does not echo from the prompt.

---

## How the dispatcher saves tokens

The dispatcher does this automatically — no action required.

**Messages.** All waiting messages go to one agent run. A run that fails returns
the messages to the inbox. If a message fails 3
runs, it moves to `inbox/<role>/failed/`. The retry count stays correct after a
restart (stored in the file name: `.retry2.md`). Do not run `coord inbox` for a
role that a dispatcher serves.

**Tasks.** The dispatcher claims one unclaimed task for its worker before the run.
The run works on that task only. If another worker took every task first, no run
starts. So two workers of one role never pay for a run without work.
The dispatcher does not retry the same unclaimed tasks every minute.
The wait between runs doubles after each run, up to 1 hour. A new or changed
task starts a run immediately. A message run never claims a task.

**Prompt cache.** LLM providers cache a conversation for a limited time after the
last request. Claude Code uses a 1-hour cache. The OpenAI cache of Codex is best
effort and lasts a few minutes.

- If the last run ended less than `--cache-window` seconds ago (default: 300 s for
  codex, else 3300 s, 55 min), the dispatcher resumes the session. The provider
  reads the old context from the cache — cheap.
- If the last run is older, the dispatcher starts a fresh session. The fresh
  session gets a short handoff note (at most 300 words), not the full old context.
  The log shows: `idle Nm, past the cache window; starting fresh with the handoff note`.
- Each resume sends the whole old context again, on every model call of the run.
  After `--max-session-runs` runs (default: 5) in one session, the dispatcher starts
  a fresh session with the handoff note. `--max-session-runs 0` turns the limit off.
- Each task in a resumed session adds to the context. If the last model call of
  the session had `--max-context` tokens or more (default: 150000), the dispatcher
  starts a fresh session with the handoff note. Only opencode reports the context
  size. `--max-context 0` turns the limit off.
- `team.limits.<role>` in `.maf/config.json` sets `max_context`, `max_session_runs`, and
  `cache_window` for a role. A dispatcher flag wins over the saved limit. The dashboard
  suggests better limits (see Token hints).
- DeepSeek bills half price off-peak. Peak hours are 01:00-04:00 and 06:00-10:00 UTC,
  Monday to Friday. If a dispatched opencode run uses a DeepSeek model in peak hours,
  the log shows `info: DeepSeek peak hours (HH:MM UTC): this run costs 2x the off-peak rate`.
  The run still starts. The dispatcher does not know Chinese public holidays, which
  are off-peak in full, so the notice can show on a holiday.
- A run that fails on a provider usage or rate limit never reached the model.
  The dispatcher returns its messages to the inbox without an attempt and starts
  no new run for 15 minutes. Each further limit doubles the pause, up to 1 hour.
  The worker status shows `paused_until`.
- A dispatched Codex run starts lean: without the user's plugins, apps, browser and
  computer tools, subagents, and MCP servers. A dispatched Claude Code run starts
  without skills and without the user's MCP servers. The user's CLAUDE.md and hooks
  stay. Only the graphify server of the project stays. Each extra tool or skill adds
  context to every model call of the run. `--full-harness` keeps the full user setup.
- A run that changed the state of the work puts a new handoff note in a
  `<handoff>` block of its final reply. The dispatcher writes the note to
  `.maf/coordination/sessions/<worker>.handoff.md`. The agent needs no tool call
  for the note. A run that changed nothing keeps the old note.

**Prefetch.** A task run prompt holds the task spec (`coord show ID`) and
`git log --oneline -10`, each cut to 2000 characters. A message run prompt holds
only the git log. The agent needs fewer tool calls to start. If a command fails,
the log shows `prefetch failed` and the prompt goes out without that part.

**Token usage.** After each run, the dispatcher adds the token usage of the run
to `.maf/coordination/usage/<worker>.json`. `input_tokens` counts every input token.
`cached_input_tokens` counts the cache reads, which cost a fraction of the input price.
`cache_write_input_tokens` counts the cache writes, which cost more than the input price.
The dispatcher log shows the usage of each run, and the idle time of a resumed session.
If a resumed run shows a large cache write, the cache was cold: lower `--cache-window`.
The dashboard shows the cache hit ratio: cache reads as a part of all input tokens.
Claude Code, Hermes, Codex, and opencode report the usage. `--command` harnesses
do not. `coord status` and the dashboard show the totals. A run never fails because
of missing usage data.

Set `--cache-window` to your provider's cache time minus a margin. For a
30-minute cache: `--cache-window 1500`. To never resume: `--cache-window 0`.

---

## Give the team work

Talk to the project manager session (terminal 1). Example:

> "Add a /health endpoint that returns the app version. Add tests and a UI badge."

Workers hand work to each other with artifacts. An artifact is a shared working file:

- Write it to `$COORD_DIR/artifacts/<goal>/<name>.md`, in the main project.
  Each worktree sees this path, because `COORD_DIR` points at the `.maf/coordination` folder of the main project.
- Never write an artifact inside a worktree. Worktrees do not share files.
- A durable artifact (an approved spec, an ADR) is committed on the goal branch. The architect
  cannot commit: it creates a task, and a worker that can edit files commits the artifact.

Expected sequence:

1. The project manager creates the goal with `coord goal add`. The command
   creates branch `goal/<short-id>` from the base branch and the goal worktree
   `.maf/worktrees/goal-<short-id>`.
2. The project manager sends the goal id to the architect.
3. The architect creates tasks with `coord add --goal <id>` and assigns them to roles.
4. Interactive workers take their tasks immediately. Dispatched workers start
   within about 60 seconds.
5. Each worker runs `coord start-task <id>`, writes code on branch
   `task/<short-id>`, runs the task tests, and commits.
6. Each worker reports with `coord annotate` and `coord done`.
7. The reviewer checks the diff. The architect lands each task with `coord land <id>`:
   one squash commit on the goal branch. The task branch is then deleted.
8. The architect runs `coord goal sync <id>` to merge the base branch into the goal,
   runs the full suite one time in the goal worktree, and closes the goal.
   The pull request goes from the goal branch into the base branch, with a merge commit.
9. The architect reports to the project manager. The project manager reports to you.

Check the goals at any time:

```sh
coord goal list
coord goal show <id>
coord show <task-id>   # one task: its fields and its annotations
```

Set the base branch in `.maf/config.json` if it is not `main` or `origin/HEAD`:
`"base_branch": "AI_development"`. Goals never start from another goal branch,
so a defect in one goal does not block the others.

Set a verify command in `.maf/config.json` to check each task mechanically:
`"verify": "bin/rails test"`. The command runs in the worktree of the worker.
`coord done` refuses the task while the command exits non-zero. `--force`
does not skip this check. A dispatched run with a failing verify command is no
success. Lead roles get no check. Without the key, nothing changes.

### Git persona of the agents

By default, the agents commit with your git config, as you do. To give them
their own name and email, add a `git_identity` key to `.maf/config.json`:

```json
"git_identity": { "name": "maf-bot", "email": "maf-bot@users.noreply.github.com" }
```

- The persona is the author and the committer of each commit of an agent and
  of the flow: task commits, `coord land`, `coord goal sync`, and the notes on
  `maf/memory`. Your own commits keep your config.
- `maf start`, the dispatcher, and coord set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL`. These win over each git config file.
- Without `git_identity`, the `bot_user` and `bot_email` of the `github` section count.
  Without both, nothing changes.
- A running agent keeps the old persona. Start it again after a change.

### Goal pull requests and reviews

Add a `github` section to `.maf/config.json` to let coord open a pull request
for each goal and read your review:

```json
"github": {
  "bot_user": "maf-bot",
  "bot_email": "maf-bot@users.noreply.github.com",
  "reviewer": "<your GitHub user>",
  "ssh_host": "github.com-maf-bot",
  "repo": "<owner>/<repo>"
}
```

- `bot_user` is a separate GitHub account for the agents. GitHub does not let
  the author of a pull request approve it, so the bot opens the pull request
  and you review it. Give the bot write access to the repository.
- Log the bot in to `gh` once: `gh auth login`. coord reads its token with
  `gh auth token --user <bot_user>`. Your own `gh` login stays active.
- `ssh_host` is a `Host` alias in `~/.ssh/config` with the key of the bot.
  Without it, coord pushes to `origin`.
- `repo` is optional. Without it, coord reads the repository from the `origin` URL.
- Without a `git_identity` key, `bot_user` and `bot_email` are the git persona of the agents
  (see "Git persona of the agents").

The flow:

1. The architect lands the tasks and runs `coord goal sync` and the merge suite.
2. `coord goal pr <goal-id>` pushes the goal branch and opens the pull request
   into the base branch. GitHub asks you for a review. coord shows a macOS
   notification. The dashboard lists each goal pull request that waits.
3. Review on GitHub: approve, or request changes with inline comments.
4. The architect dispatcher runs `coord review-watch --once` every 5 minutes.
   It sends your new reviews and comments to the architect. It ignores other authors.
5. For requested changes, the architect creates fix tasks, lands them, and runs
   `coord goal pr` again. coord comments the new commits and asks you for a new review.
6. Merge the pull request with a merge commit, not a squash. coord then closes
   the goal and runs `coord gc --yes`.

Set `MAF_NOTIFY=0` to turn off the macOS notifications.

Set a copy list in `.maf/config.json` for host files that git does not track:
`"copy_to_worktree": [".env", "config/master.key"]`. `coord worktree` and
`maf start` copy each file that exists into the worktree. A file that is
already in the worktree is never overwritten, so a change by the agent stays.
Paths outside the project are skipped.

A reused worker worktree follows the base branch on `origin`. `coord worktree`
and `maf start` fast-forward the branch `worker/<worker>` to `origin/<base branch>`.
They do this only when the worker branch is checked out, the worktree is clean,
and the update is a fast-forward. Otherwise they skip the update and print the
reason. A project without `origin` gets no update.

If you did not set up a `project-manager` role, talk to the architect session
directly.

---

## The glossary and the ADRs

The flow keeps two documents of the project domain.

- **`GLOSSARY.md`** at the repository root holds the domain terms. Each term has a bold name,
  one or two sentences, and an `_Avoid_` line for rejected words. It holds no implementation detail.
  The file does not exist until the first term resolves. A project with more than one bounded
  context also gets a `GLOSSARY-MAP.md`. A project with one context gets none.
- **ADRs** are in the decisions folder (`.agent/decisions/` if it exists, else `docs/decisions/`).
  An ADR has a title and one to three sentences. The architect offers an ADR only if the decision
  is hard to reverse, surprising without context, and the result of a real trade-off.

How it works:

1. The project manager interviews you in rounds. Each round holds the questions that are open now,
   numbered, each with a recommended answer. The project manager finds each fact itself and asks you only for decisions.
   The interview ends when no open question is left.
2. The project manager writes each resolved term to
   `.maf/coordination/artifacts/<goal>/glossary-draft.md` at once. It never commits,
   because `can_edit` is `false` for the project manager.
3. The architect and the reviewer check the draft. The reviewer checks one meaning per term,
   no implementation detail, no duplicate term, and no contradiction with an existing entry.
4. The architect creates a task. A worker that can edit files commits the agreed terms to `GLOSSARY.md` on the goal branch.
   The architect cannot commit, because `can_edit` is `false` for the architect.

`GLOSSARY.md` is one file for all goals. Two goals that add terms conflict at merge time.
The architect starts these goals one after the other, or promotes an agreed term to the base branch at once.
Without a project manager, the architect writes the terms.

This flow does not depend on a skill and does not ship one. The rules are in the role prompts. Each role prompt
ends with the coordination contract.

## Monitor progress

Run from any terminal in the project:

```sh
coord status                   # tasks per role, by state
coord log 20                   # last 20 events: claims, done, messages
coord board                    # writes .maf/coordination/exports/board.md
ls .maf/coordination/sessions/        # one .session + one .handoff.md per dispatched worker
ls .maf/coordination/inbox/*/failed/  # messages that failed 3 runs (should be empty)
```

### Obsidian kanban

`coord board` writes `.maf/coordination/exports/board.md`. Open it in Obsidian with
the Kanban plugin (mgmeyers/obsidian-kanban). Obsidian reloads the file
automatically. Keep it current while agents run:

```sh
watch -n 10 coord board
```

### Web dashboard

`dashboard` starts a local server at `http://localhost:4567`. The page
auto-refreshes every 5 seconds. It shows everything `coord status` shows, plus
signals the kanban cannot: expired-lease claims (crashed workers), unread inbox
messages, stale locks, orphaned tasks, and scope conflicts. Each declared role has a
card, also without tasks.

The Workers table has one row per worker from `.maf/coordination/workers.json`:

| Column | Source |
|---|---|
| Harness | The registry: the harness, and the mode (dispatch or interactive). |
| Model | The model that the last run or turn used. Without status data: the model of the registry. |
| State | `stopped` when the process is gone. A dispatched worker shows `run Nm` during a run, else `idle`. |
| Context | The context size of the session, with a % of the window for Codex. `over limit` past the context limit. |
| Task | The task that the worker claimed. |
| Last run | A dispatched worker: `ok`, `waiting` (status blocked or needs_review), or `failed`, and the last dispatcher message. |
| Tokens | Input, cached input, and output tokens, and the runs (dispatch) or turns (interactive). |
| Actions | The buttons, and the last log lines of the dispatcher and of the last action. |

The status comes from `.maf/coordination/status/<worker>.json`. The dispatcher and the
`context-watch.rb` hook write it.

Actions run `maf worker ACTION WORKER` in the background, in the project root:

- A dispatched worker has `start`, `stop`, and `restart`. A stop waits until a running
  agent finishes its run.
- An interactive worker has `stop`. maf stops the session only when it is idle. The
  row then shows the start command: `cd <worktree> && maf start`. maf cannot tell if an
  opencode session is idle, so it refuses the stop. Stop that session in its terminal, or
  run `maf worker stop WORKER --force`.
- One action per worker runs at a time. The output goes to
  `.maf/coordination/sessions/<worker>.control.log`.

**Token hints.** The dispatcher appends one line per run to
`.maf/coordination/usage/<worker>.runs.jsonl`: the token usage, the session run
(1 is a fresh session), the context of the last model call, the peak rate, and the
session limits of the run. The dashboard reads the last 20 runs of each worker. It
counts only the runs with the limits of the last run. It shows a hint when:

| Hint | Rule | Button |
|---|---|---|
| A resumed run costs more than a fresh run | The median resumed run uses 3x or more the input of the median fresh run, over 2 or more resumed runs. | If the harness reports the context (opencode): restart with `max_context` at 2x the context of a fresh run, at least 40k. Else: restart with `max_session_runs=1`. |
| The cache was cold | 2 or more resumed runs wrote more than 25% of their input to the cache. | Restart with half the cache window. |
| DeepSeek peak rate | The last run used DeepSeek in peak hours, and the peak hours go on. | Stop the worker. |

**Analyze button.** The rules see only the token numbers. The `analyze` button of a
worker row asks a small model for hints that the numbers do not show, for example a
worker that greps instead of querying the graph. `.maf/bin/analyst WORKER` builds a
short digest: the run history, and the tool calls of the current session (counts by
kind, output sizes, the 5 largest outputs). It reads the transcripts of Claude Code
and Codex, and the opencode database through the `sqlite3` command. The model returns
at most 3 hints. The page shows them with an `analysis` tag, with a restart button
when a hint names a session limit. The result is in
`.maf/coordination/hints/<worker>.json`.

The default model call is Claude Haiku with a one-line system prompt, without tools,
skills, MCP servers, user settings, or thinking. One analysis costs about 1.2k input
tokens and 200 output tokens (about $0.002) and takes a few seconds. The analyst runs
only when you click the button. To use another command, set
`"team": { "analyst": { "command": ["opencode", "run", "-m", "deepseek/deepseek-flash"] } }`
in `.maf/config.json`. The analyst sends the prompt on stdin. `analyst WORKER --print`
shows the prompt and calls no model.

A restart from a hint runs `maf worker restart WORKER --max-context N` (or the
other limit flag). maf saves the limit for the role in `.maf/config.json`:
`"team": { "limits": { "frontend-developer": { "max_context": 70000 } } }`. Each
later start of a worker of that role uses the limit. The runs with the new limits
start a new history, so the hint goes away.

The server listens on 127.0.0.1 only. An action needs a token that changes at each
server start, and a localhost Host header. So another web site cannot start an action.

```sh
dashboard             # default port 4567
dashboard --port N    # custom port
dashboard --maf PATH  # the maf command for actions (default: maf on PATH)
```

From a terminal, use the same command: `maf worker status|stop|start|restart ROLE[_WORKER] [--force]`.
`start` and `restart` take `--max-context N`, `--max-session-runs N`, and `--cache-window S`. maf saves
them for the role in `.maf/config.json`.

---

## Shared knowledge base

`maf add` installs a `vault` script and starts it automatically when
`graphify` is on PATH at install time. Check:

```sh
vault status
```

If `graphify` was installed after `maf add`, start the watcher by hand:

```sh
vault
```

Commands:

```sh
vault           # start (no-op if already running)
vault export    # regenerate the Obsidian vault once
vault status
vault stop
vault mcp       # exec the stdio MCP server (for an MCP client config)
```

The watcher runs `graphify update .` (incremental, no LLM) and
`graphify export obsidian --dir graphify-out/obsidian` every `VAULT_POLL` seconds (default 30).

A markdown commit or merge also refreshes the graph. `maf add` appends a flow
block to the `post-commit` and `post-merge` hooks. The block starts
`.maf/bin/doc-graph-refresh` detached. The refresh runs
`graphify extract . --backend gemini` and re-exports `graphify-out/obsidian/`. It needs
`GEMINI_API_KEY` in the environment of the agent session. Without the key it
logs a skip in `.maf/coordination/doc-graph.log`. A non-markdown commit makes no LLM
call.

### Graph in the workflow

The graph holds code knowledge. It helps the architect plan and the developer
find code. It does not carry the plan and spec exchange. That exchange uses
artifacts (see "Give the team work").

- **Rule.** Each role queries the graph when it starts a task or plans a goal,
  with `--budget 800`. The query output stays in the context for each later
  model call, so a small budget saves tokens. If the graph is missing or stale,
  the role says so in the report of that task or plan.
- **Age.** The graph age is the number of commits since the graph was built.
  The graph is stale when a commit after the build changed a source or
  markdown file. Show the age with `vault age`, `vault status`, `coord status`,
  or the dashboard. The architect checks it before the merge suite.
- **A missing, stale, or unreadable graph never fails a run.**

### Work memory

The graph also keeps what the team learned. graphify calls this work memory.

- **Done tasks.** `coord done` saves a note with `graphify save-result` in
  `graphify-out/memory/`. The question is the task title. The answer is the task
  notes. The note cites the graph nodes of the files that the task branch changed.
  The outcome is `useful`.
- **Lessons.** `coord lesson ID dead_end TEXT` saves an approach that failed.
  `coord lesson ID corrected TEXT` saves the right way. The architect does this
  when a done task is wrong.
- **Summary.** After each note, and after each graph refresh, `graphify reflect`
  writes `graphify-out/reflections/LESSONS.md`. A refresh drops each lesson whose
  node is not in the new graph.
- **Prompts.** The dispatcher adds the dead ends and the corrections of
  `LESSONS.md` to each task prompt, newest first. It keeps only the lessons
  whose note cites a file that the graph query of the task found. A lesson
  without a cited node always stays. `graphify query` marks each node
  with a useful note as `learning=preferred`, `tentative`, or `contested`.
- The next markdown refresh reads the notes into the graph as nodes.
- Without a graph, nothing is saved. `coord lesson` then fails.
- **Branch.** `graphify-out/memory/` is a worktree of the orphan branch `maf/memory`
  (ADR 0006). `maf add` and `maf update` make it, or take the branch from origin.
  Each note is one commit there. The branch shares no history with your branches,
  so a note never shows in a pull request. `coord goal pr` merges the remote
  `maf/memory` and pushes it. Without a `github` section, push it yourself:
  `git push origin maf/memory`. The refresh never replaces the folder.

### MCP server

`maf add` writes the graphify MCP server for each harness. The server runs
`vault mcp`. In a worktree, `vault mcp` serves the graph of the main project.
The project's own `.mcp.json` and `opencode.json` stay as they are.

| Harness | Where | How the harness gets it |
|---|---|---|
| Claude Code | `.maf/mcp/claude.json` | `maf start` and the dispatcher pass `--mcp-config` |
| opencode | `.maf/mcp/opencode.json` | `maf start` and the dispatcher set `OPENCODE_CONFIG`. opencode merges it with `opencode.json`. |
| Codex | `~/.codex/config.toml` (global) | `maf add` prints `codex mcp add ...`. |
| Hermes | `~/.hermes/config.yaml` (global) | `maf add` prints `hermes mcp add ...`. |

maf never replaces a graphify entry that it did not write. It leaves a file that
is not valid JSON as it is.

To turn the server off, set `"mcp": false` in `.maf/config.json`, and delete
`.maf/mcp/`. With `"mcp": false`, `maf add` and `maf update` do not write it again.

Open the `graphify-out/obsidian/` folder in Obsidian to see the code graph. To see
`.maf/coordination/exports/board.md` as a kanban alongside the graph, open the project
root as the Obsidian vault.

---

## Message hooks

`coord msg` and `coord broadcast` fire a per-role hook at
`.maf/coordination/message-hooks/<role>.sh` when a message is delivered. The hook is a plain
shell script. If there is no hook, `coord` only writes the inbox file.
An agent does not need a hook to get a message. The board watcher (Claude Code
and opencode), `coord await` (Codex), and `coord next --wait` (Hermes) wake the agent on an unread message.
`coord msg --fyi` writes a message that wakes no one: no hook runs, no dispatcher run starts, and no
watcher pokes. The next run of the role reads the message together with the next waking message.

```sh
# .maf/coordination/message-hooks/backend-developer.sh
#!/bin/sh
# Show a desktop notification (macOS)
osascript -e "display notification \"$COORD_FROM wrote to $COORD_ROLE\" with title \"coord\""
```

Hook environment variables:

- `COORD_ROLE`: the receiving role.
- `COORD_FROM`: the sender.
- `COORD_MSG_FILE` and `$1`: the message file path.

The hook runs in the background; a slow hook does not block the sender. Output
goes to `.maf/coordination/message-hooks/<role>.log`. `coord hooks [ROLE]` lists installed
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
2. Press Ctrl-C in each dispatcher terminal. Stop each background dispatcher with
   `maf worker stop WORKER`, or with the stop button of the dashboard.
3. If the vault watcher runs, run `vault stop`.

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
4. Registers the worker in `.maf/coordination/workers.json`. The dashboard shows it.
5. Returns the old worker's claimed tasks to the pool and removes its worktree.
   The task branches stay, so the next worker continues the committed work.
6. Tells the architect about the change.

Then run the two printed commands in a new terminal:

```sh
cd .maf/worktrees/frontend-developer-2
maf start
```

If the old worker still runs in a terminal, `maf prepare` stops without
changes. Stop that session, then ask the project manager again. A background
dispatcher is different: `maf` stops it for you (see below). Without `--replace`, the command
adds a worker. `maf retire backend-developer_2` removes a worker.

Worktrees can stay for the next session. To remove a worktree:

```sh
git worktree remove .maf/worktrees/<name>
```

---

## Change the setup later

`maf` keeps the agents in `.maf/config.json`. Give only the changes:

```sh
maf add opencode:frontend-developer   # add an agent
maf remove claude:architect           # remove an agent
maf agents                            # list the current agents
maf update                            # regenerate the current agents
```

`maf remove` does not delete the generated role file.
The generator skips unchanged files and updates changed files in place. There is nothing to commit:
the files of the flow stay out of git.

---

## Uninstall

The uninstaller knows only the `.maf/` layout. If the project uses the old
layout, run `maf migrate` first (see "Move an old install into `.maf/`").
On an old layout, `maf uninstall` stops with the migrate hint, and
`maf uninstall --check` prints the plan of `maf migrate`.

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

- `.maf/bin/` (`coord`, `dispatcher`, `dashboard`, `vault`, `doc-graph-refresh`), `.maf/lib/maf/shared/`,
  and `.maf/env.sh`.
- `.maf/coordination/`, with the task board, messages, locks, and message hooks.
- Clean worktrees in `.maf/worktrees/`.
- Generated role files in `.maf/agents/`, the symlinks `.claude/agents`,
  `.opencode/agents`, and `.codex/prompts`, and the project's Hermes skills.
- `.maf/claude/` and `.maf/mcp/` (the hooks and the MCP config of the flow).
- The flow hooks in `.codex/hooks.json`.
- The flow blocks in the `post-commit` and `post-merge` git hooks.
- The flow paths in `.git/info/exclude`.
- From an install of an older maf version: the flow hooks in `.claude/settings.json`,
  the graphify entry in `.mcp.json` and `opencode.json`, and the marked blocks in
  `AGENTS.md` and `.gitignore`.
- `.maf/config.json`.
- The folder `.maf/`, when nothing is left in it.

The uninstaller keeps:

- `graphify-out/` (the graph and the Obsidian vault). A rebuild costs many agent runs.
  Delete it by hand. `.git/info/exclude` keeps it out of git.
- Files that do not carry the flow signature or marker, and text outside the
  marked blocks.
- `worker/*` branches. Merge or delete them with `git branch -D`.
- Worktrees with uncommitted changes. Add `--force` to remove them.
- The guarded global Hermes hook. Other projects can use the hook.

The project keeps the code, the decisions, and `GLOSSARY.md`. If an older
maf version changed tracked files, commit the result.

## Remove maf files from git

An older maf version committed `.maf/`, the harness links, and its blocks in
`AGENTS.md`, `.gitignore`, `.claude/settings.json`, `.mcp.json`, and `opencode.json`.
Run this one time in such a project:

```sh
maf untrack --check   # preview
maf untrack           # asks for confirmation; --yes skips the question
```

`maf untrack`:

1. Removes `.maf/`, the harness links into `.maf/agents/`, the opencode plugin,
   and a `.codex/hooks.json` with only flow hooks from git (`git rm --cached`).
   The files stay on disk.
2. Removes the flow blocks and entries from `AGENTS.md`, `.gitignore`,
   `.claude/settings.json`, `.mcp.json`, and `opencode.json`. Your own text stays.
3. Lists the flow paths in `.git/info/exclude`.
4. Runs `maf update`, which writes `.maf/claude/settings.json` and `.maf/mcp/`.

maf does not commit. Review the change with `git status`, then commit it.
A `CLAUDE.md` that an older maf moved into `AGENTS.md` stays in `AGENTS.md`.

---

## Upgrade from a version before the flow glossary

This version renames terms (see [docs/flow-glossary.md](docs/flow-glossary.md)). It does not read
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

The paths in this section are the paths of the old layout. Do these steps
before you run `maf migrate`.

Do these steps in the project:

1. Stop the team (see above).
2. Finish or write down the open tasks. The reset deletes them.
3. Remove the worktrees: `git worktree remove .worktrees/<name>` for each one.
4. Delete the old branches after you merge them: `git branch -D agent/<worker>`.
5. Delete `coordination/taskdata/` and `coordination/taskrc`.
6. Move your message hooks from `coordination/hooks/` to `coordination/message-hooks/`.
7. Delete the rest of `coordination/hooks/`.
8. In `.claude/settings.json`, delete the hook entries that point to `coordination/hooks/`.
9. Run `maf migrate`, then `coord init`.
10. Run `maf untrack` (see "Remove maf files from git"), then commit.

---

## Move an old install into `.maf/`

Older versions of the flow put many files in the project root: `coord`,
`dispatcher`, `vault`, `dashboard`, `coordination/`, `.worktrees/`,
`graphify-out/`, `obsidian/`, and `.agent-flow.json`. This version keeps all of
them in one folder, `.maf/`, except the graph, which stays in `graphify-out/`. The paths of the old and the new layout:

| Old | New |
|---|---|
| `coord`, `dispatcher`, `vault`, `dashboard` | `.maf/bin/` |
| `coordination/` | `.maf/coordination/` |
| `coordination/doc-graph-refresh` | `.maf/bin/doc-graph-refresh` |
| `.worktrees/` | `.maf/worktrees/` |
| `graphify-out/` | `graphify-out/` (stays) |
| `obsidian/` | `graphify-out/obsidian/` |
| `.agent-flow.json` | `.maf/config.json` |
| `coord-env.sh` | `.maf/env.sh` |
| `.claude/agents/`, `.opencode/agents/`, `.codex/prompts/` | symlinks to `.maf/agents/<harness>/` |

`maf update`, `maf add`, and the other commands stop on an old layout. They
print this hint: `This project uses the old layout. Run: maf migrate`.

Do these steps in the project:

1. Stop the team (see above). `maf migrate` refuses to run while a registered
   worker runs.
2. Commit or stash your work. Do not leave changes in the worktrees.
3. Preview the plan. The command prints each move and changes nothing:

   ```sh
   maf migrate --check
   ```

4. Run the migration. The command prints the plan and asks for confirmation.
   Add `--yes` to skip the question:

   ```sh
   maf migrate
   ```

5. Check the result with `git status`. Git shows the old paths as deleted.
   Then run `maf untrack` (see "Remove maf files from git"), and commit:

   ```sh
   maf untrack --yes
   git commit -m "Remove the flow from git"
   ```

6. In each shell, run `source .maf/env.sh`. Then run `coord status`.

`maf migrate` does these things:

- Moves a script only if it carries the flow signature. Moves a role file only
  if it carries the flow marker.
- Moves each git worktree with `git worktree move`. The link between the
  worktree and the repository stays intact. The command writes `.maf/env.sh` in
  the worktree and removes `coord-env.sh`. Git excludes `.maf/env.sh`, so the
  worktree stays clean and `maf uninstall` can remove it.
- Changes the absolute paths in `.maf/coordination/taskrc`,
  `.maf/coordination/workers.json`, and `.claude/settings.json`.
- Regenerates the files of the current agents, as `maf update` does. This step
  updates the scripts, the role files, the harness symlinks, the git hooks, and
  the local git excludes.
- Never deletes a file. If the new path exists, the old file stays and the
  plan says `keep`.

If a harness folder holds files that the flow does not own, the folder stays a
folder and the harness cannot read the role files. Move your files out of the
folder. Then run `maf update`.

The task board keeps its tasks, because the task database moves with
`.maf/coordination/`. Run `maf migrate` again at any time: a second run finds
nothing to move.

---

## Board rules

The coordination contract at the end of each role prompt holds only the rules that agents act on.
This section holds the board details for the operator.

- **Claim lease.** A claim with no activity for `COORD_LEASE_TTL` seconds (default 4 hours)
  is free again. `coord next` and `coord claim` then treat the task as unclaimed.
- **Claim steal.** `coord claim` refuses an active claim of another worker.
  `coord claim --force` takes the task. The prior holder gets a message that names the new holder.
- **Scope check.** `coord add` warns on stderr when a new scope overlaps a pending task.
  `coord conflicts` lists all overlaps. The check is a path-prefix heuristic.
  It understands `dir/**` and exact paths. It does not understand `{}` alternation or mid-path globs.
- **Broadcast reach.** `coord broadcast` reaches each role that owns a pending task or is listed
  in `.maf/config.json`, except the sender. `--to` selects `workers` (default), `leads`, or `all`.
- **Role inboxes.** Each role has one inbox. `coord msg` to a worker, such as `backend-developer-3`,
  writes to the inbox of its role and adds a `# for: backend-developer-3` line.
  `coord msg` refuses a name that is no role and no worker.
  `coord msg --task ID` also adds the text as a note on the task. The note stays after the worker stops.
  Older versions wrote mail for a worker to `inbox/<worker>/`. `coord inbox` and the dispatcher move those messages to the role inbox.
- **Read messages.** `coord inbox` moves a read message to `.maf/coordination/inbox/<role>/read/`.
  `--peek` keeps the message unread. `--all` includes read messages.
- **Presence.** `maf start` records the session pid in `.maf/coordination/presence/`.
  A dispatcher records its own pid. A worker is live while its pid runs.
  If a receiver role has no live worker and no message hook, `coord msg` prints a warning.
  The message waits until a session for that role starts.
- **Read-only roles.** A role with `can_edit: false` gets a read-only tool grant where the harness supports one.
- **Vault.** `vault` controls the graphify watcher. `vault status` and `vault stop` report or stop the watcher.
  `vault export` regenerates the Obsidian vault one time. Agents never run `graphify export`.
  The separate `graphify-mcp` process (`vault mcp`) serves MCP, not the watcher.
- **Bounded contexts.** Add a `GLOSSARY-MAP.md` only if the project has more than one bounded context.
- **Containerized agents.** An agent in a container (for example `coi`) needs `.maf/coordination/`,
  `coord`, and `.maf/coordination/taskrc` mounted from the host.
  Without a shared file system, the agent does not share state with the host or other agents.

---

## Command reference

| Command | What it does |
|---|---|
| `maf prepare HARNESS ROLE[_WORKER] [--dispatch] [--interactive] [--replace W]` | Prepare a worker: role file, worktree, registry. Prints the two start commands. `--dispatch` starts the dispatcher instead. The architect is dispatched unless `--interactive` is given. |
| `maf retire ROLE[_WORKER]` | Remove a worker. Stops its background dispatcher. Its claimed tasks return to the pool. |
| `maf worker ACTION ROLE[_WORKER] [--force]` | Control one worker. ACTION is status, stop, start, or restart. Each action is idempotent. A dispatched worker starts again in the background. An idle interactive session stops; maf prints its start command. `--force` stops a session that maf cannot check (opencode). `start` and `restart` take `--max-context N`, `--max-session-runs N`, and `--cache-window S`, and save them for the role. |
| `maf team` | Show the budget, the workers, and the tasks by role. |
| `maf team set --max N --allow HARNESS[:MODEL]` | Set the team budget in `.maf/config.json`. |
| `maf start ... --dispatch --detach` | Start a dispatcher in the background. |
| `maf start` (in a prepared worktree) | Start the worker that `maf prepare` made. |
| `coord init` | Create the `.maf/coordination/` folders. |
| `coord goal add --title T [--base B]` | Create a goal, its branch `goal/<short-id>`, and its worktree. Prints the ID. |
| `coord goal list` / `goal show ID` | List open goals, or show one goal and its tasks. |
| `coord goal sync ID` | Merge the base branch into the goal branch. A conflict aborts the merge. |
| `coord goal done ID` | Close a goal. Refused while a task of the goal is open or the goal lacks the base head. |
| `coord land ID [--subject TEXT]` | Squash a done task branch into its goal branch as one commit with trailers. Deletes the task branch. |
| `coord goal pr ID` | Push the goal branch as the bot. Open the pull request, or comment the new commits and ask for a new review. |
| `coord review-watch [--once]` | Send new reviews of goal pull requests to the architect. Close a merged goal and run `coord gc --yes`. |
| `coord reap [--minutes N]` | Release the claims of workers not seen for N minutes (default: `team.reap_minutes`, else 90). Never releases a live dispatcher, so long local-model runs are safe. Tells the architect. The architect dispatcher runs it every 5 minutes. |
| `coord gc [--yes]` | List merged task, goal, and worker branches and finished goal worktrees. `--yes` deletes them. |
| `coord add --role ROLE --scope S --title T [--goal ID]` | Create a task for a role. Prints the ID. |
| `coord next [ROLE]` | List unclaimed tasks for a role (defaults to `$COORD_ROLE`). |
| `coord next --wait` | Block (polls every 60s) until a task or an unread message appears. Refused for lead roles. |
| `coord next --mine` | List the tasks this worker has claimed. |
| `coord conflicts` | List pending tasks whose scopes overlap. |
| `coord claim ID` | Atomically claim a task for `$COORD_WORKER`. Refuses to steal an active claim. Refused for lead roles. |
| `coord start-task ID` | In a worker worktree: check out `task/<short-id>` from the goal branch. |
| `coord unclaim ID` | Release a claim without finishing it. |
| `coord done ID [--force]` | Complete a task. Refused while the task branch has own commits and lacks the goal branch head. |
| `coord annotate ID TEXT` | Add a note to a task (permanent). |
| `coord lesson ID dead_end\|corrected TEXT` | Save a lesson of a task to the graph memory (see "Work memory"). |
| `coord msg --from A [--task ID] [--fyi] TO TEXT` | Send a message to a role or a worker (the role inbox). `--task` also notes the task. `--fyi` wakes no one. |
| `coord await [--timeout S]` | Interactive session: arm the stop hook, then end the turn. The hook waits for work without model calls (default: 3000 s). Refused in a dispatched run. |
| `coord broadcast --from A [--to workers\|leads\|all] TEXT` | Send a message to a group of roles. Default: workers. |
| `coord inbox [ROLE]` | Read messages (marks them read; `--peek` keeps them; `--wait` blocks; a second `--wait` for the same role is refused). |
| `coord log [N]` | Show the last N coordination events. |
| `coord lock NAME --ttl S` | Take an advisory lock. |
| `coord unlock NAME` | Release a lock. |
| `coord with-lock NAME -- CMD` | Run a command under a lock. |
| `coord worktree ROLE [WORKER]` | Create a git worktree + branch for a role. Source `.maf/env.sh` inside it. Warns if a harness has no file for the role. |
| `coord hooks [ROLE]` | List installed message hooks and their status. |
| `coord status` | Show tasks by role and state. |
| `coord who` | List each worker with its presence (live or gone) from `.maf/coordination/presence/`. |
| `coord board` | Write the Obsidian board file. |
| `coord export` | Write the raw tasks JSON. |
| `maf migrate [--check] [--yes]` | Move an old-layout install into `.maf/`. See the migration section. |
| `maf untrack [--check] [--yes]` | Remove an older install from git. The files stay. Review `git status`, then commit. |
| `maf uninstall [--check] [--yes] [--force]` | Remove the flow from the project. Keeps the graph, the vault, the code, and the decisions. |
| `maf start HARNESS ROLE[_WORKER]` | Worktree + env + role + launch the harness, in one command. |
| `maf start HARNESS ROLE --dispatch [FLAGS]` | Same setup, then run `dispatcher`. |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Ruby 3.0+ required` or syntax error | Install Ruby 3.0 or later (step 0). |
| A worktree has no `coord` | Run `maf update` in the main project, then `maf start` again. `coord worktree` copies `.maf/bin/` into each worktree. |
| `git status` shows `.maf/` files | An older maf version committed them. Run `maf untrack`, then commit. |
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
