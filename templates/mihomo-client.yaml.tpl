port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info

proxies:
__PROXIES_YAML__

proxy-groups:
  - name: PROXY
    type: select
    proxies:
__PROXY_GROUP_ITEMS__
      - DIRECT

rules:
  - MATCH,PROXY
