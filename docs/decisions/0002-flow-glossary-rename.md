# ADR 0002: Rename the flow glossary to docs/flow-glossary.md

Status: accepted. Date: 2026-10-01.

## Context

This repository had a `GLOSSARY.md` with the vocabulary of the flow.
The flow now installs a domain glossary into each project.
That glossary is also named `GLOSSARY.md`, at the root of the installed project.
One name had two meanings.

## Decision

- The name `GLOSSARY.md` means one thing: the domain glossary of an installed project.
- This repository keeps its flow vocabulary in `docs/flow-glossary.md`.
- The glossary uses the domain glossary format: a bold term, a short meaning, and an `_Avoid_` line.
- The column "Name in code and CLI" moved to `docs/flow-cli-names.md`. It is implementation detail.
- The old rule "Do not use agent for a role or a worker" is now `_Avoid_: agent` on both terms.

## Consequences

- The repository shows the convention that it installs.
- A link to the old path breaks. Each reference in the repository was updated.
