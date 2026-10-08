# ADR 0006: The work memory is on an orphan branch

Status: accepted. Date: 2026-10-08. Amends ADR 0005.

## Context

`coord done` and `coord lesson` save graphify notes in `graphify-out/memory/`.
The notes are what the team learned. A lost clone must not lose them.
ADR 0005 says that maf commits nothing and that the graph stays local.
A tracked folder on the project branches puts one note into each pull request.

## Decision

- The notes are on the branch `maf/memory`. The branch is an orphan: it shares no history with the project branches.
- `graphify-out/memory/` is a worktree of `maf/memory`. `maf add` and `maf update` make it.
  A new clone takes the branch from origin. Notes of an older install move into the branch.
- The flow commits each note to `maf/memory`. It commits to no other branch of the project.
- `coord goal pr` merges the remote `maf/memory` and pushes it with the goal branch.
  Each note has its own file name, so the merge has no conflicts.
- The derived files (`graph.json`, `cache/`, `reflections/`, `obsidian/`) stay local, as ADR 0005 says.

## Consequences

- The notes never show in a pull request, in a diff of `main`, or in `git log` of `main`.
- The remote has one more branch. Without a `github` section, the user pushes `maf/memory`.
- If git fails during the setup, `graphify-out/memory/` stays a plain folder. The flow works as before.
- Uninstall keeps `graphify-out/` and the branch.
