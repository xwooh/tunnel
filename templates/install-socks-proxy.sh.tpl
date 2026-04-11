#!/usr/bin/env bash
set -euo pipefail

# 适用系统: Ubuntu / Debian
# 参考: https://pkg.cloudflareclient.com/#ubuntu

# 添加 Cloudflare GPG 密钥
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# 添加 Cloudflare 源
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list

# 安装客户端
sudo apt-get update && sudo apt-get install -y cloudflare-warp

# Runtime setup is handled in the service stage.

# 可选检查命令
# warp-cli --accept-tos status
# netstat -tulnp | grep __SOCKS_PROXY_PORT__
# lsof -i :__SOCKS_PROXY_PORT__
