#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"
source "${HYPERTUNNEL_ROOT}/lib/env.sh"

acme_bin() {
  local bin_path="${HOME}/.acme.sh/acme.sh"
  [[ -x "$bin_path" ]] || die "未找到 acme.sh: ${bin_path}，请先执行 deps 阶段"
  printf '%s' "$bin_path"
}

issue_and_install_cert() {
  local domain="$1"
  local cert_file="$2"
  local key_file="$3"
  local acme
  acme="$(acme_bin)"

  if [[ -s "$cert_file" && -s "$key_file" ]]; then
    log_info "证书文件已存在，跳过签发: ${domain}"
    return 0
  fi

  mkdir -p "$(dirname "$cert_file")" "$(dirname "$key_file")"

  log_info "开始签发证书: ${domain}"
  "$acme" --set-default-ca --server letsencrypt
  "$acme" --issue --dns dns_cf -d "$domain"

  log_info "安装证书文件: ${domain} ${cert_file} ${key_file}"
  "$acme" --install-cert -d "$domain" \
    --key-file "$key_file" \
    --fullchain-file "$cert_file" \
    --reloadcmd "systemctl reload nginx || true"
}

run_cert_stage() {
  local cert_issue="${ENABLE_CERT_ISSUE:-true}"
  if is_false "$cert_issue"; then
    log_info "根据 ENABLE_CERT_ISSUE=${cert_issue} 跳过证书阶段"
    return 0
  fi

  require_cmd yq

  local missing_triplets
  missing_triplets="$(collect_missing_cert_triplets)"

  if [[ -z "$missing_triplets" ]]; then
    log_info '当前配置不需要签发证书，跳过证书阶段'
    return 0
  fi

  ensure_required_env_value "CF_Token" "请输入 Cloudflare API Token" "true"
  ensure_required_env_value "CF_Zone_ID" "请输入 Cloudflare Zone ID" "true"
  load_env

  export CF_Token
  export CF_Zone_ID

  while IFS='|' read -r domain cert_file key_file; do
    [[ -n "$domain" ]] || continue
    issue_and_install_cert "$domain" "$cert_file" "$key_file"
  done <<< "$missing_triplets"

  log_info "证书阶段完成"
}
