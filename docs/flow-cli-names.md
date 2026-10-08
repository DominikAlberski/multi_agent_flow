# Flow names in code and CLI

This file lists the code and CLI name of each term in [flow-glossary.md](flow-glossary.md).

| Term | Name in code and CLI |
|---|---|
| harness | `harness`, `maf start HARNESS` |
| role | `role`, `COORD_ROLE`, `--role`, task field `role` |
| worker | `worker`, `COORD_WORKER` |
| agent | `maf start` |
| task | `Tasks`, `coord add` |
| goal | `coord goal`, task field `goalid`, `--goal` |
| base branch | `base_branch`, `--base` |
| goal branch | `Goals.branch` |
| task branch | `coord start-task` |
| short id | `Goals.short` |
| slot | `COORD_SLOT`, `.maf/coordination/worktree-env.rb` |
| worker registry | `.maf/coordination/workers.json`, `maf prepare`, `maf retire` |
| team budget | `.maf/config.json` key `team`, `maf team set` |
| lead | `coord broadcast --to leads`, `LEADS` |
| scope | task field `scope`, `--scope` |
| message | `Messages`, `coord msg` |
| claim | `coord claim` |
| presence | `.maf/coordination/presence/<worker>.json`, `coord who` |
| commit guard | `assets/git-hooks/pre-commit` |
| lock | `coord lock`, lock field `worker` |
| message hook | `coord hooks` |
| harness hook | `next-task.rb`, `next-task-hermes.sh`, `board-watch.rb`, `session-guard.rb`, `context-watch.rb`, `board-watch-opencode.js` |
| report block | `ReportBlock`, `REPORT_FORMAT` |
| completion signal | `--completion-signal`, `Limits#complete` |
| abort signal | `--abort-signal`, `Limits#abort` |
| idle timeout | `--idle-timeout`, `Limits#idle` |
| grace window | `--grace`, `Limits#grace` |
| verify command | `.maf/config.json` key `verify`, `Verify` |
| token usage | `.maf/coordination/usage/<worker>.json`, `TokenUsage`, `coord status` |
| copy list | `.maf/config.json` key `copy_to_worktree` |
| prefetch | `Prefetch` |
| flow folder | `.maf/`, `MAF_DIR`, `maf migrate` |
| harness folder | `Flow::HARNESS_DIRS`, `Flow::AgentLinks` |
| old layout | `Migrate.old_layout?`, `maf migrate` |
| project role | `.maf/roles.yml`, `Flow::RoleCatalog`, `maf role add` |
| workflow | `.maf/workflow.md`, `Flow::Workflow` |
| orchestrator | `architect` |
| artifact | `.maf/coordination/artifacts/<goal>/<name>.md` |
| graph age | `vault age`, `vault status`, `coord status` |
| out-of-scope log | `docs/out-of-scope.md` |
| coordination contract | `assets/agents-contract.md`, `Flow::CONTRACT` |
| local exclude | `.git/info/exclude`, `LocalExclude`, `maf untrack` |
| worker status | `.maf/coordination/status/<worker>.json`, `WorkerStatus`, `maf worker status` |
| handoff note | `.maf/coordination/sessions/<worker>.handoff.md` |
| context limit | `MAF_CONTEXT_LIMIT`, `.maf/config.json` key `team.context_limit` |
