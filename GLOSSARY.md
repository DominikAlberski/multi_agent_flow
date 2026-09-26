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
| lead | The project manager or the architect. All other roles are workers for `coord broadcast`. | `coord broadcast --to leads` |
| scope | The file paths that a task may change. Example: `test/queries/**`. | task field `scope`, `--scope` |
| message | A note to a role. Unread messages are in `coordination/inbox/<role>/`. | `Messages`, `coord msg` |
| claim | A worker takes a task. A claim expires after `COORD_LEASE_TTL` seconds. | `coord claim` |
| lock | A named mutex. A worker holds the lock. | `coord lock`, lock field `worker` |
| message hook | A user script that runs when a message is delivered to a role: `coordination/message-hooks/<role>.sh`. | `coord hooks` |
| harness hook | A script that a harness runs on its own events (for example Stop, SessionStart): `coordination/harness-hooks/`. | `next-task.rb`, `board-watch.rb` |

## Rules

- Do not use "agent" for a role or a worker.
- A worker has the worktree `.worktrees/<worker>` and the branch `worker/<worker>`.
  The worker does task work on task branches, not on `worker/<worker>`.
- Harness flags keep their own names. Example: `claude --agent ROLE` and
  `opencode --agent ROLE` load a role file. These flags are not part of this glossary.
