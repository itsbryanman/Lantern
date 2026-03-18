#!/usr/bin/env bash
# =============================================================================
# Lantern - Health Check
# =============================================================================
# Usage:
#   ./scripts/health-check.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PROJECT_NAME="lantern"
failures=0

project_has_container() {
  local container_name="$1"

  docker ps -a --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format '{{.Names}}' \
    | grep -qx "$container_name"
}

check_container() {
  local container_name="$1"
  local status
  local health

  if ! project_has_container "$container_name"; then
    warn "Container missing from ${PROJECT_NAME}: ${container_name}"
    failures=$((failures + 1))
    return 0
  fi

  status="$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || true)"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container_name" 2>/dev/null || true)"

  if [[ "$status" != "running" ]]; then
    warn "Container not running: ${container_name} (${status})"
    failures=$((failures + 1))
    return 0
  fi

  if [[ "$health" == "unhealthy" ]]; then
    warn "Container unhealthy: ${container_name}"
    failures=$((failures + 1))
    return 0
  fi

  ok "Container healthy enough: ${container_name} (${health})"
}

check_url() {
  local label="$1"
  local url="$2"

  if curl -fsSk --connect-timeout 5 "$url" >/dev/null 2>&1; then
    ok "Reachable: ${label} (${url})"
    return 0
  fi

  warn "Unreachable: ${label} (${url})"
  failures=$((failures + 1))
}

main() {
  load_lantern_context
  require_command docker

  for container_name in traefik authentik-server homepage uptime-kuma; do
    check_container "$container_name"
  done

  while IFS= read -r app_name; do
    [[ -n "$app_name" ]] || continue
    check_container "$app_name"
  done < <(enabled_apps)

  if command -v curl >/dev/null 2>&1; then
    check_url "Dashboard" "https://${LANTERN_DOMAIN}"
    check_url "Auth" "https://auth.${LANTERN_DOMAIN}"
    check_url "Status" "https://status.${LANTERN_DOMAIN}"

    while IFS= read -r app_name; do
      [[ -n "$app_name" ]] || continue
      check_url "$app_name" "https://$(app_subdomain "$app_name").${LANTERN_DOMAIN}"
    done < <(enabled_apps)
  fi

  if [[ -f "${LANTERN_DATA_ROOT}/secrets/restic_password" ]] && command -v restic >/dev/null 2>&1; then
    export RESTIC_PASSWORD_FILE="${LANTERN_DATA_ROOT}/secrets/restic_password"
    if restic --repo "$LANTERN_BACKUP_PATH" snapshots >/dev/null 2>&1; then
      ok "Backup repository reachable"
    else
      warn "Backup repository check failed"
      failures=$((failures + 1))
    fi
  fi

  if (( failures > 0 )); then
    warn "Health checks completed with ${failures} failure(s)"
    exit 1
  fi

  ok "All health checks passed"
}

main "$@"
