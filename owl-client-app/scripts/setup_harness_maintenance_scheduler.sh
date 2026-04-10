#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE="${1:-show}"
CRON_EXPR="${OWL_MAINTENANCE_SCHEDULE:-0 10 * * 1}"
CYCLE_DIR="${OWL_MAINTENANCE_CYCLE_DIR:-/tmp/owl_harness/maintenance_cycle}"
HISTORY_FILE="${OWL_MAINTENANCE_CYCLE_HISTORY_FILE:-$CYCLE_DIR/maintenance_history.jsonl}"
LOCK_DIR="${OWL_MAINTENANCE_CYCLE_LOCK_DIR:-/tmp/owl_harness/maintenance_cycle.lock}"
AUTO_PR="${OWL_MAINTENANCE_CYCLE_AUTO_PR:-0}"
AUTO_PR_CREATE="${OWL_MAINTENANCE_CYCLE_PR_CREATE:-${OWL_MAINTENANCE_PR_CREATE_PR:-0}}"
AUTO_PR_DRY_RUN="${OWL_MAINTENANCE_CYCLE_PR_DRY_RUN:-${OWL_MAINTENANCE_PR_DRY_RUN:-1}}"
MARKER="# OWL_HARNESS_MAINTENANCE_CYCLE"

COMMAND="$REPO_ROOT/owl-client-app/scripts/run_harness_maintenance_cycle.sh"
CRON_CMD="cd '$REPO_ROOT' && OWL_MAINTENANCE_CYCLE_DIR='$CYCLE_DIR' OWL_MAINTENANCE_CYCLE_HISTORY_FILE='$HISTORY_FILE' OWL_MAINTENANCE_CYCLE_LOCK_DIR='$LOCK_DIR' OWL_MAINTENANCE_CYCLE_STRICT=1 OWL_MAINTENANCE_CYCLE_AUTO_PR='$AUTO_PR' OWL_MAINTENANCE_CYCLE_PR_CREATE='$AUTO_PR_CREATE' OWL_MAINTENANCE_CYCLE_PR_DRY_RUN='$AUTO_PR_DRY_RUN' '$COMMAND' >> '$CYCLE_DIR/maintenance_cycle.log' 2>&1"
LINE="$CRON_EXPR $CRON_CMD $MARKER"

usage() {
  cat <<USAGE
Usage:
  setup_harness_maintenance_scheduler.sh show     # Print suggested crontab entry
  setup_harness_maintenance_scheduler.sh install  # Append one entry to current user crontab
  setup_harness_maintenance_scheduler.sh remove   # Remove OWL maintenance entries from crontab
USAGE
}

ensure_file() {
  mkdir -p "$CYCLE_DIR"
  touch "$CYCLE_DIR/maintenance_cycle.log"
}

show_entry() {
  ensure_file
  echo "Suggested cron entry:"
  echo "$LINE"
  echo
  echo "Install with:"
  echo "  crontab -l | grep -v \"$MARKER\" | { cat; echo \"$LINE\"; } | crontab -"
  echo
  echo "Use env to customize:"
  echo "  OWL_MAINTENANCE_SCHEDULE='0 10 * * 1'"
  echo "  OWL_MAINTENANCE_CYCLE_DIR='/tmp/owl_harness/maintenance_cycle'"
  echo "  OWL_MAINTENANCE_CYCLE_AUTO_PR='0|1'"
  echo "  OWL_MAINTENANCE_CYCLE_PR_CREATE='0|1'"
  echo "  OWL_MAINTENANCE_CYCLE_PR_DRY_RUN='0|1'"
}

install_entry() {
  ensure_file
  if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab is not available on this system."
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$MARKER" || true > "$tmp"
  echo "$LINE" >> "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
  echo "Installed cron entry:"
  echo "$LINE"
}

remove_entry() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "crontab is not available on this system."
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v "$MARKER" > "$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
  echo "Removed OWL maintenance scheduler entries."
}

case "$MODE" in
  show)
    show_entry
    ;;
  install)
    install_entry
    ;;
  remove)
    remove_entry
    ;;
  *)
    usage
    exit 1
    ;;
esac
