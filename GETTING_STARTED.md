# Getting started

This guide is for a person who has never used multi-agent flow. It explains the
concepts, installs the coordination layer, and walks through a two-agent workflow
by hand — so you can see each part before automation hides it.

Read the whole guide once. Then follow the steps in order.

For a full team setup with dispatched agents, model selection, and the Obsidian
board, see **[USER_MANUAL.md](USER_MANUAL.md)** after this guide.

---

## 1. What this is

You run more than one AI coding agent on one project. Each agent works in its
own terminal. The agents share three things:

- A **task board.** Agents take tasks from the board and mark them done.
- A **message inbox.** Agents send messages to each other.
- A **knowledge base.** Agents read project knowledge instead of searching the code.

You stay in control. You can read the task board and all messages at any time.

The flow uses two programs:

- **Taskwarrior** (`task`) stores the tasks.
- **`coord`** is a small command-line tool. It is the only interface the agents
  use for tasks, messages, and locks.

All shared state lives in a `.maf/coordination/` folder inside your project.

---

## 2. Concepts

[docs/flow-glossary.md](docs/flow-glossary.md) defines every term. In short:

- A **harness** (Claude Code, opencode, Codex, Hermes) runs a **role** (architect,
  tester) as a **worker** (`tester-1`). That running session is an **agent**.
- A **task** belongs to a role. A worker **claims** a task. A **lock** is held by a worker.
- A **message** goes to a role's inbox.

Two roles have a special job:

- **Architect**: splits a request into tasks and assigns them. It does not write code.
- **Project manager** (optional): you talk to it. It creates goals and sends them to the
  architect and relays the report back.

---

## 3. Prerequisites

You need:

- A Mac or Linux machine.
- Ruby 3.0 or later.
- Taskwarrior (`task`).
- A git project with at least one commit.

Install Ruby 3.0+ on macOS:

```sh
brew install mise && mise install ruby
```

Install Taskwarrior on macOS:

```sh
brew install task
```

Check both:

```sh
ruby -v
task --version
```

Optional: install `graphify` for the knowledge base.

---

## 4. Install the coordination layer

Link the `maf` command into a folder on `PATH` once:

```sh
mkdir -p ~/.local/bin
ln -sf /path/to/multi_agent_flow/bin/maf ~/.local/bin/maf
maf help
```

Run `maf` in your project root. Preview the install (writes nothing):

```sh
cd /path/to/your/project
maf add claude:architect opencode:backend-developer claude:reviewer --check
```

Run the install:

```sh
maf add claude:architect opencode:backend-developer claude:reviewer
```

Use `maf roles` to see all roles. Each argument is `HARNESS:ROLE`.

`maf add` does these things:

1. Creates the folder `.maf/` in your project. The flow keeps all its files there.
   The folder holds `coordination/inbox`, `coordination/locks`, `coordination/exports`,
   and `coordination/taskdata`.
2. Copies `coord`, `dispatcher`, `vault`, and `dashboard` into `.maf/bin/`.
   Writes `.maf/env.sh`. The file puts `.maf/bin` on `PATH`.
3. Creates `.maf/coordination/taskrc`: a project-local Taskwarrior config. Your
   global `~/.taskrc` is never touched; two projects never share one board.
4. Appends the coordination contract to `AGENTS.md`.
5. Adds ignore rules to `.gitignore`.
6. Writes a role file per agent into `.maf/agents/<harness>/`. The folders of the
   harnesses (`.claude/agents/`, `.opencode/agents/`, `.codex/prompts/`) are
   symlinks to them. Writes the `.maf/config.json` manifest.

The project root keeps `.maf/` and `AGENTS.md`. A few files must stay where
their tool reads them (`.gitignore`, `.claude/settings.json`, the git hooks).
See the project layout in [README.md](README.md).

`maf add` is idempotent. Run it again at any time; it skips work already
done. It keeps the current agents, so give only the new ones.

---

## 5. Verify the install

```sh
cd /path/to/your/project
source .maf/env.sh
coord init
coord status
```

`source .maf/env.sh` puts `.maf/bin` on `PATH`. After that, you run `coord`, not `./coord`.
`coord init` prints `.maf/coordination/ ready (.maf/coordination)`.
`coord status` prints `no tasks`.

---

## 6. Commit the installed files

