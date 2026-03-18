#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

normalize_bool() {
  local value="$1"
  local where="$2"

  if is_true "$value"; then
    printf 'true'
    return 0
  fi
  if is_false "$value" || [[ -z "$value" || "$value" == "null" ]]; then
    printf 'false'
    return 0
  fi

  die "${where} 必须是布尔值"
}

validate_unique_bindings() {
  local socks_proxy_port
  socks_proxy_port="$(get_socks_proxy_port)"

  assert_port "$socks_proxy_port" 'egress.socks_proxy.port'

  if has_explicit_static_site; then
    local static_domain static_port
    static_domain="$(read_yaml_required '.static_site.domain' 'static_site.domain')"
    static_port="$(read_yaml_required '.static_site.listen_port' 'static_site.listen_port')"
    assert_port "$static_port" 'static_site.listen_port'
  else
    get_effective_static_site_domain >/dev/null
    get_effective_static_site_web_root >/dev/null
    get_effective_static_site_cert_file >/dev/null
    get_effective_static_site_key_file >/dev/null
  fi

  local reality_count trojan_count
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"
  if (( reality_count + trojan_count == 0 )); then
    die 'reality_backends 或 trojan_backends 至少需要配置一个后端'
  fi

  local unknown_sni_action
  unknown_sni_action="$(lower "$(get_unknown_sni_action)")"
  case "$unknown_sni_action" in
    reject|blackhole|fallback_static)
      ;;
    *)
      die 'ingress.unknown_sni_action 只能是: reject, blackhole, fallback_static'
      ;;
  esac

  # Bash 3 on macOS does not support associative arrays; keep a simple
  # tab-separated key/value table to track duplicate bindings.
  local seen_servernames=''
  local seen_ports=''

  lookup_seen_binding() {
    local table="$1"
    local key="$2"
    awk -F '\t' -v target="$key" '$1 == target { print $2; exit }' <<< "$table"
  }

  add_seen_binding() {
    local var_name="$1"
    local key="$2"
    local value="$3"
    local table="${!var_name}"
    if [[ -n "$table" ]]; then
      table+=$'\n'
    fi
    table+="${key}"$'\t'"${value}"
    printf -v "$var_name" '%s' "$table"
  }

  if has_explicit_static_site; then
    local static_domain static_port
    static_domain="$(read_yaml_required '.static_site.domain' 'static_site.domain')"
    static_port="$(read_yaml_required '.static_site.listen_port' 'static_site.listen_port')"
    add_seen_binding seen_servernames "$static_domain" 'static_site.domain'
    add_seen_binding seen_ports "$static_port" 'static_site.listen_port'
  fi

  local duplicated_port
  duplicated_port="$(lookup_seen_binding "$seen_ports" "$socks_proxy_port")"
  if [[ -n "$duplicated_port" ]]; then
    die "egress.socks_proxy.port 端口冲突: ${socks_proxy_port}，已被 ${duplicated_port} 使用"
  fi
  add_seen_binding seen_ports "$socks_proxy_port" 'egress.socks_proxy.port'

  local i
  for (( i = 0; i < reality_count; i++ )); do
    local where servername listen_port
    where="reality_backends[$i]"
    servername="$(read_yaml_required ".reality_backends[$i].servername" "${where}.servername")"
    listen_port="$(read_yaml_required ".reality_backends[$i].listen_port" "${where}.listen_port")"
    assert_port "$listen_port" "${where}.listen_port"

    local duplicated_servername duplicated_listen_port
    duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$servername")"
    if [[ -n "$duplicated_servername" ]]; then
      die "${where} 的 SNI 域名重复: ${servername}，已被 ${duplicated_servername} 使用"
    fi
    add_seen_binding seen_servernames "$servername" "$where"

    duplicated_listen_port="$(lookup_seen_binding "$seen_ports" "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_binding seen_ports "$listen_port" "$where"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local where servername listen_port fallback_enabled fallback_port
    where="trojan_backends[$i]"
    servername="$(read_yaml_required ".trojan_backends[$i].servername" "${where}.servername")"
    listen_port="$(read_yaml_required ".trojan_backends[$i].listen_port" "${where}.listen_port")"
    assert_port "$listen_port" "${where}.listen_port"

    local duplicated_servername duplicated_listen_port
    duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$servername")"
    if [[ -n "$duplicated_servername" ]]; then
      die "${where} 的 SNI 域名重复: ${servername}，已被 ${duplicated_servername} 使用"
    fi
    add_seen_binding seen_servernames "$servername" "$where"

    duplicated_listen_port="$(lookup_seen_binding "$seen_ports" "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_binding seen_ports "$listen_port" "$where"

    fallback_enabled="$(normalize_bool "$(read_yaml_optional ".trojan_backends[$i].fallback_site.enabled" 'false')" "${where}.fallback_site.enabled")"
    if is_true "$fallback_enabled"; then
      resolve_fallback_site_web_root "$i" >/dev/null
      fallback_port="$(read_yaml_optional ".trojan_backends[$i].fallback_site.listen_port" '37980')"
      assert_port "$fallback_port" "${where}.fallback_site.listen_port"
      local duplicated_fallback_port
      duplicated_fallback_port="$(lookup_seen_binding "$seen_ports" "$fallback_port")"
      if [[ -n "$duplicated_fallback_port" ]]; then
        die "${where}.fallback_site.listen_port 端口重复: ${fallback_port}，已被 ${duplicated_fallback_port} 使用"
      fi
      add_seen_binding seen_ports "$fallback_port" "${where}.fallback_site.listen_port"
    fi
  done
}

