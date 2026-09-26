# Plan: fixes from the first long flow run

Status: all items done on branch feat/flow-run-fixes. See "Implementation notes". Written 2026-09-26.

## Source

A project manager agent ran the flow in a Rails project for several hours.
About 13 goals ran in parallel. No two workers collided on a claim.
Reviews found a real privacy leak. The architect found a shared test database.
The project manager reported 8 problems. This plan maps each problem to a cause in this repo.
This plan orders the fixes by value and cost.

## Summary

| # | Problem | Cause in this repo | Fix location | Cost |
|---|---------|--------------------|--------------|------|
| 1 | Resources collide between worktrees | `coord-env.sh` sets only `COORD_DIR` and `TASKRC` | `assets/coord` Worktree | S |
| 2 | Full system suite runs 4 times per change | Contract rules 4 and 6, tester and reviewer duties | contract, `roles.yml` | S |
| 3 | Goals are not tracked | Board knows tasks only | `assets/coord` | M |
| 4 | Goal branches stack on other goals | Worker branch lives across goals, branches from main worktree HEAD | `assets/coord`, contract | M |
| 5 | Escalation is slow | No escalation rule | `roles.yml` architect | S |
| 6a | Worktree name repeats the role | `coord worktree` joins ROLE and WORKER | `assets/coord` Worktree | S |
| 6b | No warning for a role without a harness file | `coord worktree` does not check the manifest | `assets/coord` Worktree | S |
| 6c | Role change needs a manual restart | Worktree is bound to one role | docs only, later `maf up` | S |
| 7 | Project manager spec does not match use | `roles.yml` project manager, `docs/decisions/` path | `roles.yml`, contract, SKILL.md | S |
| 8 | Worker broadcasts reach the project manager | `broadcast` sends to every role | `assets/coord` | S |

Recommended order: 1, 6a, 2, 4, 8, 7, 5, 6b, 3, 6c.
Items 1, 6a, 2 and 5 are small and remove the largest cost.
Item 4 needs a design decision before code. See "Open decisions".

## 1. Resource isolation per worktree

Problem:
Workers shared one test database and one server port.
The team found each collision after a failure.
The team added a system-test lock by hand.

Cause:
`Worktree#write_env_file` writes only `COORD_DIR` and `TASKRC`.
A worktree has no unique number that a project can use.

Fix:
1. Give each worktree a stable slot number.
   Store the slot map in `coordination/slots.json` under a coord lock.
   The main worktree is slot 0.
2. Write `COORD_SLOT=<n>` to `coord-env.sh`.
3. Append the output of an optional project hook `coordination/worktree-env.rb` to `coord-env.sh`.
   Call the hook with `COORD_SLOT` and the worktree path.
   Keep only `export NAME=VALUE` lines, so a shell that sources the file runs nothing else.
   The project owns the hook, because each stack names its variables differently.
   A worktree that is gone frees its slot, so a retired worker does not push every later port higher.
4. Ship an example hook for Rails in `assets/`:
   `TEST_ENV_NUMBER=$COORD_SLOT`, `PORT=$((3000 + COORD_SLOT))`, `CAPYBARA_SERVER_PORT=$((4000 + COORD_SLOT))`.
5. Tell the architect to use `coord with-lock system-test -- CMD` for any suite that needs a shared resource.
   Name this lock in the contract, so no agent invents a new lock name.

Tests:
- Two worktrees get different slots.
- A reused worktree keeps its slot.
- The hook output is in `coord-env.sh`.
- A missing hook does not fail `coord worktree`.

## 2. Test tiers

Problem:
Workers, reviewer, architect and tester each ran the full system suite.
The processor was at maximum load for long periods.

Cause:
Contract rule 4 tells every worker to run "the tests".
Contract rule 6 tells the architect to rerun the tests of each done task.
The tester duty says "Run the suite".
No rule says which suite.

Fix: define two tiers in the contract and use the same words in `roles.yml`.
- Task tests: the unit tests and the tests for the changed files.
  The worker runs the task tests before the report.
- Merge suite: the full suite, including system tests.
  The architect runs the merge suite one time per goal, after the merge and before the pull request.
  The architect runs the merge suite under `coord with-lock system-test`.
- The reviewer reads the diff and the worker's test report. The reviewer does not run tests.
- The architect does not rerun task tests. The architect checks the diff and the TESTS line.
- The tester runs only the tests that the tester writes.

Let the project name both commands in one place: `.agent-flow.json` keys `task_tests` and `merge_suite`.
Render the two commands into each role prompt.

## 3. Goals on the board

Problem:
A goal exists only in message text.
Status needs a manual read of the event log.

Fix:
1. Add `coord goal add --title T [--ref R]`. Store the goal as a Taskwarrior task with `role:goal`.
2. Add `--goal ID` to `coord add`. Store it in a new UDA `goal`.
3. Add `coord goal list` and `coord goal show ID`.
   `show` lists the tasks of the goal, the state of each task, and the goal branch.
