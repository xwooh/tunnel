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

yaml_scalar_is_blank() {
  local expr="$1"
  local value

  value="$(yq e -r "$expr" "$CONFIG_FILE")"
  [[ -z "$value" || "$value" == "null" ]]
}

yaml_short_id_is_blank() {
  local expr="$1"
  local raw_json

  raw_json="$(yq e -o=json "$expr" "$CONFIG_FILE")"
  jq -e '
    if type == "array" then
      ([ .[] | tostring | select(length > 0) ] | length) == 0
    elif . == null then
      true
    else
      (tostring | length) == 0
    end
  ' <<< "$raw_json" >/dev/null
}

read_yaml_string_array_optional() {
  local expr="$1"
  local default_json="$2"
  local raw_json

  raw_json="$(yq e -o=json "$expr" "$CONFIG_FILE")"
  jq -c --argjson default_value "$default_json" '
    if . == null then
      $default_value
    elif type == "array" then
      [ .[] | tostring | select(length > 0) ]
    elif (tostring | length) == 0 then
      $default_value
    else
      [ tostring ]
    end
  ' <<< "$raw_json"
}

read_yaml_int_optional_json() {
  local expr="$1"
  local where="$2"
  local value

  value="$(read_yaml_optional "$expr" '')"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf 'null'
    return 0
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die "${where} 必须是非负整数"
  fi

  printf '%s' "$value"
}

read_yaml_masquerade_optional_json() {
  local expr="$1"
  local where="$2"
  local raw_json

  raw_json="$(yq e -o=json "$expr" "$CONFIG_FILE")"
  jq -c --arg where "$where" '
    def require_type($types):
      .type as $type |
      if ($type | type) != "string" or ($type | length) == 0 then
        error($where + ".type is required")
      elif ($types | index($type)) == null then
        error($where + ".type must be one of: file, proxy, string")
      else
        .
      end;

    if . == null then
      null
    elif type == "string" then
      if length == 0 then null else . end
    elif type == "object" then
      require_type(["file", "proxy", "string"])
    else
      error($where + " must be a string or object")
    end
  ' <<< "$raw_json" || die "${where} 必须是字符串，或带 type=file/proxy/string 的对象"
}

generate_reality_keypair() {
  local output private_key public_key

  output="$(sing-box generate reality-keypair)"
  private_key="$(awk -F': ' '/^PrivateKey:/ { print $2; exit }' <<< "$output")"
  public_key="$(awk -F': ' '/^PublicKey:/ { print $2; exit }' <<< "$output")"

  [[ -n "$private_key" ]] || die '无法解析 sing-box generate reality-keypair 输出中的 PrivateKey'
  [[ -n "$public_key" ]] || die '无法解析 sing-box generate reality-keypair 输出中的 PublicKey'

  printf '%s\t%s' "$private_key" "$public_key"
}

populate_reality_backend_credentials() {
  local reality_count
  reality_count="$(count_ingress_reality_backends)"
  (( reality_count > 0 )) || return 0

  require_cmd sing-box

  local i
  for (( i = 0; i < reality_count; i++ )); do
    local where generated_fields
    local user_uuid_expr private_key_expr public_key_expr short_id_expr
    local generated_uuid generated_short_id generated_keypair generated_private_key generated_public_key
    local missing_keypair missing_short_id

    where="ingress.reality_backends[$i]"
    user_uuid_expr=".ingress.reality_backends[$i].user_uuid"
    private_key_expr=".ingress.reality_backends[$i].private_key"
    public_key_expr=".ingress.reality_backends[$i].public_key"
    short_id_expr=".ingress.reality_backends[$i].short_id"
    generated_fields=()

    if yaml_scalar_is_blank "$user_uuid_expr"; then
      generated_uuid="$(sing-box generate uuid)"
      [[ -n "$generated_uuid" ]] || die "无法为 ${where}.user_uuid 生成 UUID"
      USER_UUID="$generated_uuid" yq e -i "${user_uuid_expr} = strenv(USER_UUID)" "$CONFIG_FILE"
      generated_fields+=('user_uuid')
    fi

    missing_keypair=0
    if yaml_scalar_is_blank "$private_key_expr" || yaml_scalar_is_blank "$public_key_expr"; then
      missing_keypair=1
    fi
    if (( missing_keypair )); then
      generated_keypair="$(generate_reality_keypair)"
      IFS=$'\t' read -r generated_private_key generated_public_key <<< "$generated_keypair"
      PRIVATE_KEY="$generated_private_key" PUBLIC_KEY="$generated_public_key" \
        yq e -i "${private_key_expr} = strenv(PRIVATE_KEY) | ${public_key_expr} = strenv(PUBLIC_KEY)" "$CONFIG_FILE"
      generated_fields+=('private_key' 'public_key')
    fi

    missing_short_id=1
    if ! yaml_short_id_is_blank "$short_id_expr"; then
      missing_short_id=0
    fi
    if (( missing_short_id )); then
      generated_short_id="$(sing-box generate rand --hex 8)"
      [[ -n "$generated_short_id" ]] || die "无法为 ${where}.short_id 生成 short_id"
      SHORT_ID="$generated_short_id" yq e -i "${short_id_expr} = strenv(SHORT_ID)" "$CONFIG_FILE"
      generated_fields+=('short_id')
    fi

    if (( ${#generated_fields[@]} > 0 )); then
      log_info "已补全 ${where}: ${generated_fields[*]}"
    fi
  done
}

build_outbounds_json() {
  local outbounds_json
  outbounds_json="$(jq -n '[
    {
      type: "direct",
      tag: "direct-out"
    }
  ]')"

  local egress_name egress_type outbound_obj
  while IFS= read -r egress_name; do
    [[ -n "$egress_name" ]] || continue

    egress_type="$(get_egress_type "$egress_name")"
    case "$egress_type" in
      direct)
        continue
        ;;
      socks)
        local server port
        server="$(read_named_egress_required "$egress_name" 'server' "egress.${egress_name}.server")"
        port="$(read_named_egress_required "$egress_name" 'port' "egress.${egress_name}.port")"
        assert_port "$port" "egress.${egress_name}.port"

        outbound_obj="$(jq -n \
          --arg tag "$(egress_outbound_tag "$egress_name")" \
          --arg server "$server" \
          --argjson port "$port" \
          '{
            type: "socks",
            tag: $tag,
            server: $server,
            server_port: $port
          }')"
        ;;
      *)
        die "egress.${egress_name}.type 只能是: direct, socks"
        ;;
    esac

    outbounds_json="$(jq -c --argjson obj "$outbound_obj" '. + [$obj]' <<< "$outbounds_json")"
  done < <(list_egress_names)

  printf '%s' "$outbounds_json"
}

