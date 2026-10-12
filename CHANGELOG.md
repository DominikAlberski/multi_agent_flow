# Changelog

## [Unreleased]

- New harness `cursor` (the Cursor CLI, `agent`): `maf add cursor:ROLE`, `maf start cursor ROLE`,
  and `dispatcher ROLE --harness cursor`. Role files go to `.cursor/agents/` as Cursor subagents.
  Cursor has no wake-up hook yet, so its agents wait with `coord next --wait`.

## [0.1.0] - 2026-10-08

- First release as a gem: `gem install maf`.
- All code is in the `Maf` module.
- The command moved from `bin/maf` to `exe/maf`. `bin/maf` stays for the links
  that point to it. A later version removes it.
- New commands: `maf version` and `maf guide` (prints the agent setup guide).
