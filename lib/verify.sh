#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

VERIFY_FAILURES=0

run_check() {
  local title="$1"
  shift

  if "$@"; then
    log_info "检查通过: ${title}"
  else
    log_error "检查失败: ${title}"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

resolve_probe_ip() {
  local candidate
  candidate="$(read_yaml_optional '.reality_backends[0].server' '')"
  if [[ -n "$candidate" && "$candidate" != "null" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="$(read_yaml_optional '.trojan_backends[0].server' '')"
  if [[ -n "$candidate" && "$candidate" != "null" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  printf '127.0.0.1'
}

check_static_site_http() {
  local domain public_port probe_ip
  domain="$(get_static_site_domain)"
  public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  probe_ip="$(resolve_probe_ip)"

  curl --silent --show-error --insecure --max-time 20 \
    --resolve "${domain}:${public_port}:${probe_ip}" \
    "https://${domain}/" \
    -o /dev/null
}

check_sni_handshake() {
  local servername="$1"
  local public_port probe_ip
  public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  probe_ip="$(resolve_probe_ip)"

  bash -c "echo | openssl s_client -connect '${probe_ip}:${public_port}' -servername '${servername}' -brief >/dev/null 2>&1"
}

check_socks_listener_if_needed() {
  local socks_needed="false"
  local reality_count trojan_count i
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    if is_true "$(read_yaml_optional ".reality_backends[$i].use_socks" 'false')"; then
      socks_needed="true"
      break
    fi
  done

  if is_false "$socks_needed"; then
    for (( i = 0; i < trojan_count; i++ )); do
      if is_true "$(read_yaml_optional ".trojan_backends[$i].use_socks" 'false')"; then
        socks_needed="true"
        break
      fi
    done
  fi

  if is_false "$socks_needed"; then
    return 0
  fi

  local socks_port
  socks_port="$(get_socks_proxy_port)"

  ss -ltn | grep -qE "[:.]${socks_port}[[:space:]]"
}

run_verify_stage() {
  require_cmd yq
  require_cmd openssl
  require_cmd curl

  run_check '静态域名 HTTPS 响应' check_static_site_http

  local reality_count trojan_count i servername
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    servername="$(read_yaml_required ".reality_backends[$i].servername" "reality_backends[$i].servername")"
    run_check "Reality SNI 握手 ${servername}" check_sni_handshake "$servername"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    servername="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    run_check "Trojan SNI 握手 ${servername}" check_sni_handshake "$servername"
  done

  run_check 'SOCKS 监听检查（启用 use_socks 时）' check_socks_listener_if_needed

  if (( VERIFY_FAILURES > 0 )); then
    die "验证失败: ${VERIFY_FAILURES} 项检查未通过"
  fi

  log_info '验证阶段完成'
}
