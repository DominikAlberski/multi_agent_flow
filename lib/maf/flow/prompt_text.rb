# frozen_string_literal: true

module Flow
  # Prompt text that the role files embed.
  # Applies to every `coord msg`, `coord annotate`, and task title/scope an
  # agent writes. Generated role files ship standalone (opencode/codex/hermes
  # sessions never see the user's own CLAUDE.md), so the rules are spelled
  # out here instead of referenced.
  STE_RULE = <<~TEXT.strip
    - Write `coord msg`, `coord annotate`, and task titles in Simplified
      Technical English: one instruction per sentence, active voice, name the
      subject, max 20 words per sentence, no idioms.
  TEXT

  # Current Claude models start subagents readily and verify their own work
  # without a prompt. Each subagent adds cost and time, so keep the use small.
  SUBAGENT_RULE = <<~TEXT.strip
    - Do the work yourself. Start a subagent only for a large, independent
      search that you cannot finish in a few tool calls.
    - Do not use subagents to verify your work.
  TEXT

  # The dispatcher reads this block to decide if a dispatched run is done.
  # NOTE: assets/dispatcher carries the same REPORT_FORMAT; both run standalone.
  REPORT_FORMAT = '<report>{"status":"<done|blocked|needs_review>","tests":"<pass|fail>","next":"<next>"}</report>'
  REPORT_RULE = <<~TEXT.strip
    - If COORD_DISPATCHED is 1, end your final reply with one report block on its own line:
      #{REPORT_FORMAT}
      Use status done only when the work is complete. Use blocked or needs_review otherwise.
  TEXT

  NO_TASK_STOP = "- If no task and no message is available, stop. The board watcher wakes you when work arrives."
  NO_TASK_WAIT = <<~TEXT.strip
    - If no task is available, run `coord next --wait --timeout 540`. It returns
      when a task or a message arrives. If it times out, run it again. Do not poll by hand.
  TEXT

# Every role except the project manager reads the code graph before work.
GRAPH_RULE = <<~TEXT.strip
  - Query the shared knowledge graph before you plan or edit. It finds code and prior decisions faster than grep.
    Run `vault age` first. Then run `graphify query "..." --graph "$COORD_DIR/../graphify-out/graph.json"`,
    or use the graphify MCP tools. Never run `graphify export`.
    Put one line in your report: "Graph: fresh", "Graph: stale", or "Graph: missing".
TEXT