4. Close a goal with `coord goal done ID`. Refuse if a task of the goal is open.
5. Group `coord board` output by goal.
6. Exclude `role:goal` tasks from `coord next`.

The project manager creates the goal. The architect links each task to the goal.

## 4. One branch per goal from the base branch

Problem:
Two goals were built on top of the analytics goal branch.
One privacy defect in analytics blocked two unrelated goals.

Cause:
`coord worktree` creates `worker/<slug>` one time and reuses the branch for all later work.
`git worktree add -b` starts the branch from the HEAD of the main worktree.
Each new task in the same worktree starts on top of the previous goal.

Fix:
1. Add a `base_branch` key to `.agent-flow.json`. Default: the remote HEAD, else `main`.
2. Create one integration branch per goal: `goal/<id>-<slug>`, from `base_branch`.
   `coord goal add` creates the branch.
3. Add `coord start-task ID`. The command checks out a task branch `task/<id>` from the goal branch in the worker's worktree.
   The command refuses if the worktree has uncommitted changes.
4. The architect merges task branches into the goal branch.
5. Contract rule: a goal branch starts from `base_branch`. A goal branch never starts from another goal branch.
6. If one goal really needs another goal, the architect records the dependency with `depends:` and waits for the merge.

This item depends on item 3.

## 5. Escalation rule

Problem:
Privacy fixes went through two review rounds before the architect reported a design problem.

Fix: add to the architect duties:
- If a review rejects the same kind of problem two times, stop the fix loop.
- Send the project manager two or three options with the cost of each option.
- The project manager asks the user.

Add to the project manager duties: forward an escalation to the user without a new goal.

## 6. Team changes

### 6a. Repeated role in the worktree name

Cause: `Worktree#create` uses `[role, worker].join("-")`.
The call `coord worktree frontend-developer frontend-developer-2` gives `frontend-developer-frontend-developer-2`.

Fix: if WORKER starts with `ROLE-`, use WORKER as the slug.
Add a test for both forms.

### 6b. Role without a harness file

Cause: `maf start` checks `.agent-flow.json`.
`coord worktree` does not check it, and a manual harness start does not check it.

Fix: in `coord worktree`, read `.agent-flow.json`.
If no agent entry has the role, print a warning with the fix command `maf add HARNESS:ROLE`.
Do not abort, because the manifest can be absent in a project without `maf`.

### 6c. Role change needs a restart

Cause: a worktree is bound to one role by its name and its env.

Fix now: document the procedure in USER_MANUAL.md.
Stop the dispatcher. Start a new dispatcher with the new role in a new worktree.
Fix later: `maf up` (see `maf-up-accounts.md`) restarts dispatchers from the manifest.
Do not add a role-switch command now (YAGNI).

## 7. Role definitions

Fix in `templates/roles.yml`, project manager:
- Allow team operations: `maf add`, `maf start`, `coord worktree`, `coord goal`.
  Keep the rule: the project manager does not edit source files.
- Replace "Send one goal at a time" with "Send each goal as one message.
  Run goals in parallel only if the goals touch different paths."
- Keep `can_edit: false`. Team commands do not edit files.

Fix the decisions path:
- Add a `decisions_dir` key to `.agent-flow.json`. Default: `docs/decisions/`.
- Detect `.agent/decisions/` at install time and use it if it exists.
- Render the path into the contract and SKILL.md instead of the fixed text.

## 8. Broadcast audience

Problem:
Worker notices (test database, ports, locks) reached the project manager.
The stop hook forced the project manager to process each notice.

Fix:
1. Add `coord broadcast --to workers|leads|all`. Default: `workers`.
   `leads` is the project manager and the architect.
   `workers` is each role with `can_edit: true` in the manifest.
2. The architect uses `--to all` only for notices that change a goal.
3. Item 1 removes most worker notices, because the environment is correct from the start.

## Open decisions

1. Item 4: should a task get its own branch, or should a worker commit on the goal branch?
   A task branch keeps merges small. A goal branch per worker is simpler.
   Recommendation: task branch from the goal branch.
2. Item 1: should the slot range have a maximum?
   Recommendation: no maximum. The Rails example hook uses the slot as an offset.
3. Item 3: should goals use Taskwarrior, or a separate `goals.json`?
   Recommendation: Taskwarrior with `role:goal`. Board, log and export then work without new storage.

## Implementation notes

- Item 2: the project names its test commands in its own instructions.
  The `task_tests` and `merge_suite` keys in `.agent-flow.json` are not built.
- Item 3: the goal attribute is `goalid`, not `goal`.
  Taskwarrior drops the value `role:goal` when a UDA has the same name.
- Item 3: `coord board` does not group by goal. `coord goal show` gives the per-goal view.
- Item 4: `coord goal add` also creates the goal worktree `.worktrees/goal-<short-id>`.
  The architect merges task branches there and runs the merge suite there.
- Item 7: the decisions folder is text only: `.agent/decisions/` if it exists, else `docs/decisions/`.
  No `decisions_dir` key is built.
