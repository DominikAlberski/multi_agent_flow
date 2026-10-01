# ADR 0003: The project manager writes terms, the architect commits them

Status: accepted. Date: 2026-10-01.

## Context

A project needs a domain glossary and ADRs. The project manager talks to the user, so it learns the terms first.
The project manager has `can_edit: false`. The commit guard refuses its commits. We do not widen this grant.

## Decision

- The project manager writes each resolved term to `$COORD_DIR/artifacts/<goal>/glossary-draft.md` at once.
- The architect owns the committed `GLOSSARY.md`. The architect and the reviewer agree on the terms first.
  Then the architect commits them on the goal branch.
- The reviewer checks a glossary diff: one meaning per term, no implementation detail, no duplicate term, no contradiction.
- The architect offers an ADR only if the decision is hard to reverse, surprising without context, and a real trade-off.
- The interview rules and the glossary rules are prompt text. The flow ships no skill and has no skill dependency.

## Consequences

- `GLOSSARY.md` is one file for all goals. Two goals that add terms conflict at merge time.
  The architect serializes these goals, or promotes an agreed term to the base branch at once.
- The goal must exist before the first term resolves, because the draft path holds the goal id.
  The project manager creates the goal at the start of the interview.
