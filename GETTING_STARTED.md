# Getting started

This guide explains the multi-agent flow to a person who has never used it.

Read the whole guide once. Then follow the steps in order.

---

## 1. What this is

You run more than one AI coding agent on one project.
Each agent works in its own terminal.

The agents share three things:

- A **task list**. Agents take tasks from the list and mark them done.
- A **message inbox**. Agents send messages to each other.
- A **knowledge base**. Agents read project knowledge instead of searching the code.

You stay in control. You watch the terminals. You can read the task list at any time.

The flow uses two programs:

- **Taskwarrior** (`task`) stores the tasks.
- **`coord`** is a small command-line tool. It is the only interface the agents use.

The flow stores all shared state in a folder named `coordination/`.

---

## 2. Words you must know

- **Agent**: one AI coding tool in one terminal. For example `opencode`, `Claude Code`, or `Hermes`.
- **Task**: one unit of work. A task has a title, an owner, and a scope.
- **Scope**: the files an agent may change for a task. Example: `test/queries/**`.
- **Claim**: an agent marks a task as its own and starts work.
- **Lock**: a flag that stops two agents from using one shared resource at the same time.
- **Board**: a Markdown file that shows all tasks as columns.
- **Vault**: an Obsidian folder with the project knowledge.
- **Architect**: the role that turns a request into tasks and dispatches them.
  It does not write code.
- **Project Manager**: an optional role above the architect. You talk to the
  project manager. It sends one goal at a time to the architect and relays
  the architect's report back to you. Use it so you are never stuck waiting
  on the architect's own dispatch loop.

---

## 3. Before you start

You need:

- A Mac or a Linux machine.
- Ruby 3.x.
- Taskwarrior.
- A git project.

Install Taskwarrior on macOS:

```sh
brew install task
```

Check both tools:

```sh
ruby -v
task --version
```

Optional: install `graphify` for the knowledge base.

---

## 4. Step 1 - Install the flow into your project

Set a variable for the flow folder. Use the real path on your machine.

```sh
export FLOW=/Users/dominik/Projects/AI/multi_agent_flow
```

Preview the installation. This changes nothing.

```sh
$FLOW/assets/bootstrap.rb /path/to/your/project --check
```

Run the installation.

```sh
$FLOW/assets/bootstrap.rb /path/to/your/project --roles project-manager,architect,backend-developer,reviewer
```

The installer does five things:

1. Creates `coordination/inbox`, `coordination/locks`, `coordination/exports`,
   and `coordination/taskdata`.
2. Copies the `coord` tool into your project.
3. Creates `coordination/taskrc`: a project-local Taskwarrior config, pointed
   at `coordination/taskdata`. Your global `~/.taskrc` is never touched, so
   two projects never share one task board.
4. Adds a contract to `AGENTS.md`, and to `CLAUDE.md` too if that file already
   exists (created for you if you asked `scripts/flow.rb` for a `claude` agent).
5. Adds ignore rules to `.gitignore`.

The installer is idempotent. Run it again at any time. It skips work that is already done.
If it finds an older install that used your global `~/.taskrc`, it prints a
migration note instead of silently stranding those tasks.

If a required tool is missing, add `--install-deps`.

---

## 5. Step 2 - Verify the installation

Enter your project.

```sh
cd /path/to/your/project
./coord init
./coord status
```

The first command prints `coordination/ ready`.
The second command prints `no tasks`.

---

## 6. Step 3 - Open one terminal per agent

Use Warp tabs or panes. Open one terminal for each agent.

Give each agent its own git worktree and branch, so their file changes never
collide even inside the same repository clone:

```sh
./coord worktree backend-developer
# -> ../<project>.worktrees/backend-developer, branch agent/backend-developer
```

All worktrees live in one sibling folder, `<project>.worktrees/`.

Run the agent's terminal from inside that worktree directory. Source the
environment file once so the worktree shares this project's task board:

```sh
cd ../<project>.worktrees/backend-developer
source coord-env.sh
```

`coord-env.sh` sets `COORD_DIR` and `TASKRC` to the main project. Without it,
`./coord` in the worktree would use an empty local board.

Shortcut: `./setup_agent HARNESS ROLE[_WORKER]` does this step and step 4
below, then launches the harness in the worktree, e.g.
`./setup_agent opencode backend-developer_1`. See the README's "Run an
agent" section. The rest of this walkthrough explains what it does under
the hood.

Example layout:

- Pane 1: the `local` agent. It uses your local model.
- Pane 2: the `reviewer` agent. It uses a cloud model.
- Pane 3: you. You run `coord` commands and watch.

---

## 7. Step 4 - Name each agent

In each agent terminal, set the agent role.

```sh
export COORD_AGENT=backend-developer
```

Set this once per terminal.

If you run more than one instance of the same role, give each a unique worker id.

