#!/usr/bin/env bash
# =============================================================================
# Lantern - Authentik Bootstrap
# =============================================================================
# Usage:
#   ./scripts/bootstrap-authentik.sh
#   ./scripts/bootstrap-authentik.sh /path/to/lantern.yaml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

API_BASE="http://localhost:9000/api/v3"
API_RESPONSE_BODY=""
API_RESPONSE_CODE=""
TOKEN=""
DATA_ROOT=""
DOMAIN=""
PASSWORD_FILE=""

parse_args() {
  if [[ $# -gt 0 ]] && [[ -f "$1" ]]; then
    LANTERN_CONFIG_FILE="$1"
  fi
}

wait_for_authentik() {
  local timeout=120
  local elapsed=0
  local status_code

  log "Waiting for Authentik to become ready"
  while (( elapsed < timeout )); do
    status_code="$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:9000/-/health/live/ || true)"
    if [[ "$status_code" == "200" ]]; then
      ok "Authentik is responding on http://localhost:9000"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))
  done

  err "Timed out waiting for Authentik after ${timeout}s"
  return 1
}

api_request() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local tmp_body
  local http_code
  local curl_args=(
    -sS
    -X "$method"
    "${API_BASE}${path}"
    -H "Accept: application/json"
    -H "Authorization: Bearer ${TOKEN}"
  )

  if [[ -n "$body" ]]; then
    curl_args+=(
      -H "Content-Type: application/json"
      --data "$body"
    )
  fi

  tmp_body="$(mktemp)"
  http_code="$(curl "${curl_args[@]}" -o "$tmp_body" -w '%{http_code}')"
  API_RESPONSE_BODY="$(cat "$tmp_body")"
  API_RESPONSE_CODE="$http_code"
  rm -f "$tmp_body"
}

find_group_json() {
  local group_name="$1"

  api_request GET "/core/groups/?page_size=200&include_users=true"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to list groups (HTTP $API_RESPONSE_CODE)"

  printf '%s' "$API_RESPONSE_BODY" \
    | jq -c --arg group_name "$group_name" '.results[] | select(.name == $group_name)' \
    | head -n 1
}

ensure_group() {
  local group_name="$1"
  local group_json
  local group_uuid
  local payload

  group_json="$(find_group_json "$group_name")"
  if [[ -n "$group_json" ]]; then
    group_uuid="$(printf '%s' "$group_json" | jq -r '.pk')"
    ok "Group already exists: ${group_name}" >&2
    printf '%s\n' "$group_uuid"
    return 0
  fi

  payload="$(jq -cn --arg group_name "$group_name" '{name: $group_name, is_superuser: false}')"
  api_request POST "/core/groups/" "$payload"

  case "$API_RESPONSE_CODE" in
    201) ok "Created group: ${group_name}" >&2 ;;
    409) warn "Group already existed during create: ${group_name}" >&2 ;;
    *) die "Failed to create group ${group_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY" ;;
  esac

  group_json="$(find_group_json "$group_name")"
  [[ -n "$group_json" ]] || die "Could not resolve group after create: ${group_name}"
  printf '%s\n' "$(printf '%s' "$group_json" | jq -r '.pk')"
}

sanitize_username() {
  local raw_value="$1"
  local username

  username="$(printf '%s' "$raw_value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9@._+-]/-/g; s/^-*//; s/-*$//; s/--*/-/g')"

  if [[ -z "$username" ]]; then
    username="family-user"
  fi

  printf '%s\n' "$username"
}

find_user_json() {
  local username="$1"
  local email="$2"

  api_request GET "/core/users/?page_size=200&include_groups=true"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to list users (HTTP $API_RESPONSE_CODE)"

  printf '%s' "$API_RESPONSE_BODY" \
    | jq -c --arg username "$username" --arg email "$email" '
        .results[]
        | select(.username == $username or ($email != "" and .email == $email))
      ' \
    | head -n 1
}

get_temp_password() {
  local username="$1"
  local existing_password
  local new_password

  mkdir -p "$(dirname "$PASSWORD_FILE")"
  touch "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"

  existing_password="$(awk -F: -v username="$username" '$1 == username {print $2; exit}' "$PASSWORD_FILE")"
  if [[ -n "$existing_password" ]]; then
    printf '%s\n' "$existing_password"
    return 0
  fi

  new_password="$(openssl rand -base64 24 | tr -d '=/+' | head -c 18)"
  printf '%s:%s\n' "$username" "$new_password" >> "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  printf '%s\n' "$new_password"
}

