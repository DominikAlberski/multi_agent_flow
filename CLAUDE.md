# multi_agent_flow

## Knowledge graph

`graphify-out/` holds a graphify graph of this repo. Git does not track it (`.git/info/exclude`).

- Before you grep the code, query the graph: `graphify query "<question>" --budget 800`.
  Then read only the lines that the result names (`src=... loc=L...`).
- The git hooks rebuild the code part after each commit and checkout. No LLM runs.
- After a large doc change, refresh the doc part: `graphify-codex extract .`
  (`~/.local/bin/graphify-codex` runs graphify with Codex `gpt-6-luna`).
- If `graphify-out/` is missing, run `graphify update .`.
