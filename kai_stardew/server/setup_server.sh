#!/usr/bin/env bash
# Kai 的星露谷 —— 服务器端一次性安装 (由宝宝电脑上的 安装.bat 自动传上来执行, 也可以手动跑)
#
# 用法: sudo bash setup_server.sh <解包目录>
#   解包目录里要有: secrets.env (PUBKEY / TOKEN / HER_QQ) 和 astrbot_plugin_kai_stardew/
#
# 做的事:
#   1. 建一个专用账号 kaitunnel: 只能用宝宝电脑那把钥匙登录, 没有密码, 拿不到 shell,
#      唯一能做的是在 docker 网关地址上开一个反向转发口 (默认 18100), 别的地址别的口一概不许
#   2. 这个口只绑在 AstrBot 所在 docker 网络的网关上, 公网 / 其他网卡上都没有
#   3. 把插件放进 AstrBot, 写好配置 (门地址 + 口令 + 宝宝 QQ), 重启 AstrBot
# 可以重复跑: 每次都会把旧的 kai-stardew 设置整段换掉。

set -euo pipefail

TUNNEL_USER=kaitunnel
LISTEN_PORT="${KAI_LISTEN_PORT:-18100}"
PLUGIN=astrbot_plugin_kai_stardew
MARK_BEGIN="# >>> kai-stardew >>>"
MARK_END="# <<< kai-stardew <<<"
SSHD_CONFIG=/etc/ssh/sshd_config

