#!/usr/bin/env bash

set -o pipefail

if [[ -z "${HYPERTUNNEL_ROOT:-}" ]]; then
  HYPERTUNNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

CONFIG_FILE="${CONFIG_FILE:-${HYPERTUNNEL_ROOT}/config/sni-routing.yaml}"
ENV_FILE="${ENV_FILE:-${HYPERTUNNEL_ROOT}/.env}"
GENERATED_DIR="${GENERATED_DIR:-${HYPERTUNNEL_ROOT}/generated}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${HYPERTUNNEL_ROOT}/templates}"
ASSET_NGINX_DIR="${ASSET_NGINX_DIR:-${HYPERTUNNEL_ROOT}/assets/nginx}"
ASSET_SYSTEMD_DIR="${ASSET_SYSTEMD_DIR:-${HYPERTUNNEL_ROOT}/assets/systemd}"
STATE_DIR="${STATE_DIR:-${HYPERTUNNEL_ROOT}/state}"
BACKUP_ROOT="${BACKUP_ROOT:-${STATE_DIR}/backups}"

now_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

supports_color_fd() {
  local fd="${1:-1}"
  [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -t "$fd" ]]
}

supports_color() {
  if is_true "${FORCE_COLOR:-false}"; then
    return 0
  fi

  if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    return 1
  fi

  if supports_color_fd 1 || supports_color_fd 2; then
    return 0
  fi

  return 1
}

color_text() {
  local _fd="$1"
  local color_code="$2"
  local text="$3"

  if supports_color; then
    printf '\033[%sm%s\033[0m' "$color_code" "$text"
  else
    printf '%s' "$text"
  fi
}

log_info() {
  local level_text
  level_text="$(color_text 1 '32' 'INFO')"
  printf '[%s] [%s] %s\n' "$(now_ts)" "$level_text" "$*"
}

log_warn() {
  local level_text
  level_text="$(color_text 1 '33' 'WARN')"
  printf '[%s] [%s] %s\n' "$(now_ts)" "$level_text" "$*"
}

log_error() {
  local level_text
  level_text="$(color_text 2 '31' 'ERROR')"
  printf '[%s] [%s] %s\n' "$(now_ts)" "$level_text" "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(lower "${1:-}")" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_false() {
  case "$(lower "${1:-}")" in
    0|false|no|off)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

sanitize_name() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//' | tr '[:upper:]' '[:lower:]'
}

assert_port() {
  local value="$1"
  local where="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "${where} 必须是整数端口"
  fi
  if (( value < 1 || value > 65535 )); then
    die "${where} 必须在 1 到 65535 之间"
  fi
}

parse_public_port() {
  local listen="$1"
  local port=""
  if [[ "$listen" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "$listen" == *:* ]]; then
    port="${listen##*:}"
  else
    port="$listen"
  fi
  assert_port "$port" "ingress.public_listen"
  printf '%s' "$port"
}

get_ingress_public_listen() {
  read_yaml_required '.ingress.public_listen' 'ingress.public_listen'
}

get_unknown_sni_action() {
  read_yaml_optional '.ingress.unknown_sni_action' 'reject'
}

has_ingress() {
  local exists
  exists="$(yq e -r '.ingress != null' "$CONFIG_FILE")"
  [[ "$exists" == "true" ]]
}

has_sing_box() {
  local exists
  exists="$(yq e -r '.sing_box != null' "$CONFIG_FILE")"
  [[ "$exists" == "true" ]]
}

count_ingress_reality_backends() {
  if ! has_ingress; then
    printf '0'
    return 0
  fi

  yq e '(.ingress.reality_backends // []) | length' "$CONFIG_FILE"
}

count_ingress_trojan_backends() {
  if ! has_ingress; then
    printf '0'
    return 0
  fi

  yq e '(.ingress.trojan_backends // []) | length' "$CONFIG_FILE"
}

count_sing_box_socks5_backends() {
  if ! has_sing_box; then
    printf '0'
    return 0
  fi

  yq e '(.sing_box.socks5_backends // []) | length' "$CONFIG_FILE"
}

has_sing_box_workload() {
  local reality_count trojan_count socks5_count
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"

  (( reality_count + trojan_count + socks5_count > 0 ))
}

