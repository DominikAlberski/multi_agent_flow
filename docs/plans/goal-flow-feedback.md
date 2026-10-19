# Plan: fixes from the goal 7ba28dd2 run in TastingCompanion

Status: items 1 to 4 and 6 done on branch fix/goal-flow-feedback. Item 5 was already in coord. Written 2026-10-19.

## Source

The project manager of TastingCompanion kept notes during goal 7ba28dd2
(`.maf/coordination/artifacts/7ba28dd2-.../maf-workflow-notes.md`).
All five tasks landed and the merge suite passed.
The goal still could not open its pull request without two manual git steps by the user.
The user rule is: only agents run coord and git on flow branches.
This plan maps each maf problem in the notes to a cause in this repo.

## Summary

| # | Problem | Cause in this repo | Fix location | Cost |
|---|---------|--------------------|--------------|------|
| 1 | Goal sync conflicts again after a merge-fix task lands | `Land#squash` drops the base parent | `assets/coord` Land | M |
| 2 | Base branch is missing on origin | GitHub deletes the base branch after the release PR | `assets/coord` goal add, goal pr, GitHub | S |
| 3 | `coord worktree --help` makes branch `worker/--help` | `Args#require_arg` takes any word | `assets/coord` Args | S |
| 4 | A ready plan waits 6 days unseen | `coord goal show` shows only open tasks | `assets/coord` goal show | S |
| 5 | A message goes to a role with no live worker | Already there: `coord msg` warns (`NO_PUSH`) | none | - |
| 6 | `maf update` makes worktrees dirty, `start-task` blocks | The project has an old install that git tracks | `lib/maf` update, `assets/coord` start-task | S |
| 7 | Idle interactive session does not read its inbox | No wake for an idle session | open decision | M |
| 8 | Parallel goals conflict on the plan link in `docs/README.md` | Project convention | project only | S |
| 9 | Classifier refuses `coord goal done` and `coord gc` | Harness permission classifier | project only | S |

Order: 3, 1, 2, 4, 6. Items 5 and 7 to 9 are not code in this branch.

## 1. Land keeps the base parent

Problem:
The goal branch lacked the head of the base branch, and the sync conflicted.
The architect opened a fix task. The worker merged the base branch into the task branch and solved the conflict.
`coord land` squashed the task branch. The squash commit has one parent.
Git still sees the base branch as unmerged. `coord goal sync` merges it again and gets the same conflict.
The user made the merge commit by hand (goal c0b8e1dd and goal 7ba28dd2).

Cause:
`Land#squash` always runs `git merge --squash` and commits with one parent.

Fix:
1. Before the squash, find the base commit that the task branch holds: `git merge-base <base ref> <task branch>`.
2. If the goal branch does not hold that commit, the land commit gets it as a second parent.
   Make the commit with `git commit-tree <tree> -p <goal head> -p <base commit>`, then move the goal branch to it.
3. A task without a base merge lands as before, with one parent.

Result: `coord goal sync` reports that the goal already holds the base head. The goal pull request has no conflict.

Tests: a fix task that merges the base branch lands with two parents, and `coord goal sync` is then a no-op.

## 2. Base branch missing on origin

Problem:
GitHub deletes `AI_development` after the release pull request into `main`.
`coord goal pr` pushes the goal branch, but the pull request has no base on origin.
The user pushed the base branch by hand two times.

Fix:
1. `coord goal pr` checks the base branch on origin with `git ls-remote`.
   If origin lacks it and the local branch exists, coord pushes the local branch and prints one line.
2. `coord goal add` warns when origin exists but lacks the base branch.
3. Docs: in the GitHub setup, tell the user to turn off "Automatically delete head branches"
   or to protect the base branch.

## 3. Option-like names

Problem: `coord worktree --help` made the worktree and the branch `worker/--help`.

Fix: `Args#require_arg` refuses a value that starts with `-` and prints the usage.
`coord worktree` refuses a WORKER that starts with `-`.

## 4. Plan ready, no tasks

Problem:
architect-bot wrote `plan.md` and waited for approval. It created no tasks.
The worker stopped. Nobody saw the plan for 6 days.

Fix: `coord goal show` prints a line when the goal has a plan artifact
(`$COORD_DIR/artifacts/<goal uuid>/plan.md`) and no task of any status:
`plan ready, no tasks: <path>. The plan waits for approval.`

## 5. Message to a role with no live worker

No change. `CLI#push` already warns when the role has no live session and no message hook (`NO_PUSH`).
The TastingCompanion copy of coord has this warning too.
In the 15:31 case the session was live but idle. That is item 7.

## 6. Tracked flow files

Problem:
`maf update` rewrote `.maf/bin/*`, `.maf/agents/*` and `.codex/hooks.json`.
TastingCompanion tracks these files, so the main checkout and four worktrees became dirty.
`coord start-task` refuses a dirty worktree.

Cause: ADR 0005 keeps the flow out of the project git, and `maf untrack` moves an old install.
TastingCompanion has an old install. Nothing tells the user to run `maf untrack`.

Fix:
1. `maf update` warns when git tracks a file of the flow, and names `maf untrack --check` (`Untrack.warn_tracked`).
2. The refusal of `coord start-task` lists the dirty paths. If all of them are flow files, it names `maf untrack`.

Project step (TastingCompanion): run `maf untrack --check`, then `maf untrack`, then commit.

## 7. Idle interactive session (open decision)

backend-developer-1 was live but did not read its inbox for 40 minutes.
`coord msg` pushes to the session, but an idle interactive harness does not start a new turn.
Options: a hook that shows mail at the next prompt (already there), a desktop notification to the user,
or a fallback to a dispatch worker after N minutes. Needs a decision by the user.

## 8 and 9. Project-only items

- `docs/README.md` plan links: TastingCompanion can mark the file `merge=union` in `.gitattributes`,
  or keep one index file for each goal.
- The harness permission classifier refused `coord goal done` and `coord gc`.
  The architect closed the goal later when the user told it to. Add the commands to the project allowlist.
