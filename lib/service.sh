#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

resolve_sing_box_bin() {
  if command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
    return 0
  fi

  die '未找到 sing-box 可执行文件'
}

resolve_warp_cli_bin() {
  if command -v warp-cli >/dev/null 2>&1; then
    command -v warp-cli
    return 0
  fi

  die '未找到 warp-cli 可执行文件'
}

has_local_warp_workload() {
  if ! has_local_warp_egress; then
    return 1
  fi

  backend_uses_named_egress 'warp'
}

ensure_warp_registration() {
  local warp_cli_bin="$1"

  if "$warp_cli_bin" --accept-tos registration show >/dev/null 2>&1; then
    return 0
  fi

  "$warp_cli_bin" --accept-tos registration new
}

wait_for_warp_daemon() {
  local warp_cli_bin="$1"
  local output=""
  local attempt

  for (( attempt = 1; attempt <= 20; attempt++ )); do
    if output="$("$warp_cli_bin" --accept-tos status 2>&1)"; then
      return 0
    fi

    if [[ "$output" != *"Unable to connect to the CloudflareWARP daemon"* ]] &&
      [[ "$output" != *"Maybe the daemon is not running"* ]]; then
      return 0
    fi

    sleep 1
  done

  [[ -z "$output" ]] || printf '%s\n' "$output" >&2
  systemctl --no-pager --full status warp-svc | sed -n '1,20p' >&2 || true
  die 'WARP daemon did not become ready after restart'
}

service_check_configs() {
  if has_sing_box_workload; then
    local sing_box_bin
    sing_box_bin="$(resolve_sing_box_bin)"
    "$sing_box_bin" check -c /etc/sing-box/config.json
  fi

  if has_local_warp_workload; then
    resolve_warp_cli_bin >/dev/null
  fi

  if has_ingress; then
    nginx -t
  fi

  log_info '配置校验通过'
}

service_restart() {
  if is_false "${AUTO_RESTART_SERVICES:-true}"; then
    log_info "根据 AUTO_RESTART_SERVICES=${AUTO_RESTART_SERVICES:-false} 跳过服务重启"
    return 0
  fi

  if has_sing_box_workload; then
    systemctl daemon-reload
    systemctl restart sing-box
  fi

  if has_local_warp_workload; then
    local warp_cli_bin warp_port
    warp_cli_bin="$(resolve_warp_cli_bin)"
    warp_port="$(get_warp_egress_port)"

    systemctl enable warp-svc
    systemctl restart warp-svc
    wait_for_warp_daemon "$warp_cli_bin"
    ensure_warp_registration "$warp_cli_bin"
    "$warp_cli_bin" --accept-tos mode proxy
    "$warp_cli_bin" --accept-tos proxy port "$warp_port"
    "$warp_cli_bin" --accept-tos connect
  fi

  if has_ingress; then
    systemctl restart nginx
  fi

  log_info '服务重启完成'
}

service_status() {
  if has_sing_box_workload; then
    systemctl --no-pager --full status sing-box | sed -n '1,8p' || true
  fi

  if has_local_warp_workload; then
    systemctl --no-pager --full status warp-svc | sed -n '1,8p' || true
  fi

  if has_ingress; then
    systemctl --no-pager --full status nginx | sed -n '1,8p' || true
  fi
}

run_service_stage() {
  service_check_configs
  service_restart
  service_status
  log_info '服务阶段完成'
}
