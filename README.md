# hypertunnel

适用于 Ubuntu/Debian 的一键部署工具集。

## 目录作用

`hypertunnel/` 是独立部署工作目录。
渲染阶段只会在此目录内读写。
只有在 `deploy` 阶段才会写入系统路径（`/etc/nginx`、`/etc/sing-box`、`/var/www/html`）。

## 前置条件

1. 以 `root` 用户运行。
2. 运行前准备好 `config/sni-routing.yaml`。
3. 确保域名 DNS 已解析到当前 VPS。

## 首次执行

```bash
cd hypertunnel
cp .env.example .env
./main.sh all
```

脚本会把默认开关写入 `.env`；只有在确实需要签发证书时，才会交互补全 `CF_Token`、`CF_Zone_ID`、`ACME_EMAIL` 并自动写回。

## 命令列表

```bash
./main.sh preflight
./main.sh env
./main.sh deps
./main.sh cert
./main.sh render
./main.sh deploy
./main.sh service
./main.sh verify
./main.sh nearby
./main.sh all
./main.sh rollback list
./main.sh rollback <backup-id>
```

`nearby` 会在首次运行时按 `lib/nearby.sh` 中的 `RIFT_VERSION` 下载对应版本的 `rift` 到 `state/tools/rift/<RIFT_VERSION>/`，随后复用本地缓存并直接启动扫描。

## 配置说明

- 顶层块分为 `egress`、`ingress`、`sing_box`。哪个块存在，就执行哪个块对应的逻辑；缺失的块会整体跳过，不再要求相关字段。
- `CF_Token`、`CF_Zone_ID`、`ACME_EMAIL` 只在启用证书签发且当前证书文件缺失时需要提供。
- `deps` 阶段只会在存在 `ingress` 时安装 `nginx`。
- `ingress` 负责 `443 + SNI` 这一套能力，包括 `public_listen`、`unknown_sni_action`、`static_site`、`reality_backends`、`trojan_backends`。
- `ingress.static_site` 可以省略；省略后会自动选择第一个 `fallback_site.enabled=true` 的 Trojan 后端作为静态站来源，并复用它的 `servername`、`tls_cert_file`、`tls_key_file`。
- 启用 `fallback_site` 的 Trojan 后端建议显式设置 `fallback_site.web_root`；如果没有 `ingress.static_site`，则这是必填项。
- `sing_box.socks5_backends` 会直接生成 sing-box 的独立 SOCKS5 监听端口，不复用 `443 + SNI` 分流。
- `sing_box.socks5_backends[*].server` 是导出客户端配置时使用的连接地址，可以填写域名或 IP。
- `sing_box.socks5_backends[*].listen_host` 是可选的，默认 `0.0.0.0`；如果只想本机可访问，可以改成 `127.0.0.1`。
- backend 的 `egress` 字段是可选的；不填写时默认走内置 `direct`，填写时必须引用顶层 `egress` 中已定义的名字。
- 顶层 `egress` 现在是命名集合，例如 `egress.warp`。当前支持 `type: socks`，可被 `ingress` 和 `sing_box` 下的 backend 共用。
- `ingress.reality_backends[*].user_uuid`、`private_key`、`public_key`、`short_id` 可以留空；执行 `render` 时会自动调用 `sing-box` 生成并写回 `config/sni-routing.yaml`。

## 渲染产物

执行 `render` 后会在 `generated/` 下生成：

- `nginx.conf`（仅在存在 `ingress` 时生成）
- `config.json`（仅在存在 reality/trojan/socks5 backend 时生成）
- `mihomo-client.yaml`
- `install-socks-proxy.sh`（仅在存在本地 `egress.warp` 时生成）

## 备份与回滚

部署前会在以下位置生成快照：

- `state/backups/<timestamp>/manifest.txt`

回滚示例：

```bash
./main.sh rollback list
./main.sh rollback 20260222-120000
```

## 说明

- `ENABLE_WARP_INSTALL=auto` 时，仅在有 backend 引用本地 `egress.warp` 时自动安装 WARP 客户端；WARP 服务启动和代理模式配置在 `service` 阶段执行。
- `nearby` 会根据 `RIFT_VERSION` 生成 `rift-v<RIFT_VERSION>-linux-x86_64-musl` 下载包名，需要在 Linux x86_64 主机上运行。
- 当 `ingress.unknown_sni_action=fallback_static` 且未配置 `ingress.static_site` 时，未知 SNI 会先转发到第一个启用 `fallback_site` 的 Trojan，再由它回落到对应站点。
- `sing_box.socks5_backends` 固定使用用户名密码认证，监听独立公网端口。
