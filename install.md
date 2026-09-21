# Multi-agent flow - installation instruction

This file is an instruction for an AI coding agent. Read the whole file. Then do
the steps in order.

You set up a shared coordination layer for multiple coding agents in one project.

---

## Step 1 - Find the flow folder

This file lives in the flow folder. Call that folder `FLOW`.

All commands below use `$FLOW`. Set it to the real path.

```sh
export FLOW=/path/to/multi_agent_flow
```

Check the tools. The `coord` tool and the installer are Ruby scripts.

```sh
ruby -v
task --version
```

If `task` is missing, install it (`brew install task`) or pass `--install-deps`
to the installer in step 4.

## Step 2 - Ask the user for the project folder

Ask: "Which project folder should use the multi-agent flow?"

Use the answer as `PROJECT`. The folder must exist and must be a git repository.

## Step 3 - Ask the user for harnesses and roles

Ask: "Which agent harnesses do you want to use? For example: opencode, Claude
Code, Codex, Hermes."

Show the available roles. Run:

```sh
ruby "$FLOW/scripts/flow.rb" --list-roles
```

Ask the user to map roles to harnesses. Example answer:

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

## Step 5 - Run the generator

Build one `--agent HARNESS:ROLE` flag per role. Add one `--model ROLE=MODEL` flag
per chosen model.

Preview first. This writes nothing.

```sh
ruby "$FLOW/scripts/flow.rb" \
  --project "$PROJECT" \
  --agent claude:architect \
  --agent opencode:backend-developer \
  --agent opencode:frontend-developer \
  --agent codex:reviewer \
  --agent hermes:tester \
  --model architect=anthropic/claude-opus-4-6 \
  --check
```

Then run it for real. Remove `--check`.

```sh
ruby "$FLOW/scripts/flow.rb" \
  --project "$PROJECT" \
  --agent claude:architect \
  --agent opencode:backend-developer \
  --agent opencode:frontend-developer \
  --agent codex:reviewer \
  --agent hermes:tester \
  --model architect=anthropic/claude-opus-4-6
```

The generator does these things:

1. Sets up the coordination layer. It calls `assets/bootstrap.rb`.
2. Writes one agent file per role, in the format of its harness.
3. Writes a manifest at `$PROJECT/.agent-flow.json`.

The generator is idempotent. It skips files that are already correct.

## Step 6 - Verify

```sh
cd "$PROJECT"
./coord init
./coord status
cat .agent-flow.json
ls setup_agent
```

Check that each agent file exists:

- opencode: `.opencode/agents/<role>.md`
- Claude Code: `.claude/agents/<role>.md`
- Codex: `.codex/prompts/<role>.md`
- Hermes: `~/.hermes/skills/<project-name>-<role>/SKILL.md` (namespaced by
  project; Hermes skills are global, so this keeps two projects with the
  same role from overwriting each other's skill)

## Step 7 - Report to the user

Report the generated files. Then give the user these instructions.

> For each claude, opencode, or codex agent, open a terminal in the project
> folder and run:
>
>     ./setup_agent HARNESS ROLE[_WORKER] [model:PROVIDER/MODEL]
>
> Example, for this setup:
>
>     ./setup_agent claude architect
>     ./setup_agent opencode backend-developer_1
>     ./setup_agent opencode frontend-developer_1
>     ./setup_agent codex reviewer
>
> This creates (or reuses) a worktree for that agent, sets `COORD_AGENT` and
> `COORD_WORKER`, and launches the harness there with its role loaded. To run
> several instances of one role, add a worker suffix: `backend-developer_1`,
> `backend-developer_2`. Claims are atomic, so they will not collide.
>
> Hermes has no `setup_agent` launcher yet. Open its session by hand: set
> `COORD_AGENT`/`COORD_WORKER`, then paste "Run `./coord inbox`. Then run
> `./coord next --wait` to get a task as soon as one is available, claim it
> with `./coord claim <id>`, do the work, and finish with `./coord done
> <id>`. Repeat."
>
> In the architect session, describe what you want built. For example: "Build a
> task tracker app." The architect creates tasks. The workers pick them up.

## Notes

- One writer per path. The task scope defines the paths. `coord add`/`conflicts`
  warns on overlap; roles marked "never edit" also get a restricted tool grant
  where the harness supports one (Claude Code, opencode).
- Take the `ollama` lock before a local model generation:
  `./coord with-lock ollama -- <command>`.
- Give each agent its own worktree so file changes never collide:
  `./coord worktree <role>` (creates `../<project>.worktrees/<role>` on branch `agent/<role>`).
  In that worktree run `source coord-env.sh` first; it points `COORD_DIR` and
  `TASKRC` at the main project, so every worktree shares one coordination/ dir
  and one task board. `./setup_agent` does all of this for you.
- Claude Code does not auto-load `.claude/agents/<role>.md` into an interactive
  session (that file is a subagent definition, used via its Task tool, not the
  session's own persona). `./setup_agent claude <role>` works around this by
  passing an initial prompt that tells the session to read and follow it.
- The user can add or remove agents later. Run the generator again.
- Codex and Hermes have no subagent files. Codex gets custom prompts. Hermes gets
  skills. Both work the same way in this flow.
