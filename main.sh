#!/usr/bin/env bash

set -euo pipefail

HYPERTUNNEL_ROOT="$(cd "$(dirname "$0")" && pwd)"
export HYPERTUNNEL_ROOT

source "${HYPERTUNNEL_ROOT}/lib/common.sh"
source "${HYPERTUNNEL_ROOT}/lib/preflight.sh"
source "${HYPERTUNNEL_ROOT}/lib/env.sh"
source "${HYPERTUNNEL_ROOT}/lib/deps.sh"
source "${HYPERTUNNEL_ROOT}/lib/cert.sh"
source "${HYPERTUNNEL_ROOT}/lib/render.sh"
source "${HYPERTUNNEL_ROOT}/lib/deploy.sh"
source "${HYPERTUNNEL_ROOT}/lib/service.sh"
source "${HYPERTUNNEL_ROOT}/lib/verify.sh"
source "${HYPERTUNNEL_ROOT}/lib/nearby.sh"

usage() {
  cat <<USAGE
用法: ./main.sh <命令>

命令:
  all            执行完整流程: preflight -> env -> deps -> cert -> render -> deploy -> service -> verify
  preflight      校验系统、权限和必需文件
  env            加载 .env，并交互补全缺失的敏感参数
  deps           安装 apt 依赖、yq、sing-box 和 acme.sh
  cert           按 sni-routing.yaml 申请并安装证书
  render         生成 nginx/sing-box/mihomo/socks 文件到 generated/
  deploy         备份系统现有文件并部署生成产物
  service        校验配置并重启服务
  verify         执行连通性与握手验证
  nearby         下载/缓存 rift 并扫描附近域名连通性
  rollback list  查看可用备份列表
  rollback ID    按备份 ID 回滚部署
  help           显示帮助
USAGE
}

run_all() {
  preflight_check
  setup_env
  install_dependencies
  run_cert_stage
  render_all
  deploy_all
  run_service_stage
  run_verify_stage
  log_info '全部阶段执行完成'
}

command_name="${1:-all}"

case "$command_name" in
  all)
    run_all
    ;;
  preflight)
    preflight_check
    ;;
  env)
    preflight_check
    setup_env
    ;;
  deps)
    preflight_check
    setup_env
    install_dependencies
    ;;
  cert)
    preflight_check
    setup_env
    run_cert_stage
    ;;
  render)
    render_all
    ;;
  deploy)
    preflight_check
    setup_env
    deploy_all
    ;;
  service)
    preflight_check
    setup_env
    run_service_stage
    ;;
  verify)
    preflight_check
    run_verify_stage
    ;;
  nearby)
    run_nearby_scan "${@:2}"
    ;;
  rollback)
    preflight_check
    backup_id="${2:-}"
    if [[ "$backup_id" == "list" ]]; then
      list_backup_snapshots
    elif [[ -n "$backup_id" ]]; then
      rollback_deployment "$backup_id"
    else
      die '请提供备份 ID，或使用 ./main.sh rollback list 查看列表'
    fi
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "未知命令: ${command_name}"
    ;;
esac
