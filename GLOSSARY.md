# Glossary

This file defines the domain terms of multi_agent_flow. Each term has one
meaning. Code, CLI flags, environment variables, and docs use these terms only.
If a text needs a new term, add the term here first.

| Term | Meaning | Name in code and CLI |
|---|---|---|
| harness | An AI coding tool: Claude Code, opencode, Codex, or Hermes. | `harness`, `setup_agent HARNESS` |
| role | A project function with its prompt. Examples: `architect`, `tester`. | `role`, `COORD_ROLE`, `--role`, task field `role` |
| worker | One instance of a role with a stable ID. Example: `tester-1`. A worker owns claims, locks, one worktree, and one branch. | `worker`, `COORD_WORKER` |
| agent | One harness session that runs a role as a worker. An agent ends. Its worker stays. | `setup_agent` |
| task | One unit of work on the task board. Taskwarrior stores the task board. | `Tasks`, `coord add` |
| scope | The file paths that a task may change. Example: `test/queries/**`. | task field `scope`, `--scope` |
| message | A note to a role. Unread messages are in `coordination/inbox/<role>/`. | `Messages`, `coord msg` |
| claim | A worker takes a task. A claim expires after `COORD_LEASE_TTL` seconds. | `coord claim` |
| lock | A named mutex. A worker holds the lock. | `coord lock`, lock field `worker` |
| message hook | A user script that runs when a message is delivered to a role: `coordination/message-hooks/<role>.sh`. | `coord hooks` |
| harness hook | A script that a harness runs on its own events (for example Stop, SessionStart): `coordination/harness-hooks/`. | `next-task.rb`, `board-watch.rb` |

## Rules

- Do not use "agent" for a role or a worker.
- A worker has the worktree `.worktrees/<worker>` and the branch `worker/<worker>`.
- Harness flags keep their own names. Example: `claude --agent ROLE` and
  `opencode --agent ROLE` load a role file. These flags are not part of this glossary.
