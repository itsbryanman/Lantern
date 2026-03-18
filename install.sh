#!/usr/bin/env bash
# =============================================================================
# Lantern — Family Server Installer
# https://github.com/itsbryanman/Lantern
# =============================================================================
# Usage:
#   ./install.sh                    # Uses built-in defaults for an initial bootstrap
#   ./install.sh --config lantern.yaml  # Config-driven install
#   ./install.sh --preflight        # Check requirements only
#   ./install.sh --phase core       # Deploy only core services
#   ./install.sh --phase apps       # Deploy only app services
#   ./install.sh --validate         # Post-install validation only
# =============================================================================

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
LANTERN_VERSION="0.1.0"
PROJECT_NAME="lantern"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/lantern-install-$(date +%Y%m%d-%H%M%S).log"
MIN_RAM_MB=2048
MIN_DISK_GB=20
REQUIRED_PORTS=(80 443)

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${BLUE}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[  OK]${NC}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[FAIL]${NC}  $*" | tee -a "$LOG_FILE"; }
die()  { err "$@"; exit 1; }
run_as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $*${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Config parsing ───────────────────────────────────────────────────────────
CONFIG_FILE=""
PHASE="all"
VALIDATE_ONLY=false
PREFLIGHT_ONLY=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)     CONFIG_FILE="$2"; shift 2 ;;
      --phase)      PHASE="$2"; shift 2 ;;
      --validate)   VALIDATE_ONLY=true; shift ;;
      --preflight)  PREFLIGHT_ONLY=true; shift ;;
      --help|-h)    show_help; exit 0 ;;
      *)            die "Unknown option: $1" ;;
    esac
  done
}

show_help() {
  cat <<'EOF'
Lantern — Family Server Installer

Usage:
  ./install.sh                          Bootstrap with built-in defaults
  ./install.sh --config lantern.yaml  Config-driven setup
  ./install.sh --preflight              Check system requirements
  ./install.sh --phase core|apps        Deploy specific phase
  ./install.sh --validate               Run post-install checks

Options:
  --config FILE    Path to lantern.yaml config file
  --phase PHASE    Deploy phase: "core", "apps", or "all" (default)
  --validate       Run validation checks only
  --preflight      Run preflight checks only
  -h, --help       Show this help
EOF
}

# ── Config helpers ────────────────────────────────────────────────────────────
ensure_yq() {
  if command -v yq &>/dev/null; then
    return 0
  fi

  if ! command -v curl &>/dev/null; then
    run_as_root apt-get update -qq
    run_as_root apt-get install -y -qq curl
  fi

  log "Installing yq for config parsing..."
  local yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)"
  run_as_root curl -fsSL "$yq_url" -o /usr/local/bin/yq
  run_as_root chmod +x /usr/local/bin/yq
  ok "yq installed"
}

