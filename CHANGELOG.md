# Changelog

## [Unreleased]

- New sandbox for the agents on macOS: `"sandbox": {"mode": "seatbelt"}` in `.maf/config.json`
  or `MAF_SANDBOX=seatbelt`. `maf start` and the dispatcher run the harness in `sandbox-exec`.
  The agent can write only to the project, the board, the temporary folders, and the folders of its harness.
- Each harness is one file in `lib/maf/shared/harnesses/`. To add a harness, add one
  file, one test file, and one row in the Harnesses table of the user manual.
  `test/harnesses/contract_test.rb` checks every harness file.
- The dispatcher has no default harness. Give `--harness NAME` or `--command TEMPLATE`.
  `maf start` gives the harness, so `maf start` does not change.
- A dispatched run gets `OPENCODE_CONFIG` only on the `opencode` harness.
- `maf untrack` untracks only the role links in `.cursor/agents/`, not the whole folder.
- New harness `cursor` (the Cursor CLI, `agent`): `maf add cursor:ROLE`, `maf start cursor ROLE`,
  and `dispatcher ROLE --harness cursor`. Role files go to `.cursor/agents/` as Cursor subagents.
  Cursor has no wake-up hook yet, so its agents wait with `coord next --wait`.

## [0.1.0] - 2026-10-08

- First release as a gem: `gem install maf`.
- All code is in the `Maf` module.
- The command moved from `bin/maf` to `exe/maf`. `bin/maf` stays for the links
  that point to it. A later version removes it.
- New commands: `maf version` and `maf guide` (prints the agent setup guide).