validate_unique_bindings() {
  if ! has_ingress && ! has_sing_box; then
    die 'ingress 或 sing_box 至少需要配置一个顶层块'
  fi

  local seen_servernames=''
  local seen_ports=''
  local seen_outbound_tags=''

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

  lookup_seen_port() {
    local protocol="$1"
    local port="$2"
    lookup_seen_binding "$seen_ports" "${protocol}:${port}"
  }

  add_seen_port() {
    local protocol="$1"
    local port="$2"
    local value="$3"
    add_seen_binding seen_ports "${protocol}:${port}" "$value"
  }

  local reality_count trojan_count anytls_count socks5_count hy2_count
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  anytls_count="$(count_ingress_anytls_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"
  hy2_count="$(count_sing_box_hy2_backends)"

  if has_ingress; then
    local public_listen public_port unknown_sni_action duplicated_port

    public_listen="$(get_ingress_public_listen)"
    public_port="$(parse_public_port "$public_listen")"
    duplicated_port="$(lookup_seen_port tcp "$public_port")"
    if [[ -n "$duplicated_port" ]]; then
      die "ingress.public_listen 端口冲突: ${public_port}，已被 ${duplicated_port} 使用"
    fi
    add_seen_port tcp "$public_port" 'ingress.public_listen'

    unknown_sni_action="$(lower "$(get_unknown_sni_action)")"
    case "$unknown_sni_action" in
      reject|blackhole|fallback_static)
        ;;
      *)
        die 'ingress.unknown_sni_action 只能是: reject, blackhole, fallback_static'
        ;;
    esac

    if [[ "$unknown_sni_action" == "fallback_static" ]] && ! has_effective_static_site; then
      die 'ingress.unknown_sni_action=fallback_static 时，必须配置 ingress.static_site 或启用 fallback_site 的 Trojan 后端'
    fi

    if has_explicit_static_site; then
      local static_domain static_port duplicated_servername
      static_domain="$(read_yaml_required '.ingress.static_site.domain' 'ingress.static_site.domain')"
      static_port="$(read_yaml_required '.ingress.static_site.listen_port' 'ingress.static_site.listen_port')"
      assert_port "$static_port" 'ingress.static_site.listen_port'

      duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$static_domain")"
      if [[ -n "$duplicated_servername" ]]; then
        die "ingress.static_site.domain 域名重复: ${static_domain}，已被 ${duplicated_servername} 使用"
      fi
      add_seen_binding seen_servernames "$static_domain" 'ingress.static_site.domain'

      duplicated_port="$(lookup_seen_port tcp "$static_port")"
      if [[ -n "$duplicated_port" ]]; then
        die "ingress.static_site.listen_port 端口冲突: ${static_port}，已被 ${duplicated_port} 使用"
      fi
      add_seen_port tcp "$static_port" 'ingress.static_site.listen_port'
    fi
  fi

  local egress_name egress_type egress_port egress_server safe_name duplicated_outbound_tag duplicated_port
  while IFS= read -r egress_name; do
    [[ -n "$egress_name" ]] || continue

    if [[ "$egress_name" == "direct" ]]; then
      die 'egress.direct 是保留名称，不能显式定义'
    fi

    egress_type="$(get_egress_type "$egress_name")"
    case "$egress_type" in
      direct|socks)
        ;;
      *)
        die "egress.${egress_name}.type 只能是: direct, socks"
        ;;
    esac

    safe_name="$(sanitize_name "$egress_name")"
    [[ -n "$safe_name" ]] || die "egress 名称不可用: ${egress_name}"
    duplicated_outbound_tag="$(lookup_seen_binding "$seen_outbound_tags" "egress-${safe_name}-out")"
    if [[ -n "$duplicated_outbound_tag" ]]; then
      die "egress 名称冲突: ${egress_name} 与 ${duplicated_outbound_tag} 会生成相同的 outbound tag"
    fi
    add_seen_binding seen_outbound_tags "egress-${safe_name}-out" "egress.${egress_name}"

    if [[ "$egress_type" != "socks" ]]; then
      continue
    fi

    egress_server="$(read_named_egress_required "$egress_name" 'server' "egress.${egress_name}.server")"
    egress_port="$(read_named_egress_required "$egress_name" 'port' "egress.${egress_name}.port")"
    assert_port "$egress_port" "egress.${egress_name}.port"

    if is_local_address "$egress_server"; then
      duplicated_port="$(lookup_seen_port tcp "$egress_port")"
      if [[ -n "$duplicated_port" ]]; then
        die "egress.${egress_name}.port 端口冲突: ${egress_port}，已被 ${duplicated_port} 使用"
      fi
      add_seen_port tcp "$egress_port" "egress.${egress_name}.port"
    fi
  done < <(list_egress_names)

  local i
  for (( i = 0; i < reality_count; i++ )); do
    local where servername listen_port duplicated_servername duplicated_listen_port
    where="ingress.reality_backends[$i]"
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "${where}.servername")"
    listen_port="$(read_yaml_required ".ingress.reality_backends[$i].listen_port" "${where}.listen_port")"
    assert_port "$listen_port" "${where}.listen_port"
    resolve_backend_egress_name ".ingress.reality_backends[$i].egress" "${where}.egress" >/dev/null

    duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$servername")"
    if [[ -n "$duplicated_servername" ]]; then
      die "${where} 的 SNI 域名重复: ${servername}，已被 ${duplicated_servername} 使用"
    fi
    add_seen_binding seen_servernames "$servername" "$where"

    duplicated_listen_port="$(lookup_seen_port tcp "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_port tcp "$listen_port" "$where"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local where servername listen_port fallback_enabled fallback_port duplicated_servername duplicated_listen_port
    where="ingress.trojan_backends[$i]"
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "${where}.servername")"
    listen_port="$(read_yaml_required ".ingress.trojan_backends[$i].listen_port" "${where}.listen_port")"
    assert_port "$listen_port" "${where}.listen_port"
    resolve_backend_egress_name ".ingress.trojan_backends[$i].egress" "${where}.egress" >/dev/null

    duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$servername")"
    if [[ -n "$duplicated_servername" ]]; then
      die "${where} 的 SNI 域名重复: ${servername}，已被 ${duplicated_servername} 使用"
    fi
    add_seen_binding seen_servernames "$servername" "$where"

    duplicated_listen_port="$(lookup_seen_port tcp "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_port tcp "$listen_port" "$where"

    fallback_enabled="$(normalize_bool "$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.enabled" 'false')" "${where}.fallback_site.enabled")"
    if is_true "$fallback_enabled"; then
      resolve_fallback_site_web_root "$i" >/dev/null
      fallback_port="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.listen_port" '37980')"
      assert_port "$fallback_port" "${where}.fallback_site.listen_port"

      duplicated_listen_port="$(lookup_seen_port tcp "$fallback_port")"
      if [[ -n "$duplicated_listen_port" ]]; then
        die "${where}.fallback_site.listen_port 端口重复: ${fallback_port}，已被 ${duplicated_listen_port} 使用"
      fi
      add_seen_port tcp "$fallback_port" "${where}.fallback_site.listen_port"
    fi
  done

  for (( i = 0; i < anytls_count; i++ )); do
    local where servername listen_port duplicated_servername duplicated_listen_port
    where="ingress.anytls_backends[$i]"
    servername="$(read_yaml_required ".ingress.anytls_backends[$i].servername" "${where}.servername")"
    listen_port="$(read_yaml_required ".ingress.anytls_backends[$i].listen_port" "${where}.listen_port")"
    read_yaml_required ".ingress.anytls_backends[$i].password" "${where}.password" >/dev/null
    read_yaml_required ".ingress.anytls_backends[$i].tls_cert_file" "${where}.tls_cert_file" >/dev/null
    read_yaml_required ".ingress.anytls_backends[$i].tls_key_file" "${where}.tls_key_file" >/dev/null
    assert_port "$listen_port" "${where}.listen_port"
    resolve_backend_egress_name ".ingress.anytls_backends[$i].egress" "${where}.egress" >/dev/null

    duplicated_servername="$(lookup_seen_binding "$seen_servernames" "$servername")"
    if [[ -n "$duplicated_servername" ]]; then
      die "${where} 的 SNI 域名重复: ${servername}，已被 ${duplicated_servername} 使用"
    fi
    add_seen_binding seen_servernames "$servername" "$where"

    duplicated_listen_port="$(lookup_seen_port tcp "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_port tcp "$listen_port" "$where"
  done

  for (( i = 0; i < socks5_count; i++ )); do
    local where listen_port duplicated_listen_port
    where="sing_box.socks5_backends[$i]"
    listen_port="$(read_yaml_required ".sing_box.socks5_backends[$i].listen_port" "${where}.listen_port")"
    assert_port "$listen_port" "${where}.listen_port"
    resolve_backend_egress_name ".sing_box.socks5_backends[$i].egress" "${where}.egress" >/dev/null

    duplicated_listen_port="$(lookup_seen_port tcp "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_port tcp "$listen_port" "$where"
  done

  for (( i = 0; i < hy2_count; i++ )); do
    local where listen_port duplicated_listen_port
    where="sing_box.hy2_backends[$i]"
    listen_port="$(read_yaml_required ".sing_box.hy2_backends[$i].listen_port" "${where}.listen_port")"
    read_yaml_required ".sing_box.hy2_backends[$i].password" "${where}.password" >/dev/null
    read_yaml_required ".sing_box.hy2_backends[$i].server" "${where}.server" >/dev/null
    read_yaml_required ".sing_box.hy2_backends[$i].servername" "${where}.servername" >/dev/null
    read_yaml_required ".sing_box.hy2_backends[$i].tls_cert_file" "${where}.tls_cert_file" >/dev/null
    read_yaml_required ".sing_box.hy2_backends[$i].tls_key_file" "${where}.tls_key_file" >/dev/null
    assert_port "$listen_port" "${where}.listen_port"
    read_yaml_masquerade_optional_json ".sing_box.hy2_backends[$i].masquerade" "${where}.masquerade" >/dev/null
    resolve_backend_egress_name ".sing_box.hy2_backends[$i].egress" "${where}.egress" >/dev/null

    duplicated_listen_port="$(lookup_seen_port udp "$listen_port")"
    if [[ -n "$duplicated_listen_port" ]]; then
      die "${where} 的 UDP listen_port 重复: ${listen_port}，已被 ${duplicated_listen_port} 使用"
    fi
    add_seen_port udp "$listen_port" "$where"
  done
}

