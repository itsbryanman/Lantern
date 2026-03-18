#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_lantern_context
require_command docker

failures=0

check_container() {
  local name="$1"
  local status
  local health

  status="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    warn "Container missing: $name"
    failures=$((failures + 1))
    return 0
  fi

  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$name" 2>/dev/null || true)"
  if [[ "$status" != "running" ]]; then
    warn "Container not running: $name ($status)"
    failures=$((failures + 1))
    return 0
  fi

  if [[ "$health" == "unhealthy" ]]; then
    warn "Container unhealthy: $name"
    failures=$((failures + 1))
    return 0
  fi

  info "Container healthy enough: $name (${health})"
}

check_url() {
  local label="$1"
  local url="$2"

  if curl -fsSk --connect-timeout 5 "$url" >/dev/null 2>&1; then
    info "Reachable: ${label} (${url})"
    return 0
  fi

  warn "Unreachable: ${label} (${url})"
  failures=$((failures + 1))
}

for container in traefik authentik-server homepage uptime-kuma; do
  check_container "$container"
done

while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  check_container "$app"
done < <(enabled_apps)

if command -v curl >/dev/null 2>&1; then
  check_url "Dashboard" "https://${LANTERN_DOMAIN}"
  check_url "Auth" "https://auth.${LANTERN_DOMAIN}"
  check_url "Status" "https://status.${LANTERN_DOMAIN}"

  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    check_url "$app" "https://$(app_subdomain "$app").${LANTERN_DOMAIN}"
  done < <(enabled_apps)
fi

if [[ -f "${LANTERN_DATA_ROOT}/secrets/restic_password" ]] && command -v restic >/dev/null 2>&1; then
  export RESTIC_PASSWORD_FILE="${LANTERN_DATA_ROOT}/secrets/restic_password"
  if restic --repo "$LANTERN_BACKUP_PATH" snapshots >/dev/null 2>&1; then
    info "Backup repository reachable"
  else
    warn "Backup repository check failed"
    failures=$((failures + 1))
  fi
fi

if (( failures > 0 )); then
  warn "Health checks completed with ${failures} failure(s)"
  exit 1
fi

info "All health checks passed"
