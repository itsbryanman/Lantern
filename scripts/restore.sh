#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

show_help() {
  cat <<'EOF'
Lantern restore helper

Usage:
  ./scripts/restore.sh --list
  ./scripts/restore.sh --latest [--target DIR]
  ./scripts/restore.sh --snapshot ID [--target DIR]
EOF
}

MODE=""
SNAPSHOT_ID=""
TARGET_DIR="/tmp/lantern-restore-$(date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      MODE="list"
      shift
      ;;
    --latest)
      MODE="latest"
      shift
      ;;
    --snapshot)
      MODE="snapshot"
      SNAPSHOT_ID="${2:-}"
      shift 2
      ;;
    --target)
      TARGET_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

load_lantern_context
require_command restic

RESTIC_PASSWORD_FILE="${LANTERN_DATA_ROOT}/secrets/restic_password"
[[ -f "$RESTIC_PASSWORD_FILE" ]] || die "Restic password file not found: $RESTIC_PASSWORD_FILE"
export RESTIC_PASSWORD_FILE

case "$MODE" in
  list)
    restic --repo "$LANTERN_BACKUP_PATH" snapshots
    ;;
  latest)
    mkdir -p "$TARGET_DIR"
    restic --repo "$LANTERN_BACKUP_PATH" restore latest --target "$TARGET_DIR"
    info "Latest snapshot restored into $TARGET_DIR"
    ;;
  snapshot)
    [[ -n "$SNAPSHOT_ID" ]] || die "--snapshot requires an ID"
    mkdir -p "$TARGET_DIR"
    restic --repo "$LANTERN_BACKUP_PATH" restore "$SNAPSHOT_ID" --target "$TARGET_DIR"
    info "Snapshot ${SNAPSHOT_ID} restored into $TARGET_DIR"
    ;;
  *)
    show_help
    exit 1
    ;;
esac
