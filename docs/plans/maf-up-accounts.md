# Plan: one-command team start with accounts

Status: planned, not started. Written 2026-09-24.

## Goal

The user runs one command: `maf up`.
The command works in a terminal and inside a harness.
The command installs the flow if it is missing.
The command creates all worktrees.
The command starts all workers, each on the correct subscription.
The command is idempotent.

## Problem

Users have different subscriptions for different harnesses.
Example setup of the author: 2 opencode subscriptions, 1 local model in opencode,
1 Hermes subscription, 1 Codex subscription, 2 Claude subscriptions.
Today the user starts each agent by hand in a separate terminal.
`maf start` always uses the default login of the harness.
No part of the flow knows about subscriptions or usage limits.

Token optimization comes from three sources:

1. Route each role to a subscription of the correct cost tier.
2. Keep idle workers at zero tokens. The dispatcher already does this.
3. Fail over to the next subscription when one subscription hits its usage limit.

## Current state

- `maf add` and `maf start` work on one agent at a time.
- `dispatcher` starts an agent only when work exists.
- `dispatcher` resumes a session only inside the prompt cache window.
- `dispatcher` does not detect usage limits.

## New domain terms

Add these terms to docs/flow-glossary.md before code uses them.

| Term | Meaning |
|---|---|
| account | One login for one harness. An account has a config directory, models, and a cost tier. |
| team | The list of workers that `maf up` starts. Each entry has a role, a list of accounts, a mode, and a count. |

## Phase 1: Accounts

Store accounts at user level in `~/.config/maf/accounts.yml`.
Subscriptions belong to the user, not to a project.

```yaml
accounts:
  claude-max:   { harness: claude,   tier: premium, env: { CLAUDE_CONFIG_DIR: ~/.claude-max } }
  claude-pro:   { harness: claude,   tier: premium, env: { CLAUDE_CONFIG_DIR: ~/.claude-pro } }
  codex:        { harness: codex,    tier: premium, env: { CODEX_HOME: ~/.codex } }
  hermes:       { harness: hermes,   tier: standard }
  oc-sub-a:     { harness: opencode, tier: standard, model: provider-a/model-x }
  oc-sub-b:     { harness: opencode, tier: standard, model: provider-b/model-y }
  oc-local:     { harness: opencode, tier: local, model: ollama/qwen3-coder, lock: ollama }
```

Tasks:

- Add `maf accounts`. The command lists accounts and checks the login of each account.
- Add `maf start ... --account NAME`.
- Make the launcher and the dispatcher apply the account `env` before they start the harness.

Open research:

- Find how to isolate two opencode logins. Candidates: `XDG_DATA_HOME`, or different providers in one `auth.json`.
- Find the Hermes home directory variable.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are known to work.

## Phase 2: Team

- Add a `tier` field to `roles.yml`.
- Give `architect` and `reviewer` the `premium` tier.
- Give developer roles and `tester` the `standard` or `local` tier.
- Add `maf team`. The command proposes a team: it matches role tiers to account tiers.
- Spread workers across accounts, so that one subscription does not run out first.
- Store the team in `.agent-flow.json` under the key `team`.
- Let the user edit the team by hand or in the menu.
- Default mode: `project-manager` is interactive. All other roles use `--dispatch`.

## Phase 3: `maf up`, `maf down`, `maf status`

- `maf up` installs the flow from `team` if the flow is missing.
- `maf up` creates the worktrees.
- `maf up` opens the tmux session `maf-<project>`.
- `maf up` opens one tmux window per worker.
- Each window runs `maf start HARNESS ROLE --account NAME`.
- If `maf up` runs again, it starts only the missing workers.
- `maf up --detach` is for use inside a harness. The command prints `tmux attach -t maf-<project>`.
- `maf down` stops the tmux session.
- `maf status` shows each worker, its account, and its process state.
- Update `install.md` and `SKILL.md`. The last step is `maf up --detach`.
- Add a menu item "Start team".
- If tmux is missing, print the `maf start` commands instead.

## Phase 4: Usage limit failover

- Add limit detection to each dispatcher harness adapter.
- If a run hits a usage limit, write `coordination/accounts/<account>.cooldown` with the reset time.
- On the next run, use the next account in the worker's account list that has no active cooldown.
- After a switch, start a fresh session with a handoff note.
- Do not resume the old session, because sessions do not move between accounts.
- For interactive agents, `maf status` marks the account as limited and proposes a restart on the next account.

## Phase 5: Usage ledger (later)

- The dispatcher already parses harness JSON events.
- Record tokens per account in a ledger file.
- Add `maf usage`.
- Show usage per account in the dashboard.

## Build order

1. Use the test-first flow for each slice: green baseline, red tests, green code, commit.
2. Build Phase 1 and Phase 3 first. They deliver the one command.
3. Build Phase 2 and Phase 4 next. They deliver the token savings.
4. Keep new classes under 100 lines: `Maf::Accounts`, `Maf::Team`, `Maf::Up`, `Maf::TmuxSession`.
5. Keep methods at 5 lines or fewer.
6. Add only account env handling to `setup_agent.rb`. Put new logic in new classes.

## Open decisions

1. Use tmux as a dependency? Recommended: yes. The alternative is native terminal tabs through AppleScript, macOS only.
2. Store accounts at user level or per project? Recommended: user level.
3. Build failover in the first version, or after `maf up` works?
4. Restart interactive agents on the next account automatically, or only warn?
