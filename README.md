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

如果 `.env` 中缺少必填项，脚本会交互提示并自动写回。

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

- `static_site` 现在可以省略；省略后会自动选择第一个 `fallback_site.enabled=true` 的 Trojan 后端作为静态站来源。
- 在省略 `static_site` 的模式下，静态站域名与证书会复用该 Trojan 的 `servername`、`tls_cert_file`、`tls_key_file`。
- 启用 `fallback_site` 的 Trojan 后端建议显式设置 `fallback_site.web_root`；如果没有 `static_site`，则这是必填项。
- `socks5_backends` 会直接生成 sing-box 的独立 SOCKS5 监听端口，不复用 `443 + SNI` 分流。
- `socks5_backends[*].server` 是导出客户端配置时使用的连接地址，可以填写域名或 IP。

## 渲染产物

执行 `render` 后会在 `generated/` 下生成：

- `nginx.conf`
- `config.json`（sing-box）
- `mihomo-client.yaml`
- `install-socks-proxy.sh`

## 备份与回滚

部署前会在以下位置生成快照：

- `state/backups/<timestamp>/manifest.txt`

回滚示例：

```bash
./main.sh rollback list
./main.sh rollback 20260222-120000
```

## 说明

- `ENABLE_WARP_INSTALL=auto` 时，仅在存在 `use_socks: true` 后端时自动安装 WARP socks。
- `nearby` 会根据 `RIFT_VERSION` 生成 `rift-v<RIFT_VERSION>-linux-x86_64-musl` 下载包名，需要在 Linux x86_64 主机上运行。
- 当 `ingress.unknown_sni_action=fallback_static` 且未配置 `static_site` 时，未知 SNI 会先转发到第一个启用 `fallback_site` 的 Trojan，再由它回落到对应站点。
- `socks5_backends` 固定使用用户名密码认证，监听独立公网端口，不参与 `use_socks` 出站路由。