set_user_password() {
  local user_pk="$1"
  local password="$2"
  local payload

  payload="$(jq -cn --arg password "$password" '{password: $password}')"
  api_request POST "/core/users/${user_pk}/set_password/" "$payload"

  if [[ "$API_RESPONSE_CODE" == "204" ]]; then
    ok "Set temporary password for user ID ${user_pk}"
    return 0
  fi

  die "Failed to set password for user ID ${user_pk} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
}

user_in_group() {
  local user_pk="$1"
  local group_name="$2"

  api_request GET "/core/groups/?page_size=100&members_by_pk=${user_pk}"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to inspect group membership (HTTP $API_RESPONSE_CODE)"

  printf '%s' "$API_RESPONSE_BODY" \
    | jq -e --arg group_name "$group_name" '.results[] | select(.name == $group_name)' >/dev/null
}

ensure_group_membership() {
  local group_uuid="$1"
  local group_name="$2"
  local user_pk="$3"
  local payload

  if user_in_group "$user_pk" "$group_name"; then
    ok "User ${user_pk} already belongs to group ${group_name}"
    return 0
  fi

  payload="$(jq -cn --argjson user_pk "$user_pk" '{pk: $user_pk}')"
  api_request POST "/core/groups/${group_uuid}/add_user/" "$payload"

  if [[ "$API_RESPONSE_CODE" == "204" ]]; then
    ok "Added user ${user_pk} to group ${group_name}"
    return 0
  fi

  die "Failed to add user ${user_pk} to group ${group_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
}

ensure_user() {
  local display_name="$1"
  local email="$2"
  local group_name="$3"
  local username_source="$display_name"
  local username
  local group_uuid
  local user_json
  local user_pk
  local temp_password
  local payload

  if [[ -n "$email" ]] && [[ "$email" != "null" ]]; then
    username_source="${email%%@*}"
  fi

  username="$(sanitize_username "$username_source")"
  group_uuid="$(ensure_group "$group_name")"
  user_json="$(find_user_json "$username" "$email")"

  if [[ -z "$user_json" ]]; then
    payload="$(jq -cn \
      --arg username "$username" \
      --arg display_name "$display_name" \
      --arg email "$email" '
        {
          username: $username,
          name: $display_name,
          is_active: true
        } + (if $email != "" and $email != "null" then {email: $email} else {} end)
      ')"

    api_request POST "/core/users/" "$payload"
    case "$API_RESPONSE_CODE" in
      201) ok "Created user: ${username}" ;;
      409) warn "User already existed during create: ${username}" ;;
      *) die "Failed to create user ${username} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY" ;;
    esac

    user_json="$(find_user_json "$username" "$email")"
    [[ -n "$user_json" ]] || die "Could not resolve user after create: ${username}"

    temp_password="$(get_temp_password "$username")"
    user_pk="$(printf '%s' "$user_json" | jq -r '.pk')"
    set_user_password "$user_pk" "$temp_password"
  else
    ok "User already exists: ${username}"
  fi

  user_pk="$(printf '%s' "$user_json" | jq -r '.pk')"
  ensure_group_membership "$group_uuid" "$group_name" "$user_pk"
}

get_flow_uuid() {
  local designation="$1"
  shift
  local preferred_slug
  local flow_uuid=""

  api_request GET "/flows/instances/?page_size=100&designation=${designation}"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to list ${designation} flows (HTTP $API_RESPONSE_CODE)"

  for preferred_slug in "$@"; do
    flow_uuid="$(printf '%s' "$API_RESPONSE_BODY" \
      | jq -r --arg preferred_slug "$preferred_slug" '.results[] | select(.slug == $preferred_slug) | .pk' \
      | head -n 1)"
    if [[ -n "$flow_uuid" ]]; then
      printf '%s\n' "$flow_uuid"
      return 0
    fi
  done

  flow_uuid="$(printf '%s' "$API_RESPONSE_BODY" | jq -r '.results[0].pk // empty')"
  [[ -n "$flow_uuid" ]] || die "Could not find any ${designation} flow"
  printf '%s\n' "$flow_uuid"
}

app_subdomain_name() {
  case "$1" in
    jellyfin) printf 'media\n' ;;
    immich) printf 'photos\n' ;;
    mealie) printf 'recipes\n' ;;
    filebrowser) printf 'files\n' ;;
    nextcloud) printf 'cloud\n' ;;
    paperless) printf 'docs\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

