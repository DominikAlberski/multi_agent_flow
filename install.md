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
goals to the architect (`coord goal add`), and the architect reports back to it.
Recommend it whenever the architect would otherwise take requests directly
from the user. Ask the user to map roles to harnesses. Example answer:

- claude -> project-manager
- claude -> architect
- opencode -> backend-developer
- opencode -> frontend-developer
- codex -> reviewer
- hermes -> tester

You may run more than one role in one harness. Open one session per role.

## Step 3b - Ask the user for the number of workers

Ask: "How many workers do you want for each worker role?"

A worker role is a role other than `project-manager` and `architect`.
Default: one worker per role.
Remember the answer. Step 7 uses it for the `maf start` commands.

## Step 3c - Ask the user for custom roles

Ask: "Do you need a role that is not in the list? Describe it in one sentence."

If the user needs no custom role, skip this step.
If the user needs a custom role, do these steps for each role:

1. Run `maf role add NAME`. The command writes a stub into `.maf/roles.yml`.
2. Replace each `TODO` line in the stub. Use the four duty parts: focus,
   checks, done condition, and avoid. Write them in Simplified Technical English.
3. Use `NAME` as a role in Step 5.

A role in `.maf/roles.yml` with the name of a built-in role replaces the built-in role.
`maf roles` shows the source of each role.

## Step 3d - Ask the user for the workflow

The workflow tells the architect in which order to create tasks.
Ask: "Which workflow do you want? Choose one, or describe your own in your own words."

| Name | Stages |
|---|---|
| `simple` | Implement, review, merge. |
| `plan-review` | Plan, review the plan, implement, review, merge. |
| `tdd` | Plan, review the plan, write specs, implement, review, merge. |

If the user chooses a name, copy the file `FLOW/templates/workflows/<name>.md`
to `.maf/workflow.md`.
If the user describes a workflow, write the description to `.maf/workflow.md` as
stage instructions. Use Simplified Technical English. Write one instruction per
sentence. Write "Stage N." at the start of each stage. State the gate that ends
each stage. Do not create tasks for a stage in advance: the architect creates
the tasks of the next stage after the gate passes.
If the user wants no workflow, create no `.maf/workflow.md`.

Only the architect reads `.maf/workflow.md`. Other roles do not see it.
Run `maf update` after each later change of the file.
Step 5 reads `.maf/roles.yml` and `.maf/workflow.md`, so write both before Step 5.

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
3. Writes a manifest at `$PROJECT/.maf/config.json`.
4. Writes the graphify MCP server into `.maf/mcp/` for Claude Code and opencode.
   `maf start` passes the file to the harness. The project's `.mcp.json` and `opencode.json` stay as they are.
   For Codex and Hermes, `maf add` prints a command. Run it to add the server.
   To turn the server off, set `"mcp": false` in `.maf/config.json`.

`maf add` is idempotent. It skips files that are already correct.

## Step 5b - Turn on the Hermes hook (Hermes roles only)

Skip this step when no role uses the Hermes harness.

`maf add` installs the hook script at `~/.hermes/agent-hooks/next-task.sh`.
Hermes runs it when a session ends. The hook resumes the session when the role
has unclaimed tasks.

The hook stays inactive until the Hermes config declares it and the user
approves it. `maf add` prints the commands. Run them in order.

```sh
hermes config set hooks.on_session_end '[{"command":"<script path>","timeout":30}]'
hermes chat --oneshot --accept-hooks -q ok
hermes hooks doctor
```

Do not edit `~/.hermes/config.yaml` by hand. The file holds comments and markers
that a rewrite destroys.

The first command replaces the whole `on_session_end` list. If the list is not
empty, read it first with `hermes config get hooks.on_session_end`. Then set the
list with the existing entries plus the new entry.

The second command approves the hook one time. Hermes stores the consent for this
version of the script. A new script version needs a new approval.

Confirm that every check from `hermes hooks doctor` passes. Then continue.

## Step 5c - Set the Gemini key for the doc-graph refresh

`maf add` appends a flow block to the `post-commit` and `post-merge` git hooks.
A markdown commit or merge starts `.maf/bin/doc-graph-refresh` detached.
The script runs `graphify extract . --backend gemini` and re-exports
`.maf/obsidian/`. It needs `GEMINI_API_KEY`:

```sh
export GEMINI_API_KEY=<key>
```

The hook starts no LLM call without the key. It logs a skip in
`.maf/coordination/doc-graph.log`. The hook never fails a commit.

## Step 6 - Verify

```sh
cd "$PROJECT"
coord init
coord status
maf agents
```

Check that each role file exists:

- opencode: `.opencode/agents/<role>.md`
- Claude Code: `.claude/agents/<role>.md`
- Codex: `.codex/prompts/<role>.md`
- Hermes: `~/.hermes/skills/<project-name>-<role>/SKILL.md` (namespaced by
  project; Hermes skills are global, so this keeps two projects with the
  same role from overwriting each other's skill)

## Step 6b - Do not commit the flow

maf is a tool, not a part of the project. It lists `.maf/` and its links in
`.git/info/exclude`, so `git status` shows no maf file. Do not commit them.
The project needs at least one commit, because each worker worktree starts from a commit.

If `git ls-files .maf` lists files, an older maf version committed them. Run
`maf untrack`, review `git status`, and ask the user to commit the result.

## Step 7 - Report to the user

Report the generated files. Then print one `maf start` command for each worker.
Use the number of workers from Step 3b. A worker role with N workers gets the
names `ROLE_1` to `ROLE_N`. A role with one worker may use the bare role name.
Then give the user these instructions.

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
> This creates (or reuses) a worktree at `.maf/worktrees/<role>-<worker_id>`,
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

## Domain documentation

Do not create `GLOSSARY.md` at install time. The project has no terms yet.
The project manager creates the first draft when the first term resolves.
The architect commits `GLOSSARY.md` on the goal branch. Tell the user this in the report of Step 7.
Do not add a `GLOSSARY-MAP.md` unless the project has more than one bounded context.
ADRs use the decisions folder: `.agent/decisions/` if it exists, else `docs/decisions/`.

## Notes

- One writer per path. The task scope defines the paths. `coord add`/`conflicts`
  warns on overlap; roles marked "never edit" also get a restricted tool grant
  where the harness supports one (Claude Code, opencode).
- Every generated role file requires Simplified Technical English in
  `coord msg`, `coord annotate`, and task titles: one instruction per
  sentence, active voice, named subject, no idioms.
- Take the `ollama` lock before a local model generation:
  `coord with-lock ollama -- <command>`.
- Give each agent its own worktree so file changes never collide:
  `coord worktree <role>` creates `.maf/worktrees/<role>-<worker_id>` (inside the
  project, gitignored) on branch `worker/<role>-<worker_id>`. In that worktree
  run `source .maf/env.sh` first; it points `COORD_DIR` and `TASKRC` at the
  main project, so every worktree shares one .maf/coordination/ dir and one task
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
