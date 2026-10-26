#!/usr/bin/env bash
# 隧道 + 服务器锁的端到端测试。⚠️ 只在一次性的 root 沙箱里跑 (会改 /etc/ssh/sshd_config、建 kaitunnel 账号)。
# 需要: openssh-server/client, iproute2, python3 + mcp<2。
#
# 做法: 在 lo 上挂一个假 "docker 网关" 172.31.255.1, 用假 docker/systemctl 跑真的 setup_server.sh,
# 起真 sshd + 真门 + 假 Remix, 然后从正面走一遍, 再扮坏人撬一遍。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KAI="$(dirname "$HERE")"
W="$(mktemp -d)"
GW=172.31.255.1
PORT=18100
SSH_PORT=22022
MCP_PORT=18020 GAME_PORT=17863 GATE_PORT=8100
FAILS=0
GATE="" REMIX=""
cleanup() {
    kill $GATE $REMIX 2>/dev/null
    [ -f "$W/sshd.pid" ] && kill "$(cat "$W/sshd.pid")" 2>/dev/null
    return 0
}
trap cleanup EXIT
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS+1)); }

ip -o -4 addr show | grep -q " $GW/" || ip addr add "$GW/32" dev lo

# ── 假 docker / systemctl ──
mkdir -p "$W/bin" "$W/fake/AstrBot/data/plugins"
cat > "$W/bin/docker" <<EOF
#!/usr/bin/env bash
F="$W/fake"
case "\$1" in
  ps) echo "astrbot soulter/astrbot:latest" ;;
  inspect) echo "$GW " ;;
  exec) shift 2; cmd="\$*"; cmd="\${cmd//\/AstrBot/\$F/AstrBot}"
        if [ "\$1" = sh ]; then eval "\${cmd#sh -c }"; else eval "\$cmd"; fi ;;
  cp) dst="\${3#astrbot:}"; cp -r "\$2" "\$F\$dst" ;;
  restart) echo restarted ;;
esac
EOF
cat > "$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
kill -HUP "\$(cat $W/sshd.pid)"
EOF
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH"

# ── 真 sshd ──
ssh-keygen -A >/dev/null
mkdir -p /run/sshd
grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config || sed -i "1i Port $SSH_PORT" /etc/ssh/sshd_config
/usr/sbin/sshd -f /etc/ssh/sshd_config -o PidFile="$W/sshd.pid"
sleep 1

# ── 宝宝电脑那边的钥匙 + 打包 ──
ssh-keygen -q -t ed25519 -N "" -C kai-stardew -f "$W/key"
ssh-keygen -q -t ed25519 -N "" -C attacker -f "$W/evil"
TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
mkdir -p "$W/bundle/server"
cp "$KAI/server/setup_server.sh" "$W/bundle/server/"
cp -r "$KAI/astrbot_plugin_kai_stardew" "$W/bundle/"
printf 'PUBKEY=%s\r\nTOKEN=%s\r\nHER_QQ=123456\r\n' "$(cat "$W/key.pub")" "$TOKEN" > "$W/bundle/secrets.env"

