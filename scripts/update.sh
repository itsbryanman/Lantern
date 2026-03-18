#!/usr/bin/env bash
# =============================================================================
# Lantern - Update Helper
# =============================================================================
# Usage:
#   ./scripts/update.sh
#   ./scripts/update.sh core
#   ./scripts/update.sh authentik
#   ./scripts/update.sh jellyfin
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

CORE_COMPOSE_FILE="$LANTERN_REPO_ROOT/compose/docker-compose.core.yml"
APPS_COMPOSE_FILE="$LANTERN_REPO_ROOT/compose/docker-compose.apps.yml"

show_help() {
  cat <<'EOF'
Lantern update helper

Usage:
  ./scripts/update.sh
  ./scripts/update.sh all
  ./scripts/update.sh core
  ./scripts/update.sh authentik
  ./scripts/update.sh jellyfin
EOF
}

load_env_file() {
  local env_path="$1"
  local line
  local key
  local value

  [[ -f "$env_path" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    export "${key}=${value}"
  done < "$env_path"
}

prepare_app_environment() {
  local app

  export DATA_ROOT="$LANTERN_DATA_ROOT"
  export TZ="$LANTERN_TIMEZONE"
  export LANTERN_DOMAIN

  for app in jellyfin immich nextcloud filebrowser mealie paperless; do
    load_env_file "${LANTERN_DATA_ROOT}/stacks/${app}.env"
  done
}

run_core_update() {
  local services=("$@")
  local compose_args=(
    docker compose
    -f "$CORE_COMPOSE_FILE"
    --env-file "${LANTERN_DATA_ROOT}/stacks/core.env"
    --project-name lantern
  )

  log "Updating core services"
  "${compose_args[@]}" pull "${services[@]}"
  "${compose_args[@]}" up -d --wait "${services[@]}"
}

run_apps_update() {
  local profiles=("$@")
  local profile_csv
  local compose_args=(
    docker compose
    -f "$APPS_COMPOSE_FILE"
    --project-name lantern
  )

  if [[ ${#profiles[@]} -eq 0 ]]; then
    warn "No app profiles selected for update"
    return 0
  fi

  prepare_app_environment
  profile_csv="$(IFS=','; echo "${profiles[*]}")"
  export COMPOSE_PROFILES="$profile_csv"

  log "Updating app profiles: ${COMPOSE_PROFILES}"
  "${compose_args[@]}" pull
  "${compose_args[@]}" up -d --wait
}

update_enabled_apps() {
  local profiles=()
  local app_name

  while IFS= read -r app_name; do
    [[ -n "$app_name" ]] || continue
    profiles+=("$app_name")
  done < <(enabled_apps)

  run_apps_update "${profiles[@]}"
}

main() {
  load_lantern_context
  require_command docker

  case "${1:-}" in
    ""|all)
      run_core_update
      update_enabled_apps
      ;;
    core)
      run_core_update
      ;;
    traefik|homepage|uptime-kuma)
      run_core_update "$1"
      ;;
    authentik)
      run_core_update authentik-postgres authentik-redis authentik-server authentik-worker
      ;;
    apps)
      update_enabled_apps
      ;;
    jellyfin|immich|nextcloud|filebrowser|mealie|paperless)
      run_apps_update "$1"
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      die "Unknown update target: $1"
      ;;
  esac

  ok "Update flow completed"
}

main "$@"
