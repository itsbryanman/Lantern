#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_lantern_context
require_command docker

show_help() {
  cat <<'EOF'
Lantern update helper

Usage:
  ./scripts/update.sh
  ./scripts/update.sh SERVICE
EOF
}

update_stack() {
  local name="$1"
  local env_name="$2"
  local compose_path
  local env_path

  compose_path="$(stack_file "$name")"
  env_path="$(env_file "$env_name")"

  [[ -f "$compose_path" ]] || die "Compose file not found: $compose_path"
  [[ -f "$env_path" ]] || die "Environment file not found: $env_path"

  info "Updating ${name}"
  docker compose -f "$compose_path" --env-file "$env_path" --project-name "$LANTERN_COMPOSE_PROJECT_NAME" pull
  docker compose -f "$compose_path" --env-file "$env_path" --project-name "$LANTERN_COMPOSE_PROJECT_NAME" up -d
}

case "${1:-}" in
  "" )
    update_stack traefik core
    update_stack authentik core
    update_stack homepage core
    update_stack uptime-kuma core

    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      update_stack "$app" "$app"
    done < <(enabled_apps)
    ;;
  --help|-h)
    show_help
    exit 0
    ;;
  traefik|authentik|homepage|uptime-kuma)
    update_stack "$1" core
    ;;
  jellyfin|immich|nextcloud|filebrowser|mealie|paperless)
    update_stack "$1" "$1"
    ;;
  *)
    die "Unknown service: $1"
    ;;
esac

info "Update flow completed"
