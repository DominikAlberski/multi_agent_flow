# ADR 0008: Effort levels per agent

Status: accepted. Date: 2026-10-17.

## Context

Issue #44 asks for an effort level per role. The effort level (reasoning effort)
changes how deep a model works and how many tokens it uses.
Each harness CLI sets it in a different way, and each harness has different levels.
See the table in USER_MANUAL.md.

## Decision

- The effort is a string in the format of the harness, as the model is. maf passes it as it is.
  maf does not map one common scale to the harnesses: a map would hide real differences
  (for example, only some Codex models have `ultra`).
- The effort is a flag (`--effort ROLE=LEVEL`, `--effort LEVEL`), not a 4th field of
  `HARNESS:ROLE[:MODEL]`. A model ID can contain `:` (Bedrock IDs), so a 4th field
  would break the split of the spec.
- maf saves the effort in `.maf/config.json` and in `workers.json`, next to the model.
  The order: the flag of the command, then the saved effort, then the default of the role, then nothing.
- Without an effort, maf passes no flag. The default of the harness applies.
  The command lines of the current users do not change.
- An unknown level gives a warning, not an error, as an unknown model does.
  A harness can add levels before maf knows them.
- Each role has a default level in `roles.yml`. The level changes the token use and the
  accuracy a lot, so a cheap role (tester) gets `low`, and a judgment role gets `high`.
  maf uses the default only if the harness lists the level for the model: an unknown level
  makes Codex fail every run. A harness without a list gets no default.
- Codex: without a pinned model, maf reads the `model` key of `~/.codex/config.toml` to find the levels.
- opencode: the TUI has no variant flag, so the role file carries `variant:`.
  A dispatched run also passes `--variant`.
- Cursor: the CLI has no effort flag, and it rejects `MODEL[effort=LEVEL]` (checked 2026-10-17).
  The level is a part of the model name: `BASE-LEVEL` or `BASE-LEVEL-fast` (`gpt-5.3-codex-high-fast`).
  maf reads `agent --list-models`, lists each base with its levels, and builds the name from
  the base and the level. maf offers only the names that the list has, so it does not guess.

## Consequences

- A new harness overrides `effort_flag`, and `efforts` if it can list its levels.
- A change of the effort in `maf start --effort` does not change the role file: the role files
  are shared, and a one-time flag must not change the other sessions.
  For opencode in an interactive session, maf prints a hint: `ctrl+t` in the TUI, or `maf add --effort`.
- maf does not write `effort:` into the Claude agent file. maf passes `--effort` on each `claude` command.
