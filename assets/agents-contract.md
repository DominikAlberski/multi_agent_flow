<!-- >>> multi-agent-flow >>> -->
## Multi-agent coordination

This project uses `coord`, a shared task board for several coding agents.
Run `source .maf/env.sh` once. It puts `coord` on `PATH` and points `COORD_DIR` at the shared board.
Use `coord`. Never use raw `task`.
Your role file holds your work loop. This section holds the terms and rules that all roles share.

### Terms

- A role is a project function, for example `backend-developer`. A task belongs to a role.
- A worker is one instance of a role, for example `backend-1`. `COORD_ROLE` and `COORD_WORKER` identify you.
- A goal is one user-visible outcome. A goal has the branch `goal/<short-id>`.
- A task is one part of a goal. A worker does the task on the branch `task/<short-id>`.
- The lead roles are the project manager and the architect. A lead role never claims a task and never commits.
- Use the terms of the project glossary, `GLOSSARY.md` at the repository root.

### Hierarchy

If the project has a project manager, the user talks only to the project manager.
The project manager sends each goal to the architect.
The architect splits the goal into tasks, lands the done tasks, and reports back.
Workers never talk to the user. Workers ask the architect with `coord msg`.

### Commands

```
coord show ID                                # one task: its fields and annotations (the task spec)
coord next [ROLE] [--wait] | --mine          # unclaimed tasks, or your claimed tasks
coord claim ID | start-task ID | done ID     # take a task, check out its branch, finish it
coord annotate ID TEXT                       # add a note to a task
coord escalate [--task ID] TEXT              # a problem you cannot fix: the project manager asks the user
coord msg --from A TO TEXT                   # message one role
coord broadcast --from A [--to workers|leads|all] TEXT
coord inbox [ROLE] [--wait]                  # read your messages
coord goal list | goal show ID               # open goals, or one goal and its tasks
coord who | status | log [N]                 # live workers, tasks by role, recent events
coord with-lock NAME -- CMD                  # run a command under a lock
```

If a dispatcher serves your role, the prompt holds your messages. Do not run `coord inbox` then.

### Rules

1. One writer per path. The task scope lists the paths that you own. Never edit outside the scope.
2. A role with `can_edit: false` cannot commit. The git `pre-commit` hook refuses the commit.
3. Run each local model generation under the `ollama` lock: `coord with-lock ollama -- <command>`.
4. Run each command that needs a shared resource (browser, system tests, one fixed port) under one lock:
   `coord with-lock system-test -- <command>`. Do not invent other lock names.
5. Each worktree has its own test database and server port. Do not share a test database.

### Tests

- Task tests: the unit tests and the tests for the changed behavior. The worker runs them before the report.
- Merge suite: the full suite, with system tests. Only the architect runs it, one time per goal.
- The reviewer does not run tests. The reviewer reads the TESTS line of the report.

### Handoff artifacts

- A shared working file is an artifact. Write it to `$COORD_DIR/artifacts/<goal>/<name>.md`.
  Run `mkdir -p` for the folder first.
- Never write an artifact inside a worktree. Worktrees do not share files.
- A worker commits each durable artifact (an approved spec, an ADR) on the goal branch.

### Domain documentation

- `GLOSSARY.md` holds domain terms only. The file does not exist until the first term resolves.
- Each term has a bold name, one or two sentences, and an optional `_Avoid_` line for rejected words.
- The decisions folder holds the ADRs: `.agent/decisions/` if it exists, else `docs/decisions/`.
  Append. Never rewrite an ADR.
- `.maf/obsidian/` is rebuilt from the code graph. Do not keep permanent notes there.
<!-- <<< multi-agent-flow <<< -->
