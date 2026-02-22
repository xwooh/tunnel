#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

ensure_env_file() {
  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

load_env() {
  ensure_env_file
  set -a
  source "$ENV_FILE"
  set +a
}

quote_env_value() {
  local raw="$1"
  printf '%q' "$raw"
}

upsert_env() {
  local key="$1"
  local value="$2"
  local escaped
  escaped="$(quote_env_value "$value")"

  ensure_env_file
  local tmp
  tmp="$(mktemp)"

  awk -v k="$key" -v v="$escaped" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" {
      print k "=" v
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print k "=" v
      }
    }
  ' "$ENV_FILE" > "$tmp"

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

prompt_env_value() {
  local key="$1"
  local prompt_text="$2"
  local is_secret="${3:-false}"
  local value=""

  while [[ -z "$value" ]]; do
    if is_true "$is_secret"; then
      read -r -s -p "$prompt_text: " value
      printf '\n'
    else
      read -r -p "$prompt_text: " value
    fi

    if [[ -z "$value" ]]; then
      log_warn "${key} 不能为空"
    fi
  done

  upsert_env "$key" "$value"
}

set_default_env_value() {
  local key="$1"
  local default_value="$2"
  local current_value="${!key:-}"

  if [[ -z "$current_value" ]]; then
    upsert_env "$key" "$default_value"
  fi
}

ensure_required_env_value() {
  local key="$1"
  local prompt_text="$2"
  local is_secret="${3:-false}"
  local current_value="${!key:-}"

  if [[ -z "$current_value" ]]; then
    prompt_env_value "$key" "$prompt_text" "$is_secret"
    load_env
  fi
}

setup_env() {
  load_env

  set_default_env_value "ENABLE_CERT_ISSUE" "true"
  set_default_env_value "ENABLE_WARP_INSTALL" "auto"
  set_default_env_value "AUTO_RESTART_SERVICES" "true"

  load_env

  ensure_required_env_value "CF_Token" "请输入 Cloudflare API Token" "true"
  ensure_required_env_value "CF_Zone_ID" "请输入 Cloudflare Zone ID" "true"
  ensure_required_env_value "ACME_EMAIL" "请输入 acme.sh 注册邮箱" "false"

  load_env

  log_info "环境变量已就绪: ${ENV_FILE}"
}
