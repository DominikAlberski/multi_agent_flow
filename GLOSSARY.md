# Glossary

This file defines the domain terms of multi_agent_flow. Each term has one
meaning. Code, CLI flags, environment variables, and docs use these terms only.
If a text needs a new term, add the term here first.

| Term | Meaning | Name in code and CLI |
|---|---|---|
| harness | An AI coding tool: Claude Code, opencode, Codex, or Hermes. | `harness`, `maf start HARNESS` |
| role | A project function with its prompt. Examples: `architect`, `tester`. | `role`, `COORD_ROLE`, `--role`, task field `role` |
| worker | One instance of a role with a stable ID. Example: `tester-1`. A worker owns claims, locks, one worktree, and one branch. | `worker`, `COORD_WORKER` |
| agent | One harness session that runs a role as a worker. An agent ends. Its worker stays. | `maf start` |
| task | One unit of work on the task board. Taskwarrior stores the task board. | `Tasks`, `coord add` |
| goal | One user-visible outcome. A goal groups tasks. Taskwarrior stores a goal as a task with role `goal`. | `coord goal`, task field `goalid`, `--goal` |
| base branch | The branch where each goal starts. Default: `base_branch` in `.agent-flow.json`, else `origin/HEAD`, else `main`. | `base_branch`, `--base` |
| goal branch | The branch `goal/<short-id>` of one goal. The goal worktree `.worktrees/goal-<short-id>` holds it. The pull request starts from it. | `Goals.branch` |
| task branch | The branch `task/<short-id>` of one task. It starts from the goal branch. | `coord start-task` |
| short id | The first 8 characters of a task or goal uuid. | `Goals.short` |
| slot | A unique number per worktree. The main worktree is slot 0. A project uses the slot for a test database and a port. | `COORD_SLOT`, `coordination/worktree-env.rb` |
| worker registry | The list of prepared workers: role, harness, model, and worktree of each worker. | `coordination/workers.json`, `maf prepare`, `maf retire` |
| team budget | The limits for `maf prepare`: the maximum number of workers and the allowed harnesses and models. The project manager does not count. | `.agent-flow.json` key `team`, `maf team set` |
| lead | The project manager or the architect. All other roles are workers for `coord broadcast`. A lead never claims a task. | `coord broadcast --to leads`, `LEADS` |
| scope | The file paths that a task may change. Example: `test/queries/**`. | task field `scope`, `--scope` |
| message | A note to a role. Unread messages are in `coordination/inbox/<role>/`. | `Messages`, `coord msg` |
| claim | A worker takes a task. A claim expires after `COORD_LEASE_TTL` seconds. | `coord claim` |
| presence | The record that a worker runs now: role, mode, pid. A worker is live while its pid runs. | `coordination/presence/<worker>.json`, `coord who` |
| commit guard | The git `pre-commit` hook. It refuses a commit by a role with `can_edit: false`. | `assets/git-hooks/pre-commit` |
| lock | A named mutex. A worker holds the lock. | `coord lock`, lock field `worker` |
| message hook | A user script that runs when a message is delivered to a role: `coordination/message-hooks/<role>.sh`. | `coord hooks` |
| harness hook | A script that a harness runs on its own events (for example Stop, SessionStart): `coordination/harness-hooks/`. | `next-task.rb`, `board-watch.rb`, `board-watch-opencode.js` |
| report block | The typed result at the end of the final reply of a dispatched agent: `<report>{"status":"done","tests":"pass","next":"..."}</report>`. Status `done` is success. Status `blocked` and `needs_review` are no success. | `ReportBlock`, `REPORT_FORMAT` |
| completion signal | A text that a dispatched agent prints when its work is complete. The run is a success. | `--completion-signal`, `Limits#complete` |
| abort signal | A text that a dispatched agent prints when it gives up. The run is a failure. | `--abort-signal`, `Limits#abort` |
| idle timeout | The seconds without agent output after which a dispatched run fails. 0 means off. | `--idle-timeout`, `Limits#idle` |
| grace window | The seconds the dispatcher waits for an agent to exit after the completion signal, and for a child process that holds the output pipe. | `--grace`, `Limits#grace` |
| verify command | A shell command that checks the work mechanically, for example the test suite. `coord done` and the dispatcher success path refuse a task while the command exits non-zero. | `.agent-flow.json` key `verify`, `Verify` |
| token usage | The input and output tokens of the dispatched runs of one worker, added up. Claude Code, Hermes, and Codex report them. | `coordination/usage/<worker>.json`, `TokenUsage`, `coord status` |
| copy list | Host files that `coord worktree` copies into each new or reused worktree, for example `.env`. Only existing files inside the project are copied. A file in the worktree is never overwritten. | `.agent-flow.json` key `copy_to_worktree` |
| prefetch | Live context that the dispatcher adds to a dispatch prompt: the output of `coord next ROLE` and `git log --oneline -10`, each cut to 2000 characters. | `Prefetch` |
| out-of-scope log | The list of requests that the project rejects on purpose, each with its reason. | `docs/out-of-scope.md` |

## Rules

- Do not use "agent" for a role or a worker.
- A worker has the worktree `.worktrees/<worker>` and the branch `worker/<worker>`.
  The worker does task work on task branches, not on `worker/<worker>`.
- Harness flags keep their own names. Example: `claude --agent ROLE` and
  `opencode --agent ROLE` load a role file. These flags are not part of this glossary.
