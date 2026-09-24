# Multi-agent flow - installation instruction

This file is an instruction for an AI coding agent. Read the whole file. Then do
the steps in order.

You set up a shared coordination layer for multiple coding agents in one project.

---

## Step 1 - Install the maf command

This file lives in the flow folder. Call that folder `FLOW`.
Link `FLOW/bin/maf` into a folder on `PATH`:

```sh
export FLOW=/path/to/multi_agent_flow
mkdir -p ~/.local/bin
ln -sf "$FLOW/bin/maf" ~/.local/bin/maf
maf help
```

If `maf help` fails, add `~/.local/bin` to `PATH`.
If the link exists already, keep it.

Check the tools. `maf` and the `coord` tool are Ruby scripts.

```sh
ruby -v
task --version
```

If `task` is missing, install it (`brew install task`).

## Step 2 - Ask the user for the project folder

Ask: "Which project folder should use the multi-agent flow?"

Use the answer as `PROJECT`. The folder must exist and must be a git repository.
Run all `maf` commands below in `PROJECT`:

```sh
cd "$PROJECT"
```

## Step 3 - Ask the user for harnesses and roles

Ask: "Which agent harnesses do you want to use? For example: opencode, Claude
Code, Codex, Hermes."

Show the available roles. Run:

```sh
maf roles
```

Tell the user about the `project-manager` role: the user talks to it, it sends
one goal at a time to the architect, and the architect reports back to it.
Recommend it whenever the architect would otherwise take requests directly
from the user. Ask the user to map roles to harnesses. Example answer:

- claude -> project-manager
- claude -> architect
- opencode -> backend-developer
- opencode -> frontend-developer
- codex -> reviewer
- hermes -> tester

You may run more than one role in one harness. Open one session per role.

## Step 4 - Ask the user for a model per role

Do not choose models yourself. Ask the user.

Show the model hint from step 3 for each role. Explain that the hint is only a
recommendation. The user knows what runs on the machine.

The user may skip a model. If skipped, the harness default applies.

## Step 5 - Add the agents

Give one `HARNESS:ROLE` argument per role. Add one `--model ROLE=MODEL` flag
per chosen model.

Preview first. This writes nothing.

```sh
maf add claude:project-manager claude:architect \
  opencode:backend-developer opencode:frontend-developer \
  codex:reviewer hermes:tester \
  --model project-manager=anthropic/claude-opus-4-6 \
  --model architect=anthropic/claude-opus-4-6 \
  --check
```

Then run the same command without `--check`.

`maf add` does these things:

1. Sets up the coordination layer.
2. Writes a role file for each role, in the format of its harness.
3. Writes a manifest at `$PROJECT/.agent-flow.json`.

`maf add` is idempotent. It skips files that are already correct.

## Step 6 - Verify

```sh
cd "$PROJECT"
./coord init
./coord status
maf agents
```

Check that each role file exists:

- opencode: `.opencode/agents/<role>.md`
- Claude Code: `.claude/agents/<role>.md`
- Codex: `.codex/prompts/<role>.md`
- Hermes: `~/.hermes/skills/<project-name>-<role>/SKILL.md` (namespaced by
  project; Hermes skills are global, so this keeps two projects with the
  same role from overwriting each other's skill)

## Step 6b - Commit the installed files

Worktrees contain only committed files. Commit before starting any agent.

```sh
cd "$PROJECT"
git add coord dispatcher AGENTS.md .gitignore \
        .agent-flow.json .claude .opencode coordination
git rm --cached -q --ignore-unmatch CLAUDE.md .claude/CLAUDE.md   # maf add moved it into AGENTS.md
git add vault vault-daemon 2>/dev/null; true
git commit -m "Add multi-agent flow"
```

The `.gitignore` already excludes runtime state (task database, inboxes,
sessions, logs).

## Step 7 - Report to the user

Report the generated files. Then give the user these instructions.

> For each claude, opencode, or codex agent, open a terminal in the project
> folder and run:
>
>     maf start HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
>
> Example, for this setup:
>
>     maf start claude project-manager
>     maf start claude architect
>     maf start opencode backend-developer_1
>     maf start opencode frontend-developer_1
>     maf start codex reviewer
>
> To run an agent unattended, add `--dispatch`. The agent then starts only
> when there is work, and it exits when the work is done:
>
>     maf start hermes tester --dispatch
>
> This creates (or reuses) a worktree at `.worktrees/<role>-<worker_id>`,
> sets `COORD_ROLE` and `COORD_WORKER`, and launches the harness there with
> its role loaded. To run several instances of one role, add a worker suffix:
> `backend-developer_1`, `backend-developer_2`. Claims are atomic, so they
> will not collide.
>
> Hermes loads the role as a skill (`--skills <project>-<role>`); the skill
> file at `~/.hermes/skills/<project>-<role>/SKILL.md` must have been generated
> by `maf add` first.
>
> Talk to the project manager session, not the architect. For example: "Build a
> task tracker app." The project manager sends the goal to the architect. The
> architect creates tasks. The workers pick them up. The architect reports back
> to the project manager, and the project manager reports back to you. If no
> `project-manager` role was set up, talk to the architect session directly
> instead.

## Notes

- One writer per path. The task scope defines the paths. `coord add`/`conflicts`
  warns on overlap; roles marked "never edit" also get a restricted tool grant
  where the harness supports one (Claude Code, opencode).
- Every generated role file requires Simplified Technical English in
  `coord msg`, `coord annotate`, and task titles: one instruction per
  sentence, active voice, named subject, no idioms.
- Take the `ollama` lock before a local model generation:
  `./coord with-lock ollama -- <command>`.
- Give each agent its own worktree so file changes never collide:
  `./coord worktree <role>` creates `.worktrees/<role>-<worker_id>` (inside the
  project, gitignored) on branch `worker/<role>-<worker_id>`. In that worktree
  run `source coord-env.sh` first; it points `COORD_DIR` and `TASKRC` at the
  main project, so every worktree shares one coordination/ dir and one task
  board. `maf start` does all of this for you.
- Claude Code does not auto-load `.claude/agents/<role>.md` into an interactive
  session (that file is a subagent definition, used via its Task tool, not the
  session's own persona). `maf start claude <role>` works around this by
  passing an initial prompt that tells the session to read and follow it.
- The user can add agents later with `maf add HARNESS:ROLE`.
  The user can remove agents with `maf remove HARNESS:ROLE`.
  `maf add` keeps the current agents.
- Codex and Hermes have no subagent files. Codex gets custom prompts. Hermes gets
  skills, loaded via `--skills <project>-<role>`. Both work the same way in this flow.
