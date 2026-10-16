# Plan: effort levels per agent

Source: issue #44 "Add effort levels".
Status: draft, open questions at the end. Date: 2026-10-17.

## Problem

- The effort level (reasoning effort) changes how a model works: depth, speed, and token cost.
- maf sets the model of each agent, but not the effort. Each agent uses the default of the harness or of the user config.
- An architect or a reviewer needs high effort. A tester or a simple developer task can use low effort and spend fewer tokens.

## Goal

- Each agent (harness + role) can have an effort level, as it can have a model.
- maf passes the effort to the harness in an interactive session (`maf start`) and in a dispatched run (dispatcher).
- No effort set: maf passes no flag. The harness default applies, as today.

## What the harnesses support (checked 2026-10-17 on the local CLIs)

| Harness  | Interactive (`launch`)                 | Dispatched (`build_command`)            | Levels |
|----------|----------------------------------------|-----------------------------------------|--------|
| claude   | `--effort L`                           | `--effort L`                            | low, medium, high, xhigh, max |
| codex    | `-c model_reasoning_effort="L"`        | same, on `codex exec`                   | per model: `supported_reasoning_levels` in `~/.codex/models_cache.json` (low ... max, some models also ultra) |
| hermes   | `--reasoning L`                        | `--reasoning L`                         | none, minimal, low, medium, high, xhigh, max, ultra |
| opencode | no flag on the TUI                     | `opencode run --variant L`              | provider-specific (for example minimal, high, max) |
| cursor   | no flag; part of the model: `MODEL[effort=L]` | same                             | depends on the model |
| generic (`--command`) | -                         | new `%{effort}` placeholder             | any |

Result: all five harnesses can take an effort in a dispatched run. Interactive opencode needs another way (see open question 3).

## Decisions

1. The effort is a string in the format of the harness, like the model. maf passes it as it is.
2. maf checks the effort against the list of the harness, if the harness has one (`efforts`). An unknown effort gives a warning in the `maf add` report. It does not stop the command (same as an unknown model).
3. The effort is NOT a 4th field of the spec `HARNESS:ROLE[:MODEL]`. A model ID can contain `:` (Bedrock IDs), and `Options#parse_agent` uses `split(":", 3)`. maf uses flags:
   - `maf add ... --effort ROLE=LEVEL` (same form as `--model ROLE=MODEL`)
   - `maf start HARNESS ROLE --effort LEVEL`, `maf prepare ... --effort LEVEL`
   - `dispatcher ROLE --harness H --effort LEVEL`
4. maf stores the effort in `.maf/config.json` (agent entry, key `effort`) and in `.maf/coordination/workers.json`, next to `model`.
5. Order of precedence: flag of this command > saved effort > nothing. maf has no built-in default (open question 1).

## Steps

### 1. Harness interface (`lib/maf/shared/harness/defaults.rb`)

- `RoleFiles#efforts` - the levels of the harness, or nil (every value counts as known). Optional argument `model` for harnesses with levels per model (codex).
- `RoleFiles#known_effort?(effort, model = nil)`.
- `RoleFiles#effort_hint(effort)` - the command that sets the effort, for a harness that cannot take it at launch (opencode TUI). Default nil.
- `Run#effort_flag(effort)` - default `[]`.
- `Run#launch(role, model, effort = nil)` - new optional argument. Update the 5 harnesses and `SetupAgent::Launcher.launch` / `.sandboxed`.

### 2. Harnesses (`lib/maf/shared/harnesses/*.rb`)

