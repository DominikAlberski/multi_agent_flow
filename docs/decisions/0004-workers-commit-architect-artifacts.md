# ADR 0004: A worker commits the artifacts of the architect

Status: accepted. Date: 2026-10-01. Supersedes the commit rule of [ADR 0003](0003-glossary-authorship-split.md).

## Context

ADR 0003 told the architect to commit `GLOSSARY.md`.
The architect has `can_edit: false`. The commit guard refuses its commit (ADR 0001, section 5).
The architect did not bypass the guard. In a test project, the architect gave the commit to a backend developer.

## Decision

- The architect does not commit. We do not widen the `can_edit` grant of the architect.
- The architect owns the content of `GLOSSARY.md` and of each ADR.
- When the architect and the reviewer agree on the content, the architect creates a task.
  The task names the file and holds the agreed text.
- A worker with `can_edit: true` commits the file on the goal branch.

## Consequences

- A glossary change costs one extra task.
- The edit wall of ADR 0001 stays whole. No role has a path exception.
- The reviewer checks the committed diff against the agreed text.