default_backend_value() {
  local action
  action="$(lower "$(get_unknown_sni_action)")"

  case "$action" in
    fallback_static)
      if has_explicit_static_site; then
        local static_host static_port
        static_host="$(read_yaml_required '.static_site.listen_host' 'static_site.listen_host')"
        static_port="$(read_yaml_required '.static_site.listen_port' 'static_site.listen_port')"
        printf '%s:%s' "$static_host" "$static_port"
      else
        local trojan_listen_port
        trojan_listen_port="$(get_primary_fallback_trojan_listen_port)"
        assert_port "$trojan_listen_port" "trojan_backends[$(get_primary_fallback_trojan_index)].listen_port"
        printf '127.0.0.1:%s' "$trojan_listen_port"
      fi
      ;;
    blackhole)
      printf '127.0.0.1:9'
      ;;
    *)
      printf '127.0.0.1:65535'
      ;;
  esac
}

render_nginx_config() {
  local nginx_public_listen
  nginx_public_listen="$(get_ingress_public_listen)"
  local map_entries=""
  local static_server_block=""

  if has_explicit_static_site; then
    local static_host static_port static_domain static_cert static_key static_web_root
    static_host="$(read_yaml_required '.static_site.listen_host' 'static_site.listen_host')"
    static_port="$(read_yaml_required '.static_site.listen_port' 'static_site.listen_port')"
    static_domain="$(read_yaml_required '.static_site.domain' 'static_site.domain')"
    static_cert="$(read_yaml_required '.static_site.cert_file' 'static_site.cert_file')"
    static_key="$(read_yaml_required '.static_site.key_file' 'static_site.key_file')"
    static_web_root="$(read_yaml_required '.static_site.web_root' 'static_site.web_root')"
    map_entries="        ${static_domain} ${static_host}:${static_port};"

    static_server_block=$(cat <<BLOCK
    server {
        listen ${static_host}:${static_port} ssl;
        server_name ${static_domain};

        ssl_certificate ${static_cert};
        ssl_certificate_key ${static_key};
        ssl_session_cache shared:SSL:20m;
        ssl_session_timeout 10m;
        ssl_protocols TLSv1.2 TLSv1.3;

        root ${static_web_root};
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
BLOCK
)
  fi

  local reality_count trojan_count i
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    local servername listen_port
    servername="$(read_yaml_required ".reality_backends[$i].servername" "reality_backends[$i].servername")"
    listen_port="$(read_yaml_required ".reality_backends[$i].listen_port" "reality_backends[$i].listen_port")"
    if [[ -n "$map_entries" ]]; then
      map_entries+=$'\n'
    fi
    map_entries+="        ${servername} 127.0.0.1:${listen_port};"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local servername listen_port
    servername="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    listen_port="$(read_yaml_required ".trojan_backends[$i].listen_port" "trojan_backends[$i].listen_port")"
    if [[ -n "$map_entries" ]]; then
      map_entries+=$'\n'
    fi
    map_entries+="        ${servername} 127.0.0.1:${listen_port};"
  done

  local trojan_fallback_blocks=""
  for (( i = 0; i < trojan_count; i++ )); do
    local enabled servername fallback_host fallback_port fallback_web_root block
    enabled="$(normalize_bool "$(read_yaml_optional ".trojan_backends[$i].fallback_site.enabled" 'false')" "trojan_backends[$i].fallback_site.enabled")"
    if ! is_true "$enabled"; then
      continue
    fi

    servername="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    fallback_host="$(read_yaml_optional ".trojan_backends[$i].fallback_site.listen_host" '127.0.0.1')"
    fallback_port="$(read_yaml_optional ".trojan_backends[$i].fallback_site.listen_port" '37980')"
    fallback_web_root="$(resolve_fallback_site_web_root "$i")"

    block=$(cat <<BLOCK
    server {
        listen ${fallback_host}:${fallback_port};
        server_name ${servername};

        root ${fallback_web_root};
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
BLOCK
)

    if [[ -n "$trojan_fallback_blocks" ]]; then
      trojan_fallback_blocks+=$'\n\n'
    fi
    trojan_fallback_blocks+="$block"
  done

  render_template_file \
    "${TEMPLATE_DIR}/nginx.conf.tpl" \
    "${GENERATED_DIR}/nginx.conf" \
    '__MAP_ENTRIES__' "$map_entries" \
    '__DEFAULT_BACKEND__' "$(default_backend_value)" \
    '__NGINX_PUBLIC_LISTEN__' "$nginx_public_listen" \
    '__STATIC_SERVER_BLOCK__' "$static_server_block" \
    '__TROJAN_FALLBACK_SERVER_BLOCK__' "$trojan_fallback_blocks"

  log_info "已生成 nginx 配置: ${GENERATED_DIR}/nginx.conf"
}

render_sing_box_config() {
  local socks_proxy_port
  socks_proxy_port="$(get_socks_proxy_port)"
  assert_port "$socks_proxy_port" 'egress.socks_proxy.port'

  local inbounds_json='[]'
  local socks_route_inbounds='[]'

  local reality_count trojan_count i
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    local name safe_name inbound_tag user_name short_id_raw short_id_list
    local listen_port user_uuid servername handshake_server handshake_port private_key use_socks

    name="$(read_yaml_required ".reality_backends[$i].name" "reality_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((i + 1))"

    inbound_tag="${safe_name}-vless-in"
    user_name="${safe_name}-vless-user"

    listen_port="$(read_yaml_required ".reality_backends[$i].listen_port" "reality_backends[$i].listen_port")"
    user_uuid="$(read_yaml_required ".reality_backends[$i].user_uuid" "reality_backends[$i].user_uuid")"
    servername="$(read_yaml_required ".reality_backends[$i].servername" "reality_backends[$i].servername")"
    handshake_server="$(read_yaml_required ".reality_backends[$i].handshake_server" "reality_backends[$i].handshake_server")"
    handshake_port="$(read_yaml_required ".reality_backends[$i].port" "reality_backends[$i].port")"
    private_key="$(read_yaml_required ".reality_backends[$i].private_key" "reality_backends[$i].private_key")"
    use_socks="$(normalize_bool "$(read_yaml_optional ".reality_backends[$i].use_socks" 'false')" "reality_backends[$i].use_socks")"

    assert_port "$listen_port" "reality_backends[$i].listen_port"
    assert_port "$handshake_port" "reality_backends[$i].port"

    short_id_raw="$(yq e -o=json ".reality_backends[$i].short_id" "$CONFIG_FILE")"
    short_id_list="$(jq -c '
      if type == "array" then
        [ .[] | tostring | select(length > 0) ]
      elif . == null then
        []
      else
        [ tostring ]
      end
    ' <<< "$short_id_raw")"

    if [[ "$(jq 'length' <<< "$short_id_list")" -eq 0 ]]; then
      die "reality_backends[$i].short_id 不能为空"
    fi

    local inbound_obj
    inbound_obj="$(jq -n \
      --arg tag "$inbound_tag" \
      --arg user_name "$user_name" \
      --arg uuid "$user_uuid" \
      --arg server_name "$servername" \
      --arg handshake_server "$handshake_server" \
      --arg private_key "$private_key" \
      --argjson listen_port "$listen_port" \
      --argjson handshake_port "$handshake_port" \
      --argjson short_id "$short_id_list" \
      '{
        type: "vless",
        tag: $tag,
        listen: "127.0.0.1",
        listen_port: $listen_port,
        users: [
          {
            name: $user_name,
            uuid: $uuid,
            flow: "xtls-rprx-vision"
          }
        ],
        tls: {
          enabled: true,
          server_name: $server_name,
          reality: {
            enabled: true,
            handshake: {
              server: $handshake_server,
              server_port: $handshake_port
            },
            private_key: $private_key,
            short_id: $short_id
          }
        }
      }')"

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    if is_true "$use_socks"; then
      socks_route_inbounds="$(jq -c --arg tag "$inbound_tag" '. + [$tag]' <<< "$socks_route_inbounds")"
    fi
  done

  local trojan_offset
  trojan_offset="$reality_count"

  for (( i = 0; i < trojan_count; i++ )); do
    local idx name safe_name inbound_tag user_name
    local listen_port password servername cert_path key_path use_socks
    local fallback_enabled fallback_host fallback_port

    idx=$((trojan_offset + i + 1))
    name="$(read_yaml_required ".trojan_backends[$i].name" "trojan_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-${idx}"

    inbound_tag="${safe_name}-trojan-in"
    user_name="${safe_name}-trojan-user"

    listen_port="$(read_yaml_required ".trojan_backends[$i].listen_port" "trojan_backends[$i].listen_port")"
    password="$(read_yaml_required ".trojan_backends[$i].password" "trojan_backends[$i].password")"
    servername="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    cert_path="$(read_yaml_required ".trojan_backends[$i].tls_cert_file" "trojan_backends[$i].tls_cert_file")"
    key_path="$(read_yaml_required ".trojan_backends[$i].tls_key_file" "trojan_backends[$i].tls_key_file")"
    use_socks="$(normalize_bool "$(read_yaml_optional ".trojan_backends[$i].use_socks" 'false')" "trojan_backends[$i].use_socks")"

    assert_port "$listen_port" "trojan_backends[$i].listen_port"

    local inbound_obj
    inbound_obj="$(jq -n \
      --arg tag "$inbound_tag" \
      --arg user_name "$user_name" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --arg cert_path "$cert_path" \
      --arg key_path "$key_path" \
      --argjson listen_port "$listen_port" \
      '{
        type: "trojan",
        tag: $tag,
        listen: "127.0.0.1",
        listen_port: $listen_port,
        users: [
          {
            name: $user_name,
            password: $password
          }
        ],
        tls: {
          enabled: true,
          server_name: $server_name,
          alpn: ["http/1.1"],
          certificate_path: $cert_path,
          key_path: $key_path
        }
      }')"

    fallback_enabled="$(normalize_bool "$(read_yaml_optional ".trojan_backends[$i].fallback_site.enabled" 'false')" "trojan_backends[$i].fallback_site.enabled")"
    if is_true "$fallback_enabled"; then
      fallback_host="$(read_yaml_optional ".trojan_backends[$i].fallback_site.listen_host" '127.0.0.1')"
      fallback_port="$(read_yaml_optional ".trojan_backends[$i].fallback_site.listen_port" '37980')"
      assert_port "$fallback_port" "trojan_backends[$i].fallback_site.listen_port"
      inbound_obj="$(jq -c --arg fallback_host "$fallback_host" --argjson fallback_port "$fallback_port" '. + {
        fallback: {
          server: $fallback_host,
          server_port: $fallback_port
        }
      }' <<< "$inbound_obj")"
    fi

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    if is_true "$use_socks"; then
      socks_route_inbounds="$(jq -c --arg tag "$inbound_tag" '. + [$tag]' <<< "$socks_route_inbounds")"
    fi
  done

  local outbounds_json route_rules_json
  outbounds_json="$(jq -n --argjson socks_port "$socks_proxy_port" '[
    {
      type: "socks",
      tag: "local-socks-out",
      server: "127.0.0.1",
      server_port: $socks_port
    },
    {
      type: "direct",
      tag: "direct-out"
    }
  ]')"

  if [[ "$(jq 'length' <<< "$socks_route_inbounds")" -gt 0 ]]; then
    route_rules_json="$(jq -n --argjson inbound "$socks_route_inbounds" '[
      {
        inbound: $inbound,
        outbound: "local-socks-out"
      }
    ]')"
  else
    route_rules_json='[]'
  fi

  render_template_file \
    "${TEMPLATE_DIR}/sing-box.config.json.tpl" \
    "${GENERATED_DIR}/config.json" \
    '__INBOUNDS_JSON__' "$(jq '.' <<< "$inbounds_json")" \
    '__OUTBOUNDS_JSON__' "$(jq '.' <<< "$outbounds_json")" \
    '__ROUTE_RULES_JSON__' "$(jq '.' <<< "$route_rules_json")"

  jq . "${GENERATED_DIR}/config.json" >/dev/null
  log_info "已生成 sing-box 配置: ${GENERATED_DIR}/config.json"
}