# 走宝宝真实的路, 两句关键命令都从 setup_pc.ps1 里原样抠出来 (按 PowerShell 引号规则还原):
#   ① 她用手机 Termius 粘贴的那一行 (让服务器认识电脑钥匙) —— 这里用 root 直接跑来模拟
#   ② 电脑拿自己的钥匙 scp 上传, 再 ssh -t 执行安装
# 顺便模拟 Windows 打包时脚本带了 CRLF。
ssh-keygen -q -t ed25519 -N "" -C kai-pc -f "$W/pc_admin"
sed -i 's/$/\r/' "$W/bundle/server/setup_server.sh"
tar -czf "$W/bundle.tgz" -C "$W/bundle" .
python3 - "$KAI/pc/setup_pc.ps1" "$W/pc_admin.pub" "$W/phone_line.sh" "$W/remote.sh" <<'PY'
import re, sys
ps = open(sys.argv[1], encoding="utf-8-sig").read()
line = re.search(r'^\s*\$line = "(.*)"\s*$', ps, re.M).group(1)
line = line.replace("$adminPub", open(sys.argv[2]).read().strip())
assert "$" not in line, line
remote = re.search(r"^\$remote = '((?:[^']|'')*)'\s*$", ps, re.M).group(1).replace("''", "'")
open(sys.argv[3], "w").write(line + "\n")
open(sys.argv[4], "w").write(remote)
PY
OUT="$(HOME=/root bash "$W/phone_line.sh" 2>&1)"
[ "$OUT" = "KAI-OK" ] && pass "手机粘贴的那一行跑通 (回 KAI-OK)" || fail "手机那一行: $OUT"
ssh-keyscan -p $SSH_PORT 127.0.0.1 2>/dev/null > "$W/known_hosts"
ADMIN=(-i "$W/pc_admin" -o IdentitiesOnly=yes -o UserKnownHostsFile="$W/known_hosts" -o StrictHostKeyChecking=yes)
ssh "${ADMIN[@]}" -p $SSH_PORT -o BatchMode=yes root@127.0.0.1 true && pass "服务器认识电脑钥匙了" || fail "电脑钥匙登不上"
for round in 1 2; do
    scp "${ADMIN[@]}" -q -P $SSH_PORT "$W/bundle.tgz" root@127.0.0.1:kai_stardew_bundle.tgz || fail "scp"
    # 登进去以后 PATH 是 sshd 给的, 前面补上假 docker/systemctl, 其余就是 setup_pc.ps1 里那句原样
    ssh "${ADMIN[@]}" -t -p $SSH_PORT root@127.0.0.1 "PATH=$W/bin:\$PATH; $(cat "$W/remote.sh")" > "$W/setup$round.log" 2>&1 \
        && grep -q "服务器这边全好了" "$W/setup$round.log" && pass "电脑自动上传+安装跑通 (第 $round 次)" \
        || { fail "自动安装第 $round 次"; cat "$W/setup$round.log"; }
done
[ ! -e /root/kai_stardew_bundle.tgz ] && pass "装完包删了 (口令不留在服务器上)" || fail "包还留在家目录"
[ "$(grep -c '>>> kai-stardew >>>' /etc/ssh/sshd_config)" = 1 ] && pass "sshd_config 里只有一段 kai-stardew" || fail "sshd_config 段落重复"
CONF="$W/fake/AstrBot/data/config/astrbot_plugin_kai_stardew_config.json"
python3 -c "import json,sys;c=json.load(open('$CONF'));sys.exit(0 if c['token']=='$TOKEN' and c['gate_url']=='http://$GW:$PORT' and c['her_qq']=='123456' else 1)" \
    && pass "插件配置写对了 (口令/门地址/QQ)" || fail "插件配置"
[ -f "$W/fake/AstrBot/data/plugins/astrbot_plugin_kai_stardew/main.py" ] && pass "插件放进去了" || fail "插件没放进去"