Each agent works in its own git worktree. A worktree contains only committed
files, so commit before starting any agent.

```sh
cd /path/to/your/project
git add .maf AGENTS.md .gitignore .claude .opencode .codex
git commit -m "Add multi-agent flow"
```

---

## 7. Open terminals and set the agent role

Give each agent its own git worktree and branch so file changes never collide:

```sh
cd /path/to/your/project
coord worktree backend-developer
```

This creates `.maf/worktrees/backend-developer-1` on branch `worker/backend-developer-1`.

In the agent's terminal:

```sh
cd /path/to/your/project/.maf/worktrees/backend-developer-1
source .maf/env.sh
export COORD_ROLE=backend-developer
export COORD_WORKER=backend-developer-1
```

`source .maf/env.sh` sets `COORD_DIR` and `TASKRC` to the main project.
Without it, `coord` in the worktree sees an empty local board.

Do the same for each agent. Example layout:

- Terminal 1: `backend-developer` (your local model, interactive)
- Terminal 2: `reviewer` (cloud model, interactive)
- Terminal 3: you — run `coord` commands and watch

> **Shortcut:** use `maf start HARNESS ROLE[_WORKER]` instead. It does
> the worktree, `.maf/env.sh`, `COORD_ROLE`, and `COORD_WORKER` steps and
> then launches the harness.

If you run more than one instance of the same role, give each a unique worker id:

```sh
export COORD_WORKER=backend-developer-2
```

Without distinct `COORD_WORKER` values, two instances share one identity and can
claim the same task.

---

## 8. Create a task

```sh
coord add --role backend-developer --scope "test/queries/**" \
  --title "Fix reek offenses in test/queries"
```

The command prints the task ID. Use `$ID` below.

---

## 9. Claim the task

List unclaimed tasks for a role:

```sh
coord next
```

Claim a task before starting work:

```sh
coord claim $ID
```

`claim` is atomic: if two workers race for one task, one wins and the other is
refused. Use `--force` only to take over a task on purpose.

If the task is unclaimed but no agent is working on it:

```sh
coord next --wait   # block until a task or a message appears (polls every 60s)
```

If a worker crashes mid-task, its claim is not stuck forever. After
`COORD_LEASE_TTL` seconds with no activity (default 4 hours), the task is
claimable again without `--force`. To release a task without finishing it:

```sh
coord unclaim $ID
```

Do not unclaim a task you are blocked on. Keep the claim, annotate the blocker,
and message the architect. Another worker would hit the same wall.

---

## 10. Do the work

The agent changes files inside its scope. If the agent uses a shared local
model, take the `ollama` lock first (see step 12).

---

## 11. Report progress

Add a short note after each milestone:

```sh
coord annotate $ID "fixed 6 of 11 offenses"
```

Notes are permanent. They are part of the task history.

---

## 12. Complete the task

```sh
coord done $ID
```

---

## 13. Share a local model

One local model host serves one generation at a time. Wrap the command in a lock:

```sh
coord with-lock ollama -- opencode run --agent backend-developer "Fix reek in test/queries"
```

The lock releases automatically when the command ends. For a long interactive
session, take an advisory lock:

```sh
coord lock ollama --ttl 3600
# ... work ...
coord unlock ollama
```

---

## 14. Send a message to another agent

```sh
coord msg --from backend-developer reviewer "test/queries is clean, please review"
```

Read your messages:

```sh
coord inbox
```

`inbox` defaults to `$COORD_ROLE`. Reading marks messages as read. Use
`--peek` to read without marking. Messages are files in
`.maf/coordination/inbox/<role>/`.

---

## 15. Watch the work

Task summary by role and state:

```sh
coord status
```

Write the Obsidian board file:

```sh
coord board
```

The board is at `.maf/coordination/exports/board.md`. Open it in Obsidian with the
Kanban plugin (mgmeyers/obsidian-kanban). Keep it current:

```sh
watch -n 10 coord board
```

Web dashboard (stuck-detection: expired leases, unread inboxes, stale locks,
scope conflicts):

```sh
dashboard
```

Open `http://localhost:4567`. The page auto-refreshes every 5 seconds.
Stop with Ctrl-C.

---

## 16. Full example

Two agents work on one project.

Terminal 1 (`backend-developer`):

