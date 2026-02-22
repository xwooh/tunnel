#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

assert_root_user() {
  if (( EUID != 0 )); then
    die "请使用 root 用户运行此脚本"
  fi
}

assert_supported_os() {
  [[ -f /etc/os-release ]] || die "无法识别操作系统"

  source /etc/os-release
  local os_id="${ID:-}"

  case "$os_id" in
    ubuntu|debian)
      ;;
    *)
      die "不支持的系统: ${os_id}，仅支持 Ubuntu/Debian"
      ;;
  esac

  log_info "检测到支持的系统: ${os_id}"
}

assert_required_paths() {
  [[ -f "$CONFIG_FILE" ]] || die "必须提供配置文件: ${CONFIG_FILE}"

  [[ -f "${TEMPLATE_DIR}/nginx.conf.tpl" ]] || die "缺少模板: nginx.conf.tpl"
  [[ -f "${TEMPLATE_DIR}/sing-box.config.json.tpl" ]] || die "缺少模板: sing-box.config.json.tpl"
  [[ -f "${TEMPLATE_DIR}/mihomo-client.yaml.tpl" ]] || die "缺少模板: mihomo-client.yaml.tpl"
  [[ -f "${TEMPLATE_DIR}/install-socks-proxy.sh.tpl" ]] || die "缺少模板: install-socks-proxy.sh.tpl"

  [[ -f "${ASSET_SYSTEMD_DIR}/sing-box.service" ]] || die "缺少 systemd 服务文件"

  shopt -s nullglob
  local html_files=("${ASSET_NGINX_DIR}"/*.html)
  shopt -u nullglob
  (( ${#html_files[@]} > 0 )) || die "未找到 HTML 静态文件: ${ASSET_NGINX_DIR}"

  mkdir -p "$GENERATED_DIR" "$BACKUP_ROOT"
}

assert_basic_commands() {
  require_cmd bash
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd curl
}

preflight_check() {
  log_info "开始执行预检"
  assert_root_user
  assert_supported_os
  assert_required_paths
  assert_basic_commands
  log_info "预检通过"
}