default_app_label() {
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

config_app_enabled() {
  local app_name="$1"

  if [[ ! -f "$LANTERN_CONFIG_FILE" ]]; then
    return 1
  fi

  [[ "$(yq -r ".apps.${app_name}.enabled" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf 'false')" == "true" ]]
}

config_app_label() {
  local app_name="$1"
  local default_label

  default_label="$(default_app_label "$app_name")"
  if [[ ! -f "$LANTERN_CONFIG_FILE" ]]; then
    printf '%s\n' "$default_label"
    return 0
  fi

  yq -r ".apps.${app_name}.label // \"${default_label}\"" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf '%s\n' "$default_label"
}

find_provider_json() {
  local provider_name="$1"

  api_request GET "/providers/proxy/?page_size=200"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to list proxy providers (HTTP $API_RESPONSE_CODE)"

  printf '%s' "$API_RESPONSE_BODY" \
    | jq -c --arg provider_name "$provider_name" '.results[] | select(.name == $provider_name)' \
    | head -n 1
}

ensure_proxy_provider() {
  local app_name="$1"
  local authentication_flow_uuid="$2"
  local authorization_flow_uuid="$3"
  local invalidation_flow_uuid="$4"
  local provider_name="${app_name}-provider"
  local external_host="https://$(app_subdomain_name "$app_name").${DOMAIN}"
  local provider_json
  local provider_pk
  local payload

  payload="$(jq -cn \
    --arg provider_name "$provider_name" \
    --arg authentication_flow_uuid "$authentication_flow_uuid" \
    --arg authorization_flow_uuid "$authorization_flow_uuid" \
    --arg invalidation_flow_uuid "$invalidation_flow_uuid" \
    --arg external_host "$external_host" '
      {
        name: $provider_name,
        authorization_flow: $authorization_flow_uuid,
        invalidation_flow: $invalidation_flow_uuid,
        mode: "forward_single",
        external_host: $external_host
      } + (if $authentication_flow_uuid != "" then {authentication_flow: $authentication_flow_uuid} else {} end)
    ')"

  provider_json="$(find_provider_json "$provider_name")"
  if [[ -n "$provider_json" ]]; then
    provider_pk="$(printf '%s' "$provider_json" | jq -r '.pk')"
    api_request PUT "/providers/proxy/${provider_pk}/" "$payload"
    [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to update proxy provider ${provider_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
    ok "Updated proxy provider: ${provider_name}" >&2
    printf '%s\n' "$provider_pk"
    return 0
  fi

  api_request POST "/providers/proxy/" "$payload"
  case "$API_RESPONSE_CODE" in
    201) ok "Created proxy provider: ${provider_name}" >&2 ;;
    409) warn "Proxy provider already existed during create: ${provider_name}" >&2 ;;
    *) die "Failed to create proxy provider ${provider_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY" ;;
  esac

  provider_json="$(find_provider_json "$provider_name")"
  [[ -n "$provider_json" ]] || die "Could not resolve proxy provider after create: ${provider_name}"
  printf '%s\n' "$(printf '%s' "$provider_json" | jq -r '.pk')"
}

ensure_application() {
  local app_name="$1"
  local app_label="$2"
  local provider_pk="$3"
  local launch_url="https://$(app_subdomain_name "$app_name").${DOMAIN}"
  local payload

  payload="$(jq -cn \
    --arg app_label "$app_label" \
    --arg app_name "$app_name" \
    --arg launch_url "$launch_url" \
    --argjson provider_pk "$provider_pk" '
      {
        name: $app_label,
        slug: $app_name,
        provider: $provider_pk,
        meta_launch_url: $launch_url
      }
    ')"

  api_request GET "/core/applications/${app_name}/"
  case "$API_RESPONSE_CODE" in
    200)
      api_request PUT "/core/applications/${app_name}/" "$payload"
      [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to update application ${app_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
      ok "Updated application: ${app_name}"
      ;;
    404)
      api_request POST "/core/applications/" "$payload"
      case "$API_RESPONSE_CODE" in
        201) ok "Created application: ${app_name}" ;;
        409) warn "Application already existed during create: ${app_name}" ;;
        *) die "Failed to create application ${app_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY" ;;
      esac
      ;;
    *)
      die "Failed to inspect application ${app_name} (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
      ;;
  esac
}