ssh-keyscan -p $SSH_PORT 127.0.0.1 2>/dev/null > "$W/known_hosts"
SSH=(ssh -i "$W/key" -p $SSH_PORT -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$W/known_hosts" -o StrictHostKeyChecking=yes)
EVIL=(ssh -i "$W/evil" -p $SSH_PORT -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$W/known_hosts" -o StrictHostKeyChecking=yes)

# ── 正面: 门 + 隧道 ──
python3 "$HERE/fake_remix.py" $MCP_PORT $GAME_PORT >/dev/null 2>&1 &
REMIX=$!
mkdir -p "$W/pc"
cp "$KAI/pc/kai_gate.py" "$W/pc/"
cat > "$W/pc/kai_gate_config.json" <<EOF
{"token": "$TOKEN", "gate_port": $GATE_PORT, "mcp_port": $MCP_PORT, "game_port": $GAME_PORT,
 "manage_remix": false, "tunnel": true, "server_host": "127.0.0.1", "ssh_port": $SSH_PORT,
 "ssh_key": "$W/key", "known_hosts": "$W/known_hosts"}
EOF
python3 "$W/pc/kai_gate.py" > "$W/gate.log" 2>&1 &
GATE=$!
for _ in $(seq 40); do ss -ltnH | grep -q "$GW:$PORT" && break; sleep 0.5; done
ss -ltnH | grep -q "$GW:$PORT" && pass "隧道开在假网关 $GW:$PORT" || { fail "隧道没开"; cat "$W/gate.log"; }
ss -ltnH | awk '{print $4}' | grep -E "^(0\.0\.0\.0|\*|\[::\]):$PORT$" && fail "隧道口暴露在所有网卡上" || pass "隧道口没绑到 0.0.0.0"
for _ in $(seq 20); do
    H="$(curl -s -H "Authorization: Bearer $TOKEN" "http://$GW:$PORT/health")"
    echo "$H" | grep -q '"mcp": true' && break; sleep 0.5
done
echo "$H" | grep -q '"mcp": true' && pass "从服务器侧经隧道敲门: $H" || fail "经隧道敲门: $H"
R="$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"tool":"intent","args":{"ops":"do","kw":{"code":"1"}}}' "http://$GW:$PORT/call")"
echo "$R" | grep -q '做了第 1 行' && pass "经隧道调工具" || fail "经隧道调工具: $R"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://$GW:$PORT/health")" = 401 ] && pass "没口令敲门 → 401" || fail "没口令也进来了"

# ── 扮坏人 ──
OUT="$(timeout 10 "${SSH[@]}" kaitunnel@127.0.0.1 'id; cat /etc/shadow' 2>&1)"
[ "$OUT" = "KAI_LISTEN=$GW:$PORT" ] && pass "拿着钥匙也要不到 shell (只回监听地址)" || fail "钥匙拿到了别的东西: $OUT"
OUT="$(printf 'id\n' | timeout 10 "${SSH[@]}" -tt kaitunnel@127.0.0.1 2>&1)"
echo "$OUT" | grep -q "uid=" && fail "要到了终端: $OUT" || pass "要终端被拒, 往里塞命令也没用"
OUT="$(printf 'id\n' | timeout 10 "${SSH[@]}" kaitunnel@127.0.0.1 2>&1)"
echo "$OUT" | grep -q "uid=" && fail "stdin 塞命令执行了: $OUT" || pass "stdin 塞命令不执行"
timeout 10 "${SSH[@]}" -N -o ExitOnForwardFailure=yes -R 0.0.0.0:18200:127.0.0.1:$GATE_PORT kaitunnel@127.0.0.1 >/dev/null 2>&1
[ $? -ne 0 ] && pass "不许把口开到 0.0.0.0" || fail "能开到 0.0.0.0"
timeout 10 "${SSH[@]}" -N -o ExitOnForwardFailure=yes -R 127.0.0.1:18201:127.0.0.1:$GATE_PORT kaitunnel@127.0.0.1 >/dev/null 2>&1
[ $? -ne 0 ] && pass "不许把口开到别的地址" || fail "能开到 127.0.0.1"
timeout 10 "${SSH[@]}" -N -o ExitOnForwardFailure=yes -R $GW:18202:127.0.0.1:$GATE_PORT kaitunnel@127.0.0.1 >/dev/null 2>&1
[ $? -ne 0 ] && pass "同一个网关也不许开别的端口" || fail "能开别的端口"
timeout 6 "${SSH[@]}" -N -L 127.0.0.1:19999:127.0.0.1:$SSH_PORT kaitunnel@127.0.0.1 >/dev/null 2>&1 &
sleep 2
timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/19999; head -c 7 <&3" 2>/dev/null | grep -q SSH && fail "能用 -L 摸进服务器内网" || pass "不许 -L 往服务器里钻"
timeout 10 "${EVIL[@]}" kaitunnel@127.0.0.1 true >/dev/null 2>&1
[ $? -ne 0 ] && pass "别的钥匙进不来" || fail "别的钥匙进来了"
timeout 10 ssh -p $SSH_PORT -o BatchMode=yes -o PubkeyAuthentication=no -o UserKnownHostsFile="$W/known_hosts" kaitunnel@127.0.0.1 true >/dev/null 2>&1
[ $? -ne 0 ] && pass "没钥匙 (密码) 进不来" || fail "没钥匙进来了"

# 服务器开着 fail2ban: 钥匙被拒时门只试一次就停手, 不能连撞把她的 IP 封掉
kill $GATE 2>/dev/null; wait $GATE 2>/dev/null
mkdir -p "$W/pc2"
cp "$KAI/pc/kai_gate.py" "$W/pc2/"
printf '{"token": "%s", "gate_port": 8102, "mcp_port": %s, "game_port": %s, "manage_remix": false, "tunnel": true, "server_host": "127.0.0.1", "ssh_port": %s, "ssh_key": "%s", "known_hosts": "%s"}\n' \
    "$TOKEN" $MCP_PORT $GAME_PORT $SSH_PORT "$W/evil" "$W/known_hosts" > "$W/pc2/kai_gate_config.json"
python3 "$W/pc2/kai_gate.py" > "$W/gate2.log" 2>&1 &
GATE=$!
sleep 15
N="$(grep -c '钥匙被服务器拒绝' "$W/gate2.log")"
[ "$N" = 1 ] && pass "钥匙被拒只试一次就停手 (15 秒内 $N 次, 不会招来 fail2ban)" || { fail "钥匙被拒后试了 $N 次"; cat "$W/gate2.log"; }

[ $FAILS = 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
