# ADR 0005: The flow stays out of the project's git

Status: accepted. Date: 2026-10-05.

## Context

maf committed `.maf/`, the harness links, and its blocks in `AGENTS.md`, `.gitignore`,
`.claude/settings.json`, `.mcp.json`, and `opencode.json`.
The flow is a tool that writes the project. It is not a part of the project.
A user who removes maf must keep what the agents made, and must not keep the tool.

## Decision

- maf commits nothing and edits no file that the project tracks.
- `.git/info/exclude` lists `.maf/` and each link and plugin that maf creates. The file is local to the clone.
- The coordination contract is at the end of each role prompt, not in `AGENTS.md`.
- Claude Code gets the hooks from `.maf/claude/settings.json` (`--settings`) and the
  graphify MCP server from `.maf/mcp/claude.json` (`--mcp-config`). opencode gets the
  server from `.maf/mcp/opencode.json` (`OPENCODE_CONFIG`).
- The project keeps the code, the decisions, and `GLOSSARY.md`. The knowledge graph stays local:
  it is generated and large.
- `maf untrack` moves an older install out of git. The user commits the result.

## Consequences

- A new clone has no flow. The user runs `maf add` in that clone.
- `coord worktree` and `maf start` copy the flow files into each worktree, because a worktree checks out only committed files.
- A session that maf does not start never loads the contract, so it spends no tokens on it.
