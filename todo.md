# TODO

## Ignore the installed flow files in the host project

Problem: the installer adds the flow files to the git history of the host project.
A later flow swaps or updates these files. Each swap then changes the host project history.
The flow files are exchangeable tooling, not project source.

Task: extend `assets/gitignore.append` so the host project ignores the installed flow files.

Candidate paths, as installed in TastingCompanion on 2026-09-30:

- `coord`
- `dispatcher`
- `vault`
- `dashboard`
- `.agent-flow.json`
- `coordination/doc-graph-refresh`
- `coordination/harness-hooks/`
- `coordination/presence/`
- `.claude/agents/` (the flow role files only)
- `.opencode/agents/` and `.opencode/plugins/` (the flow files only)
- the flow block in `AGENTS.md`

Acceptance:

1. After a fresh install, `git status` in the host project shows no flow file.
2. An update or a swap of the flow changes no tracked file in the host project.
3. The uninstaller removes the ignore block.
4. A test covers the install and the uninstall of the ignore block.
5. The docs state how a host project removes the flow files that it already tracks
   (`git rm --cached`).

Open questions:

- `AGENTS.md` and `.claude/agents/` also hold project content. Decide how to
  separate the flow part from the project part.
- Decide if the `pre-commit` hook and the git hooks stay tracked or stay local.
