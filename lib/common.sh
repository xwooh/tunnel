#!/usr/bin/env bash

set -o pipefail

if [[ -z "${HYPERTUNNEL_ROOT:-}" ]]; then
  HYPERTUNNEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

CONFIG_FILE="${HYPERTUNNEL_ROOT}/config/sni-routing.yaml"
ENV_FILE="${HYPERTUNNEL_ROOT}/.env"
GENERATED_DIR="${HYPERTUNNEL_ROOT}/generated"
TEMPLATE_DIR="${HYPERTUNNEL_ROOT}/templates"
ASSET_NGINX_DIR="${HYPERTUNNEL_ROOT}/assets/nginx"
ASSET_SYSTEMD_DIR="${HYPERTUNNEL_ROOT}/assets/systemd"
STATE_DIR="${HYPERTUNNEL_ROOT}/state"
BACKUP_ROOT="${STATE_DIR}/backups"

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

has_explicit_static_site() {
  local exists
  exists="$(yq e -r '.static_site != null' "$CONFIG_FILE")"
  [[ "$exists" == "true" ]]
}

find_first_enabled_fallback_trojan_index() {
  local trojan_count i enabled
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < trojan_count; i++ )); do
    enabled="$(read_yaml_optional ".trojan_backends[$i].fallback_site.enabled" 'false')"
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
  read_yaml_required ".trojan_backends[$fallback_index].listen_port" "trojan_backends[$fallback_index].listen_port"
}

resolve_fallback_site_web_root() {
  local fallback_index="$1"
  local value=""
  value="$(read_yaml_optional ".trojan_backends[$fallback_index].fallback_site.web_root" '')"

  if [[ -n "$value" && "$value" != "null" ]]; then
    printf '%s' "$value"
    return 0
  fi

  if has_explicit_static_site; then
    read_yaml_required '.static_site.web_root' 'static_site.web_root'
    return 0
  fi

  die "缺少必填字段: trojan_backends[$fallback_index].fallback_site.web_root"
}

get_effective_static_site_domain() {
  if has_explicit_static_site; then
    read_yaml_required '.static_site.domain' 'static_site.domain'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".trojan_backends[$fallback_index].servername" "trojan_backends[$fallback_index].servername"
}

get_effective_static_site_cert_file() {
  if has_explicit_static_site; then
    read_yaml_required '.static_site.cert_file' 'static_site.cert_file'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".trojan_backends[$fallback_index].tls_cert_file" "trojan_backends[$fallback_index].tls_cert_file"
}

get_effective_static_site_key_file() {
  if has_explicit_static_site; then
    read_yaml_required '.static_site.key_file' 'static_site.key_file'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  read_yaml_required ".trojan_backends[$fallback_index].tls_key_file" "trojan_backends[$fallback_index].tls_key_file"
}

get_effective_static_site_web_root() {
  if has_explicit_static_site; then
    read_yaml_required '.static_site.web_root' 'static_site.web_root'
    return 0
  fi

  local fallback_index
  fallback_index="$(get_primary_fallback_trojan_index)"
  resolve_fallback_site_web_root "$fallback_index"
}

get_static_site_domain() {
  get_effective_static_site_domain
}

get_socks_proxy_port() {
  read_yaml_optional '.egress.socks_proxy.port' '39996'
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