```sh
export COORD_WORKER=backend-developer-1
```

Without `COORD_WORKER`, two instances of the same role share one identity and can
claim the same task. With it, claims are atomic: exactly one instance wins.

---

## 8. Step 5 - Create a task

Decide the work. Create one task for it.
Give the task an owner and a scope.

```sh
./coord add --agent local --scope "test/queries/**" --title "Fix reek offenses in test/queries"
```

The command prints the task ID. Write it down.
The examples below call it `$ID`.

---

## 9. Step 6 - Claim the task

An agent lists the unclaimed tasks for its role.

```sh
./coord next
```

The command prints one line per task: id, title, scope.

An agent claims a task before it starts work.

```sh
./coord claim $ID
```

The task now belongs to your worker. Other workers must not touch the same files.
`claim` is atomic: if two workers race for one task, one wins and the other is
refused. Use `--force` only to take over on purpose.

If a worker crashes mid-task, its claim is not stuck forever: after
`COORD_LEASE_TTL` seconds with no activity (default 4 hours), the task is
claimable again without `--force`. To give a task back sooner, without
finishing it:

```sh
./coord unclaim $ID
```

Do not unclaim a task you are blocked on. Keep the claim, annotate the
blocker, and message the architect. Another worker would hit the same wall.

If no task is available, block instead of polling by hand:

```sh
./coord next --wait
```

---

## 10. Step 7 - Do the work

The agent changes files inside its scope.

If the agent uses the shared local model, hold the model lock first.
See step 10.

---

## 11. Step 8 - Report progress

An agent adds a short note after each milestone.

```sh
./coord annotate $ID "fixed 6 of 11 offenses"
```

Notes are permanent. They are part of the task history.

---

## 12. Step 9 - Complete the task

```sh
./coord done $ID
```

The task leaves the active list.

---

## 13. Step 10 - Share the local model

One local model host serves one generation at a time.
Two agents must not use it together.

Wrap the local command in a lock:

```sh
./coord with-lock ollama -- opencode run --agent tester "Fix reek in test/queries"
```

The lock is released automatically when the command ends.

For a long interactive session, take an advisory lock:

```sh
./coord lock ollama --ttl 3600
# ... work ...
./coord unlock ollama
```

Rule: always take the `ollama` lock before a local generation.

---

## 14. Step 11 - Send a message to another agent

```sh
./coord msg --from local reviewer "test/queries is clean, please review"
```

Read your messages:

```sh
./coord inbox
```

`inbox` defaults to `COORD_AGENT`. Reading marks the messages as read. They move
to `coordination/inbox/<agent>/read/`. Use `--peek` to read without marking. Use
`--all` to include already-read messages.

Messages are files in `coordination/inbox/<agent>/`.

---

## 15. Step 12 - Watch the work

Show a summary by agent and state:

```sh
./coord status
```

Write the board file:

```sh
./coord board
```

The board is at `coordination/exports/board.md`.
Open it in Obsidian with the Kanban plugin.

Export the raw tasks:

```sh
./coord export
```

The export is at `coordination/exports/tasks.json`.

---

## 16. Step 13 - Build the shared knowledge base

Bootstrap already started this for you if `graphify` was on PATH during
install. Check:

```sh
./vault status
```

If it says "not running" (for example, `graphify` was installed after
bootstrap), start it by hand:

```sh
./vault
```

This runs `graphify . --obsidian --obsidian-dir vault --watch --mcp` as a
background process. Now agents query the knowledge graph instead of grepping
the code.

- `--obsidian` writes the vault.
- `--watch` rebuilds the graph when files change.
- `--mcp` serves the graph to agents.
- `./vault stop` stops it.

Open the `vault/` folder in Obsidian. You now see the task board and the code graph together.

---

## 17. Full example

Two agents work on one project.

Terminal 1 (`backend-developer`):

```sh
cd /path/to/project
export COORD_AGENT=backend-developer
./coord add --agent backend-developer --scope "test/queries/**" --title "Fix reek in test/queries"
# prints: 3f2a...  (call it $ID)
./coord claim $ID
./coord with-lock ollama -- opencode run --agent backend-developer "Fix reek in test/queries"
./coord annotate $ID "0 offenses remain, tests pass"
./coord done $ID
./coord msg --from backend-developer reviewer "please review test/queries"
```

Terminal 2 (`reviewer`):

```sh
cd /path/to/project
export COORD_AGENT=reviewer
./coord inbox
./coord add --agent reviewer --scope "test/queries/**" --title "Review test/queries changes"
# prints: 9c1b...  (call it $RID)
./coord claim $RID
# ... review ...
./coord annotate $RID "approved"
./coord done $RID
```

### Running three backend developers

Create the tasks once, for the role. Then start three terminals with the same
role and different worker ids.

