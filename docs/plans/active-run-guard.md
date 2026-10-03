# Plan: protect a claimed task during an active run

Source: proposal 6 of the Pavlina 2026 two-goal run (2026-10-02 to 2026-10-03).
Status: ready to implement. Date: 2026-10-03.

## Problem

- The architect moved a claimed review task while reviewer-2 worked on it.
- The work of reviewer-2 on task `ee07cd07` was lost. The single-writer rule broke.
- `coord unclaim ID` has no owner check. Any role can release the claim of any worker.
- `coord claim ID --force` takes any claim. Lead roles cannot claim, but worker roles can.

## Goal

- coord refuses to release or take a claim while the holder of the claim is active.
- The holder can always release its own claim.
- Only the operator (the user) can override the guard.

## Decisions

Record these decisions in ADR 0005 (see step 6).

1. A dispatcher worker is active while its dispatcher runs an agent.
   The presence file of the dispatcher records the run.
2. An interactive session is active while its process is alive and it made a coord call in the reap limit.
   The reap limit is `team.reap_minutes` in `.maf/config.json`, else 90 minutes.
   A stalled session is not active, so `coord reap` can still release its claims.
3. The operator is a caller without `COORD_ROLE`. An agent session always has `COORD_ROLE`.
   During an active run, `--force` works only for the operator.
4. `coord reap` does not change. It already skips a live dispatcher.
5. Raw `task modify` bypasses the guard. The contract already forbids raw `task`. Do not try to enforce it.

Open question for the user: should an interactive session count as active (decision 2)?
If the user says no, drop the session rule in step 2. Keep the dispatcher rule.

## Rules for the implementer

- Follow the code rules of the repository: methods of 5 lines or less, classes of 100 lines or less.
- Match the style of `assets/coord` and `assets/dispatcher`. Both scripts run standalone and share no load path.
- Write comments, commit messages, and docs in ASD-STE100 Simplified Technical English.
- Make each commit as maf-bot:
  `git -c user.name=maf-bot -c user.email=337282247+maf-bot@users.noreply.github.com commit ...`
- Run every test file and `ruby scripts/check.rb` before each commit.

## Steps

### 1. Dispatcher: record the active run

File: `assets/dispatcher`.

- `Presence.record(config)` gets two more keys: `"running"` (true or false) and `"run_started"` (ISO 8601 UTC or nil).
- `Presence.write(config, running: false)` takes the new keyword. `Main#cycle` keeps the call without the keyword.
- `Runner#spawn(cmd)` writes the presence with `running: true` before `Spawn.run`.
- `Runner#spawn(cmd)` writes the presence with `running: false` in an `ensure` block after `Spawn.run`.
- A dead dispatcher leaves `"running": true`. coord checks that the pid is alive, so the stale value does no harm.

Tests in `test/dispatcher_test.rb`:

- A run writes `"running": true` before the agent starts. Use a `--command` harness that copies the presence file.
- After the run, the presence file has `"running": false`.

### 2. coord: find out if a holder is active

File: `assets/coord`.

- Add a class `RunGuard` near `Reaper`. It reads `presence/<worker>.json`.
- `RunGuard#active?(worker)` returns true in two cases:
  - The entry has mode `dispatch`, `"running": true`, and `Presence.live_entry?(entry)` is true.
  - The entry has mode `session`, `Presence.live_entry?(entry)` is true, and `seen_at` is newer than the reap limit.
- `RunGuard#describe(worker)` returns a short text for the refusal.
  Example: `dispatcher pid 4711, running for 12 min` or `session pid 4711, seen 3 min ago`.
- Read the reap limit with `Manifest#reap_minutes`. Do not add a second setting.
- Move the presence file read of `Reaper#entry` into one shared helper. Both classes use it. Do not copy the code.

Tests in `test/coord_test.rb`, class `TaskwarriorTest`:

- A dispatcher entry with `"running": true` and the pid of the test process is active.
- A dispatcher entry with `"running": false` is not active.
- A session entry with an old `seen_at` is not active.

