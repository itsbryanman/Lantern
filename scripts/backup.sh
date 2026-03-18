#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

show_help() {
  cat <<'EOF'
Lantern backup helper

Usage:
  ./scripts/backup.sh
  ./scripts/backup.sh --initial
  ./scripts/backup.sh --status
  ./scripts/backup.sh --verify
EOF
}

MODE="backup"
case "${1:-}" in
  --initial) MODE="initial" ;;
  --status) MODE="status" ;;
  --verify) MODE="verify" ;;
  --help|-h) show_help; exit 0 ;;
  "") ;;
  *) die "Unknown option: ${1}" ;;
esac

load_lantern_context
require_command restic

RESTIC_PASSWORD_FILE="${LANTERN_DATA_ROOT}/secrets/restic_password"
[[ -f "$RESTIC_PASSWORD_FILE" ]] || die "Restic password file not found: $RESTIC_PASSWORD_FILE"

mkdir -p "$LANTERN_BACKUP_PATH"
export RESTIC_PASSWORD_FILE

if [[ ! -f "${LANTERN_BACKUP_PATH}/config" ]]; then
  info "Initializing restic repository at ${LANTERN_BACKUP_PATH}"
  restic init --repo "$LANTERN_BACKUP_PATH" --password-file "$RESTIC_PASSWORD_FILE"
fi

if [[ "$MODE" == "status" ]]; then
  restic --repo "$LANTERN_BACKUP_PATH" snapshots
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then
  info "Running repository verification"
  restic --repo "$LANTERN_BACKUP_PATH" check --read-data-subset=10%
  exit 0
fi

BACKUP_TARGETS=()
for target in \
  "${LANTERN_DATA_ROOT}/data" \
  "${LANTERN_DATA_ROOT}/configs" \
  "${LANTERN_DATA_ROOT}/secrets"
do
  [[ -e "$target" ]] && BACKUP_TARGETS+=("$target")
done

[[ ${#BACKUP_TARGETS[@]} -gt 0 ]] || die "No backup targets found under ${LANTERN_DATA_ROOT}"

info "Backing up ${#BACKUP_TARGETS[@]} path(s)"
restic --repo "$LANTERN_BACKUP_PATH" backup \
  "${BACKUP_TARGETS[@]}" \
  --tag lantern \
  --tag "$MODE" \
  --one-file-system

restic --repo "$LANTERN_BACKUP_PATH" forget --prune \
  --keep-daily "$LANTERN_BACKUP_DAILY" \
  --keep-weekly "$LANTERN_BACKUP_WEEKLY" \
  --keep-monthly "$LANTERN_BACKUP_MONTHLY"

info "Backup completed"