- claude: `EFFORTS = %w[low medium high xhigh max]`; `effort_flag(e) = e ? ["--effort", e] : []`; add to `launch` and `build_command`.
- codex: `efforts(model)` reads `supported_reasoning_levels` from `models_cache.json` (same file as `models`); `effort_flag(e) = e ? ["-c", "model_reasoning_effort=\"#{e}\""] : []`; add to `launch` and `build_command`. `-c` must come before the prompt and before `resume`'s session id.
- hermes: `EFFORTS = %w[none minimal low medium high xhigh max ultra]`; `["--reasoning", e]` in both commands.
- opencode: `["--variant", e]` in `build_command` only. `launch` gets the effort from the agent file or prints `effort_hint` (open question 3).
- cursor: `model_with_effort(model, effort)` returns `"#{model}[effort=#{effort}]"` when both are set. Use it in `launch` and `build_command` instead of the raw model. Check first that a model without brackets support rejects or ignores the suffix (step 7).

### 3. Dispatcher (`assets/dispatcher`)

- `Config` gets `:effort`. Parse `--effort L` next to `--model`. Update the usage text at the top.
- `Generic::PLACEHOLDERS` gets `effort`.
- Log the effort on the run start line next to the model, so the dashboard and the analyst can read it.

### 4. maf start / prepare (`lib/maf/setup_agent/*`, `lib/maf/team.rb`)

- `Args`: `take_effort(flags)` like `take_model`; `Parsed` gets `effort`.
- `Manifest#effort_for(harness, role)`.
- `SetupAgent.run`: `effort = args.effort || manifest.effort_for(...)`; pass to `Launcher.launch` and `Dispatch.launch` (`--effort` for the dispatcher).
- Saved worker entry (`setup_agent.rb:58,64`, `team.rb:101,106`): store and replay `effort`.
- `maf team` table (`team_command.rb:35`): show `model/effort` or a new column.

### 5. maf add (`lib/maf/flow/*`, `lib/maf/cli.rb`, `lib/maf/menu.rb`)

- `Options`: `--effort ROLE=LEVEL` flag, `@efforts`, `effort_for(agent)` (flag > saved).
- `Roster`: keep `saved_effort` like `saved_model`.
- Writer of `.maf/config.json`: add `effort` to the agent entry (only when set).
- `Report`: warn on an unknown effort; list `effort_hint` lines for harnesses that need a manual step.
- `cli.rb` help text and `maf list` output (`cli.rb:135`).
- `Menu`: after the model, ask the effort if the harness has `efforts` (Enter = harness default).

### 6. Docs

- README and USER_MANUAL: the `--effort` flags, the table above, the precedence rule.
- CHANGELOG entry.
- ADR: "Effort is a harness-native string set by flag, not a spec field" (decision 3).

### 7. Tests

- `test/harnesses/*_test.rb`: `launch` and `build_command` with and without effort, for each harness. No flag when effort is nil (the current command must not change).
- codex: `efforts(model)` with a fixture `models_cache.json`.
- `Args`, `Options`, `Manifest`: parse and precedence.
- dispatcher: `--effort` reaches `build_command`; `%{effort}` in a generic template.
- Manual check on real CLIs: one dispatched run per harness with `--effort high`; verify that the CLI accepts the flag and the transcript shows the level. For cursor, try one model with and one model without bracket support.

## Open questions

1. Defaults per role: should `RoleCatalog.builtin` give each role a default effort (for example architect and reviewer `high`, developer `medium`, tester `low`)? Recommendation: not in the first PR. Add it after one real run shows the token effect.
2. A common scale: should maf accept `low|medium|high|max` for every harness and map it (for example `max` -> `ultra` on hermes)? Recommendation: no. Pass the native value, as for the model. Mapping hides real differences between the harnesses.
3. Interactive opencode: the TUI has no `--variant` flag. Options: (a) write the variant into the agent file, if opencode reads it there (verify); (b) print an `effort_hint`, as `model_hint` does for codex and hermes. Recommendation: (b) first, (a) after verification.
4. Claude agent files: should maf also write `effort:` into the frontmatter of `.claude/agents/<role>.md`? It would apply when the user starts `claude --agent ROLE` outside maf. Verify that Claude Code reads the key before you add it.
