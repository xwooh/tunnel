#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"
source "${HYPERTUNNEL_ROOT}/lib/env.sh"

install_apt_packages() {
  log_info "通过 apt 安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive

  local packages=(
    ca-certificates
    curl
    gnupg
    jq
    lsb-release
    openssl
    sudo
  )

  apt-get update
  apt-get install -y "${packages[@]}"
}

install_nginx_if_needed() {
  export DEBIAN_FRONTEND=noninteractive

  if has_ingress; then
    log_info "检测到 ingress 配置，安装 nginx"
    apt-get install -y nginx
  else
    log_info "未配置 ingress，跳过 nginx 安装"
  fi
}

install_yq_v4() {
  local current_version=""
  if command -v yq >/dev/null 2>&1; then
    current_version="$(yq --version 2>/dev/null || true)"
  fi

  if [[ "$current_version" == *"version v4"* ]]; then
    log_info "已安装 yq v4: ${current_version}"
    return 0
  fi

  local arch
  arch="$(dpkg --print-architecture)"

  local yq_arch=""
  case "$arch" in
    amd64)
      yq_arch="amd64"
      ;;
    arm64)
      yq_arch="arm64"
      ;;
    armhf)
      yq_arch="arm"
      ;;
    *)
      die "不支持的 yq 架构: ${arch}"
      ;;
  esac

  local tmp_file
  tmp_file="$(mktemp)"

  log_info "安装 yq v4 二进制: ${yq_arch}"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -o "$tmp_file"
  chmod +x "$tmp_file"
  mv "$tmp_file" /usr/local/bin/yq

  local post_version
  post_version="$(yq --version 2>/dev/null || true)"
  [[ "$post_version" == *"version v4"* ]] || die "安装 yq v4 失败"
}

install_sing_box() {
  if command -v sing-box >/dev/null 2>&1; then
    log_info "已安装 sing-box: $(command -v sing-box)"
    return 0
  fi

  log_info "安装 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash
  command -v sing-box >/dev/null 2>&1 || die "安装 sing-box 失败"
}

sing_box_version_number() {
  sing-box version 2>/dev/null | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {
          print $i
          exit
        }
      }
    }
  '
}

version_gte() {
  local current="$1"
  local required="$2"
  [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | tail -n 1)" == "$current" ]]
}

ensure_sing_box_anytls_support_if_needed() {
  local anytls_count
  anytls_count="$(count_ingress_anytls_backends)"
  (( anytls_count > 0 )) || return 0

  local current_version
  current_version="$(sing_box_version_number)"
  if [[ -n "$current_version" ]] && version_gte "$current_version" '1.12.0'; then
    log_info "sing-box 版本支持 AnyTLS: ${current_version}"
    return 0
  fi

  log_info "AnyTLS 需要 sing-box 1.12.0+，尝试更新 sing-box"
  curl -fsSL https://sing-box.app/install.sh | bash

  current_version="$(sing_box_version_number)"
  [[ -n "$current_version" ]] || die '无法解析 sing-box 版本'
  version_gte "$current_version" '1.12.0' || die "AnyTLS 需要 sing-box 1.12.0+，当前版本: ${current_version}"
  log_info "sing-box 版本支持 AnyTLS: ${current_version}"
}

install_acme_sh() {
  local acme_bin="${HOME}/.acme.sh/acme.sh"
  if [[ -x "$acme_bin" ]]; then
    log_info "已安装 acme.sh: ${acme_bin}"
    return 0
  fi

  [[ -n "${ACME_EMAIL:-}" ]] || die "安装 acme.sh 前必须设置 ACME_EMAIL"

  log_info "安装 acme.sh"
  curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}"
  [[ -x "$acme_bin" ]] || die "安装 acme.sh 失败"
}

install_acme_sh_if_needed() {
  local cert_issue="${ENABLE_CERT_ISSUE:-true}"
  if is_false "$cert_issue"; then
    log_info "根据 ENABLE_CERT_ISSUE=${cert_issue} 跳过 acme.sh 安装"
    return 0
  fi

  local missing_triplets
  missing_triplets="$(collect_missing_cert_triplets)"
  if [[ -z "$missing_triplets" ]]; then
    log_info "当前配置不需要签发证书，跳过 acme.sh 安装"
    return 0
  fi

  ensure_required_env_value "ACME_EMAIL" "请输入 acme.sh 注册邮箱" "false"
  load_env
  install_acme_sh
}

install_dependencies() {
  log_info "开始安装依赖"
  install_apt_packages
  install_yq_v4
  install_nginx_if_needed
  install_sing_box
  ensure_sing_box_anytls_support_if_needed
  install_acme_sh_if_needed
  log_info "依赖安装完成"
}