render_mihomo_config() {
  local nginx_public_listen public_port
  nginx_public_listen="$(get_ingress_public_listen)"
  public_port="$(parse_public_port "$nginx_public_listen")"

  local proxies_json='[]'

  local reality_count trojan_count i
  reality_count="$(yq e '(.reality_backends // []) | length' "$CONFIG_FILE")"
  trojan_count="$(yq e '(.trojan_backends // []) | length' "$CONFIG_FILE")"

  for (( i = 0; i < reality_count; i++ )); do
    local name server uuid servername public_key short_id_raw short_id_first

    name="$(read_yaml_required ".reality_backends[$i].name" "reality_backends[$i].name")"
    server="$(read_yaml_optional ".reality_backends[$i].server" "")"
    servername="$(read_yaml_required ".reality_backends[$i].servername" "reality_backends[$i].servername")"
    uuid="$(read_yaml_required ".reality_backends[$i].user_uuid" "reality_backends[$i].user_uuid")"
    public_key="$(read_yaml_required ".reality_backends[$i].public_key" "reality_backends[$i].public_key")"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    short_id_raw="$(yq e -o=json ".reality_backends[$i].short_id" "$CONFIG_FILE")"
    short_id_first="$(jq -r '
      if type == "array" then
        (map(tostring | select(length > 0)) | .[0] // "")
      elif . == null then
        ""
      else
        tostring
      end
    ' <<< "$short_id_raw")"
    [[ -n "$short_id_first" ]] || die "reality_backends[$i].short_id 不能为空"

    local proxy_obj
    proxy_obj="$(jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --arg uuid "$uuid" \
      --arg servername "$servername" \
      --arg public_key "$public_key" \
      --arg short_id "$short_id_first" \
      --argjson port "$public_port" \
      '{
        name: $name,
        type: "vless",
        server: $server,
        port: $port,
        uuid: $uuid,
        network: "tcp",
        tls: true,
        udp: true,
        servername: $servername,
        flow: "xtls-rprx-vision",
        "packet-encoding": "xudp",
        "client-fingerprint": "chrome",
        "reality-opts": {
          "public-key": $public_key,
          "short-id": $short_id
        }
      }')"

    proxies_json="$(jq -c --argjson obj "$proxy_obj" '. + [$obj]' <<< "$proxies_json")"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local name server password servername skip_cert_verify

    name="$(read_yaml_required ".trojan_backends[$i].name" "trojan_backends[$i].name")"
    server="$(read_yaml_optional ".trojan_backends[$i].server" "")"
    servername="$(read_yaml_required ".trojan_backends[$i].servername" "trojan_backends[$i].servername")"
    password="$(read_yaml_required ".trojan_backends[$i].password" "trojan_backends[$i].password")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".trojan_backends[$i].skip_cert_verify" 'false')" "trojan_backends[$i].skip_cert_verify")"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    local proxy_obj
    proxy_obj="$(jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --arg password "$password" \
      --arg servername "$servername" \
      --argjson skip_cert_verify "$skip_cert_verify" \
      --argjson port "$public_port" \
      '{
        name: $name,
        type: "trojan",
        server: $server,
        port: $port,
        password: $password,
        udp: true,
        sni: $servername,
        "skip-cert-verify": $skip_cert_verify
      }')"

    proxies_json="$(jq -c --argjson obj "$proxy_obj" '. + [$obj]' <<< "$proxies_json")"
  done

  local proxies_yaml proxy_group_items
  proxies_yaml="$(yq e -P - <<< "$proxies_json" | sed 's/^/  /')"
  proxy_group_items="$(jq -r '.[] | "      - \(.name)"' <<< "$proxies_json")"

  render_template_file \
    "${TEMPLATE_DIR}/mihomo-client.yaml.tpl" \
    "${GENERATED_DIR}/mihomo-client.yaml" \
    '__PROXIES_YAML__' "$proxies_yaml" \
    '__PROXY_GROUP_ITEMS__' "$proxy_group_items"

  log_info "已生成 mihomo 配置: ${GENERATED_DIR}/mihomo-client.yaml"
}

render_socks_installer() {
  local socks_proxy_port
  socks_proxy_port="$(get_socks_proxy_port)"
  assert_port "$socks_proxy_port" 'egress.socks_proxy.port'

  render_template_file \
    "${TEMPLATE_DIR}/install-socks-proxy.sh.tpl" \
    "${GENERATED_DIR}/install-socks-proxy.sh" \
    '__SOCKS_PROXY_PORT__' "$socks_proxy_port"

  chmod +x "${GENERATED_DIR}/install-socks-proxy.sh"
  log_info "已生成 socks 安装脚本: ${GENERATED_DIR}/install-socks-proxy.sh"
}

render_all() {
  require_cmd yq
  require_cmd jq

  mkdir -p "$GENERATED_DIR"

  validate_unique_bindings
  render_nginx_config
  render_sing_box_config
  render_mihomo_config
  render_socks_installer

  log_info "渲染阶段完成"
}
