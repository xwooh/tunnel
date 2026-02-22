#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

resolve_sing_box_bin() {
  if command -v sing-box >/dev/null 2>&1; then
    command -v sing-box
    return 0
  fi

  die '未找到 sing-box 可执行文件'
}

service_check_configs() {
  local sing_box_bin
  sing_box_bin="$(resolve_sing_box_bin)"

  "$sing_box_bin" check -c /etc/sing-box/config.json
  nginx -t

  log_info '配置校验通过'
}

service_restart() {
  if is_false "${AUTO_RESTART_SERVICES:-true}"; then
    log_info "根据 AUTO_RESTART_SERVICES=${AUTO_RESTART_SERVICES:-false} 跳过服务重启"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable --now sing-box
  systemctl restart nginx

  log_info '服务重启完成'
}

service_status() {
  systemctl --no-pager --full status sing-box | sed -n '1,8p' || true
  systemctl --no-pager --full status nginx | sed -n '1,8p' || true
}

run_service_stage() {
  service_check_configs
  service_restart
  service_status
  log_info '服务阶段完成'
}
