Stage 1. Write the goal text and its acceptance criteria to $COORD_DIR/artifacts/<goal>/goal.md.
Write the plan to $COORD_DIR/artifacts/<goal>/plan.md.
Stage 2. Create three plan review tasks: one for reviewer, one for skeptic, and one for auditor.
Name goal.md and plan.md in the Inputs of each task.
The gate passes when each of the three reviews ends with `VERDICT: pass`.
If a review reports critical findings, copy plan.md to plan.r1.md first. Then fix plan.md.
Create three new review tasks. Name both plan files and the open finding IDs.
Stop after 2 rounds. Escalate each open critical finding to the project manager.
Put the open warnings and minor findings into the implementation task specs as notes.
Stage 3. Commit the approved plan on the goal branch.
Create one implementation task per part of the plan.
After each implementation task is done, create one review task for the reviewer.
Stage 4. Land the approved tasks. Then run `coord goal sync`.
Create three goal review tasks: one for reviewer, one for skeptic, and one for auditor.
Name goal.md, plan.md, and `git diff <base>...goal/<goal-short-id>` in the Inputs of each task.
The gate passes when each of the three reviews ends with `VERDICT: pass`.
If a review reports critical findings, create fix tasks and land them.
Then create three new review tasks. Name the previous findings and the new commits.
Stop after 3 rounds and escalate to the project manager.
Stage 5. Run the merge suite. Close the goal.
