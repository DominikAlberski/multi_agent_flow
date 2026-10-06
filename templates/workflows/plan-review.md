Stage 1. Write the plan to $COORD_DIR/artifacts/<goal>/plan.md.
Create one review task for the reviewer. Wait for approval.
If the reviewer requests changes, copy plan.md to plan.r<round>.md first. Then improve plan.md.
Create a new review task. Name both files and the open finding IDs. The reviewer reads only the diff.
Stop after 3 rounds and escalate to the project manager.
Stage 2. Commit the approved plan on the goal branch.
Create one implementation task per part of the plan.
Stage 3. After each implementation task is done, create one review task.
Stage 4. Merge the approved branches. Close the goal.