default_backend_value() {
  local action
  action="$(lower "$(get_unknown_sni_action)")"

  case "$action" in
    fallback_static)
      if has_explicit_static_site; then
        local static_host static_port
        static_host="$(read_yaml_required '.ingress.static_site.listen_host' 'ingress.static_site.listen_host')"
        static_port="$(read_yaml_required '.ingress.static_site.listen_port' 'ingress.static_site.listen_port')"
        printf '%s:%s' "$static_host" "$static_port"
      else
        local trojan_listen_port fallback_index
        fallback_index="$(get_primary_fallback_trojan_index)"
        trojan_listen_port="$(get_primary_fallback_trojan_listen_port)"
        assert_port "$trojan_listen_port" "ingress.trojan_backends[${fallback_index}].listen_port"
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
    static_host="$(read_yaml_required '.ingress.static_site.listen_host' 'ingress.static_site.listen_host')"
    static_port="$(read_yaml_required '.ingress.static_site.listen_port' 'ingress.static_site.listen_port')"
    static_domain="$(read_yaml_required '.ingress.static_site.domain' 'ingress.static_site.domain')"
    static_cert="$(read_yaml_required '.ingress.static_site.cert_file' 'ingress.static_site.cert_file')"
    static_key="$(read_yaml_required '.ingress.static_site.key_file' 'ingress.static_site.key_file')"
    static_web_root="$(read_yaml_required '.ingress.static_site.web_root' 'ingress.static_site.web_root')"
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

  local reality_count trojan_count anytls_count i
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  anytls_count="$(count_ingress_anytls_backends)"

  for (( i = 0; i < reality_count; i++ )); do
    local servername listen_port
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "ingress.reality_backends[$i].servername")"
    listen_port="$(read_yaml_required ".ingress.reality_backends[$i].listen_port" "ingress.reality_backends[$i].listen_port")"
    if [[ -n "$map_entries" ]]; then
      map_entries+=$'\n'
    fi
    map_entries+="        ${servername} 127.0.0.1:${listen_port};"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local servername listen_port
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    listen_port="$(read_yaml_required ".ingress.trojan_backends[$i].listen_port" "ingress.trojan_backends[$i].listen_port")"
    if [[ -n "$map_entries" ]]; then
      map_entries+=$'\n'
    fi
    map_entries+="        ${servername} 127.0.0.1:${listen_port};"
  done

  for (( i = 0; i < anytls_count; i++ )); do
    local servername listen_port
    servername="$(read_yaml_required ".ingress.anytls_backends[$i].servername" "ingress.anytls_backends[$i].servername")"
    listen_port="$(read_yaml_required ".ingress.anytls_backends[$i].listen_port" "ingress.anytls_backends[$i].listen_port")"
    if [[ -n "$map_entries" ]]; then
      map_entries+=$'\n'
    fi
    map_entries+="        ${servername} 127.0.0.1:${listen_port};"
  done

  local trojan_fallback_blocks=""
  for (( i = 0; i < trojan_count; i++ )); do
    local enabled servername fallback_host fallback_port fallback_web_root block
    enabled="$(normalize_bool "$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.enabled" 'false')" "ingress.trojan_backends[$i].fallback_site.enabled")"
    if ! is_true "$enabled"; then
      continue
    fi

    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    fallback_host="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.listen_host" '127.0.0.1')"
    fallback_port="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.listen_port" '37980')"
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
  local inbounds_json='[]'
  local route_rules_json='[]'

  local reality_count trojan_count anytls_count socks5_count hy2_count i
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  anytls_count="$(count_ingress_anytls_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"
  hy2_count="$(count_sing_box_hy2_backends)"

  for (( i = 0; i < reality_count; i++ )); do
    local name safe_name inbound_tag user_name short_id_raw short_id_list
    local listen_port user_uuid servername handshake_server handshake_port private_key egress_name outbound_tag

    name="$(read_yaml_required ".ingress.reality_backends[$i].name" "ingress.reality_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((i + 1))"

    inbound_tag="${safe_name}-vless-in"
    user_name="${safe_name}-vless-user"

    listen_port="$(read_yaml_required ".ingress.reality_backends[$i].listen_port" "ingress.reality_backends[$i].listen_port")"
    user_uuid="$(read_yaml_required ".ingress.reality_backends[$i].user_uuid" "ingress.reality_backends[$i].user_uuid")"
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "ingress.reality_backends[$i].servername")"
    handshake_server="$(read_yaml_required ".ingress.reality_backends[$i].handshake_server" "ingress.reality_backends[$i].handshake_server")"
    handshake_port="$(read_yaml_required ".ingress.reality_backends[$i].port" "ingress.reality_backends[$i].port")"
    private_key="$(read_yaml_required ".ingress.reality_backends[$i].private_key" "ingress.reality_backends[$i].private_key")"
    egress_name="$(resolve_backend_egress_name ".ingress.reality_backends[$i].egress" "ingress.reality_backends[$i].egress")"

    assert_port "$listen_port" "ingress.reality_backends[$i].listen_port"
    assert_port "$handshake_port" "ingress.reality_backends[$i].port"

    short_id_raw="$(yq e -o=json ".ingress.reality_backends[$i].short_id" "$CONFIG_FILE")"
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
      die "ingress.reality_backends[$i].short_id 不能为空"
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

    outbound_tag="$(egress_outbound_tag "$egress_name")"
    if [[ "$outbound_tag" != "direct-out" ]]; then
      route_rules_json="$(jq -c --arg inbound "$inbound_tag" --arg outbound "$outbound_tag" '. + [{
        inbound: [$inbound],
        outbound: $outbound
      }]' <<< "$route_rules_json")"
    fi
  done

  local trojan_offset
  trojan_offset="$reality_count"

  for (( i = 0; i < trojan_count; i++ )); do
    local idx name safe_name inbound_tag user_name
    local listen_port password servername cert_path key_path egress_name outbound_tag
    local fallback_enabled fallback_host fallback_port

    idx=$((trojan_offset + i + 1))
    name="$(read_yaml_required ".ingress.trojan_backends[$i].name" "ingress.trojan_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-${idx}"

    inbound_tag="${safe_name}-trojan-in"
    user_name="${safe_name}-trojan-user"

    listen_port="$(read_yaml_required ".ingress.trojan_backends[$i].listen_port" "ingress.trojan_backends[$i].listen_port")"
    password="$(read_yaml_required ".ingress.trojan_backends[$i].password" "ingress.trojan_backends[$i].password")"
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    cert_path="$(read_yaml_required ".ingress.trojan_backends[$i].tls_cert_file" "ingress.trojan_backends[$i].tls_cert_file")"
    key_path="$(read_yaml_required ".ingress.trojan_backends[$i].tls_key_file" "ingress.trojan_backends[$i].tls_key_file")"
    egress_name="$(resolve_backend_egress_name ".ingress.trojan_backends[$i].egress" "ingress.trojan_backends[$i].egress")"

    assert_port "$listen_port" "ingress.trojan_backends[$i].listen_port"

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

    fallback_enabled="$(normalize_bool "$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.enabled" 'false')" "ingress.trojan_backends[$i].fallback_site.enabled")"
    if is_true "$fallback_enabled"; then
      fallback_host="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.listen_host" '127.0.0.1')"
      fallback_port="$(read_yaml_optional ".ingress.trojan_backends[$i].fallback_site.listen_port" '37980')"
      assert_port "$fallback_port" "ingress.trojan_backends[$i].fallback_site.listen_port"
      inbound_obj="$(jq -c --arg fallback_host "$fallback_host" --argjson fallback_port "$fallback_port" '. + {
        fallback: {
          server: $fallback_host,
          server_port: $fallback_port
        }
      }' <<< "$inbound_obj")"
    fi

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    outbound_tag="$(egress_outbound_tag "$egress_name")"
    if [[ "$outbound_tag" != "direct-out" ]]; then
      route_rules_json="$(jq -c --arg inbound "$inbound_tag" --arg outbound "$outbound_tag" '. + [{
        inbound: [$inbound],
        outbound: $outbound
      }]' <<< "$route_rules_json")"
    fi
  done

  local anytls_offset
  anytls_offset=$((reality_count + trojan_count))

  for (( i = 0; i < anytls_count; i++ )); do
    local idx name safe_name inbound_tag user_name
    local listen_port password servername cert_path key_path egress_name outbound_tag alpn_json padding_scheme_json

    idx=$((anytls_offset + i + 1))
    name="$(read_yaml_required ".ingress.anytls_backends[$i].name" "ingress.anytls_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-${idx}"

    inbound_tag="${safe_name}-anytls-in"
    user_name="${safe_name}-anytls-user"

    listen_port="$(read_yaml_required ".ingress.anytls_backends[$i].listen_port" "ingress.anytls_backends[$i].listen_port")"
    password="$(read_yaml_required ".ingress.anytls_backends[$i].password" "ingress.anytls_backends[$i].password")"
    servername="$(read_yaml_required ".ingress.anytls_backends[$i].servername" "ingress.anytls_backends[$i].servername")"
    cert_path="$(read_yaml_required ".ingress.anytls_backends[$i].tls_cert_file" "ingress.anytls_backends[$i].tls_cert_file")"
    key_path="$(read_yaml_required ".ingress.anytls_backends[$i].tls_key_file" "ingress.anytls_backends[$i].tls_key_file")"
    egress_name="$(resolve_backend_egress_name ".ingress.anytls_backends[$i].egress" "ingress.anytls_backends[$i].egress")"
    alpn_json="$(read_yaml_string_array_optional ".ingress.anytls_backends[$i].alpn" '["h2","http/1.1"]')"
    padding_scheme_json="$(read_yaml_string_array_optional ".ingress.anytls_backends[$i].padding_scheme" 'null')"

    assert_port "$listen_port" "ingress.anytls_backends[$i].listen_port"

    local inbound_obj
    inbound_obj="$(jq -n \
      --arg tag "$inbound_tag" \
      --arg user_name "$user_name" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --arg cert_path "$cert_path" \
      --arg key_path "$key_path" \
      --argjson listen_port "$listen_port" \
      --argjson alpn "$alpn_json" \
      --argjson padding_scheme "$padding_scheme_json" \
      '{
        type: "anytls",
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
          alpn: $alpn,
          certificate_path: $cert_path,
          key_path: $key_path
        }
      }
      | if $padding_scheme == null then . else . + { padding_scheme: $padding_scheme } end')"

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    outbound_tag="$(egress_outbound_tag "$egress_name")"
    if [[ "$outbound_tag" != "direct-out" ]]; then
      route_rules_json="$(jq -c --arg inbound "$inbound_tag" --arg outbound "$outbound_tag" '. + [{
        inbound: [$inbound],
        outbound: $outbound
      }]' <<< "$route_rules_json")"
    fi
  done

  local socks5_offset
  socks5_offset=$((reality_count + trojan_count + anytls_count))

  for (( i = 0; i < socks5_count; i++ )); do
    local idx name safe_name inbound_tag username password listen_host listen_port egress_name outbound_tag

    idx=$((socks5_offset + i + 1))
    name="$(read_yaml_required ".sing_box.socks5_backends[$i].name" "sing_box.socks5_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-${idx}"

    inbound_tag="${safe_name}-socks5-in"
    username="$(read_yaml_required ".sing_box.socks5_backends[$i].username" "sing_box.socks5_backends[$i].username")"
    password="$(read_yaml_required ".sing_box.socks5_backends[$i].password" "sing_box.socks5_backends[$i].password")"
    listen_host="$(read_yaml_optional ".sing_box.socks5_backends[$i].listen_host" '0.0.0.0')"
    listen_port="$(read_yaml_required ".sing_box.socks5_backends[$i].listen_port" "sing_box.socks5_backends[$i].listen_port")"
    egress_name="$(resolve_backend_egress_name ".sing_box.socks5_backends[$i].egress" "sing_box.socks5_backends[$i].egress")"
    assert_port "$listen_port" "sing_box.socks5_backends[$i].listen_port"

    local inbound_obj
    inbound_obj="$(jq -n \
      --arg tag "$inbound_tag" \
      --arg username "$username" \
      --arg password "$password" \
      --arg listen_host "$listen_host" \
      --argjson listen_port "$listen_port" \
      '{
        type: "socks",
        tag: $tag,
        listen: $listen_host,
        listen_port: $listen_port,
        users: [
          {
            username: $username,
            password: $password
          }
        ]
      }')"

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    outbound_tag="$(egress_outbound_tag "$egress_name")"
    if [[ "$outbound_tag" != "direct-out" ]]; then
      route_rules_json="$(jq -c --arg inbound "$inbound_tag" --arg outbound "$outbound_tag" '. + [{
        inbound: [$inbound],
        outbound: $outbound
      }]' <<< "$route_rules_json")"
    fi
  done

  local hy2_offset
  hy2_offset=$((reality_count + trojan_count + anytls_count + socks5_count))

  for (( i = 0; i < hy2_count; i++ )); do
    local idx name safe_name inbound_tag user_name
    local listen_host listen_port password servername cert_path key_path egress_name outbound_tag
    local up_mbps_json down_mbps_json obfs_type obfs_password alpn_json
    local masquerade_json

    idx=$((hy2_offset + i + 1))
    name="$(read_yaml_required ".sing_box.hy2_backends[$i].name" "sing_box.hy2_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-${idx}"

    inbound_tag="${safe_name}-hy2-in"
    user_name="${safe_name}-hy2-user"

    listen_host="$(read_yaml_optional ".sing_box.hy2_backends[$i].listen_host" '0.0.0.0')"
    listen_port="$(read_yaml_required ".sing_box.hy2_backends[$i].listen_port" "sing_box.hy2_backends[$i].listen_port")"
    password="$(read_yaml_required ".sing_box.hy2_backends[$i].password" "sing_box.hy2_backends[$i].password")"
    servername="$(read_yaml_required ".sing_box.hy2_backends[$i].servername" "sing_box.hy2_backends[$i].servername")"
    cert_path="$(read_yaml_required ".sing_box.hy2_backends[$i].tls_cert_file" "sing_box.hy2_backends[$i].tls_cert_file")"
    key_path="$(read_yaml_required ".sing_box.hy2_backends[$i].tls_key_file" "sing_box.hy2_backends[$i].tls_key_file")"
    egress_name="$(resolve_backend_egress_name ".sing_box.hy2_backends[$i].egress" "sing_box.hy2_backends[$i].egress")"
    up_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].up_mbps" "sing_box.hy2_backends[$i].up_mbps")"
    down_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].down_mbps" "sing_box.hy2_backends[$i].down_mbps")"
    obfs_type="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.type" '')"
    obfs_password="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.password" '')"
    alpn_json="$(read_yaml_string_array_optional ".sing_box.hy2_backends[$i].alpn" '["h3"]')"
    masquerade_json="$(read_yaml_masquerade_optional_json ".sing_box.hy2_backends[$i].masquerade" "sing_box.hy2_backends[$i].masquerade")"

    assert_port "$listen_port" "sing_box.hy2_backends[$i].listen_port"
    if [[ -n "$obfs_type" && "$obfs_type" != "null" ]]; then
      [[ "$obfs_type" == "salamander" ]] || die "sing_box.hy2_backends[$i].obfs.type 只能是: salamander"
      [[ -n "$obfs_password" && "$obfs_password" != "null" ]] || die "缺少必填字段: sing_box.hy2_backends[$i].obfs.password"
    fi

    local inbound_obj obfs_json
    obfs_json='null'
    if [[ -n "$obfs_type" && "$obfs_type" != "null" ]]; then
      obfs_json="$(jq -n --arg type "$obfs_type" --arg password "$obfs_password" '{
        type: $type,
        password: $password
      }')"
    fi

    inbound_obj="$(jq -n \
      --arg tag "$inbound_tag" \
      --arg listen_host "$listen_host" \
      --arg user_name "$user_name" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --arg cert_path "$cert_path" \
      --arg key_path "$key_path" \
      --argjson listen_port "$listen_port" \
      --argjson up_mbps "$up_mbps_json" \
      --argjson down_mbps "$down_mbps_json" \
      --argjson obfs "$obfs_json" \
      --argjson alpn "$alpn_json" \
      --argjson masquerade "$masquerade_json" \
      '{
        type: "hysteria2",
        tag: $tag,
        listen: $listen_host,
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
          alpn: $alpn,
          certificate_path: $cert_path,
          key_path: $key_path
        }
      }
      | if $up_mbps == null then . else . + { up_mbps: $up_mbps } end
      | if $down_mbps == null then . else . + { down_mbps: $down_mbps } end
      | if $obfs == null then . else . + { obfs: $obfs } end
      | if $masquerade == null then . else . + { masquerade: $masquerade } end')"

    inbounds_json="$(jq -c --argjson obj "$inbound_obj" '. + [$obj]' <<< "$inbounds_json")"

    outbound_tag="$(egress_outbound_tag "$egress_name")"
    if [[ "$outbound_tag" != "direct-out" ]]; then
      route_rules_json="$(jq -c --arg inbound "$inbound_tag" --arg outbound "$outbound_tag" '. + [{
        inbound: [$inbound],
        outbound: $outbound
      }]' <<< "$route_rules_json")"
    fi
  done

  render_template_file \
    "${TEMPLATE_DIR}/sing-box.config.json.tpl" \
    "${GENERATED_DIR}/config.json" \
    '__INBOUNDS_JSON__' "$(jq '.' <<< "$inbounds_json")" \
    '__OUTBOUNDS_JSON__' "$(build_outbounds_json | jq '.')" \
    '__ROUTE_RULES_JSON__' "$(jq '.' <<< "$route_rules_json")"

  jq . "${GENERATED_DIR}/config.json" >/dev/null
  log_info "已生成 sing-box 配置: ${GENERATED_DIR}/config.json"
}