```sh
cd /path/to/project/.maf/worktrees/backend-developer-1
source .maf/env.sh
export COORD_ROLE=backend-developer
export COORD_WORKER=backend-developer-1

coord add --role backend-developer --scope "test/queries/**" \
  --title "Fix reek in test/queries"
# prints: 3f2a...  (use as $ID)
coord claim $ID
coord with-lock ollama -- opencode run --agent backend-developer \
  "Fix reek in test/queries"
coord annotate $ID "0 offenses remain, tests pass"
coord done $ID
coord msg --from backend-developer reviewer "please review test/queries"
```

Terminal 2 (`reviewer`):

```sh
cd /path/to/project/.maf/worktrees/reviewer-1
source .maf/env.sh
export COORD_ROLE=reviewer
export COORD_WORKER=reviewer-1

coord inbox
coord add --role reviewer --scope "test/queries/**" \
  --title "Review test/queries changes"
# prints: 9c1b...  (use as $RID)
coord claim $RID
# ... review ...
coord annotate $RID "approved"
coord done $RID
```

Running three backend developers in parallel — create tasks once, start three
terminals with the same role and different worker ids:

```sh
# architect terminal
coord add --role backend-developer --scope "app/models/**"   --title "Refactor models"
coord add --role backend-developer --scope "app/services/**" --title "Refactor services"
coord add --role backend-developer --scope "app/jobs/**"     --title "Refactor jobs"
```

```sh
# terminal 1
export COORD_ROLE=backend-developer; export COORD_WORKER=backend-developer-1
coord next      # shows all three unclaimed tasks
coord claim <id>  # claims one; the rest stay available
```

```sh
# terminal 2
export COORD_ROLE=backend-developer; export COORD_WORKER=backend-developer-2
coord next      # shows remaining unclaimed tasks
```

Each worker sees only unclaimed tasks. A claim is atomic; two workers cannot
take the same task.

---

## 17. Rules

1. One writer per path. The task scope defines the paths. Agents must follow it.
2. Use one git worktree per worker. `coord worktree ROLE` creates one.
3. Take the `ollama` lock before a local generation.
4. Write decisions in `.agent/decisions/` if it exists, else `docs/decisions/`. Append; never rewrite history.
5. Use `annotate` for progress. Use `msg` to talk to another agent.
6. Write `annotate` and `msg` text in Simplified Technical English: one
   instruction per sentence, active voice, named subject, no idioms.
7. If blocked, keep the claim. Annotate the blocker. Message the architect.

---

## 18. Troubleshooting

**`coord: Taskwarrior ('task') is not installed`**
Run `brew install task`, or re-run the installer with `--install-deps`.

**`coord: locked by ...`**
Another worker holds the lock. Wait, or release it with `coord unlock NAME`.

**The task ID is unknown.**
Run `coord status`. Or run `task +LATEST uuids`.

**The board file is empty.**
Run `coord board` again. Check that `task status:pending export` returns data.

**The installer refuses to overwrite `coord`.**
The existing file is not from this flow. Add `--force` only if you are sure.

**Agents change the same file.**
The task scopes overlap. Split the tasks. Give each task a different scope.

**`coord: no role set`**
`COORD_ROLE` is unset or set to `unknown`. Run `export COORD_ROLE=<role>`.

**A task looks claimed but nobody is working on it.**
The worker likely crashed. Wait for the lease to expire (`COORD_LEASE_TTL`,
default 4 hours) or free it now: `coord unclaim $ID`.

**A Claude Code session says it has no role.**
Setting `COORD_ROLE` does not make Claude Code assume that role. `.claude/agents/ROLE.md`
is a subagent definition, not the session's persona. Tell the session directly:
"Read `.claude/agents/ROLE.md` and follow it exactly." `maf start claude ROLE` does
this for you.

**A Hermes session says the skill is unknown.**
The skill file does not exist. Run `maf add hermes:ROLE` first to
generate `~/.hermes/skills/<project>-<role>/SKILL.md`. `maf start hermes ROLE`
checks for the skill and only passes `--skills` when it exists.

---

## Next steps

This guide covered the basic workflow. For a real multi-agent team setup with:

- Harness-specific role files for each role
- Dispatched (unattended) agents that start only when there is work
- Prompt cache management to save tokens
- The graphify knowledge base
- Full monitoring and the web dashboard

See **[USER_MANUAL.md](USER_MANUAL.md)**.
