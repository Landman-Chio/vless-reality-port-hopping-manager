#!/usr/bin/env bash
# VLESS + REALITY / TLS TCP Port-Hopping Manager
# Copyright (c) 2026 Landman-Chio
set -Eeuo pipefail
IFS=$'\n\t'
VERSION="0.2.0"
BASE="/etc/vless-reality"
CONFIG="$BASE/config.env"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HOP_SCRIPT="/usr/local/sbin/vless-reality-hop-firewall"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[+]\033[0m $*"; }
warn(){ echo -e "${YELLOW}[!]\033[0m $*"; }
die(){ echo -e "${RED}[-]\033[0m $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "请使用 root 运行"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
rand_hex(){ od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
load_config(){ [[ -f "$CONFIG" ]] && source "$CONFIG"; }
save_config(){
  install -d -m 700 "$BASE"; umask 077
  cat >"$CONFIG" <<EOF
MODE="$MODE"
SERVER="$SERVER"
SNI="$SNI"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
LISTEN_PORT="$LISTEN_PORT"
HOP_START="$HOP_START"
HOP_END="$HOP_END"
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
EOF
  chmod 600 "$CONFIG"
}
install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates jq openssl nftables uuid-runtime nginx certbot
}
install_xray(){
  if ! command -v xray >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
}
make_keys(){
  local out
  out="$(xray x25519 2>&1)" || die "生成 REALITY 密钥失败：$out"
  PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': *' '/Private key:/{print $2; exit}')"
  PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': *' '/Public key:/{print $2; exit}')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "无法解析 xray x25519 输出，请检查 Xray 版本"
}
setup_tls_site(){
  [[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || die "请输入有效域名（暂不支持 IP 申请证书）"
  [[ "$EMAIL" == *@*.* ]] || die "请输入有效的证书通知邮箱"
  install -d -m 755 /var/www/vless-reality
  cat >/var/www/vless-reality/index.html <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Welcome</title><body><main><h1>Welcome</h1><p>The website is running normally.</p></main></body></html>
HTML
  cat >/etc/nginx/sites-available/vless-reality-masquerade <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name $DOMAIN;
  root /var/www/vless-reality;
  index index.html;
  location ^~ /.well-known/acme-challenge/ { root /var/www/vless-reality; default_type text/plain; }
  location / { try_files \$uri \$uri/ =404; }
}
server {
  listen 127.0.0.1:8080;
  server_name _;
  root /var/www/vless-reality;
  index index.html;
  location / { try_files \$uri \$uri/ =404; }
}
EOF
  ln -sf /etc/nginx/sites-available/vless-reality-masquerade /etc/nginx/sites-enabled/vless-reality-masquerade
  rm -f /etc/nginx/sites-enabled/default
  nginx -t || die "Nginx 配置校验失败"
  systemctl enable --now nginx
  systemctl reload nginx
  certbot certonly --webroot -w /var/www/vless-reality -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive --keep-until-expiring || die "Let's Encrypt 证书申请失败。请确认域名 A/AAAA 记录指向本机，且 TCP 80 可从公网访问"
}
write_xray_config(){
  local tmp
  tmp="$(mktemp)"
  if [[ "$MODE" == "reality" ]]; then
    jq -n --arg uuid "$UUID" --arg priv "$PRIVATE_KEY" --arg sni "$SNI" --arg sid "$SHORT_ID" --argjson port "$LISTEN_PORT" '
    {log:{loglevel:"warning"},inbounds:[{listen:"0.0.0.0",port:$port,protocol:"vless",
      settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
      streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}},
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],
      outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}]}' >"$tmp"
  else
    jq -n --arg uuid "$UUID" --arg domain "$DOMAIN" --argjson port "$LISTEN_PORT" '
    {log:{loglevel:"warning"},inbounds:[{listen:"0.0.0.0",port:$port,protocol:"vless",
      settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none",
        fallbacks:[{dest:"127.0.0.1:8080",xver:0}]},
      streamSettings:{network:"tcp",security:"tls",tlsSettings:{serverName:$domain,certificates:[{certificateFile:("/etc/letsencrypt/live/"+$domain+"/fullchain.pem"),keyFile:("/etc/letsencrypt/live/"+$domain+"/privkey.pem")}] }},
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],
      outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"blocked"}]}' >"$tmp"
  fi
  install -D -m 600 "$tmp" "$XRAY_CONFIG"; rm -f "$tmp"
  xray run -test -config "$XRAY_CONFIG" || die "Xray 配置校验失败；请检查当前 Xray 版本和配置"
}
write_hop_firewall(){
  cat >"$HOP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
nft delete table inet vless_reality_hop 2>/dev/null || true
nft -f - <<'NFT'
table inet vless_reality_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    tcp dport $HOP_START-$HOP_END redirect to :$LISTEN_PORT
  }
}
NFT
EOF
  chmod 700 "$HOP_SCRIPT"
  cat >/etc/systemd/system/vless-reality-hop-firewall.service <<EOF
