#!/bin/sh
# next-task-hermes.sh - on_session_end hook for Hermes Agent.
#
# Fires when a supervised session ends. If unclaimed tasks exist for the
# agent's role, resumes the session in one-shot mode with a task prompt.
#
# Install in ~/.hermes/config.yaml:
#   hooks:
#     on_session_end:
#       - command: "~/.hermes/agent-hooks/next-task.sh"
#         timeout: 30
#
# Required env: COORD_ROLE (set by setup_agent). COORD_DIR and TASKRC optional.

PAYLOAD=$(cat 2>/dev/null)

[ -n "$COORD_ROLE" ] || exit 0
[ "$COORD_ROLE" != "unknown" ] || exit 0

COORD_DIR="${COORD_DIR:-coordination}"
TASKRC="${TASKRC:-${COORD_DIR}/taskrc}"

# Find coord one level above COORD_DIR (the project root).
COORD="$(dirname "$COORD_DIR")/coord"
[ -x "$COORD" ] || exit 0

OUTPUT=$(TASKRC="$TASKRC" COORD_DIR="$COORD_DIR" COORD_ROLE="$COORD_ROLE" \
  ruby "$COORD" next "$COORD_ROLE" 2>/dev/null)
echo "$OUTPUT" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | ruby -rjson -e \
  'puts JSON.parse(STDIN.read)["session_id"].to_s rescue ""' 2>/dev/null)

PROMPT="Unclaimed tasks exist for role ${COORD_ROLE}. Run ./coord inbox, then ./coord next. Claim and complete the next task. When no tasks remain, stop."

# Run detached: let the ending session exit cleanly, then resume in one-shot mode.
HERMES_ACCEPT_HOOKS=1 nohup hermes chat --oneshot --yolo --accept-hooks \
  ${SESSION_ID:+--resume "$SESSION_ID"} \
  -q "$PROMPT" >/dev/null 2>&1 &
