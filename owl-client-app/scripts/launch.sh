#!/bin/bash
# Launch OWL Browser interactively. Kills stale Host processes first.
# Usage: ./scripts/launch.sh [--timeout N]  (default: no timeout)
set +e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source "$SCRIPT_DIR/common.sh"

TIMEOUT="${1:-0}"
if [ "$1" = "--timeout" ]; then
    TIMEOUT="${2:-30}"
fi

# Kill stale Host processes
STALE=$(pgrep -f "OWL Host" 2>/dev/null | wc -l | tr -d ' ')
if [ "$STALE" -gt 0 ]; then
    echo -e "${CYAN}Killing $STALE stale OWL Host process(es)...${NC}"
    pkill -f "OWL Host" 2>/dev/null
    sleep 1
fi

LOG_FILE="/tmp/owl-launch.log"
echo -e "${CYAN}=== Launching OWL Browser ===${NC}"
echo -e "  Log file: ${LOG_FILE}"

if [ "$TIMEOUT" -gt 0 ]; then
    echo -e "  Timeout: ${TIMEOUT}s"
    swift run OWLBrowser 2>&1 | tee "$LOG_FILE" &
    APP_PID=$!
    (sleep "$TIMEOUT" && kill $APP_PID 2>/dev/null) &
    TIMER_PID=$!
    wait $APP_PID 2>/dev/null
    EXIT_CODE=$?
    kill $TIMER_PID 2>/dev/null 2>&1
    wait $TIMER_PID 2>/dev/null 2>&1
else
    swift run OWLBrowser 2>&1 | tee "$LOG_FILE"
    EXIT_CODE=$?
fi

# Check exit status
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}OWL Browser exited normally${NC}"
elif [ $EXIT_CODE -eq 139 ] || [ $EXIT_CODE -eq 134 ]; then
    echo -e "${RED}OWL Browser CRASHED (signal $((EXIT_CODE - 128)))${NC}"
    exit 1
elif [ $EXIT_CODE -eq 143 ]; then
    echo -e "${CYAN}OWL Browser timed out (killed after ${TIMEOUT}s)${NC}"
else
    echo -e "${RED}OWL Browser exited with code $EXIT_CODE${NC}"
    exit $EXIT_CODE
fi