has_egress() {
  local exists
  exists="$(yq e -r '.egress != null' "$CONFIG_FILE")"
  [[ "$exists" == "true" ]]
}

has_explicit_static_site() {
  if ! has_ingress; then
    return 1
  fi

  local exists
  exists="$(yq e -r '.ingress.static_site != null' "$CONFIG_FILE")"
  [[ "$exists" == "true" ]]
}

has_effective_static_site() {
  if has_explicit_static_site; then
    return 0
  fi

  find_first_enabled_fallback_trojan_index >/dev/null 2>&1
}

find_first_enabled_fallback_trojan_index() {
  local trojan_count i enabled
  trojan_count="$(count_ingress_trojan_backends)"

  for (( i = 0; i < trojan_count; i++ )); do
    enabled="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.enabled" 'false')"
    if is_true "$enabled"; then
      printf '%s' "$i"
      return 0
    fi
  done

  return 1
}

get_primary_fallback_trojan_index() {
  local fallback_index
  if fallback_index="$(find_first_enabled_fallback_trojan_index)"; then
    printf '%s' "$fallback_index"
    return 0
  fi

  die 'static_site 缺省时，至少需要一个启用 fallback_site 的 Trojan 后端'
}

get_primary_fallback_trojan_listen_port() {
  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".ingress.trojan_backends[$fallback_index].listen_port" "ingress.trojan_backends[$fallback_index].listen_port"
}

resolve_fallback_site_web_root() {
  local fallback_index="$1"
  local value=""
  value="$(read_yaml_optional ".ingress.trojan_backends[$fallback_index].fallback_site.web_root" '')"

  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if has_explicit_static_site; then
    read_yaml_required '.ingress.static_site.web_root' 'ingress.static_site.web_root'
    return 0
  fi

  die "缺少必填字段: ingress.trojan_backends[$fallback_index].fallback_site.web_root"
}

get_effective_static_site_domain() {
  if has_explicit_static_site; then
    read_yaml_required '.ingress.static_site.domain' 'ingress.static_site.domain'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".ingress.trojan_backends[$fallback_index].servername" "ingress.trojan_backends[$fallback_index].servername"
}

get_effective_static_site_cert_file() {
  if has_explicit_static_site; then
    read_yaml_required '.ingress.static_site.cert_file' 'ingress.static_site.cert_file'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".ingress.trojan_backends[$fallback_index].tls_cert_file" "ingress.trojan_backends[$fallback_index].tls_cert_file"
}

get_effective_static_site_key_file() {
  if has_explicit_static_site; then
    read_yaml_required '.ingress.static_site.key_file' 'ingress.static_site.key_file'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".ingress.trojan_backends[$fallback_index].tls_key_file" "ingress.trojan_backends[$fallback_index].tls_key_file"
}

get_effective_static_site_web_root() {
  if has_explicit_static_site; then
    read_yaml_required '.ingress.static_site.web_root' 'ingress.static_site.web_root'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  resolve_fallback_site_web_root "$fallback_index"
}

get_static_site_domain() {
  get_effective_static_site_domain
}

list_egress_names() {
  if ! has_egress; then
    return 0
  fi

  yq e -r '.egress | keys | .[]' "$CONFIG_FILE"
}

