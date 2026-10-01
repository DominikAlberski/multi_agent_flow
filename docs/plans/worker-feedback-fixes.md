# Plan: fixes from the first worker feedback

Source: a 19-item list from workers in a Crystal test project (2026-10-01).
The list mixes maf defects with project problems. This plan keeps only the maf defects.

## Done in the working tree (2026-10-01)

Items 3, 4, 6, 7, 8, 9, 10, 11, 14, and the `coord escalate` feature. Each has a test.
Open: items 13, 18, 5 (see "Fix next").

## Fix now (valid maf defects, small)

Each fix needs a test.

1. **Item 3: add `coord show ID`.**
   Print the description, role, scope, goal, status, worker, and all annotations of one task.
   Workers must not read `task` or the SQLite file. The contract bans raw `task`, so `coord` must give the spec.
   Update the usage text, `assets/agents-contract.md`, and the role prompts that say "read the task spec".
2. **Item 6: log every state change.**
   `coord add`, `coord annotate`, `coord start-task`, `coord goal add`, `coord goal done`, and `coord with-lock`
   append an event. `with-lock` records the lock name, the exit status, and the duration.
   The merge suite runs under `with-lock system-test`, so this also gives the merge-suite event.
3. **Item 8: remove the `TASKRC override` noise.**
   Add a `verbose=` line to `TASKRC_BLOCK` in `assets/coord` and `assets/taskrc.append`.
   The list is the Taskwarrior default without `override`. A test run showed that this removes the footnote.
   `maf update` must add the line to an existing taskrc, like it adds missing UDAs.
4. **Item 9: start a worker branch from the base branch.**
   `Worktree#checkout` calls `git worktree add -b` with no start point. Git then uses the HEAD of the main checkout.
   If that HEAD is a task branch, the new worker starts on foreign commits.
   Pass `Git.base_branch` as the start point for a new `worker/` branch.
5. **Item 10: correct the `COORD_DIR` text.**
   `COORD_DIR` points at `<main project>/.maf/coordination`, not at the main project.
   Fix `assets/agents-contract.md` (lines 116 and 182) and `lib/maf/flow/prompt_text.rb`.
   The graph path `$COORD_DIR/../graphify-out/graph.json` stays correct, because `COORD_DIR` ends in `.maf/coordination`.
6. **Item 7: document the architect notice.**
   `coord done` sends a message to the architect (`report_done`). The contract does not say so.
   Add one sentence to the contract and to the worker prompt. `coord annotate` sends nothing; the report was wrong on that part.
7. **Item 14: ignore `.claude/settings.local.json`.**
   Add the path to `assets/gitignore.append`. Claude Code creates this file per user.
   Do the same for the equivalent local file of other harnesses, if one exists.
8. **Item 11: remove the glossary contradiction.**
   This is the earlier commit-guard finding. The architect has `can_edit: false` but must commit `GLOSSARY.md`.
   The workers already solved it: the architect gave the commit to a worker. Make that the rule.
   Change the architect duties and ADR 0003 (new ADR 0004 that supersedes the commit part).

## Fix next (valid, needs a decision or more design)

## Closed without work

- **Item 13, review tasks.** An empty scope is already ignored by `coord conflicts`.
  The fix is guidance only: the architect omits `--scope` for a review task and names the branch in Inputs.
  The reviewer does not run `start-task` and does not commit. Done in `templates/roles.yml`.
- **Item 18, goal state.** A new goal and a goal with all tasks closed both show `open=0`.
  A label would be wrong for one of them. A finished goal already leaves the list. No change.
- **Item 5, unsupported languages.** maf cannot know which suffixes graphify lacks.
  graphify already lists unclassified files in its own report. No change.

## Not maf defects (no maf work)

| Item | Reason |
| --- | --- |
| 1, 2 | The user decides the PR step during project setup. The `pr-organizer` role was a test role. The flow adds no default PR step. |
| Crystal support (5, part) | The user accepts no coverage. This is a graphify limit. |
| 12 | Code rules and the linter belong to the project. `.maf/config.json` already has a `verify` command. |
| 15 | A mise and shards problem in the project. Optional: one line in `GETTING_STARTED.md`. |
| 16 | A harmless timing race in the board watcher. |
| 17 | A review speed check cannot prove that a reviewer read the diff. Do not build it. |
| 19 | Warnings from the graphify tool. Check `vault.log` once; open an upstream issue if it repeats. |

## New feature: worker escalation to the project manager

Goal: a worker that cannot fix a problem reports it to the user through the project manager.
Today a blocked worker messages the architect. The architect cannot fix an environment problem,
such as a missing tool, a missing remote, a refused commit, or contradicting rules.

Design (smallest version):

1. `coord escalate [--task ID] TEXT...` is the one new command.
   - It sends the message to `project-manager`, with the sender, the task id, and the text.
   - It copies the message to `architect`, so the architect knows why the task stops.
   - It appends an `escalate` event to `events.log`.
   - If `--task` is set, it annotates the task with `ESCALATED: <text>`. The worker keeps the claim.
   - A project manager cannot escalate to itself. The command refuses with a clear error.
   - If no project manager session runs, the existing "no live session" warning appears.
2. Worker rule (`WORKER_LOOP`, contract): use `coord escalate` for a problem outside the task scope
   that the worker cannot fix. Examples: a missing tool, no access, a refused guard, rules that contradict.
   Use `coord msg architect` for a question about the task itself. Then stop. Do not retry.
3. Project manager duty (`templates/roles.yml`):
   - On an escalation, tell the user in plain words: what failed, which task, and the impact.
   - Give two or three options with a recommended one. Wait for the answer.
   - Send the answer to the worker with `coord msg`. Tell the worker to continue or to stop.
4. Dashboard: show an alert for each task with an `ESCALATED` annotation and no later `done`.
   This needs no new storage. The dashboard reads the events and the task annotations.

Not in this version (YAGNI): automatic retry, a separate escalation queue, a severity level.

Acceptance:

- `coord escalate` delivers one message to the project manager and one copy to the architect.
- The event log and the task annotation record the escalation.
- The project manager prompt tells the project manager to ask the user and to answer the worker.
- A test covers the command, the refusal for the project manager, and the dashboard alert.


## Order

1. Items 3, 6, 8, 9, 10, 14 first. They are independent and small.
2. Item 2 (events), then item 11 (ADR).
3. `coord escalate` (it builds on the event log and `coord show`).
4. Items 13, 18, 12 last.

## Acceptance

- Every fix has a test. `ruby scripts/check.rb` and each `test/*_test.rb` pass.
- A fresh `maf add` project shows no `TASKRC override` line, no `settings.local.json` in `git status`,
  and `coord show ID` prints the task spec.
- A new worker branch starts on the base branch, even if the main checkout is on a task branch.