render_mihomo_config() {
  local proxies_json='[]'

  local reality_count trojan_count anytls_count socks5_count hy2_count i
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  anytls_count="$(count_ingress_anytls_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"
  hy2_count="$(count_sing_box_hy2_backends)"

  local public_port=""
  if (( reality_count + trojan_count + anytls_count > 0 )); then
    public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  fi

  for (( i = 0; i < reality_count; i++ )); do
    local name server uuid servername public_key short_id_raw short_id_first

    name="$(read_yaml_required ".ingress.reality_backends[$i].name" "ingress.reality_backends[$i].name")"
    server="$(read_yaml_optional ".ingress.reality_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "ingress.reality_backends[$i].servername")"
    uuid="$(read_yaml_required ".ingress.reality_backends[$i].user_uuid" "ingress.reality_backends[$i].user_uuid")"
    public_key="$(read_yaml_required ".ingress.reality_backends[$i].public_key" "ingress.reality_backends[$i].public_key")"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    short_id_raw="$(yq e -o=json ".ingress.reality_backends[$i].short_id" "$CONFIG_FILE")"
    short_id_first="$(jq -r '
      if type == "array" then
        (map(tostring | select(length > 0)) | .[0] // "")
      elif . == null then
        ""
      else
        tostring
      end
    ' <<< "$short_id_raw")"
    [[ -n "$short_id_first" ]] || die "ingress.reality_backends[$i].short_id 不能为空"

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

    name="$(read_yaml_required ".ingress.trojan_backends[$i].name" "ingress.trojan_backends[$i].name")"
    server="$(read_yaml_optional ".ingress.trojan_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    password="$(read_yaml_required ".ingress.trojan_backends[$i].password" "ingress.trojan_backends[$i].password")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".ingress.trojan_backends[$i].skip_cert_verify" 'false')" "ingress.trojan_backends[$i].skip_cert_verify")"

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

  for (( i = 0; i < anytls_count; i++ )); do
    local name server password servername skip_cert_verify alpn_json client_fingerprint

    name="$(read_yaml_required ".ingress.anytls_backends[$i].name" "ingress.anytls_backends[$i].name")"
    server="$(read_yaml_optional ".ingress.anytls_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.anytls_backends[$i].servername" "ingress.anytls_backends[$i].servername")"
    password="$(read_yaml_required ".ingress.anytls_backends[$i].password" "ingress.anytls_backends[$i].password")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".ingress.anytls_backends[$i].skip_cert_verify" 'false')" "ingress.anytls_backends[$i].skip_cert_verify")"
    client_fingerprint="$(read_yaml_optional ".ingress.anytls_backends[$i].client_fingerprint" 'chrome')"
    alpn_json="$(read_yaml_string_array_optional ".ingress.anytls_backends[$i].alpn" '["h2","http/1.1"]')"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    local proxy_obj
    proxy_obj="$(jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --arg password "$password" \
      --arg servername "$servername" \
      --arg client_fingerprint "$client_fingerprint" \
      --argjson skip_cert_verify "$skip_cert_verify" \
      --argjson port "$public_port" \
      --argjson alpn "$alpn_json" \
      '{
        name: $name,
        type: "anytls",
        server: $server,
        port: $port,
        password: $password,
        udp: true,
        sni: $servername,
        alpn: $alpn,
        "client-fingerprint": $client_fingerprint,
        "skip-cert-verify": $skip_cert_verify
      }')"

    proxies_json="$(jq -c --argjson obj "$proxy_obj" '. + [$obj]' <<< "$proxies_json")"
  done

  for (( i = 0; i < socks5_count; i++ )); do
    local name server username password listen_port

    name="$(read_yaml_required ".sing_box.socks5_backends[$i].name" "sing_box.socks5_backends[$i].name")"
    server="$(read_yaml_required ".sing_box.socks5_backends[$i].server" "sing_box.socks5_backends[$i].server")"
    username="$(read_yaml_required ".sing_box.socks5_backends[$i].username" "sing_box.socks5_backends[$i].username")"
    password="$(read_yaml_required ".sing_box.socks5_backends[$i].password" "sing_box.socks5_backends[$i].password")"
    listen_port="$(read_yaml_required ".sing_box.socks5_backends[$i].listen_port" "sing_box.socks5_backends[$i].listen_port")"
    assert_port "$listen_port" "sing_box.socks5_backends[$i].listen_port"

    local proxy_obj
    proxy_obj="$(jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --arg username "$username" \
      --arg password "$password" \
      --argjson port "$listen_port" \
      '{
        name: $name,
        type: "socks5",
        server: $server,
        port: $port,
        username: $username,
        password: $password,
        udp: true
      }')"

    proxies_json="$(jq -c --argjson obj "$proxy_obj" '. + [$obj]' <<< "$proxies_json")"
  done

  for (( i = 0; i < hy2_count; i++ )); do
    local name server password servername listen_port skip_cert_verify alpn_json obfs_type obfs_password
    local up_mbps_json down_mbps_json

    name="$(read_yaml_required ".sing_box.hy2_backends[$i].name" "sing_box.hy2_backends[$i].name")"
    server="$(read_yaml_required ".sing_box.hy2_backends[$i].server" "sing_box.hy2_backends[$i].server")"
    servername="$(read_yaml_required ".sing_box.hy2_backends[$i].servername" "sing_box.hy2_backends[$i].servername")"
    password="$(read_yaml_required ".sing_box.hy2_backends[$i].password" "sing_box.hy2_backends[$i].password")"
    listen_port="$(read_yaml_required ".sing_box.hy2_backends[$i].listen_port" "sing_box.hy2_backends[$i].listen_port")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".sing_box.hy2_backends[$i].skip_cert_verify" 'false')" "sing_box.hy2_backends[$i].skip_cert_verify")"
    alpn_json="$(read_yaml_string_array_optional ".sing_box.hy2_backends[$i].alpn" '["h3"]')"
    up_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].up_mbps" "sing_box.hy2_backends[$i].up_mbps")"
    down_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].down_mbps" "sing_box.hy2_backends[$i].down_mbps")"
    obfs_type="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.type" '')"
    obfs_password="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.password" '')"
    assert_port "$listen_port" "sing_box.hy2_backends[$i].listen_port"

    local proxy_obj
    proxy_obj="$(jq -n \
      --arg name "$name" \
      --arg server "$server" \
      --arg password "$password" \
      --arg servername "$servername" \
      --arg obfs_type "$obfs_type" \
      --arg obfs_password "$obfs_password" \
      --argjson port "$listen_port" \
      --argjson skip_cert_verify "$skip_cert_verify" \
      --argjson alpn "$alpn_json" \
      --argjson up_mbps "$up_mbps_json" \
      --argjson down_mbps "$down_mbps_json" \
      '{
        name: $name,
        type: "hysteria2",
        server: $server,
        port: $port,
        password: $password,
        udp: true,
        sni: $servername,
        alpn: $alpn,
        "skip-cert-verify": $skip_cert_verify
      }
      | if $up_mbps == null then . else . + { up: $up_mbps } end
      | if $down_mbps == null then . else . + { down: $down_mbps } end
      | if $obfs_type == "" or $obfs_type == "null" then . else . + { obfs: $obfs_type, "obfs-password": $obfs_password } end')"

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

