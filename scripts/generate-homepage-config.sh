#!/usr/bin/env bash
# =============================================================================
# Lantern - Homepage Config Generator
# =============================================================================
# Usage:
#   ./scripts/generate-homepage-config.sh
#   ./scripts/generate-homepage-config.sh /path/to/lantern.yaml /srv/lantern
#   ./scripts/generate-homepage-config.sh --force /path/to/lantern.yaml /srv/lantern
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FORCE=false
OUTPUT_ROOT=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE=true
        shift
        ;;
      *)
        if [[ -f "$1" ]]; then
          LANTERN_CONFIG_FILE="$1"
        elif [[ -z "$OUTPUT_ROOT" ]]; then
          OUTPUT_ROOT="$1"
        else
          die "Unknown argument: $1"
        fi
        shift
        ;;
    esac
  done
}

config_app_enabled() {
  local app_name="$1"

  if [[ ! -f "$LANTERN_CONFIG_FILE" ]]; then
    return 1
  fi

  [[ "$(yq -r ".apps.${app_name}.enabled" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf 'false')" == "true" ]]
}

app_label() {
  case "$1" in
    jellyfin) printf 'Movies & TV\n' ;;
    immich) printf 'Photos\n' ;;
    mealie) printf 'Recipes\n' ;;
    filebrowser) printf 'Files\n' ;;
    nextcloud) printf 'Family Cloud\n' ;;
    paperless) printf 'Documents\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

write_file() {
  local destination="$1"
  local contents="$2"

  if [[ -f "$destination" ]] && [[ "$FORCE" != "true" ]]; then
    warn "Keeping existing Homepage file: ${destination}"
    return 0
  fi

  printf '%s\n' "$contents" > "$destination"
  ok "Wrote Homepage file: ${destination}"
}

generate_settings_yaml() {
  cat <<EOF
title: "${LANTERN_SERVER_NAME}"
favicon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/lantern.png
theme: dark
color: slate
headerStyle: clean
layout:
  Family:
    style: row
    columns: 4
    icon: mdi-home-heart
  Home:
    style: row
    columns: 3
    icon: mdi-home
  Admin:
    style: row
    columns: 3
    icon: mdi-shield-lock
    initiallyCollapsed: true
EOF
}

generate_docker_yaml() {
  cat <<'EOF'
docker:
  local:
    socket: /var/run/docker.sock
EOF
}

generate_services_yaml() {
  cat <<'EOF'
# Services are auto-discovered via Docker labels.
# Add manual entries below for anything that is not exposed through Docker metadata.
[]
EOF
}

generate_widgets_yaml() {
  cat <<EOF
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
- resources:
    label: Server
    expanded: true
    cpu: true
    memory: true
    disk:
      - ${LANTERN_DATA_ROOT}
- search:
    provider: duckduckgo
    target: _blank
EOF
}

generate_bookmarks_yaml() {
  local app_name

  cat <<EOF
- Quick Links:
    - Authentik Admin:
        - icon: authentik
          href: https://auth.${LANTERN_DOMAIN}/if/admin/
    - Lantern Docs:
        - icon: github
          href: https://github.com/itsbryanman/Lantern
EOF

  if [[ -f "$LANTERN_CONFIG_FILE" ]]; then
    echo ""
    echo "- Apps:"
    for app_name in jellyfin immich nextcloud filebrowser mealie paperless; do
      if config_app_enabled "$app_name"; then
        cat <<EOF
    - $(app_label "$app_name"):
        - icon: ${app_name}
          href: https://$(app_subdomain "$app_name").${LANTERN_DOMAIN}
EOF
      fi
    done
  fi
}

main() {
  parse_args "$@"
  require_command yq
  load_lantern_context

  if [[ -z "$OUTPUT_ROOT" ]]; then
    OUTPUT_ROOT="$LANTERN_DATA_ROOT"
  fi

  mkdir -p "$OUTPUT_ROOT/data/homepage/images"

  write_file "$OUTPUT_ROOT/data/homepage/settings.yaml" "$(generate_settings_yaml)"
  write_file "$OUTPUT_ROOT/data/homepage/docker.yaml" "$(generate_docker_yaml)"
  write_file "$OUTPUT_ROOT/data/homepage/services.yaml" "$(generate_services_yaml)"
  write_file "$OUTPUT_ROOT/data/homepage/widgets.yaml" "$(generate_widgets_yaml)"
  write_file "$OUTPUT_ROOT/data/homepage/bookmarks.yaml" "$(generate_bookmarks_yaml)"
}

main "$@"