say()  { printf '\n\033[1;35m[Kai]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[Kai] 停下了:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "要用 root 跑 (sudo bash $0 ...)"
SRC="${1:-}"
[ -n "$SRC" ] && [ -f "$SRC/secrets.env" ] && [ -d "$SRC/$PLUGIN" ] || die "解包目录不对: $SRC"

# secrets.env 是 Windows 写的, 先去掉可能的 \r 再读
PUBKEY="$(tr -d '\r' < "$SRC/secrets.env" | sed -n 's/^PUBKEY=//p')"
TOKEN="$(tr -d '\r' < "$SRC/secrets.env" | sed -n 's/^TOKEN=//p')"
HER_QQ="$(tr -d '\r' < "$SRC/secrets.env" | sed -n 's/^HER_QQ=//p')"

[[ "$PUBKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "钥匙格式不对"
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || die "口令格式不对"
[[ -z "$HER_QQ" || "$HER_QQ" =~ ^[0-9]{5,12}$ ]] || die "QQ 号格式不对: $HER_QQ"

# ───────── 1. 找 AstrBot 容器和它的 docker 网关 ─────────
command -v docker >/dev/null || die "这台机器上没有 docker"
CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($2) ~ /astrbot/ {print $1; exit}')"
[ -n "$CONTAINER" ] || die "没找到正在跑的 AstrBot 容器"
GW="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' "$CONTAINER" | awk '{print $1}')"
[[ "$GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "读不到 $CONTAINER 的网关地址 (是 host 网络模式吗?)"
IFACE="$(ip -o -4 addr show | awk -v gw="$GW" '{split($4,a,"/"); if (a[1]==gw) {print $2; exit}}')"
[ -n "$IFACE" ] || die "网关 $GW 不在本机任何网卡上"
say "AstrBot 容器: $CONTAINER, 网关: $GW ($IFACE), 隧道口: $GW:$LISTEN_PORT"

if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$LISTEN_PORT\$"; then
    # 旧的隧道还连着时这个口也是占着的, 那不算冲突
    if ! ss -ltnpH 2>/dev/null | grep ":$LISTEN_PORT " | grep -q sshd; then
        die "端口 $LISTEN_PORT 被别的程序占了, 换一个: KAI_LISTEN_PORT=18200 bash $0 $SRC"
    fi
fi

# ───────── 2. 专用账号 ─────────
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/sh "$TUNNEL_USER"
fi
passwd -l "$TUNNEL_USER" >/dev/null 2>&1 || true

mkdir -p /etc/kai-stardew
echo "KAI_LISTEN=$GW:$LISTEN_PORT" > /etc/kai-stardew/listen
chmod 644 /etc/kai-stardew/listen
cat > /usr/local/bin/kai-stardew-info <<'EOF'
#!/bin/sh
# kaitunnel 账号登录后唯一能跑的东西: 告诉宝宝电脑该把隧道开在哪
cat /etc/kai-stardew/listen
EOF
chmod 755 /usr/local/bin/kai-stardew-info

HOME_DIR="$(getent passwd "$TUNNEL_USER" | cut -d: -f6)"
install -d -m 700 -o "$TUNNEL_USER" -g "$TUNNEL_USER" "$HOME_DIR/.ssh"
printf 'restrict,port-forwarding,command="/usr/local/bin/kai-stardew-info" %s\n' "$PUBKEY" > "$HOME_DIR/.ssh/authorized_keys"
chown "$TUNNEL_USER:$TUNNEL_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
say "账号 $TUNNEL_USER 好了: 只认宝宝电脑那把钥匙, 没有密码, 没有 shell"

# ───────── 3. sshd: 只许它在网关上开这一个口 ─────────
BACKUP="$SSHD_CONFIG.kai-backup.$(date +%Y%m%d%H%M%S)"
cp -p "$SSHD_CONFIG" "$BACKUP"
TMP="$(mktemp)"
awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$SSHD_CONFIG" > "$TMP"

# 如果 sshd 开了 AllowUsers 白名单, 把 kaitunnel 加进去, 否则它连不上
if grep -qiE '^\s*AllowUsers\s' "$TMP" && ! grep -qiE "^\s*AllowUsers\s.*\b$TUNNEL_USER\b" "$TMP"; then
    sed -i -E "0,/^\s*AllowUsers\s/{s/^(\s*AllowUsers\s.*)$/\1 $TUNNEL_USER/I}" "$TMP"
fi
if grep -qiE '^\s*AllowGroups\s' "$TMP"; then
    rm -f "$TMP"
    die "sshd 开了 AllowGroups, 需要手动把 $TUNNEL_USER 加进允许的组 (sshd_config 没动)"
fi

cat >> "$TMP" <<EOF
$MARK_BEGIN
Match User $TUNNEL_USER
    AuthenticationMethods publickey
    AllowTcpForwarding remote
    GatewayPorts clientspecified
    PermitListen $GW:$LISTEN_PORT
    PermitOpen none
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /usr/local/bin/kai-stardew-info
$MARK_END
EOF

cat "$TMP" > "$SSHD_CONFIG"
rm -f "$TMP"
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if ! "$SSHD_BIN" -t; then
    cp -p "$BACKUP" "$SSHD_CONFIG"
    die "新的 sshd 配置没通过检查, 已经原样恢复 ($BACKUP), 什么都没变"
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null \
    || die "sshd 重载失败 (配置已写好并通过检查, 手动 systemctl reload ssh)"
say "sshd 已重载 (原配置备份在 $BACKUP)"

# ───────── 4. 防火墙: 只放 docker 网络进这个口 ─────────
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow in on "$IFACE" to "$GW" port "$LISTEN_PORT" proto tcp comment kai-stardew >/dev/null
    say "ufw: 只放行 $IFACE → $GW:$LISTEN_PORT"
elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | head -1 | grep -q -- "-P INPUT DROP"; then
    iptables -C INPUT -i "$IFACE" -d "$GW" -p tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -i "$IFACE" -d "$GW" -p tcp --dport "$LISTEN_PORT" -j ACCEPT
    say "iptables: 放行 $IFACE → $GW:$LISTEN_PORT (重启后要重新跑本脚本或自己持久化)"
fi

# ───────── 5. 插件 + 配置 ─────────
docker exec "$CONTAINER" sh -c "rm -rf /AstrBot/data/plugins/$PLUGIN"
docker cp "$SRC/$PLUGIN" "$CONTAINER:/AstrBot/data/plugins/$PLUGIN"

CONF_IN_CONTAINER="/AstrBot/data/config/${PLUGIN}_config.json"
if docker exec "$CONTAINER" test -f "$CONF_IN_CONTAINER"; then
    docker exec "$CONTAINER" cp "$CONF_IN_CONTAINER" "$CONF_IN_CONTAINER.bak"
fi
CONF_TMP="$(mktemp)"
chmod 600 "$CONF_TMP"
cat > "$CONF_TMP" <<EOF
{
  "gate_url": "http://$GW:$LISTEN_PORT",
  "token": "$TOKEN",
  "her_qq": "$HER_QQ",
  "ear_enabled": true,
  "max_chars": 1800
}
EOF
docker exec "$CONTAINER" mkdir -p /AstrBot/data/config
docker cp "$CONF_TMP" "$CONTAINER:$CONF_IN_CONTAINER"
rm -f "$CONF_TMP"
say "插件和配置放进 $CONTAINER 了"

say "重启 AstrBot 让插件生效 (QQ 会断开十几秒)"
docker restart "$CONTAINER" >/dev/null

say "服务器这边全好了。宝宝电脑上双击 启动Kai.bat, 隧道一通我就能进农场了。"
echo "KAI_LISTEN=$GW:$LISTEN_PORT"