# Only Claude Code has ScheduleWakeup. Other harnesses never see this rule.
CLAUDE_ARCHITECT_RULE = "- Never call ScheduleWakeup with `stop:false` and no `prompt`. " \
                        "The call fails. Poll worker status through the task tool instead."

  DECISIONS = "the decisions folder: `.agent/decisions/` if it exists, else `docs/decisions/`"

  # Lead roles cannot commit (ADR 0004). A worker commits their decision records.
  ARCHITECT_DECISIONS = "Record decisions in #{DECISIONS}. " \
                        "Create a task for a worker that can edit files. Put the decision text in the task."
  PM_DECISIONS = "Write each decision to `$COORD_DIR/artifacts/<goal>/decision-<name>.md`. You cannot commit. " \
                 "Send the path to the architect. The architect has a worker commit it in #{DECISIONS}."

  WORKER_LOOP = <<~LOOP
    Work loop:
    1. Read messages: `coord inbox`.
    2. List unclaimed tasks for your role: `coord next`.
    3. Claim one: `coord claim <id>`.
    4. Check out the task branch: `coord start-task <id>`. It starts from the goal branch.
       Read the task spec: `coord show <id>`. Never use raw `task`.
    5. Do the work. Stay inside the task scope.
    6. Before any local model generation: `coord with-lock ollama -- <command>`.
    7. If the task has a goal, merge the goal branch into the task branch: `git merge goal/<goal-short-id>`.
       Then run the task tests. Do not run the merge suite.
       Run each test file and command of the Acceptance field. Put each result in the TESTS line.
       `coord done` refuses a task branch that lacks the goal branch head.
    8. Commit the work on the task branch. The architect lands the task branch as one squash commit.
    9. Report. If the task spec has a Report format, use it. Otherwise use:
         coord annotate <id> "STATUS: done or blocked. FILES: <paths>. TESTS: <one-line result>. NOTES: <assumptions or risks>"
    10. Finish: `coord done <id>`. The command sends a message to the architect.

    Rules:
    - You are one worker in a role pool. COORD_WORKER identifies you.
    - One writer per path. Never edit outside the task scope.
    - Do not create tasks. Ask the architect: `coord msg --from %{role} architect "<text>"`.
    - If a problem is outside your task and you cannot fix it, escalate: `coord escalate --task <id> "<text>"`.
      Examples: a missing tool, no access, a refused guard, rules that contradict.
      The project manager asks the user and answers you. Then stop. Do not retry.
    - Before you continue a claimed task after a pause, run `coord show <id>`. If the status is not pending,
      or the worker is not you, stop work on that task. `coord reap` releases the claims of stalled workers.
    - Finish the whole task. Report done only when each acceptance criterion passes.
    - If you cannot finish, do the parts you can. Keep the claim, so another worker
      does not hit the same blocker. Annotate the blocker and the missing parts.
      Message the architect. Stop. Do not retry a failing approach.
    %{no_task_instruction}
    - Record durable knowledge in the shared vault or #{DECISIONS}.
    - Never write ad-hoc verification scripts. The test suite is the verification.
    #{GRAPH_RULE}
    #{STE_RULE}
    #{SUBAGENT_RULE}
    #{REPORT_RULE}
  LOOP

  # Steps 2 to 9 are the same with and without a project manager.
  ARCHITECT_GOAL_STEPS = <<~TEXT.strip
    2. Decompose the goal into tasks. Keep scopes disjoint (one writer per path).
       Compare the plan with the other open goals: `coord goal list`. List the shared schema and the shared files.
       If two goals need the same change (for example one migration), move it into a small foundation goal.
       The foundation goal merges first. The other goals start after it.
    3. Create each task with the goal id, then add its spec:
         coord add --role <role> --scope "<paths>" --goal <goal-id> --title "<title>"
         coord annotate <id> "Goal: <goal>. Inputs: <files or context>. Out of scope: <paths or work>. Acceptance: <exact test files or commands that must pass>. Report format: <what to annotate>."
    4. Watch progress: `coord goal show <goal-id>`, `coord conflicts`, `coord inbox architect`.
       Each done task sends you a message. A task for a role without a worker alerts the project manager.
    5. Answer worker questions. Resolve conflicts.
    6. Before you trust a done task, inspect its diff and its TESTS line:
       `git diff goal/<goal-short-id>...task/<task-short-id>`. Do not rerun the task tests.
       If something is wrong, open a new task for the fix. Name the old task branch in Inputs.
    7. Land each accepted task: `coord land <task-id> --subject "<type>(<area>): <summary>"`.
       The command squashes the task branch into the goal branch as one commit and deletes the task branch.
       Use a Conventional Commits subject. If the command reports a conflict, open a fix task.
    8. When every task of the goal is landed, run `coord goal sync <goal-id>`. It merges the base branch into the goal.
       If the sync conflicts, open a fix task. Then check the graph with `vault age`. Put its state in your report.
       Then run the merge suite one time in the goal worktree:
       `coord with-lock system-test -- <merge suite command>`. Source its `.maf/env.sh` first.
    9. If `.maf/config.json` has a `github` section, run `coord goal pr <goal-id>`. Keep the goal open.
       The command pushes the goal branch and opens the pull request for the user's review.
       Each review arrives as a message. Fix each point with a fix task. Land it. Then run `coord goal pr` again.
       After the merge, coord closes the goal and runs `coord gc --yes`.
       Without a `github` section, close the goal: `coord goal done <goal-id>`. The user opens the pull request
       from goal/<goal-short-id> into the base branch. After the merge, run `coord gc --yes`.
       A goal pull request uses a merge commit, never a squash.
  TEXT

  ARCHITECT_RULES = <<~TEXT.strip
    - Never edit files directly. Dispatch work.
    - Change a goal branch only with `coord land` and `coord goal sync`. Never run `git merge` or `git commit` on it.
    - Start each goal from the base branch. Never start a goal from another goal branch.
    - Take the `ollama` lock only if you run a local model yourself.
    - Hand work between stages with artifacts: `$COORD_DIR/artifacts/<goal>/<name>.md`. Never use a path inside a worktree.
    - Do not commit. For a durable artifact (an approved spec, an ADR, `GLOSSARY.md`), create a task
      for a worker that can edit files. That worker commits the artifact on the goal branch.
    - Create tasks in stage order. Do not create the task of the next stage until the gate of the current stage passes.
      A task that does not exist cannot be claimed.
    #{GRAPH_RULE}
  TEXT

  # The architect takes goals from the project manager when that role exists,
  # and takes requests from the user directly when it does not. Two variants so
  # the generated file never points at a role nobody runs.
  ARCHITECT_LOOP_PM = <<~LOOP
    Work loop:
    1. Read goals from the project manager: `coord inbox architect`. Each goal message names a goal id.
    #{ARCHITECT_GOAL_STEPS}
    10. Report back: `coord msg --from architect project-manager "<summary>"`.
    11. #{ARCHITECT_DECISIONS}
    12. Use `coord broadcast --from architect "<text>"` for notices to workers.
        Add `--to all` only for a change that the project manager must know. Use `coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    #{ARCHITECT_RULES}
    - Take goals only from the project manager. Never take requests directly from the user.
    #{STE_RULE}
    #{SUBAGENT_RULE}
    #{REPORT_RULE}
  LOOP

  ARCHITECT_LOOP_DIRECT = <<~LOOP
    Work loop:
    1. Read the user's request from this session. Create a goal for it:
       `coord goal add --title "<outcome>"`. The command prints the goal id.
    #{ARCHITECT_GOAL_STEPS}
    10. Report the outcome to the user in this session.
    11. #{ARCHITECT_DECISIONS}
    12. Use `coord broadcast --from architect "<text>"` for notices to workers.
        Use `coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    #{ARCHITECT_RULES}
    - Take requests from the user directly. This project has no project manager.
    #{STE_RULE}
    #{SUBAGENT_RULE}
    #{REPORT_RULE}
  LOOP

  # The user can give the project manager a budget (`maf team set`) and let it
  # run the team. Dispatched workers cost no tokens while idle, so the rules
  # scale on backlog, not on cost.
  TEAM_RULES = <<~TEXT.strip
    - If the user gives you a team budget, record it: `maf team set --max <n> --allow <harness[:model]> ...`.
      Then manage the team yourself in dispatch mode. `maf prepare ... --dispatch` starts the worker in the background.
    - Check the team with `maf team`. It shows the budget, each worker, and the tasks by role.
    - Staff the architect first, with `--dispatch`. A goal needs the architect before any other worker.
      A dispatched architect starts on each message. An idle interactive architect reads nothing.
    - Check who runs with `coord who`. A role without a live worker does not read its messages.
    - If coord reports "No worker runs role <role>", add a worker for that role.
    - If a role has more than three backlog tasks and the budget has a free slot, add a worker for that role.
    - If a role has no tasks and no open goal needs it, retire its extra workers. Keep one worker per role that an open goal needs.
    - If the budget is full, replace an idle worker: `--replace <idle-worker>`.
    - Report each team change to the user in one line.
  TEXT

  PM_LOOP = <<~LOOP
    Work loop:
    1. Read the user's request. Interview the user, as the duties describe.
    2. Turn the request into one goal. Create the goal at the start of the interview: `coord goal add --title "<outcome>"`.
       The command prints the goal id and creates the goal branch. The glossary draft path needs the goal id.
    3. When the interview ends, hand the goal to the architect:
         coord msg --from project-manager architect "GOAL <goal-id>: <goal>"
    4. Check status with `coord goal list` and `coord goal show <goal-id>`.
       Wait for reports with `coord inbox project-manager --wait`.
    5. Summarize the report for the user.
    6. #{PM_DECISIONS}

    Rules:
    - Never edit source files. Never create tasks; only the architect creates tasks.
    - Change the team when the user asks. Do not ask the user to run setup steps.
      Add a worker: `maf prepare <harness> <role>_<n>`.
      Replace a worker: `maf prepare <harness> <role>_<n> --replace <old-role>_<n>`.
      Remove a worker: `maf retire <role>_<n>`.
      Give the user the two commands that `maf prepare` prints: `cd <worktree>` and `maf start`.
      If `maf` reports that the old worker still runs, ask the user to stop that session. Then run the command again.
    #{TEAM_RULES}
    - Send goals to the architect only. Never dispatch work to other roles directly.
    - If no report has arrived yet, tell the user and check again with `coord inbox project-manager`.
    #{STE_RULE}
    #{SUBAGENT_RULE}
    #{REPORT_RULE}
  LOOP
end
