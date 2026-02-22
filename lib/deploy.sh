#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

ensure_generated_files() {
  [[ -f "${GENERATED_DIR}/nginx.conf" ]] || die "缺少生成文件: nginx.conf"
  [[ -f "${GENERATED_DIR}/config.json" ]] || die "缺少生成文件: config.json"
  [[ -f "${GENERATED_DIR}/mihomo-client.yaml" ]] || die "缺少生成文件: mihomo-client.yaml"
  [[ -f "${GENERATED_DIR}/install-socks-proxy.sh" ]] || die "缺少生成文件: install-socks-proxy.sh"
}

has_socks_backends() {
  local reality_count trojan_count i
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    if is_true "$(read_yaml_optional ".reality_backends[$i].use_socks" 'false')"; then
      printf 'true'
      return 0
    fi
  done

  for (( i = 0; i < trojan_count; i++ )); do
    if is_true "$(read_yaml_optional ".trojan_backends[$i].use_socks" 'false')"; then
      printf 'true'
      return 0
    fi
  done

  printf 'false'
}

should_install_warp() {
  local mode needs_socks
  mode="$(lower "${ENABLE_WARP_INSTALL:-auto}")"
  needs_socks="$(has_socks_backends)"

  case "$mode" in
    true|1|yes|on)
      printf 'true'
      ;;
    false|0|no|off)
      printf 'false'
      ;;
    auto)
      if is_true "$needs_socks"; then
        printf 'true'
      else
        printf 'false'
      fi
      ;;
    *)
      die "ENABLE_WARP_INSTALL 只能是 auto/true/false"
      ;;
  esac
}

is_warp_installed() {
  if command -v warp-cli >/dev/null 2>&1; then
    return 0
  fi

  if command -v dpkg >/dev/null 2>&1; then
    dpkg -s cloudflare-warp >/dev/null 2>&1 && return 0
  fi

  return 1
}

deploy_generated_files() {
  local web_root
  web_root="$(read_yaml_required '.static_site.web_root' 'static_site.web_root')"

  mkdir -p /etc/nginx /etc/sing-box /etc/systemd/system "$web_root" /root

  install -m 644 "${GENERATED_DIR}/nginx.conf" /etc/nginx/nginx.conf
  install -m 644 "${GENERATED_DIR}/config.json" /etc/sing-box/config.json
  install -m 644 "${ASSET_SYSTEMD_DIR}/sing-box.service" /etc/systemd/system/sing-box.service
  install -m 755 "${GENERATED_DIR}/install-socks-proxy.sh" /root/install-socks-proxy.sh

  shopt -s nullglob
  local html
  for html in "${ASSET_NGINX_DIR}"/*.html; do
    install -m 644 "$html" "${web_root}/$(basename "$html")"
  done
  shopt -u nullglob

  log_info "部署文件已复制到系统目录"
}

create_backup_snapshot() {
  local web_root backup_id backup_dir manifest_file
  web_root="$(read_yaml_required '.static_site.web_root' 'static_site.web_root')"

  backup_id="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="${BACKUP_ROOT}/${backup_id}"
  manifest_file="${backup_dir}/manifest.txt"

  mkdir -p "$backup_dir"
  : > "$manifest_file"

  backup_target_file "/etc/nginx/nginx.conf" "$backup_dir" "$manifest_file"
  backup_target_file "/etc/sing-box/config.json" "$backup_dir" "$manifest_file"
  backup_target_file "/etc/systemd/system/sing-box.service" "$backup_dir" "$manifest_file"
  backup_target_file "/root/install-socks-proxy.sh" "$backup_dir" "$manifest_file"

  shopt -s nullglob
  local html
  for html in "${ASSET_NGINX_DIR}"/*.html; do
    backup_target_file "${web_root}/$(basename "$html")" "$backup_dir" "$manifest_file"
  done
  shopt -u nullglob

  printf '%s\n' "$backup_id" > "${STATE_DIR}/last-backup"
  log_info "已创建备份: ${backup_id}"
}

run_warp_installer_if_needed() {
  if ! is_true "$(should_install_warp)"; then
    log_info "跳过 WARP 安装"
    return 0
  fi

  if is_warp_installed; then
    log_info "检测到 WARP 已安装，跳过安装脚本"
    return 0
  fi

  log_info "执行 WARP socks 安装脚本"
  bash "${GENERATED_DIR}/install-socks-proxy.sh"
}

deploy_all() {
  require_cmd yq
  ensure_generated_files

  create_backup_snapshot
  deploy_generated_files
  run_warp_installer_if_needed

  log_info "部署阶段完成"
}

rollback_deployment() {
  local backup_id="$1"
  [[ -n "$backup_id" ]] || die 'rollback 需要提供备份 ID'

  local backup_dir manifest_file
  backup_dir="${BACKUP_ROOT}/${backup_id}"
  manifest_file="${backup_dir}/manifest.txt"

  [[ -d "$backup_dir" ]] || die "未找到备份目录: ${backup_dir}"
  [[ -f "$manifest_file" ]] || die "未找到备份清单: ${manifest_file}"

  while IFS='|' read -r action target_file; do
    [[ -n "$target_file" ]] || continue

    case "$action" in
      backup)
        local src
        src="${backup_dir}/${target_file#/}"
        if [[ -f "$src" ]]; then
          mkdir -p "$(dirname "$target_file")"
          cp "$src" "$target_file"
          log_info "已恢复文件: ${target_file}"
        else
          log_warn "备份源文件不存在，跳过恢复: ${target_file}"
        fi
        ;;
      new)
        if [[ -f "$target_file" ]]; then
          rm -f "$target_file"
          log_info "已删除新增文件: ${target_file}"
        fi
        ;;
      *)
        log_warn "未知清单项，跳过处理: ${action} ${target_file}"
        ;;
    esac
  done < "$manifest_file"

  log_info "回滚完成: ${backup_id}"
}

list_backup_snapshots() {
  mkdir -p "$BACKUP_ROOT"

  local latest_backup=""
  if [[ -f "${STATE_DIR}/last-backup" ]]; then
    latest_backup="$(tr -d ' \n\r' < "${STATE_DIR}/last-backup")"
  fi

  local backups=()
  local dir
  for dir in "${BACKUP_ROOT}"/*; do
    [[ -d "$dir" ]] || continue
    backups+=("$(basename "$dir")")
  done

  if (( ${#backups[@]} == 0 )); then
    log_info "当前没有可用备份"
    return 0
  fi

  log_info "可用备份列表:"
  local backup_id
  while IFS= read -r backup_id; do
    [[ -n "$backup_id" ]] || continue
    if [[ "$backup_id" == "$latest_backup" ]]; then
      printf '%s\n' "${backup_id} (最近一次)"
    else
      printf '%s\n' "$backup_id"
    fi
  done < <(printf '%s\n' "${backups[@]}" | sort -r)
}
