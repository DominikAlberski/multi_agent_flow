# Out-of-scope log

This file records each request that the project rejects on purpose.
Each entry gives the request, the decision date, and the reason.
Read this file before you propose a new feature.
If a reason does not apply any more, remove the entry and open the work.

## How to add an entry

1. Add a level-2 heading with the name of the request.
2. Write the date of the decision: `Decided: YYYY-MM-DD`.
3. Write the source of the request, for example an issue or a review.
4. Write the reason in one to three short sentences.

## Sandbox providers (Docker, Podman, Vercel)

Decided: 2026-10-01.
Source: review of Sandcastle (mattpocock/sandcastle).
multi_agent_flow is CLI + files. Each worker runs in a git worktree on the host.
A sandbox provider adds a container runtime and a second file system.
Run the whole project in a container if you need isolation.

## Session fork

Decided: 2026-10-01.
Source: review of Sandcastle (mattpocock/sandcastle).
A fork copies one harness session into two sessions.
Each harness stores sessions in its own format, so the dispatcher cannot fork a session in a harness-agnostic way.
A fresh session with the handoff note gives most of the value.

## Sandcastle library architecture

Decided: 2026-10-01.
Source: review of Sandcastle (mattpocock/sandcastle).
Sandcastle is a TypeScript library that orchestrates one agent run.
multi_agent_flow coordinates many workers through files and the coord CLI.
The project adopts single mechanisms only: the report block, the completion signal,
the idle timeout, the verify command, token usage, the copy list, and the prefetch.

## Flow schema and `coord flow` command

Decided: 2026-10-01.
Source: design discussion for the workflow fragment.
The workflow is text in `.maf/workflow.md`. The architect prompt carries the behavior.
A schema and a command add a second language and a workflow engine.

## Task dependencies (`coord add --after`)

Decided: 2026-10-01.
Source: design discussion for the workflow fragment.
The architect creates the task of the next stage after the gate passes.
A task that does not exist cannot be claimed, so no dependency field is needed.

## A `maf/coordination` git branch

Decided: 2026-10-01.
Source: design discussion for the workflow fragment.
The coordination state lives in `.maf/coordination/` and is not committed.
A durable artifact is committed on the goal branch by the architect.