config_value() {
  local expr="$1"
  local default_value="${2:-}"
  local value=""

  if [[ -n "$CONFIG_FILE" ]] && [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    value=$(yq -r "$expr" "$CONFIG_FILE" 2>/dev/null || true)
  fi

  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$value"
  fi
}

load_config_values() {
  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
    ensure_yq
    log "Loading config from: $CONFIG_FILE"
  else
    warn "No config file supplied. Using defaults for the initial buildout."
  fi

  export SERVER_NAME
  export DOMAIN
  export EMAIL
  export TIMEZONE
  export DATA_ROOT
  export TAILSCALE_ENABLED
  export FAIL2BAN
  export BACKUP_PATH
  export BACKUP_SCHEDULE
  export COMPOSE_PROJECT_NAME

  SERVER_NAME=$(config_value '.server.name' 'Our Family Server')
  DOMAIN=$(config_value '.server.domain' 'home.example.com')
  EMAIL=$(config_value '.server.email' 'admin@example.com')
  TIMEZONE=$(config_value '.server.timezone' 'America/New_York')
  DATA_ROOT=$(config_value '.server.data_root' '/srv/lantern')
  TAILSCALE_ENABLED=$(config_value '.network.tailscale.enabled' 'false')
  FAIL2BAN=$(config_value '.advanced.fail2ban' 'true')
  BACKUP_PATH=$(config_value '.backups.destinations[0].path' '/mnt/backups/lantern')
  BACKUP_SCHEDULE=$(config_value '.backups.schedule' '0 2 * * *')
  COMPOSE_PROJECT_NAME="$PROJECT_NAME"
}

# =============================================================================
# PHASE 0: Preflight checks
# =============================================================================
preflight() {
  header "Preflight Checks"
  local failures=0

  # OS check
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    log "OS: $PRETTY_NAME"
    case "$ID" in
      debian|ubuntu|raspbian) ok "Supported OS detected" ;;
      *) warn "Untested OS ($ID) — proceed with caution"; ((failures++)) || true ;;
    esac
  else
    warn "Cannot detect OS"; ((failures++)) || true
  fi

  # Root / sudo check
  if [[ $EUID -ne 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
      err "Not running as root and no passwordless sudo"
      ((failures++)) || true
    else
      ok "Sudo access available"
    fi
  else
    ok "Running as root"
  fi

  # RAM check
  local ram_mb
  ram_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  if (( ram_mb >= MIN_RAM_MB )); then
    ok "RAM: ${ram_mb} MB (minimum: ${MIN_RAM_MB} MB)"
  else
    err "Insufficient RAM: ${ram_mb} MB (need ${MIN_RAM_MB} MB)"
    ((failures++)) || true
  fi

  # Disk check
  local disk_gb
  disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
  if (( disk_gb >= MIN_DISK_GB )); then
    ok "Free disk: ${disk_gb} GB (minimum: ${MIN_DISK_GB} GB)"
  else
    err "Insufficient disk: ${disk_gb} GB (need ${MIN_DISK_GB} GB)"
    ((failures++)) || true
  fi

  # Docker check
  if command -v docker &>/dev/null; then
    local docker_ver
    docker_ver=$(docker --version | awk '{print $3}' | tr -d ',')
    ok "Docker: $docker_ver"
  else
    warn "Docker not installed — will install during setup"
  fi

  # Docker Compose check
  if docker compose version &>/dev/null 2>&1; then
    ok "Docker Compose plugin available"
  else
    warn "Docker Compose plugin not found — will install"
  fi

  # Port checks
  for port in "${REQUIRED_PORTS[@]}"; do
    if ss -tlnp | grep -q ":${port} "; then
      err "Port $port is already in use"
      ((failures++)) || true
    else
      ok "Port $port available"
    fi
  done

  # DNS check (basic)
  if command -v dig &>/dev/null; then
    ok "DNS tools available"
  elif command -v nslookup &>/dev/null; then
    ok "DNS tools available (nslookup)"
  else
    warn "No DNS tools found — will install dnsutils"
  fi

  echo ""
  if (( failures > 0 )); then
    warn "Preflight completed with $failures warning(s)/failure(s)"
    return 1
  else
    ok "All preflight checks passed"
    return 0
  fi
}

# =============================================================================
# PHASE 1: Directory structure & dependencies
# =============================================================================
setup_directories() {
  header "Creating Directory Structure"

  local data_root="${DATA_ROOT:-/srv/lantern}"

  local dirs=(
    "$data_root/stacks"
    "$data_root/data"
    "$data_root/backups"
    "$data_root/configs"
    "$data_root/configs/homepage"
    "$data_root/configs/traefik/dynamic"
    "$data_root/secrets"
    "$data_root/logs"
    "$data_root/data/traefik/certs"
    "$data_root/data/authentik/postgres"
    "$data_root/data/authentik/redis"
    "$data_root/data/authentik/media"
    "$data_root/data/authentik/templates"
    "$data_root/data/authentik/certs"
    "$data_root/data/homepage/images"
    "$data_root/data/uptime-kuma"
    "$data_root/data/jellyfin/config"
    "$data_root/data/jellyfin/cache"
    "$data_root/data/immich/upload"
    "$data_root/data/immich/library"
    "$data_root/data/immich/postgres"
    "$data_root/data/immich/redis"
    "$data_root/data/immich/model-cache"
    "$data_root/data/immich/cache"
    "$data_root/data/filebrowser/database"
    "$data_root/data/mealie/data"
    "$data_root/data/nextcloud/html"
    "$data_root/data/nextcloud/data"
    "$data_root/data/nextcloud/mariadb"
    "$data_root/data/nextcloud/redis"
    "$data_root/data/paperless/data"
    "$data_root/data/paperless/media"
    "$data_root/data/paperless/export"
    "$data_root/data/paperless/consume"
    "$data_root/data/paperless/postgres"
    "$data_root/data/paperless/redis"
    "$data_root/files/shared"
  )

  for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
    log "Created: $dir"
  done

  # Lock down secrets directory
  chmod 700 "$data_root/secrets"
  touch "$data_root/data/traefik/certs/acme.json"
  chmod 600 "$data_root/data/traefik/certs/acme.json"
  ok "Directory structure created at $data_root"
}

install_dependencies() {
  header "Installing Dependencies"

  # Update package list
  log "Updating package list..."
  run_as_root apt-get update -qq

  # Install Docker if missing
  if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    run_as_root usermod -aG docker "${SUDO_USER:-$USER}"
    ok "Docker installed"
  fi

  # Install Docker Compose plugin if missing
  if ! docker compose version &>/dev/null 2>&1; then
    log "Installing Docker Compose plugin..."
    run_as_root apt-get install -y -qq docker-compose-plugin
    ok "Docker Compose plugin installed"
  fi

  # Install utilities
  local packages=(curl jq openssl apache2-utils pwgen dnsutils gettext-base restic)
  log "Installing utilities: ${packages[*]}"
  run_as_root apt-get install -y -qq "${packages[@]}"

  # Install yq for YAML parsing
  if ! command -v yq &>/dev/null; then
    ensure_yq
  fi

  # Optional: fail2ban
  if [[ "${FAIL2BAN:-true}" == "true" ]]; then
    if ! command -v fail2ban-client &>/dev/null; then
      log "Installing fail2ban..."
      run_as_root apt-get install -y -qq fail2ban
      run_as_root systemctl enable fail2ban
      ok "fail2ban installed and enabled"
    fi
  fi

  # Optional: Tailscale
  if [[ "${TAILSCALE_ENABLED:-false}" == "true" ]]; then
    if ! command -v tailscale &>/dev/null; then
      log "Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
      ok "Tailscale installed"
    fi
  fi

  ok "All dependencies installed"
}

# =============================================================================
# PHASE 2: Generate secrets & env files
# =============================================================================
generate_secrets() {
  header "Generating Secrets"

  local secrets_dir="${DATA_ROOT:-/srv/lantern}/secrets"

  # Generate passwords for each service
  local services=(authentik postgres admin traefik nextcloud_db nextcloud_db_root)
  for svc in "${services[@]}"; do
    local pw_file="$secrets_dir/${svc}_password"
    if [[ ! -f "$pw_file" ]]; then
      openssl rand -base64 32 | tr -d '=/+' | head -c 32 > "$pw_file"
      chmod 600 "$pw_file"
      log "Generated password for: $svc"
    else
      log "Password already exists for: $svc (skipping)"
    fi
  done

  # Generate authentik secret key
  local ak_key="$secrets_dir/authentik_secret_key"
  if [[ ! -f "$ak_key" ]]; then
    openssl rand -base64 60 | tr -d '=/+' | head -c 50 > "$ak_key"
    chmod 600 "$ak_key"
    log "Generated authentik secret key"
  fi

  # Generate API keys for internal service communication
  local api_key="$secrets_dir/internal_api_key"
  if [[ ! -f "$api_key" ]]; then
    openssl rand -hex 32 > "$api_key"
    chmod 600 "$api_key"
    log "Generated internal API key"
  fi

  local authentik_api_token="$secrets_dir/authentik_api_token"
  if [[ ! -f "$authentik_api_token" ]]; then
    openssl rand -hex 32 > "$authentik_api_token"
    chmod 600 "$authentik_api_token"
    log "Generated Authentik API token"
  fi

  ok "All secrets generated in $secrets_dir"
}

generate_env_files() {
  header "Generating Environment Files"

  local env_dir="${DATA_ROOT:-/srv/lantern}/stacks"
  local secrets_dir="${DATA_ROOT:-/srv/lantern}/secrets"
  local data_root="${DATA_ROOT:-/srv/lantern}"
  local domain="${DOMAIN:-home.example.com}"
  local email="${EMAIL:-admin@example.com}"
  local tz="${TIMEZONE:-America/New_York}"
  local authentik_admin_email

  authentik_admin_email=$(config_value '.auth.admin.email' "$email")

  # ── Core .env ──
  cat > "$env_dir/core.env" <<EOF
# Auto-generated by Lantern installer — do not commit to git
LANTERN_SERVER_NAME=${SERVER_NAME:-Our Family Server}
LANTERN_DOMAIN=${domain}
LANTERN_EMAIL=${email}
TZ=${tz}
DATA_ROOT=${data_root}

# Traefik
TRAEFIK_ACME_EMAIL=${email}
TRAEFIK_LOG_LEVEL=WARN

# Authentik
AUTHENTIK_SECRET_KEY=$(cat "$secrets_dir/authentik_secret_key")
AUTHENTIK_POSTGRESQL__PASSWORD=$(cat "$secrets_dir/postgres_password")
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_BOOTSTRAP_PASSWORD=$(cat "$secrets_dir/admin_password")
AUTHENTIK_BOOTSTRAP_TOKEN=$(cat "$secrets_dir/authentik_api_token")
AUTHENTIK_BOOTSTRAP_EMAIL=${authentik_admin_email}

# Postgres (for authentik)
POSTGRES_PASSWORD=$(cat "$secrets_dir/postgres_password")
POSTGRES_USER=authentik
POSTGRES_DB=authentik
EOF
  chmod 600 "$env_dir/core.env"

  for app in jellyfin immich nextcloud filebrowser mealie paperless; do
    generate_app_env "$app"
  done

  ok "Environment files generated"
}

render_config_templates() {
  local data_root="${DATA_ROOT:-/srv/lantern}"
  local template

  export LANTERN_SERVER_NAME="${SERVER_NAME:-Our Family Server}"
  export LANTERN_DOMAIN="${DOMAIN:-home.example.com}"
  export LANTERN_EMAIL="${EMAIL:-admin@example.com}"
  export TZ="${TIMEZONE:-America/New_York}"

  while IFS= read -r template; do
    envsubst < "$template" > "${template%.tmpl}"
    rm -f "$template"
  done < <(find "$data_root/configs" -type f -name '*.tmpl' | sort)
}

sync_assets() {
  header "Syncing Project Assets"

  local data_root="${DATA_ROOT:-/srv/lantern}"

  cp -f "$SCRIPT_DIR"/compose/core/*.yml "$data_root/stacks/"
  cp -f "$SCRIPT_DIR"/compose/apps/*.yml "$data_root/stacks/"
  cp -R "$SCRIPT_DIR/configs/." "$data_root/configs/"

  render_config_templates
  ok "Compose files and configuration templates copied to $data_root"
}

generate_homepage_configs() {
  local config_arg=()

  if [[ -n "$CONFIG_FILE" ]]; then
    config_arg+=("$CONFIG_FILE")
  fi

  "$SCRIPT_DIR/scripts/generate-homepage-config.sh" "${config_arg[@]}" "${DATA_ROOT:-/srv/lantern}"
}

bootstrap_authentik() {
  local config_arg=()

  if [[ -n "$CONFIG_FILE" ]]; then
    config_arg+=("$CONFIG_FILE")
  fi

  "$SCRIPT_DIR/scripts/bootstrap-authentik.sh" "${config_arg[@]}"
}

# =============================================================================
# PHASE 3: Deploy core stack
# =============================================================================
deploy_core() {
  header "Deploying Core Services"

  local data_root="${DATA_ROOT:-/srv/lantern}"

  log "Starting unified core stack"
  docker compose -f "$SCRIPT_DIR/compose/docker-compose.core.yml" \
    --env-file "$data_root/stacks/core.env" \
    --project-name "$PROJECT_NAME" up -d --wait

  ok "Core stack deployed"
}

# =============================================================================
# PHASE 4: Deploy app stack
# =============================================================================
deploy_apps() {
  header "Deploying Family Apps"

  local data_root="${DATA_ROOT:-/srv/lantern}"
  local enabled_apps=()
  local app

  if [[ -n "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
    for app in jellyfin immich nextcloud filebrowser mealie paperless; do
      local is_enabled
      is_enabled=$(yq ".apps.${app}.enabled" "$CONFIG_FILE" 2>/dev/null || echo "false")
      if [[ "$is_enabled" == "true" ]]; then
        enabled_apps+=("$app")
      fi
    done
  fi

  if [[ ${#enabled_apps[@]} -eq 0 ]]; then
    warn "No apps enabled in config — skipping app deployment"
    return 0
  fi

  load_app_compose_env "$data_root"
  export COMPOSE_PROFILES
  COMPOSE_PROFILES=$(IFS=','; echo "${enabled_apps[*]}")

  log "Deploying unified app stack for profiles: $COMPOSE_PROFILES"
  docker compose -f "$SCRIPT_DIR/compose/docker-compose.apps.yml" \
    --project-name "$PROJECT_NAME" up -d --wait

  for app in "${enabled_apps[@]}"; do
    register_dashboard "$app"
    ok "Deployed: $app"
  done

  ok "Family apps deployed"
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

load_app_compose_env() {
  local data_root="$1"
  local app

  export DATA_ROOT="$data_root"
  export TZ="${TIMEZONE:-America/New_York}"
  export LANTERN_DOMAIN="${DOMAIN:-home.example.com}"

  for app in jellyfin immich nextcloud filebrowser mealie paperless; do
    load_env_file "$data_root/stacks/${app}.env"
  done
}

generate_app_env() {
  local app="$1"
  local data_root="${DATA_ROOT:-/srv/lantern}"
  local env_file="$data_root/stacks/${app}.env"
  local domain="${DOMAIN:-home.example.com}"

  # Base env vars shared by all apps
  cat > "$env_file" <<EOF
TZ=${TIMEZONE:-America/New_York}
LANTERN_DOMAIN=${domain}
DATA_ROOT=${data_root}
EOF

  # App-specific env vars — extend per service
  case "$app" in
    immich)
      local upload_location
      local external_library
      upload_location=$(config_value '.apps.immich.upload_path' "${data_root}/data/immich/upload")
      external_library=$(config_value '.apps.immich.external_library' "${data_root}/data/immich/library")
      cat >> "$env_file" <<EOF
UPLOAD_LOCATION=${upload_location}
IMMICH_EXTERNAL_LIBRARY=${external_library}
IMMICH_DB_PASSWORD=$(cat "$data_root/secrets/postgres_password")
EOF
      ;;
    jellyfin)
      local media_path
      media_path=$(config_value '.apps.jellyfin.media_path' '/mnt/media')
      cat >> "$env_file" <<EOF
JELLYFIN_MEDIA_PATH=${media_path}
EOF
      ;;
    filebrowser)
      local root_path
      root_path=$(config_value '.apps.filebrowser.root_path' "${data_root}/files/shared")
      cat >> "$env_file" <<EOF
FILEBROWSER_ROOT_PATH=${root_path}
EOF
      ;;
    mealie)
      cat >> "$env_file" <<EOF
ALLOW_SIGNUP=false
BASE_URL=https://recipes.${domain}
EOF
      ;;
    nextcloud)
      local admin_username
      cat >> "$env_file" <<EOF
NEXTCLOUD_TRUSTED_DOMAINS=cloud.${domain} ${domain}
NEXTCLOUD_DB_NAME=nextcloud
NEXTCLOUD_DB_USER=nextcloud
NEXTCLOUD_DB_PASSWORD=$(cat "$data_root/secrets/nextcloud_db_password")
NEXTCLOUD_DB_ROOT_PASSWORD=$(cat "$data_root/secrets/nextcloud_db_root_password")
NEXTCLOUD_DB_HOST=nextcloud-mariadb
NEXTCLOUD_REDIS_HOST=nextcloud-redis
EOF
      admin_username=$(config_value '.auth.admin.username' 'admin')
      cat >> "$env_file" <<EOF
NEXTCLOUD_ADMIN_USER=${admin_username}
NEXTCLOUD_ADMIN_PASSWORD=$(cat "$data_root/secrets/admin_password")
EOF
      ;;
    paperless)
      local consume_path
      consume_path=$(config_value '.apps.paperless.consume_path' "${data_root}/data/paperless/consume")
      cat >> "$env_file" <<EOF
PAPERLESS_CONSUME_PATH=${consume_path}
PAPERLESS_DB_PASSWORD=$(cat "$data_root/secrets/postgres_password")
EOF
      ;;
  esac

  chmod 600 "$env_file"
}

register_dashboard() {
  local app="$1"
  log "Dashboard entry available for $app via the generated Homepage config"
}

# =============================================================================
# PHASE 5: Backup setup
# =============================================================================
setup_backups() {
  header "Configuring Backups"

  local data_root="${DATA_ROOT:-/srv/lantern}"
  local backup_dest="${BACKUP_PATH:-/mnt/backups/lantern}"

  # Initialize restic repo
  if [[ ! -d "$backup_dest" ]] || [[ ! -f "$backup_dest/config" ]]; then
    log "Initializing restic repository at $backup_dest"
    mkdir -p "$backup_dest"
    export RESTIC_PASSWORD_FILE="$data_root/secrets/restic_password"

    # Generate restic password if not exists
    if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
      openssl rand -base64 32 | head -c 32 > "$RESTIC_PASSWORD_FILE"
      chmod 600 "$RESTIC_PASSWORD_FILE"
    fi

    restic init --repo "$backup_dest" --password-file "$RESTIC_PASSWORD_FILE"
    ok "Restic repository initialized"
  else
    ok "Restic repository already exists"
  fi

  # Install backup cron
  local cron_schedule="${BACKUP_SCHEDULE:-0 2 * * *}"
  local cron_entry="$cron_schedule $SCRIPT_DIR/scripts/backup.sh >> $data_root/logs/backup.log 2>&1"

  if ! crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/scripts/backup.sh"; then
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    ok "Backup cron installed: $cron_schedule"
  else
    ok "Backup cron already configured"
  fi

  # Run initial snapshot
  log "Running initial backup snapshot..."
  "$SCRIPT_DIR/scripts/backup.sh" --initial
  ok "Initial backup snapshot completed"
}

# =============================================================================
# PHASE 6: Validation
# =============================================================================
validate() {
  header "Post-Install Validation"
  local failures=0
  local domain="${DOMAIN:-home.example.com}"

  # Check all containers are running and healthy
  log "Checking container health..."
  local containers
  containers=$(docker ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format '{{.Names}} {{.Status}}')
  while IFS= read -r line; do
    local name status
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | grep -o '(healthy)\|(unhealthy)\|(starting)')
    case "$status" in
      "(healthy)")   ok "Container: $name — healthy" ;;
      "(unhealthy)") err "Container: $name — UNHEALTHY"; ((failures++)) || true ;;
      "(starting)")  warn "Container: $name — still starting" ;;
      *)             warn "Container: $name — no healthcheck defined" ;;
    esac
  done <<< "$containers"

  # Check URLs resolve
  log "Checking service URLs..."
  local urls=(
    "https://${domain}"
    "https://auth.${domain}"
    "https://status.${domain}"
  )
  for url in "${urls[@]}"; do
    if curl -fsSLk -o /dev/null --connect-timeout 5 "$url" 2>/dev/null; then
      ok "URL reachable: $url"
    else
      warn "URL not reachable: $url (may need DNS configured)"
    fi
  done

  # Check TLS
  if echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null | grep -q "Verify return code: 0"; then
    ok "TLS certificate valid for $domain"
  else
    warn "TLS certificate not valid (expected if using self-signed or DNS not configured)"
  fi

  # Check backup repo
  if [[ -f "${DATA_ROOT:-/srv/lantern}/secrets/restic_password" ]]; then
    local snap_count
    snap_count=$(restic -r "${BACKUP_PATH:-/mnt/backups/lantern}" \
      --password-file "${DATA_ROOT:-/srv/lantern}/secrets/restic_password" \
      snapshots --json 2>/dev/null | jq length 2>/dev/null || echo "0")
    if (( snap_count > 0 )); then
      ok "Backup repo has $snap_count snapshot(s)"
    else
      warn "No backup snapshots found yet"
    fi
  fi

  echo ""
  if (( failures > 0 )); then
    warn "Validation completed with $failures issue(s)"
  else
    ok "All validation checks passed"
  fi
}

# =============================================================================
# PHASE 7: Summary
# =============================================================================
print_summary() {
  header "Lantern — Installation Summary"
  local domain="${DOMAIN:-home.example.com}"
  local data_root="${DATA_ROOT:-/srv/lantern}"
  local password_file="${data_root}/secrets/family_user_passwords"

  cat <<EOF

${GREEN}Installation complete.${NC}

${BOLD}Service URLs:${NC}
  Dashboard:     https://${domain}
  Auth Admin:    https://auth.${domain}/if/admin/
  Status Page:   https://status.${domain}

${BOLD}App URLs:${NC}
EOF

  # List deployed app URLs
  for app in jellyfin immich mealie filebrowser nextcloud paperless; do
    if docker ps --format '{{.Names}}' | grep -q "^${app}"; then
      local subdomain="$app"
      case "$app" in
        jellyfin)    subdomain="media" ;;
        immich)      subdomain="photos" ;;
        mealie)      subdomain="recipes" ;;
        filebrowser) subdomain="files" ;;
        nextcloud)   subdomain="cloud" ;;
        paperless)   subdomain="docs" ;;
      esac
      echo "  ${app^}:$(printf '%*s' $((14 - ${#app})) '')https://${subdomain}.${domain}"
    fi
  done

  cat <<EOF

${BOLD}Admin Info:${NC}
  Data root:     ${data_root}
  Secrets:       ${data_root}/secrets/  (chmod 700)
  Logs:          ${data_root}/logs/
  Backups:       ${BACKUP_PATH:-/mnt/backups/lantern}
  Config:        ${CONFIG_FILE:-lantern.yaml}
  Install log:   ${LOG_FILE}

${BOLD}Authentik:${NC}
  Admin email:   $(config_value '.auth.admin.email' "${EMAIL:-admin@example.com}")
  Apps:          Pre-configured for enabled services
  User secrets:  ${password_file}

${BOLD}Next steps:${NC}
  1. Configure DNS — point *.${domain} to this server
  2. Share the dashboard URL with your family
  3. Review family user passwords in ${password_file}
  4. Verify backups — run: ./scripts/backup.sh --verify

${YELLOW}Save your secrets.${NC}
  Restic password:   ${data_root}/secrets/restic_password
  Admin password:    ${data_root}/secrets/admin_password
  Authentik key:     ${data_root}/secrets/authentik_secret_key
  API token:         ${data_root}/secrets/authentik_api_token

EOF

  if [[ -f "$password_file" ]]; then
    echo "${BOLD}Family users:${NC}"
    while IFS=: read -r username password; do
      [[ -n "$username" ]] || continue
      printf '  %s: %s\n' "$username" "$password"
    done < "$password_file"
    echo ""
  fi
}

# =============================================================================
# Helpers
# =============================================================================
wait_healthy() {
  local container="$1"
  local timeout="${2:-30}"
  local elapsed=0

  while (( elapsed < timeout )); do
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    case "$health" in
      healthy) ok "$container is healthy"; return 0 ;;
      unhealthy) err "$container is unhealthy"; return 1 ;;
      missing)
        # No healthcheck defined — just check if running
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
          ok "$container is running (no healthcheck)"
          return 0
        fi
        ;;
    esac
    sleep 2
    ((elapsed += 2))
  done

  warn "$container did not become healthy within ${timeout}s"
  return 1
}

# =============================================================================
# Main
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}  Lantern Family Server Installer v${LANTERN_VERSION}${NC}"
  echo ""

  parse_args "$@"

  # Preflight-only mode
  if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
    preflight
    exit $?
  fi

  load_config_values

  # Validate-only mode
  if [[ "$VALIDATE_ONLY" == "true" ]]; then
    validate
    exit $?
  fi

  # Full install flow
  case "$PHASE" in
    core)
      preflight
      setup_directories
      install_dependencies
      generate_secrets
      generate_env_files
      sync_assets
      generate_homepage_configs
      deploy_core
      bootstrap_authentik
      ;;
    apps)
      setup_directories
      install_dependencies
      generate_secrets
      generate_env_files
      sync_assets
      deploy_apps
      ;;
    all)
      preflight
      setup_directories
      install_dependencies
      generate_secrets
      generate_env_files
      sync_assets
      generate_homepage_configs
      deploy_core
      bootstrap_authentik
      deploy_apps
      setup_backups
      validate
      print_summary
      ;;
    *)
      die "Unknown phase: $PHASE (use: core, apps, or all)"
      ;;
  esac
}

main "$@"
