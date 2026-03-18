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
  if has_sing_box_workload; then
    local sing_box_bin
    sing_box_bin="$(resolve_sing_box_bin)"
    "$sing_box_bin" check -c /etc/sing-box/config.json
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
    systemctl enable --now sing-box
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
