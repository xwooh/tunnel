#!/usr/bin/env bash

source "${HYPERTUNNEL_ROOT}/lib/common.sh"

RIFT_VERSION="0.1.2"
RIFT_RELEASE_FILE="rift-v${RIFT_VERSION}-linux-x86_64-musl.tar.gz"
RIFT_DOWNLOAD_URL="https://github.com/xwooh/rift/releases/download/${RIFT_VERSION}/${RIFT_RELEASE_FILE}"
RIFT_CACHE_DIR="${STATE_DIR}/tools/rift/${RIFT_VERSION}"
RIFT_BIN_PATH=""

assert_nearby_requirements() {
  require_cmd curl
  require_cmd tar
  require_cmd find
  require_cmd chmod
  require_cmd mktemp
}

assert_rift_supported_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  [[ "$os" == "Linux" ]] || die "nearby 命令仅支持 Linux 主机，当前系统: ${os}"
  [[ "$arch" == "x86_64" ]] || die "nearby 命令仅支持 x86_64 主机，当前架构: ${arch}"
}

resolve_rift_binary_path() {
  local candidate=""

  if [[ -x "${RIFT_CACHE_DIR}/rift" ]]; then
    printf '%s' "${RIFT_CACHE_DIR}/rift"
    return 0
  fi

  candidate="$(find "$RIFT_CACHE_DIR" -type f -name 'rift' -print -quit 2>/dev/null || true)"
  [[ -n "$candidate" ]] || return 1

  printf '%s' "$candidate"
}

download_rift_binary() {
  local archive_file=""
  archive_file="$(mktemp)"

  mkdir -p "$RIFT_CACHE_DIR"

  log_info "下载 rift ${RIFT_VERSION}"
  curl -fsSL "$RIFT_DOWNLOAD_URL" -o "$archive_file"

  log_info "解压 rift 到 ${RIFT_CACHE_DIR}"
  tar -xzvf "$archive_file" -C "$RIFT_CACHE_DIR"

  rm -f "$archive_file"
}

ensure_rift_binary() {
  local bin_path=""

  assert_nearby_requirements
  assert_rift_supported_platform
  mkdir -p "$RIFT_CACHE_DIR"

  if bin_path="$(resolve_rift_binary_path)"; then
    chmod +x "$bin_path"
    RIFT_BIN_PATH="$bin_path"
    log_info "使用已缓存的 rift: ${RIFT_BIN_PATH}"
    return 0
  fi

  download_rift_binary

  if ! bin_path="$(resolve_rift_binary_path)"; then
    die "rift 下载完成后未找到可执行文件"
  fi

  chmod +x "$bin_path"
  RIFT_BIN_PATH="$bin_path"
  log_info "rift 已就绪: ${RIFT_BIN_PATH}"
}

run_nearby_scan() {
  ensure_rift_binary
  log_info "开始扫描附近域名连通性"
  "${RIFT_BIN_PATH}" "$@"
}
