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

resolve_probe_target() {
  local candidate
  candidate="$(read_yaml_optional '.ingress.reality_backends[0].server' '')"
  if [[ -n "$candidate" && "$candidate" != "null" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="$(read_yaml_optional '.ingress.trojan_backends[0].server' '')"
  if [[ -n "$candidate" && "$candidate" != "null" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  printf '127.0.0.1'
}

check_static_site_http() {
  local domain public_port probe_target
  domain="$(get_effective_static_site_domain)"
  public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  probe_target="$(resolve_probe_target)"

  # Keep the original URL host and SNI while steering the TCP connection
  # to the ingress entrypoint configured for client access.
  curl --silent --show-error --insecure --max-time 20 \
    --connect-to "${domain}:${public_port}:${probe_target}:${public_port}" \
    "https://${domain}/" \
    -o /dev/null
}

check_sni_handshake() {
  local servername="$1"
  local public_port probe_target
  public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  probe_target="$(resolve_probe_target)"

  bash -c "echo | openssl s_client -connect '${probe_target}:${public_port}' -servername '${servername}' -brief >/dev/null 2>&1"
}

check_listener_port() {
  local port="$1"
  ss -ltn | grep -qE "[:.]${port}[[:space:]]"
}

check_local_warp_listener_if_needed() {
  if ! backend_uses_named_egress 'warp'; then
    return 0
  fi

  if ! has_local_warp_egress; then
    return 0
  fi

  local socks_port
  socks_port="$(get_warp_egress_port)"
  check_listener_port "$socks_port"
}

check_socks5_backend_listener() {
  local listen_port="$1"
  check_listener_port "$listen_port"
}

run_verify_stage() {
  require_cmd yq
  require_cmd ss

  if has_ingress; then
    require_cmd openssl
  fi

  if has_effective_static_site; then
    require_cmd curl
    run_check '静态域名 HTTPS 响应' check_static_site_http
  elif has_ingress; then
    log_info '跳过静态域名 HTTPS 响应检查：当前未配置静态站'
  fi

  local reality_count trojan_count socks5_count i servername
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"

  for (( i = 0; i < reality_count; i++ )); do
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "ingress.reality_backends[$i].servername")"
    run_check "Reality SNI 握手 ${servername}" check_sni_handshake "$servername"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    run_check "Trojan SNI 握手 ${servername}" check_sni_handshake "$servername"
  done

  for (( i = 0; i < socks5_count; i++ )); do
    local name listen_port
    name="$(read_yaml_required ".sing_box.socks5_backends[$i].name" "sing_box.socks5_backends[$i].name")"
    listen_port="$(read_yaml_required ".sing_box.socks5_backends[$i].listen_port" "sing_box.socks5_backends[$i].listen_port")"
    run_check "SOCKS5 监听 ${name}" check_socks5_backend_listener "$listen_port"
  done

  run_check 'WARP 本地监听检查（使用 egress.warp 时）' check_local_warp_listener_if_needed

  if (( VERIFY_FAILURES > 0 )); then
    die "验证失败: ${VERIFY_FAILURES} 项检查未通过"
  fi

  log_info '验证阶段完成'
}