```sh
# architect terminal
./coord add --agent backend-developer --scope "app/models/**" --title "Refactor models"
./coord add --agent backend-developer --scope "app/services/**" --title "Refactor services"
./coord add --agent backend-developer --scope "app/jobs/**" --title "Refactor jobs"
```

```sh
# terminal 1
export COORD_AGENT=backend-developer
export COORD_WORKER=backend-developer-1
./coord next          # shows all three unclaimed tasks
./coord claim <id>    # claims one; the other two are now hidden from 'next'
```

```sh
# terminal 2
export COORD_AGENT=backend-developer
export COORD_WORKER=backend-developer-2
./coord next          # shows the remaining unclaimed tasks
```

```sh
# terminal 3
export COORD_AGENT=backend-developer
export COORD_WORKER=backend-developer-3
./coord next
```

Each worker sees only unclaimed tasks. A claim is atomic, so two workers cannot
take the same task. The architect does not need to know how many instances run.
Check your own work with `./coord next --mine`.

You watch from any terminal:

```sh
./coord status
./coord board
```

---

## 18. Command reference

| Command | What it does |
| --- | --- |
| `./coord init` | Create the `coordination/` folders. |
| `./coord add --agent ROLE --scope S --title T` | Create a task for a role. Prints the ID. |
| `./coord next [ROLE]` | List unclaimed tasks for a role (defaults to `COORD_AGENT`). |
| `./coord next --wait` | Block, polling every 60s, until one appears. |
| `./coord next --mine` | List the tasks your worker has claimed. |
| `./coord conflicts` | List pending tasks whose scopes overlap. |
| `./coord claim ID` | Atomically claim a task for `COORD_WORKER`. Refuses to steal an active claim. |
| `./coord unclaim ID` | Release a claim without finishing it. |
| `./coord done ID` | Complete a task. |
| `./coord annotate ID TEXT` | Add a note to a task. |
| `./coord msg --from A TO TEXT` | Send a message to an agent. |
| `./coord inbox [AGENT]` | Read messages (marks them read; `--peek` keeps them; `--wait` blocks until one arrives). |
| `./coord lock NAME --ttl S` | Take an advisory lock. |
| `./coord unlock NAME` | Release a lock. |
| `./coord with-lock NAME -- CMD` | Run a command under a lock. |
| `./coord worktree ROLE [WORKER]` | Create a git worktree + branch for a role. In it, run `source coord-env.sh` to share this project's coordination state. |
| `./setup_agent HARNESS ROLE[_WORKER] [model:M]` | Worktree + env + `COORD_AGENT`/`COORD_WORKER` + launch the harness, in one command. |
| `./coord status` | Show tasks by agent and state. |
| `./coord board` | Write the Obsidian board file. |
| `./coord export` | Write the raw tasks JSON. |

---

## 19. Rules

1. One writer per path. The task scope defines the paths. This is a
   convention, not an enforced lock. Agents must follow it themselves.
2. Use one git branch or worktree per agent. `./coord worktree ROLE` creates one.
3. Take the `ollama` lock before a local generation.
4. Write decisions in `docs/decisions/`. Append. Never rewrite history.
5. Use `annotate` for progress. Use `msg` to talk to another agent.
6. Write `annotate` and `msg` text in Simplified Technical English: one
   instruction per sentence, active voice, named subject, no idioms.
7. If you are blocked, keep the claim. Annotate the blocker. Message the
   architect. Do not unclaim the task.

---

## 20. Troubleshooting

**`coord: Taskwarrior ('task') is not installed`**
Install it: `brew install task`. Or run the installer with `--install-deps`.

**`coord: locked by ...`**
Another agent holds the lock. Wait, or release it with `./coord unlock NAME`.

**The task ID is unknown.**
Run `./coord status`. Or run `task +LATEST uuids`.

**The board file is empty.**
Run `./coord export` first. Check that `task status:pending export` returns data.

**The installer refuses to overwrite `coord`.**
The existing file is not from this flow. Add `--force` only if you are sure.

**Agents change the same file.**
The task scopes overlap. Split the tasks. Give each task a different scope.

**`coord: no role set.`**
`COORD_AGENT` is unset (or literally `unknown`). Run `export COORD_AGENT=<role>`
in that terminal, or pass the role/agent explicitly on the command line.

**A task looks claimed but nobody is working on it.**
The worker likely crashed. Either wait for the lease to expire
(`COORD_LEASE_TTL`, default 4 hours) or free it now: `./coord unclaim ID`.

**A Claude Code session says it has no role.**
Setting `COORD_AGENT` does not make Claude Code assume that role by itself.
`.claude/agents/ROLE.md` is a subagent definition; Claude Code loads it only
when dispatched through its own Task tool, not into a plain interactive
session. Tell the session directly: "Read .claude/agents/ROLE.md and follow
it exactly." `./setup_agent claude ROLE[_WORKER]` does this for you.