read_named_egress_optional() {
  local egress_name="$1"
  local field="$2"
  local default_value="$3"
  local value

  value="$(EGRESS_NAME="$egress_name" yq e -r ".egress[strenv(EGRESS_NAME)].${field}" "$CONFIG_FILE")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

read_named_egress_required() {
  local egress_name="$1"
  local field="$2"
  local where="$3"
  local value

  value="$(EGRESS_NAME="$egress_name" yq e -r ".egress[strenv(EGRESS_NAME)].${field}" "$CONFIG_FILE")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    die "缺少必填字段: ${where}"
  fi

  printf '%s' "$value"
}

get_egress_type() {
  local egress_name="$1"

  if [[ "$egress_name" == "direct" ]]; then
    printf 'direct'
    return 0
  fi

  read_named_egress_required "$egress_name" 'type' "egress.${egress_name}.type"
}

resolve_backend_egress_name() {
  local expr="$1"
  local where="$2"
  local egress_name

  egress_name="$(read_yaml_optional "$expr" 'direct')"
  if [[ -z "$egress_name" || "$egress_name" == "null" ]]; then
    egress_name='direct'
  fi

  if [[ "$egress_name" == "direct" ]]; then
    printf 'direct'
    return 0
  fi

  get_egress_type "$egress_name" >/dev/null
  printf '%s' "$egress_name"
}

egress_outbound_tag() {
  local egress_name="$1"

  if [[ "$egress_name" == "direct" ]]; then
    printf 'direct-out'
    return 0
  fi

  local safe_name
  safe_name="$(sanitize_name "$egress_name")"
  [[ -n "$safe_name" ]] || die "egress 名称不可用: ${egress_name}"
  printf 'egress-%s-out' "$safe_name"
}

is_local_address() {
  case "${1:-}" in
    127.0.0.1|localhost|::1|[::1])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_local_socks_egress() {
  local egress_name="$1"
  local egress_type egress_server

  egress_type="$(get_egress_type "$egress_name")"
  if [[ "$egress_type" != "socks" ]]; then
    return 1
  fi

  egress_server="$(read_named_egress_required "$egress_name" 'server' "egress.${egress_name}.server")"
  is_local_address "$egress_server"
}

has_warp_egress() {
  if ! has_egress; then
    return 1
  fi

  local warp_type
  warp_type="$(read_named_egress_optional 'warp' 'type' '')"
  [[ -n "$warp_type" && "$warp_type" != "null" ]]
}

has_local_warp_egress() {
  if ! has_warp_egress; then
    return 1
  fi

  is_local_socks_egress 'warp'
}

get_warp_egress_port() {
  read_named_egress_required 'warp' 'port' 'egress.warp.port'
}

backend_uses_named_egress() {
  local target="$1"
  local reality_count trojan_count socks5_count i egress_name

  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"

  for (( i = 0; i < reality_count; i++ )); do
    egress_name="$(resolve_backend_egress_name ".ingress.reality_backends[$i].egress" "ingress.reality_backends[$i].egress")"
    if [[ "$egress_name" == "$target" ]]; then
      return 0
    fi
  done

  for (( i = 0; i < trojan_count; i++ )); do
    egress_name="$(resolve_backend_egress_name ".ingress.trojan_backends[$i].egress" "ingress.trojan_backends[$i].egress")"
    if [[ "$egress_name" == "$target" ]]; then
      return 0
    fi
  done

  for (( i = 0; i < socks5_count; i++ )); do
    egress_name="$(resolve_backend_egress_name ".sing_box.socks5_backends[$i].egress" "sing_box.socks5_backends[$i].egress")"
    if [[ "$egress_name" == "$target" ]]; then
      return 0
    fi
  done

  return 1
}

render_template_file() {
  local template_file="$1"
  local output_file="$2"
  shift 2

  [[ -f "$template_file" ]] || die "模板不存在: $template_file"

  local content
  content="$(cat "$template_file")"

  while [[ "$#" -ge 2 ]]; do
    local key="$1"
    local value="$2"
    content="${content//${key}/${value}}"
    shift 2
  done

  printf '%s\n' "$content" > "$output_file"
}

read_yaml_required() {
  local expr="$1"
  local where="$2"
  local value
  value="$(yq e -r "$expr" "$CONFIG_FILE")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    die "缺少必填字段: $where"
  fi
  printf '%s' "$value"
}

read_yaml_optional() {
  local expr="$1"
  local default_value="$2"
  local value
  value="$(yq e -r "$expr" "$CONFIG_FILE")"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

backup_target_file() {
  local target_file="$1"
  local backup_dir="$2"
  local manifest_file="$3"

  local rel_path="${target_file#/}"
  if [[ -f "$target_file" ]]; then
    mkdir -p "${backup_dir}/$(dirname "$rel_path")"
    cp "$target_file" "${backup_dir}/${rel_path}"
    printf 'backup|%s\n' "$target_file" >> "$manifest_file"
  else
    printf 'new|%s\n' "$target_file" >> "$manifest_file"
  fi
}