[Unit]
Description=VLESS TCP port hopping firewall rules
After=network-online.target nftables.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$HOP_SCRIPT
ExecStop=/bin/sh -c 'nft delete table inet vless_reality_hop 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now vless-reality-hop-firewall.service
}
setup(){
  need_root
  echo "=== VLESS TCP Port-Hopping Manager v$VERSION ==="
  echo "1) REALITY：使用第三方真实站点作为握手目标（不需要节点证书）"
  echo "2) TLS：自有域名 + Let's Encrypt 证书 + HTTPS 网站伪装"
  read -r -p "请选择模式 [1]: " choice; choice="${choice:-1}"
  case "$choice" in 1) MODE="reality";; 2) MODE="tls";; *) die "模式无效";; esac
  read -r -p "节点连接地址（公网 IP 或域名）: " SERVER
  [[ -n "$SERVER" ]] || die "服务器地址不能为空"
  if [[ "$MODE" == "reality" ]]; then
    read -r -p "REALITY 目标 SNI（例如 www.microsoft.com）: " SNI
    [[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确"
    DOMAIN=""
    EMAIL=""
  else
    read -r -p "自有域名（必须已解析到本机）: " DOMAIN
    read -r -p "Let's Encrypt 通知邮箱: " EMAIL
    SNI="$DOMAIN"
  fi
  read -r -p "Xray 本机监听端口 [443]: " LISTEN_PORT; LISTEN_PORT="${LISTEN_PORT:-443}"
  valid_port "$LISTEN_PORT" || die "监听端口无效"
  read -r -p "TCP 跳跃端口起始 [20000]: " HOP_START; HOP_START="${HOP_START:-20000}"
  read -r -p "TCP 跳跃端口结束 [30000]: " HOP_END; HOP_END="${HOP_END:-30000}"
  valid_port "$HOP_START" && valid_port "$HOP_END" && ((HOP_START<=HOP_END)) || die "跳跃端口范围无效"
  (( LISTEN_PORT < HOP_START || LISTEN_PORT > HOP_END )) || die "监听端口不能包含在跳跃端口范围内"
  install_deps
  install_xray
  if [[ "$MODE" == "tls" ]]; then
    (( LISTEN_PORT != 80 )) || die "TLS 模式监听端口不能是 80"
    setup_tls_site
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
  else
    UUID="$(cat /proc/sys/kernel/random/uuid)"
    SHORT_ID="$(rand_hex 8)"
    make_keys
  fi
  save_config
  write_xray_config
  write_hop_firewall
  systemctl enable --now xray
  systemctl restart xray
  log "安装完成"
  show_client
}
show_client(){
  load_config || { warn "尚未安装"; return; }
  echo; echo "模式: $MODE"; echo "服务器: $SERVER"; echo "UUID: $UUID"
  echo "监听端口: $LISTEN_PORT"; echo "TCP 跳跃端口范围: $HOP_START-$HOP_END"
  if [[ "$MODE" == "reality" ]]; then
    echo "REALITY SNI: $SNI"; echo "Public Key: $PUBLIC_KEY"; echo "Short ID: $SHORT_ID"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#VLESS-REALITY\n' "$UUID" "$SERVER" "$HOP_START" "$SNI" "$PUBLIC_KEY" "$SHORT_ID"
  else
    echo "TLS 域名: $DOMAIN"; echo "证书: /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=tls&sni=%s&fp=chrome&type=tcp&headerType=none#VLESS-TLS\n' "$UUID" "$SERVER" "$HOP_START" "$DOMAIN"
  fi
  warn "当前为服务端 TCP 端口映射；客户端自动轮换端口尚未实现。"
}
status(){
  systemctl --no-pager --full status xray 2>/dev/null || true
  systemctl --no-pager --full status vless-reality-hop-firewall 2>/dev/null || true
  [[ -f /etc/nginx/sites-enabled/vless-reality-masquerade ]] && systemctl --no-pager --full status nginx 2>/dev/null || true
  nft list table inet vless_reality_hop 2>/dev/null || true
}
logs(){ journalctl -u xray -n 80 --no-pager; }
restart(){ systemctl restart xray; systemctl restart vless-reality-hop-firewall; systemctl reload nginx 2>/dev/null || true; log "服务已重启"; }
backup(){
  need_root; [[ -d "$BASE" ]] || die "未找到配置"
  local f="/root/vless-reality-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$f" "$BASE" "$XRAY_CONFIG" "$HOP_SCRIPT" /etc/systemd/system/vless-reality-hop-firewall.service /etc/nginx/sites-available/vless-reality-masquerade 2>/dev/null || true
  chmod 600 "$f"; log "备份文件：$f"
}
uninstall(){
  need_root; read -r -p "确认卸载本项目配置？输入 YES: " ok; [[ "$ok" == YES ]] || return
  systemctl disable --now vless-reality-hop-firewall.service 2>/dev/null || true
  systemctl disable --now xray 2>/dev/null || true
  rm -f /etc/systemd/system/vless-reality-hop-firewall.service "$HOP_SCRIPT" /etc/nginx/sites-enabled/vless-reality-masquerade /etc/nginx/sites-available/vless-reality-masquerade
  rm -rf "$BASE" /usr/local/etc/xray /var/www/vless-reality
  systemctl daemon-reload; nginx -t && systemctl reload nginx || true
  warn "已移除本项目配置。未自动删除证书、Nginx/Xray 软件包或其他防火墙规则。"
}
menu(){
 while true; do
  echo; echo "=============================================="
  echo " VLESS TCP Port-Hopping Manager v$VERSION"
  echo "=============================================="
  echo "1) 安装 / 重新配置节点（REALITY 或 TLS）"
  echo "2) 查看客户端参数 / 分享链接"
  echo "3) 查看服务状态"
  echo "4) 查看最近日志"
  echo "5) 重启服务"
  echo "6) 备份配置"
  echo "7) 卸载本项目配置"
  echo "0) 退出"
  read -r -p "请选择: " c
  case "$c" in 1) setup;; 2) show_client;; 3) status;; 4) logs;; 5) restart;; 6) backup;; 7) uninstall;; 0) exit 0;; *) warn "无效选项";; esac
 done
}
menu "$@"
