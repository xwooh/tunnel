#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

acme_bin() {
  local bin_path="${HOME}/.acme.sh/acme.sh"
  [[ -x "$bin_path" ]] || die "未找到 acme.sh: ${bin_path}，请先执行 deps 阶段"
  printf '%s' "$bin_path"
}

collect_cert_triplets() {
  local static_domain static_cert static_key
  static_domain="$(get_effective_static_site_domain)"
  static_cert="$(get_effective_static_site_cert_file)"
  static_key="$(get_effective_static_site_key_file)"

  printf '%s|%s|%s\n' "$static_domain" "$static_cert" "$static_key"

  local trojan_count
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  local i
  for (( i = 0; i < trojan_count; i++ )); do
    local domain cert_file key_file
    domain="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    cert_file="$(read_yaml_required ".trojan_backends[$i].tls_cert_file" "trojan_backends[$i].tls_cert_file")"
    key_file="$(read_yaml_required ".trojan_backends[$i].tls_key_file" "trojan_backends[$i].tls_key_file")"
    printf '%s|%s|%s\n' "$domain" "$cert_file" "$key_file"
  done
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

  [[ -n "${CF_Token:-}" ]] || die "缺少 CF_Token"
  [[ -n "${CF_Zone_ID:-}" ]] || die "缺少 CF_Zone_ID"

  export CF_Token
  export CF_Zone_ID

  local triplets
  triplets="$(collect_cert_triplets | awk '!seen[$0]++')"

  while IFS='|' read -r domain cert_file key_file; do
    [[ -n "$domain" ]] || continue
    issue_and_install_cert "$domain" "$cert_file" "$key_file"
  done <<< "$triplets"

  log_info "证书阶段完成"
}
