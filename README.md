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
walkthrough for a first-time user. For the fastest path from a fresh clone to a
running team with several harnesses and dispatched agents, read
**[USER_MANUAL.md](USER_MANUAL.md)**.

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
  USER_MANUAL.md              # clone-to-running-team guide (3 harnesses, dispatch)
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
    dispatcher                # unattended agent: poll board, spin up, exit (Ruby)
    vault                     # graphify + Obsidian + MCP watcher control (Ruby)
    bootstrap.rb              # idempotent installer (Ruby)
    taskrc.append             # Taskwarrior UDA block
    agents-contract.md        # contract appended to AGENTS.md / CLAUDE.md
    gitignore.append          # marker-guarded ignore entries
    coordination/             # inbox / locks / exports skeleton
  test/
    coord_test.rb             # behavioral tests for the coord CLI
    installer_test.rb         # tests for bootstrap.rb, flow.rb, setup_agent
    dispatcher_test.rb        # tests for the dispatcher
```

## Install into a project

```sh
./assets/bootstrap.rb /path/to/project --roles project-manager,architect,backend-developer,frontend-developer,reviewer,tester
```

Prerequisites: Ruby 3.0+ and `task` (Taskwarrior). Optional: `graphify`.
macOS: `brew install mise && mise install ruby` for Ruby 3.0+; `brew install task` for Taskwarrior. No `jq` needed.

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
./coord broadcast --from architect "scope change: all tests move to spec/"  # every known role except the sender
./coord inbox
./coord log 20                    # last 20 coordination events
./coord with-lock ollama -- opencode run --agent backend-developer "..."
./coord worktree backend-developer  # git worktree + branch; then `source coord-env.sh` in it
./coord status
./coord board        # coordination/exports/board.md — open in Obsidian (Kanban plugin); keep fresh with: watch -n 10 ./coord board
./dashboard          # http://localhost:4567 — stuck-detection: stale leases, unread inboxes, locks, conflicts
./setup_agent hermes tester --dispatch  # worktree + dispatcher: agent runs only when there is work
```

A task left claimed with no activity for `COORD_LEASE_TTL` seconds (default 4
hours, override via env) is treated as abandoned: `next`/`claim` reclaim it
without `--force`. `coord unclaim` releases one immediately.

## Run an agent

`setup_agent` wraps the manual per-agent setup (worktree, `coord-env.sh`,
`COORD_AGENT`/`COORD_WORKER`, role bootstrap) into one command:

```sh
./setup_agent HARNESS ROLE[_WORKER] [model:MODEL] [--model MODEL] [--dispatch [FLAGS...]]
./setup_agent claude backend-developer_1
./setup_agent opencode reviewer_1 --model openrouter/deepseek-v3
./setup_agent hermes tester --dispatch --model openrouter/deepseek-v3
```

With `--dispatch`, `setup_agent` runs `./dispatcher` in the worktree instead
of an interactive session (see "Run a dispatcher" below). Other flags after
the positional arguments go to the dispatcher, for example
`--cache-window 1500` or `--interval 30`. With `--dispatch`, `WORKER`
defaults to `bot`, so a dispatched instance and an interactive instance of
one role get separate worktrees.

It creates or reuses the worktree, exports `COORD_DIR`/`TASKRC`/`COORD_AGENT`/
`COORD_WORKER`, then execs the harness in that worktree. All worktrees live in
one sibling folder, `<project>.worktrees/<role>-<worker>`:

- `opencode`/`codex`: `--agent ROLE` (or the `.codex/prompts/ROLE.md` file)
  loads the role file automatically.
- `claude`: Claude Code does not auto-load `.claude/agents/*.md` into an
  interactive session (those files are subagent definitions, used via its
  Task tool). `setup_agent` instead passes an initial prompt telling the
  session to read and follow its role file.
- `hermes`: Hermes loads roles as skills (`--skills <project>-<role>`).
  `setup_agent hermes ROLE` launches `hermes chat --skills <project>-<role>`
  with an initial work-loop prompt.

`HARNESS:ROLE` must already exist in `.agent-flow.json` (add one with
`scripts/flow.rb --agent HARNESS:ROLE`). `WORKER` defaults to `1` if omitted
(`bot` with `--dispatch`).

## Run a dispatcher (unattended agent)

`./dispatcher <role>` polls the role's inbox and the task board every 60
seconds. When there is work, it starts the agent in one-shot mode. The agent
exits when the work is done. Between runs, no agent is alive, so no tokens
are spent.

Start a dispatcher with `setup_agent --dispatch`. It creates the worktree,
connects it to the task board, and runs `./dispatcher` there:

```sh
./setup_agent hermes tester --dispatch
./setup_agent claude reviewer --dispatch --model sonnet --cache-window 3300
```

You can also run `./dispatcher` directly inside a prepared worktree:

```sh
# Built-in adapters: hermes (default), claude, codex, opencode
./dispatcher tester
./dispatcher reviewer --harness claude --model sonnet
./dispatcher backend-developer --harness opencode --model openrouter/qwen3-coder
./dispatcher reviewer --harness codex

# Any other harness via a --command template (no session resume):
./dispatcher reviewer --command 'my-agent --role %{role} %{prompt}'

# One poll cycle, then exit (for testing or cron)
./dispatcher reviewer --once
```

Each built-in adapter loads the role that `flow.rb` generated for it:

| Harness | Role source | Resume flag |
|---|---|---|
| hermes | skill `<project>-<role>` | `--resume` |
| claude | `.claude/agents/<role>.md` via `--agent` | `--resume` |
| codex | `.codex/prompts/<role>.md`, sent at the start of a fresh session | `exec resume` |
| opencode | `.opencode/agents/<role>.md` via `--agent` | `--session` |

How the dispatcher handles work:

- **Messages.** The dispatcher owns the role's inbox. It moves each unread
  message to `inbox/<role>/processing/` and sends all of them to one agent
  run. If the run succeeds, the messages move to `read/`. If the run fails,
  the messages go back to the inbox. After 3 failed runs, a message moves to
  `failed/`. The count is kept in the file name (`.retry2.md`), so it survives
  a dispatcher restart. Do not run `coord inbox` for a role that a dispatcher serves.
- **Tasks.** If `coord next <role>` lists unclaimed tasks, the dispatcher
  starts one run. If the same tasks are still unclaimed after the run, the
  dispatcher waits before the next run. The wait doubles each time, up to 1
  hour. A new or changed task set starts a run at once.
- **Timeout.** After `--timeout` seconds, the dispatcher kills the agent's
  whole process group.
- **Environment.** The agent gets `COORD_DIR`, `COORD_AGENT`,
  `COORD_WORKER` (default `<role>-dispatcher`), and `TASKRC`. Its stdin is
  closed.

### Sessions and the prompt cache

LLM providers cache the start of a conversation for a limited time after the
last request. Claude Code uses a 1-hour cache. A resume inside that time is
cheap, because the provider reads the old context from the cache. A resume
after that time sends the whole old context again at full price.

The dispatcher resumes a session only inside the cache window:

1. After each successful run, the dispatcher saves the session ID to
   `coordination/sessions/<worker>.session`. The file's time is the time of
   the last run.
2. Every run ends with a short handoff note (at most 300 words) in
   `coordination/sessions/<worker>.handoff.md`. The agent writes the note while
   its cache is still warm. If the agent writes no note, the dispatcher saves
   the agent's final reply as the note.
3. If the last run ended less than `--cache-window` seconds ago (default: 3300,
   55 minutes), the dispatcher resumes the session.
4. If the last run is older, the dispatcher starts a fresh session. The fresh
   session gets the handoff note at the start of its prompt, not the old
   context.

Set `--cache-window` to your provider's cache time minus a margin. Use
`--cache-window 0` to never resume. The rule uses time only, because the
harnesses do not report the context size the same way. A small session also
starts fresh after the window. That costs little, because the handoff note is
short.

If the harness reports an unknown session, the dispatcher starts a fresh
session with the handoff note. Other failures keep the saved session. Runs
with `--command` never resume, so they get the handoff note every time. Two
dispatchers for one role need different `COORD_WORKER` values, so they keep
separate sessions and notes.

> **Warning:** every built-in adapter skips permission prompts: hermes
> `--yolo`, claude `--permission-mode bypassPermissions`, codex
> `--dangerously-bypass-approvals-and-sandbox`. The agent runs every tool call
> without approval. Run each dispatcher only in its own worktree or a sandbox
> that you trust the agent with.

Flags: `--harness` (hermes, claude, codex, opencode; default: hermes),
`--command` (template with `%{prompt}`, `%{role}`, `%{skill}`, `%{model}`,
each shell-escaped), `--model` (in the harness CLI's own format), `--skill`
(hermes; default: `<project>-<role>` if `flow.rb` generated that skill),
`--no-skill`, `--interval` (default: 60s), `--max-turns` (hermes; default: 50),
`--timeout` (default: 300s), `--cache-window` (default: 3300s),
`--no-poll-tasks`, `--once`, `--verbose`.

## Message hooks (harness-agnostic)

`coord msg` and `coord broadcast` fire a per-role hook at
`coordination/hooks/<role>.sh` when a message is delivered. The hook is a
plain shell script. `coord` does not know which harness the agent runs in.
The hook can poke a running tmux session, start a one-shot run, send a
notification, or do nothing. If there is no hook, `coord` only writes the
inbox file. The agent reads it on its next `coord inbox`.

```sh
# coordination/hooks/backend-developer.sh
#!/bin/sh
# Poke a running tmux session to check its inbox
tmux send-keys -t backend './coord inbox' Enter
```

The hook gets these values:

- `COORD_AGENT`: the receiving role.
- `COORD_FROM`: the sender.
- `COORD_MSG_FILE` and `$1`: the message file path.

The hook runs in the background, so a slow hook does not block the sender.
Its output goes to `coordination/hooks/<role>.log`. `coord hooks [ROLE]`
lists installed hooks and their status.

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
