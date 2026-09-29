# ADR 0001: Lead roles, presence, integration on done, and the edit wall

Status: accepted. Date: 2026-09-29.

## Context

A project manager agent ran the flow on the hermes harness.
The agent reported five weak points.

1. No push. A message reaches a role only when a session for that role starts.
   The architect did not read a decision request for hours.
   `coord hooks` showed no message hooks. No dispatcher ran for the architect.
2. No liveness. The agent used `ps aux` to find out if the architect ran.
   A claim has a lease. A session has no record.
3. The edit rule is prose. `templates/hermes.md.erb` ignores `can_edit`.
   On hermes, the project manager, the architect and the reviewer can write files.
4. Semantic merge conflicts show only at the end.
   Two tasks changed different lines of one file. Git reported no conflict.
   The merge suite found the defect after many branches were merged.
5. The contract tells every agent to use `coord next --wait`.
   A lead role has no tasks. The rule for lead roles was only in a skill reference file.

The review found one more cause.
The hermes launcher in `lib/maf/setup_agent.rb` gave every role one prompt:
"Claim a task, do the work, finish it."
The dispatcher prompt in `assets/dispatcher` did the same.
The project manager got this prompt and read it as a user instruction.

## Decision

### 1. Lead roles never claim

- A lead role is `project-manager` or `architect` (`Coord::LEADS`).
- `coord claim` refuses when `COORD_ROLE` is a lead role.
- `coord next --wait` refuses for a lead role.
  The error tells the agent to use `coord inbox --wait`.
- The hermes launcher and the dispatcher build a prompt per role.
  A lead role gets an inbox prompt. A worker role gets the task prompt.
- Contract rule 8 has two parts: one for worker roles, one for lead roles.

### 2. Presence per worker

- Each worker has a file `coordination/presence/<worker>.json`.
  The file holds the role, the worker, the mode, the pid and the last-seen time.
- `maf start` exports `COORD_SESSION_PID` before it runs the harness with `exec`.
  The harness keeps this pid.
- Every `coord` call with `COORD_SESSION_PID` set writes the presence file.
- The dispatcher writes its own presence file with mode `dispatch`.
  `coord` does not write presence when `COORD_DISPATCHED` is set.
- A worker is live if its pid runs (`kill -0`). A worker is gone if its pid does not run.
- `coord who` lists each worker with its state.

We chose a pid check, not a heartbeat interval.
A pid check has no timer to tune and no false "live" state after a crash.
A limit: a session in a container shows as gone, because the host cannot see its pid.

### 3. Missing push is visible

- `coord msg` and `coord broadcast` check each receiver role.
- If the role has no executable message hook and no live worker, `coord` prints a warning on stderr.
  The warning names the two fixes: a dispatcher or a message hook.
- The project manager rules tell the project manager to start the architect with `--dispatch`.

### 4. Integration on done

- Before `coord done`, the worker merges the goal branch into the task branch.
  Then the worker runs the task tests again.
- `coord done` refuses if the task branch has its own commits
  and does not contain the head of the goal branch.
- `coord done --force` skips the check.
- A task branch without its own commits passes. Reviewer tasks do not commit.

We did not choose `git merge-tree` before dispatch.
`git merge-tree` finds text conflicts only. The reported defect had no text conflict.
We did not choose the full suite per task. The full suite is too slow for each task.
The check does not close every gap.
The architect can merge a second task after the worker ran `coord done`.
The goal merge suite still finds that case.

### 5. Edit wall

- `.agent-flow.json` records `can_edit` for each agent.
- Hermes starts a role with `can_edit: false` with a limited toolset list (`-t`).
  The list has no `file`, `code_execution` or `delegation` toolset.
- `maf add` installs a git `pre-commit` hook.
  The hook refuses a commit when `COORD_ROLE` names a role with `can_edit: false`.
- The hook does not replace a `pre-commit` hook that is not ours.
- `git merge` does not run `pre-commit`. The architect can still merge task branches.

The shell stays open for lead roles. A lead role needs `./coord` and `git`.
So a lead role can still write a file with the shell.
The commit hook stops that change from reaching a branch.
An agent can skip the hook with `--no-verify`. The hook stops mistakes, not attacks.

## Consequences

- A lead role that tries to claim gets an error, not a silent role break.
- `coord who` answers "is role X live" without `ps`.
- A message to a role without a push path gives a warning at send time.
- A worker does one more merge and one more test run per task.
- Users with an own `pre-commit` hook do not get the edit wall. `maf add` prints a notice.
