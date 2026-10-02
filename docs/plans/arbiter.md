# Plan: arbiter — a per-task model selector for the flow

Status: proposed, not built. Written 2026-10-02.

## Source

Hermes routes models per slot (aux, delegation, fallback), not per task.
`delegate_task` has no per-task model override. See the hermes-agent skill.
multi_agent_flow already picks a model per role with a static `model_hint`.
A role hint is fixed. The best model for a task changes with the task.
This plan adds a selector that picks the cheapest model that can do the task.
It works with every harness. It is an addon, not a fork.

## The two jobs

1. Catalog. Monitor the available models, their price, and their capability.
2. Route. Pick the cheapest model that can do the task.

## Verified facts

- OpenRouter `https://openrouter.ai/api/v1/models` returns 464 models, no auth.
  Each model has `pricing`, `context_length`, and `supported_parameters`
  (tools, response_format, and more).
- Hermes `delegate_task` has no per-task model. `delegation.model` is one
  global model. Cron jobs have per-job `model`. A spawned `hermes chat -q`
  and `hermes run` take `--model`.
- multi_agent_flow already logs token usage per worker and carries a
  `model_hint` per role. Both feed the selector.

## Pipeline

Do the deterministic step first.

1. Filter by capability. Use hard facts: context window, tools, vision,
   output format. No tokens, no model.
2. Classify the task. A cheap model reads the task and returns a task type.
3. Rank by cost. Pick the cheapest model in the pool for that task type.
4. Apply. The harness adapter sets the model.

## Harness adapters

The core is pure: task and catalog in, model out. No I/O.
Each harness sets a model differently, so an adapter does the apply step.

| Harness | Set model |
|---|---|
| Hermes | `/model`, `--model`, `delegation.model`, aux slots |
| Claude Code | `--model`, `/model` |
| Codex | `--model`, config |
| opencode | config, env |

In multi_agent_flow, `maf start HARNESS ROLE` and the dispatcher pass `--model`.
The selector replaces the static `model_hint` with a per-task pick.

## Context and cash

Two dimensions only. Both come from the catalog.

- context window = capability filter input
- price = cost rank

multi_agent_flow already stores token usage per worker. Feed the real cost
back into the ranking so the selector improves from actual runs.

## Trigger points

Do not route every turn. Route only at decision points.

- once at session start
- on an explicit switch
- on a delegation or a subagent spawn
- on a new task type

This amortizes the router cost.

## Risks

- Router overhead. The classifier costs latency and a few tokens each time.
  The saving must beat the overhead. That holds when the price spread is large
  and most tasks are simple.
- Cheap classifier misroutes. The selector is only as good as its classifier.
  Fine for a cost target, not for a quality target.
- Catalog drift. New models and price changes make a stale catalog wrong.
  Cache with a refresh interval.
- Capability guessed by the classifier. Fixed by the filter-first pipeline.

## Decisions

Recorded 2026-10-02.

1. Name: `arbiter`.
2. Classifier model: a fixed cheap model. It is predictable.
3. Classifier output: one task type from a fixed set. The type maps to a model
   pool in config. The pool maps to the cheapest model. The classifier does
   not name a model.
4. Apply step: a skill and a script. The script picks. The skill tells the
   agent when to run it and how to apply the result.
5. Catalog source: OpenRouter only.

## Out of scope

- A model gateway. The selector does not proxy requests.
- Rewriting each harness model config. The selector only picks and hands off.
- Per-turn routing. Routing happens only at decision points.

## v1 shape

1. A Ruby script pulls the catalog and caches it.
2. `arbiter pick "task text"` filters by capability, classifies, picks the
   cheapest, and prints the model.
3. In maf, `maf start` asks the selector instead of a fixed hint. The
   dispatcher passes `--model`.