### 3. coord: guard `unclaim` and `claim --force`

File: `assets/coord`.

- `cmd_unclaim`: parse `--force`. Find the task. If the holder is not `@worker` and `RunGuard#active?(holder)` is true, refuse.
- `cmd_claim`: if `--force` is set, the holder is another worker, and the holder is active, refuse.
- `--force` overrides both guards only when `COORD_ROLE` is not set. Read the raw environment value, not `@role`.
  `@role` falls back to "unknown". Check `@env["COORD_ROLE"].to_s.empty?`.
- Refusal text, one constant:
  `coord: task %<id>s is in an active run of %<worker>s (%<detail>s). Wait for the run to end. Only the user can override: coord unclaim %<id>s --force.`
- Keep the old `--force` behavior when the holder is not active. A claim with an expired lease stays claimable.
- Add `--force` to the usage text of `coord unclaim`.

Tests in `test/coord_test.rb`:

- `unclaim` of the task of an active dispatcher worker is refused for another worker.
- `unclaim` by the holder itself passes.
- `unclaim` passes after the run ends (`"running": false`).
- `claim --force` of the task of an active worker is refused.
- `unclaim --force` with `COORD_ROLE` set is refused during an active run.
- `unclaim --force` without `COORD_ROLE` passes during an active run.

### 4. Show the active run

Files: `assets/coord`, `assets/dashboard`.

- `coord who`: add `running=<minutes>m` to the line of a dispatcher entry with `"running": true`.
- Dashboard: in `task_summary`, add `in_run`: the claimed tasks whose worker has a running dispatcher entry.
  Show a small `running` label on these tasks. Do not add an alert.

Tests:

- `test/coord_test.rb`: `coord who` prints `running=` for a running dispatcher.
- `test/dashboard_test.rb`: `task_summary` lists a task of a running worker in `in_run`.

### 5. Prompts and docs

Files: `lib/maf/flow/prompt_text.rb`, `assets/agents-contract.md`, `USER_MANUAL.md`, `docs/flow-glossary.md`.

- `ARCHITECT_RULES`: add "Never move a claimed task. If a task must move, message its worker or escalate to the user."
- Contract, section "Rules": add the same rule. Add that `coord unclaim` refuses the task of an active worker.
- Manual, command table: update the rows of `coord claim` and `coord unclaim`. Name the operator override.
- Glossary: add **Active run**: the time while a dispatcher runs an agent, or while a live session makes coord calls.
- Glossary: add **Operator**: the user at a terminal without `COORD_ROLE`.

Test in `test/roles_workflow_test.rb`: the architect role file holds "Never move a claimed task".

### 6. ADR 0005

File: `docs/decisions/0005-active-run-guard.md`.

- Use the format of `docs/decisions/0004-workers-commit-architect-artifacts.md`.
- Title: "coord protects a claimed task during an active run".
- Context: the lost review of task `ee07cd07`, and the missing owner check of `coord unclaim`.
- Decision: decisions 1 to 4 of this plan.
- Consequences: the operator needs `--force` without `COORD_ROLE`. A stuck session stays protected for up to the reap limit.

### 7. Install in TastingCompanion

- Do this step only if the user asks. A separate session works on TastingCompanion.
- In `~/Projects/TastingCompanion`, run `maf update`. Commit on `AI_development`. Push `AI_development`.

## Acceptance

- Every test file in `test/` passes. `ruby scripts/check.rb` prints `check: OK`.
- Each test of steps 1 to 5 exists and fails without its code change.
- A manual check passes:
  1. Start a dispatcher with `--command "sleep 60"` for `reviewer`. Let it claim a task.
  2. As `COORD_ROLE=architect`, run `coord unclaim <id>`. The command refuses.
  3. Without `COORD_ROLE`, run `coord unclaim <id> --force`. The command passes.

## Out of scope

- A lock on raw `task` commands.
- A change of `coord reap`.
- A change of the lease TTL.
