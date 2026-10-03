# Flow glossary

This file defines the domain terms of multi_agent_flow. Each term has one
meaning. Code, CLI flags, environment variables, and docs use these terms only.
If a text needs a new term, add the term here first.

The names of the terms in code and in the CLI are in [flow-cli-names.md](flow-cli-names.md).

## Language

**Harness**: An AI coding tool: Claude Code, opencode, Codex, or Hermes.

**Role**: A project function with its prompt. Examples: `architect`, `tester`. _Avoid_: agent

**Worker**: One instance of a role with a stable ID. Example: `tester-1`. A worker owns claims, locks, one worktree, and one branch. A worker has the worktree `.maf/worktrees/<worker>` and the branch `worker/<worker>`. The worker does task work on task branches, not on `worker/<worker>`. _Avoid_: agent

**Agent**: One harness session that runs a role as a worker. An agent ends. Its worker stays.

**Task**: One unit of work on the task board. Taskwarrior stores the task board.

**Goal**: One user-visible outcome. A goal groups tasks. Taskwarrior stores a goal as a task with role `goal`.

**Base branch**: The branch where each goal starts. Default: `base_branch` in `.maf/config.json`, else `origin/HEAD`, else `main`.

**Goal branch**: The branch `goal/<short-id>` of one goal. The goal worktree `.maf/worktrees/goal-<short-id>` holds it. The pull request starts from it.

**Task branch**: The branch `task/<short-id>` of one task. It starts from the goal branch. `coord land` deletes it.

**Land**: Squash a done task branch into its goal branch as one commit. The commit message has the trailers `Task`, `Goal`, `Worker`, and `Tests`.

**Goal sync**: Merge the base branch into a goal branch before the merge suite and the pull request.

**Goal pull request**: The pull request from a goal branch into the base branch. The bot account opens it. The human reviewer approves it or requests changes.

**Bot account**: The GitHub account of the agents, in the `github` section of `.maf/config.json`. It pushes goal branches and opens goal pull requests.

**Human reviewer**: The GitHub user who reviews and merges goal pull requests. `coord review-watch` reads reviews of this user only.

**Short id**: The first 8 characters of a task or goal uuid.

**Slot**: A unique number per worktree. The main worktree is slot 0. A project uses the slot for a test database and a port.

**Worker registry**: The list of prepared workers: role, harness, model, and worktree of each worker.

**Team budget**: The limits for `maf prepare`: the maximum number of workers and the allowed harnesses and models. The project manager does not count.

**Lead**: The project manager or the architect. All other roles are workers for `coord broadcast`. A lead never claims a task.

**Scope**: The file paths that a task may change. Example: `test/queries/**`.

**Message**: A note to a role. Unread messages are in `.maf/coordination/inbox/<role>/`.

**Claim**: A worker takes a task. A claim expires after `COORD_LEASE_TTL` seconds.

**Presence**: The record that a worker runs now: role, mode, pid. A worker is live while its pid runs.

**Commit guard**: The git `pre-commit` hook. It refuses a commit by a role with `can_edit: false`.

**Lock**: A named mutex. A worker holds the lock.

**Message hook**: A user script that runs when a message is delivered to a role: `.maf/coordination/message-hooks/<role>.sh`.

**Harness hook**: A script that a harness runs on its own events (for example Stop, SessionStart): `.maf/coordination/harness-hooks/`.

**Report block**: The typed result at the end of the final reply of a dispatched agent: `<report>{"status":"done","tests":"pass","next":"..."}</report>`. Status `done` is success. Status `blocked` and `needs_review` are no success.

**Completion signal**: A text that a dispatched agent prints when its work is complete. The run is a success.

**Abort signal**: A text that a dispatched agent prints when it gives up. The run is a failure.

**Idle timeout**: The seconds without agent output after which a dispatched run fails. 0 means off.

**Grace window**: The seconds the dispatcher waits for an agent to exit after the completion signal, and for a child process that holds the output pipe.

**Verify command**: A shell command that checks the work mechanically, for example the test suite. `coord done` and the dispatcher success path refuse a task while the command exits non-zero.

**Token usage**: The input and output tokens of the dispatched runs of one worker, added up. Claude Code, Hermes, and Codex report them.

**Copy list**: Host files that `coord worktree` copies into each new or reused worktree, for example `.env`. Only existing files inside the project are copied. A file in the worktree is never overwritten.

**Prefetch**: Live context that the dispatcher adds to a dispatch prompt: the output of `coord next ROLE`, `git log --oneline -10`, and a graph query for the first task, each cut to 2000 characters.

**Flow folder**: The folder `.maf/` in a project. It holds every file that the flow owns. A few files stay outside it, because a tool reads them at a fixed path.

**Harness folder**: The folder where a harness reads role files: `.claude/agents/`, `.opencode/agents/`, or `.codex/prompts/`. It is a relative symlink to `.maf/agents/<harness>/`.

**Old layout**: The file layout of the versions before the flow folder. The scripts, `coordination/`, and `.agent-flow.json` are in the project root.

**Project role**: A role that the project defines in `.maf/roles.yml`. It adds a role to the built-in roles, or replaces one.

**Workflow**: The stage instructions of a project, in words. The architect reads them and creates the tasks stage by stage. The other roles do not see them.

**Orchestrator**: The role that runs the workflow. It is the architect.

**Artifact**: A working file that one worker writes and another worker reads. It lives in the main project, so each worktree sees it.

**Graph age**: The number of commits since the shared knowledge graph was built. The graph is stale when a commit after the build changed a source or markdown file.

**Out-of-scope log**: The list of requests that the project rejects on purpose, each with its reason.

## Notes

- Harness flags keep their own names. Example: `claude --agent ROLE` and
  `opencode --agent ROLE` load a role file. These flags are not part of this glossary.