find_outpost_json() {
  api_request GET "/outposts/instances/?page_size=100"
  [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to list outposts (HTTP $API_RESPONSE_CODE)"

  printf '%s' "$API_RESPONSE_BODY" \
    | jq -c '.results[] | select(.name == "lantern-outpost")' \
    | head -n 1
}

ensure_outpost() {
  local provider_pks_json="$1"
  local outpost_json
  local outpost_uuid
  local payload

  payload="$(jq -cn \
    --arg authentik_host "https://auth.${DOMAIN}" \
    --argjson provider_pks "$provider_pks_json" '
      {
        name: "lantern-outpost",
        type: "proxy",
        providers: $provider_pks,
        service_connection: null,
        config: {
          authentik_host: $authentik_host,
          docker_network: "lantern"
        }
      }
    ')"

  outpost_json="$(find_outpost_json)"
  if [[ -n "$outpost_json" ]]; then
    outpost_uuid="$(printf '%s' "$outpost_json" | jq -r '.pk')"
    api_request PUT "/outposts/instances/${outpost_uuid}/" "$payload"
    [[ "$API_RESPONSE_CODE" == "200" ]] || die "Failed to update outpost lantern-outpost (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY"
    ok "Updated outpost: lantern-outpost"
    return 0
  fi

  api_request POST "/outposts/instances/" "$payload"
  case "$API_RESPONSE_CODE" in
    201) ok "Created outpost: lantern-outpost" ;;
    409) warn "Outpost already existed during create: lantern-outpost" ;;
    *) die "Failed to create outpost lantern-outpost (HTTP $API_RESPONSE_CODE): $API_RESPONSE_BODY" ;;
  esac
}

bootstrap_family_users() {
  local user_count=0
  local index
  local display_name
  local email
  local group_name

  ensure_group "family" >/dev/null

  if [[ -f "$LANTERN_CONFIG_FILE" ]]; then
    user_count="$(yq -r '.auth.family_users | length' "$LANTERN_CONFIG_FILE" 2>/dev/null || printf '0')"
  fi

  for ((index = 0; index < user_count; index++)); do
    display_name="$(yq -r ".auth.family_users[${index}].name // \"\"" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf '')"
    email="$(yq -r ".auth.family_users[${index}].email // \"\"" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf '')"
    group_name="$(yq -r ".auth.family_users[${index}].group // \"family\"" "$LANTERN_CONFIG_FILE" 2>/dev/null || printf 'family')"

    [[ -n "$display_name" ]] || continue
    ensure_user "$display_name" "$email" "$group_name"
  done
}

bootstrap_apps() {
  local authentication_flow_uuid
  local authorization_flow_uuid
  local invalidation_flow_uuid
  local app_name
  local app_label
  local provider_pk
  local provider_pks=()

  authentication_flow_uuid="$(get_flow_uuid authentication default-authentication-flow)"
  authorization_flow_uuid="$(get_flow_uuid authorization default-provider-authorization-explicit-consent default-provider-authorization-implicit-consent)"
  invalidation_flow_uuid="$(get_flow_uuid invalidation default-provider-invalidation-flow default-invalidation-flow)"

  for app_name in jellyfin immich nextcloud filebrowser mealie paperless; do
    if ! config_app_enabled "$app_name"; then
      continue
    fi

    app_label="$(config_app_label "$app_name")"
    provider_pk="$(ensure_proxy_provider "$app_name" "$authentication_flow_uuid" "$authorization_flow_uuid" "$invalidation_flow_uuid")"
    ensure_application "$app_name" "$app_label" "$provider_pk"
    provider_pks+=("$provider_pk")
  done

  if [[ ${#provider_pks[@]} -eq 0 ]]; then
    warn "No enabled apps found for Authentik application bootstrap"
    return 0
  fi

  ensure_outpost "$(printf '%s\n' "${provider_pks[@]}" | jq -Rcs 'split("\n") | map(select(length > 0) | tonumber)')"
}

main() {
  parse_args "$@"
  require_command curl
  require_command jq
  require_command openssl
  require_command yq
  load_lantern_context

  DATA_ROOT="$LANTERN_DATA_ROOT"
  DOMAIN="$LANTERN_DOMAIN"
  PASSWORD_FILE="${DATA_ROOT}/secrets/family_user_passwords"

  [[ -f "${DATA_ROOT}/secrets/authentik_api_token" ]] || die "Missing Authentik API token file"
  TOKEN="$(<"${DATA_ROOT}/secrets/authentik_api_token")"
  [[ -n "$TOKEN" ]] || die "Authentik API token file is empty"

  wait_for_authentik
  bootstrap_family_users
  bootstrap_apps
  ok "Authentik bootstrap completed"
}

main "$@"
