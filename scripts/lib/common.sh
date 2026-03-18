#!/usr/bin/env bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANTERN_REPO_ROOT="$(cd "$COMMON_DIR/../.." && pwd)"
LANTERN_CONFIG_FILE="${LANTERN_CONFIG_FILE:-$LANTERN_REPO_ROOT/lantern.yaml}"

log() {
  printf '[INFO] %s\n' "$*"
}

ok() {
  printf '[  OK] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[FAIL] %s\n' "$*" >&2
}

info() {
  log "$@"
}

die() {
  err "$@"
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
}

yaml_read() {
  local expr="$1"

  if [[ ! -f "$LANTERN_CONFIG_FILE" ]] || ! command -v yq >/dev/null 2>&1; then
    return 0
  fi

  yq -r "$expr" "$LANTERN_CONFIG_FILE" 2>/dev/null || true
}

config_value() {
  local expr="$1"
  local default_value="$2"
  local value

  value="$(yaml_read "$expr")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  printf '%s\n' "$value"
}

load_lantern_context() {
  export LANTERN_SERVER_NAME
  export LANTERN_DOMAIN
  export LANTERN_EMAIL
  export LANTERN_TIMEZONE
  export LANTERN_DATA_ROOT
  export LANTERN_BACKUP_PATH
  export LANTERN_BACKUP_DAILY
  export LANTERN_BACKUP_WEEKLY
  export LANTERN_BACKUP_MONTHLY
  export LANTERN_COMPOSE_PROJECT_NAME
  export DATA_ROOT
  export TZ

  LANTERN_SERVER_NAME="$(config_value '.server.name' 'Our Family Server')"
  LANTERN_DOMAIN="$(config_value '.server.domain' 'home.example.com')"
  LANTERN_EMAIL="$(config_value '.server.email' 'admin@example.com')"
  LANTERN_TIMEZONE="$(config_value '.server.timezone' 'America/New_York')"
  LANTERN_DATA_ROOT="$(config_value '.server.data_root' '/srv/lantern')"
  LANTERN_BACKUP_PATH="$(config_value '.backups.destinations[0].path' '/mnt/backups/lantern')"
  LANTERN_BACKUP_DAILY="$(config_value '.backups.retention.keep_daily' '7')"
  LANTERN_BACKUP_WEEKLY="$(config_value '.backups.retention.keep_weekly' '4')"
  LANTERN_BACKUP_MONTHLY="$(config_value '.backups.retention.keep_monthly' '6')"
  LANTERN_COMPOSE_PROJECT_NAME="lantern"
  DATA_ROOT="$LANTERN_DATA_ROOT"
  TZ="$LANTERN_TIMEZONE"
}

stack_file() {
  printf '%s/stacks/%s.yml\n' "$LANTERN_DATA_ROOT" "$1"
}

env_file() {
  if [[ "$1" == "core" ]]; then
    printf '%s/stacks/core.env\n' "$LANTERN_DATA_ROOT"
    return 0
  fi

  printf '%s/stacks/%s.env\n' "$LANTERN_DATA_ROOT" "$1"
}

app_subdomain() {
  case "$1" in
    jellyfin) printf 'media\n' ;;
    immich) printf 'photos\n' ;;
    mealie) printf 'recipes\n' ;;
    filebrowser) printf 'files\n' ;;
    nextcloud) printf 'cloud\n' ;;
    paperless) printf 'docs\n' ;;
    homepage) printf '%s\n' "$LANTERN_DOMAIN" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

enabled_apps() {
  local app

  if [[ -f "$LANTERN_CONFIG_FILE" ]] && command -v yq >/dev/null 2>&1; then
    for app in jellyfin immich nextcloud filebrowser mealie paperless; do
      if [[ "$(yq -r ".apps.${app}.enabled" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf 'false')" == "true" ]]; then
        printf '%s\n' "$app"
      fi
    done
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    for app in jellyfin immich nextcloud filebrowser mealie paperless; do
      if docker ps -a --filter "label=com.docker.compose.project=${LANTERN_COMPOSE_PROJECT_NAME}" --format '{{.Names}}' \
        | grep -qx "$app"; then
        printf '%s\n' "$app"
      fi
    done
  fi
}