render_sing_box_client_config() {
  local outbounds_json='[]'
  local selector_outbounds_json='[]'

  append_client_outbound() {
    local outbound_obj="$1"
    local outbound_tag="$2"

    outbounds_json="$(jq -c --argjson obj "$outbound_obj" '. + [$obj]' <<< "$outbounds_json")"
    selector_outbounds_json="$(jq -c --arg tag "$outbound_tag" '. + [$tag]' <<< "$selector_outbounds_json")"
  }

  local reality_count trojan_count anytls_count socks5_count hy2_count i
  reality_count="$(count_ingress_reality_backends)"
  trojan_count="$(count_ingress_trojan_backends)"
  anytls_count="$(count_ingress_anytls_backends)"
  socks5_count="$(count_sing_box_socks5_backends)"
  hy2_count="$(count_sing_box_hy2_backends)"

  local public_port=""
  if (( reality_count + trojan_count + anytls_count > 0 )); then
    public_port="$(parse_public_port "$(get_ingress_public_listen)")"
  fi

  for (( i = 0; i < reality_count; i++ )); do
    local name safe_name tag server uuid servername public_key short_id_raw short_id_first client_fingerprint

    name="$(read_yaml_required ".ingress.reality_backends[$i].name" "ingress.reality_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((i + 1))"
    tag="${safe_name}-vless-out"

    server="$(read_yaml_optional ".ingress.reality_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.reality_backends[$i].servername" "ingress.reality_backends[$i].servername")"
    uuid="$(read_yaml_required ".ingress.reality_backends[$i].user_uuid" "ingress.reality_backends[$i].user_uuid")"
    public_key="$(read_yaml_required ".ingress.reality_backends[$i].public_key" "ingress.reality_backends[$i].public_key")"
    client_fingerprint="$(read_yaml_optional ".ingress.reality_backends[$i].client_fingerprint" 'chrome')"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    short_id_raw="$(yq e -o=json ".ingress.reality_backends[$i].short_id" "$CONFIG_FILE")"
    short_id_first="$(jq -r '
      if type == "array" then
        (map(tostring | select(length > 0)) | .[0] // "")
      elif . == null then
        ""
      else
        tostring
      end
    ' <<< "$short_id_raw")"
    [[ -n "$short_id_first" ]] || die "ingress.reality_backends[$i].short_id 不能为空"

    local outbound_obj
    outbound_obj="$(jq -n \
      --arg tag "$tag" \
      --arg server "$server" \
      --arg uuid "$uuid" \
      --arg server_name "$servername" \
      --arg public_key "$public_key" \
      --arg short_id "$short_id_first" \
      --arg client_fingerprint "$client_fingerprint" \
      --argjson server_port "$public_port" \
      '{
        type: "vless",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        uuid: $uuid,
        flow: "xtls-rprx-vision",
        network: "tcp",
        packet_encoding: "xudp",
        tls: {
          enabled: true,
          server_name: $server_name,
          utls: {
            enabled: true,
            fingerprint: $client_fingerprint
          },
          reality: {
            enabled: true,
            public_key: $public_key,
            short_id: $short_id
          }
        }
      }')"

    append_client_outbound "$outbound_obj" "$tag"
  done

  for (( i = 0; i < trojan_count; i++ )); do
    local name safe_name tag server password servername skip_cert_verify alpn_json client_fingerprint

    name="$(read_yaml_required ".ingress.trojan_backends[$i].name" "ingress.trojan_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((reality_count + i + 1))"
    tag="${safe_name}-trojan-out"

    server="$(read_yaml_optional ".ingress.trojan_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.trojan_backends[$i].servername" "ingress.trojan_backends[$i].servername")"
    password="$(read_yaml_required ".ingress.trojan_backends[$i].password" "ingress.trojan_backends[$i].password")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".ingress.trojan_backends[$i].skip_cert_verify" 'false')" "ingress.trojan_backends[$i].skip_cert_verify")"
    client_fingerprint="$(read_yaml_optional ".ingress.trojan_backends[$i].client_fingerprint" 'chrome')"
    alpn_json="$(read_yaml_string_array_optional ".ingress.trojan_backends[$i].alpn" '["http/1.1"]')"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi

    local outbound_obj
    outbound_obj="$(jq -n \
      --arg tag "$tag" \
      --arg server "$server" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --arg client_fingerprint "$client_fingerprint" \
      --argjson server_port "$public_port" \
      --argjson insecure "$skip_cert_verify" \
      --argjson alpn "$alpn_json" \
      '{
        type: "trojan",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        password: $password,
        network: "tcp",
        tls: {
          enabled: true,
          server_name: $server_name,
          insecure: $insecure,
          alpn: $alpn,
          utls: {
            enabled: true,
            fingerprint: $client_fingerprint
          }
        }
      }')"

    append_client_outbound "$outbound_obj" "$tag"
  done

  for (( i = 0; i < anytls_count; i++ )); do
    local name safe_name tag server password servername skip_cert_verify alpn_json client_fingerprint
    local idle_check_interval idle_timeout min_idle_session

    name="$(read_yaml_required ".ingress.anytls_backends[$i].name" "ingress.anytls_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((reality_count + trojan_count + i + 1))"
    tag="${safe_name}-anytls-out"

    server="$(read_yaml_optional ".ingress.anytls_backends[$i].server" "")"
    servername="$(read_yaml_required ".ingress.anytls_backends[$i].servername" "ingress.anytls_backends[$i].servername")"
    password="$(read_yaml_required ".ingress.anytls_backends[$i].password" "ingress.anytls_backends[$i].password")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".ingress.anytls_backends[$i].skip_cert_verify" 'false')" "ingress.anytls_backends[$i].skip_cert_verify")"
    client_fingerprint="$(read_yaml_optional ".ingress.anytls_backends[$i].client_fingerprint" 'chrome')"
    alpn_json="$(read_yaml_string_array_optional ".ingress.anytls_backends[$i].alpn" '["h2","http/1.1"]')"
    idle_check_interval="$(read_yaml_optional ".ingress.anytls_backends[$i].idle_session_check_interval" '')"
    idle_timeout="$(read_yaml_optional ".ingress.anytls_backends[$i].idle_session_timeout" '')"
    min_idle_session="$(read_yaml_optional ".ingress.anytls_backends[$i].min_idle_session" '')"

    if [[ -z "$server" || "$server" == "null" ]]; then
      server="$servername"
    fi
    if [[ -n "$min_idle_session" && "$min_idle_session" != "null" && ! "$min_idle_session" =~ ^[0-9]+$ ]]; then
      die "ingress.anytls_backends[$i].min_idle_session 必须是非负整数"
    fi

    local outbound_obj min_idle_session_json
    min_idle_session_json='null'
    if [[ -n "$min_idle_session" && "$min_idle_session" != "null" ]]; then
      min_idle_session_json="$min_idle_session"
    fi

    outbound_obj="$(jq -n \
      --arg tag "$tag" \
      --arg server "$server" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --arg client_fingerprint "$client_fingerprint" \
      --arg idle_check_interval "$idle_check_interval" \
      --arg idle_timeout "$idle_timeout" \
      --argjson server_port "$public_port" \
      --argjson insecure "$skip_cert_verify" \
      --argjson alpn "$alpn_json" \
      --argjson min_idle_session "$min_idle_session_json" \
      '{
        type: "anytls",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        password: $password,
        tls: {
          enabled: true,
          server_name: $server_name,
          insecure: $insecure,
          alpn: $alpn,
          utls: {
            enabled: true,
            fingerprint: $client_fingerprint
          }
        }
      }
      | if $idle_check_interval == "" then . else . + { idle_session_check_interval: $idle_check_interval } end
      | if $idle_timeout == "" then . else . + { idle_session_timeout: $idle_timeout } end
      | if $min_idle_session == null then . else . + { min_idle_session: $min_idle_session } end')"

    append_client_outbound "$outbound_obj" "$tag"
  done

  for (( i = 0; i < socks5_count; i++ )); do
    local name safe_name tag server username password listen_port

    name="$(read_yaml_required ".sing_box.socks5_backends[$i].name" "sing_box.socks5_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((reality_count + trojan_count + anytls_count + i + 1))"
    tag="${safe_name}-socks5-out"

    server="$(read_yaml_required ".sing_box.socks5_backends[$i].server" "sing_box.socks5_backends[$i].server")"
    username="$(read_yaml_required ".sing_box.socks5_backends[$i].username" "sing_box.socks5_backends[$i].username")"
    password="$(read_yaml_required ".sing_box.socks5_backends[$i].password" "sing_box.socks5_backends[$i].password")"
    listen_port="$(read_yaml_required ".sing_box.socks5_backends[$i].listen_port" "sing_box.socks5_backends[$i].listen_port")"
    assert_port "$listen_port" "sing_box.socks5_backends[$i].listen_port"

    local outbound_obj
    outbound_obj="$(jq -n \
      --arg tag "$tag" \
      --arg server "$server" \
      --arg username "$username" \
      --arg password "$password" \
      --argjson server_port "$listen_port" \
      '{
        type: "socks",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        version: "5",
        username: $username,
        password: $password
      }')"

    append_client_outbound "$outbound_obj" "$tag"
  done

  for (( i = 0; i < hy2_count; i++ )); do
    local name safe_name tag server password servername listen_port skip_cert_verify alpn_json
    local up_mbps_json down_mbps_json obfs_type obfs_password

    name="$(read_yaml_required ".sing_box.hy2_backends[$i].name" "sing_box.hy2_backends[$i].name")"
    safe_name="$(sanitize_name "$name")"
    [[ -n "$safe_name" ]] || safe_name="backend-$((reality_count + trojan_count + anytls_count + socks5_count + i + 1))"
    tag="${safe_name}-hy2-out"

    server="$(read_yaml_required ".sing_box.hy2_backends[$i].server" "sing_box.hy2_backends[$i].server")"
    servername="$(read_yaml_required ".sing_box.hy2_backends[$i].servername" "sing_box.hy2_backends[$i].servername")"
    password="$(read_yaml_required ".sing_box.hy2_backends[$i].password" "sing_box.hy2_backends[$i].password")"
    listen_port="$(read_yaml_required ".sing_box.hy2_backends[$i].listen_port" "sing_box.hy2_backends[$i].listen_port")"
    skip_cert_verify="$(normalize_bool "$(read_yaml_optional ".sing_box.hy2_backends[$i].skip_cert_verify" 'false')" "sing_box.hy2_backends[$i].skip_cert_verify")"
    alpn_json="$(read_yaml_string_array_optional ".sing_box.hy2_backends[$i].alpn" '["h3"]')"
    up_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].up_mbps" "sing_box.hy2_backends[$i].up_mbps")"
    down_mbps_json="$(read_yaml_int_optional_json ".sing_box.hy2_backends[$i].down_mbps" "sing_box.hy2_backends[$i].down_mbps")"
    obfs_type="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.type" '')"
    obfs_password="$(read_yaml_optional ".sing_box.hy2_backends[$i].obfs.password" '')"
    assert_port "$listen_port" "sing_box.hy2_backends[$i].listen_port"

    local outbound_obj obfs_json
    obfs_json='null'
    if [[ -n "$obfs_type" && "$obfs_type" != "null" ]]; then
      obfs_json="$(jq -n --arg type "$obfs_type" --arg password "$obfs_password" '{
        type: $type,
        password: $password
      }')"
    fi

    outbound_obj="$(jq -n \
      --arg tag "$tag" \
      --arg server "$server" \
      --arg password "$password" \
      --arg server_name "$servername" \
      --argjson server_port "$listen_port" \
      --argjson insecure "$skip_cert_verify" \
      --argjson alpn "$alpn_json" \
      --argjson up_mbps "$up_mbps_json" \
      --argjson down_mbps "$down_mbps_json" \
      --argjson obfs "$obfs_json" \
      '{
        type: "hysteria2",
        tag: $tag,
        server: $server,
        server_port: $server_port,
        password: $password,
        tls: {
          enabled: true,
          server_name: $server_name,
          insecure: $insecure,
          alpn: $alpn
        }
      }
      | if $up_mbps == null then . else . + { up_mbps: $up_mbps } end
      | if $down_mbps == null then . else . + { down_mbps: $down_mbps } end
      | if $obfs == null then . else . + { obfs: $obfs } end')"

    append_client_outbound "$outbound_obj" "$tag"
  done

  local config_json
  config_json="$(jq -n \
    --argjson proxy_outbounds "$outbounds_json" \
    --argjson selector_outbounds "$selector_outbounds_json" \
    '{
      log: {
        level: "info",
        timestamp: true
      },
      inbounds: [
        {
          type: "mixed",
          tag: "mixed-in",
          listen: "127.0.0.1",
          listen_port: 7890
        }
      ],
      outbounds: (
        $proxy_outbounds
        + (if ($selector_outbounds | length) > 0 then [
          {
            type: "selector",
            tag: "proxy",
            outbounds: $selector_outbounds
          }
        ] else [] end)
        + [
          {
            type: "direct",
            tag: "direct"
          }
        ]
      ),
      route: {
        final: (if ($selector_outbounds | length) > 0 then "proxy" else "direct" end)
      }
    }')"

  jq '.' <<< "$config_json" > "${GENERATED_DIR}/sing-box-client.json"
  log_info "已生成 sing-box 客户端配置: ${GENERATED_DIR}/sing-box-client.json"
}

render_socks_installer() {
  local socks_proxy_port
  socks_proxy_port="$(get_warp_egress_port)"
  assert_port "$socks_proxy_port" 'egress.warp.port'

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

  populate_reality_backend_credentials
  validate_unique_bindings

  if has_ingress; then
    render_nginx_config
  fi

  if has_sing_box_workload; then
    render_sing_box_config
  fi

  render_mihomo_config
  render_sing_box_client_config

  if has_local_warp_egress; then
    render_socks_installer
  fi

  log_info "渲染阶段完成"
}
