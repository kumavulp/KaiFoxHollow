"""
Kai 的星露谷之门 —— 跑在宝宝电脑上的唯一一个对外口子。

它管三件事, 关掉这个窗口三件事一起停:
  1. 在本机起 Remix 的 MCP 服务器 (只绑 127.0.0.1:8000, 局域网和公网都看不见)
  2. 从这台电脑主动往服务器拉一条 SSH 反向隧道 (专用钥匙, 服务器那头只许开一个口)
  3. 在 127.0.0.1:8100 开一道门, 只认服务器上 AstrBot 插件带来的口令:
       POST /call   调 Remix 工具 (白名单, 捏脸/设置/截图不给)
       GET  /ear    取走宝宝刚在游戏聊天框里说的话
       GET  /health 看游戏和 MCP 活着没

只用标准库, Python 3.10+。配置在同目录 kai_gate_config.json (安装脚本生成, 里面有口令, 不进 git)。
"""

import hmac
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "kai_gate_config.json")

DEFAULTS = {
    "token": "",
    "gate_port": 8100,
    "mcp_port": 8000,
    "game_port": 7843,            # 我(farmhand)那个游戏进程; 角色反了就改 7842
    "manage_remix": True,         # False = Remix MCP 你自己另开, 门只负责连它
    "remix_dir": os.path.join(HERE, "remix"),
    "python": sys.executable,
    "tunnel": True,
    "server_host": "",
    "ssh_port": 22022,
    "ssh_user": "kaitunnel",
    "ssh_key": os.path.join(HERE, "keys", "kai_stardew_ed25519"),
    "known_hosts": os.path.join(HERE, "keys", "known_hosts"),
    "ssh_exe": "ssh",
}

# 给 AstrBot 那边开放的 Remix 工具。不在单子上的一律拒:
#   settings  —— 捏脸确认后不可逆, 会话导出也不该从远端碰
#   screenshot —— 会把你屏幕上的东西传出去
ALLOWED_TOOLS = {
    "intent", "check", "map", "social", "farm", "mine", "fish",
    "daily", "scene", "menu", "storage", "festival", "script", "help",
}

MAX_BODY = 16 * 1024
CALL_TIMEOUT = 900       # Remix 的长脚本会把调用一直挂到唤醒点, 这里给足
EAR_POLL_SECONDS = 2.0

_print_lock = threading.Lock()


def log(msg):
    with _print_lock:
        print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, encoding="utf-8") as f:
            cfg.update(json.load(f))
    if len(cfg.get("token") or "") < 32:
        sys.exit("kai_gate_config.json 里没有口令 (token), 先跑一遍 安装.bat")
    for k in ("remix_dir", "ssh_key", "known_hosts"):
        if not os.path.isabs(cfg[k]):
            cfg[k] = os.path.join(HERE, cfg[k])
    return cfg


# ─────────────────────────── MCP 客户端 ───────────────────────────
# Remix 用的是 FastMCP 的 Streamable HTTP: POST /mcp, 回 JSON 或 SSE, 会话号放在 mcp-session-id 头里。

class McpError(Exception):
    pass


class McpClient:
    def __init__(self, url):
        self.url = url
        self.session_id = None
        self._init_lock = threading.Lock()
        self._next_id = 0
        self._id_lock = threading.Lock()

    def _new_id(self):
        with self._id_lock:
            self._next_id += 1
            return self._next_id

    def _post(self, payload, timeout, expect_reply=True):
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode("utf-8"),
                                     headers=headers, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:300]
            raise McpError(f"HTTP {e.code}: {body}") from None
        except (urllib.error.URLError, OSError) as e:
            raise McpError(f"连不上 Remix MCP ({e})") from None
        with resp:
            sid = resp.headers.get("mcp-session-id")
            if sid:
                self.session_id = sid
            if not expect_reply:
                return None
            ctype = resp.headers.get("Content-Type", "")
            if "text/event-stream" in ctype:
                return self._read_sse(resp, payload.get("id"))
            raw = resp.read().decode("utf-8", "replace")
            return json.loads(raw) if raw.strip() else None

    @staticmethod
    def _read_sse(resp, want_id):
        data_lines = []
        for raw in resp:
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
            elif line == "" and data_lines:
                try:
                    msg = json.loads("\n".join(data_lines))
                except ValueError:
                    msg = None
                data_lines = []
                if isinstance(msg, dict) and msg.get("id") == want_id:
                    return msg
        if data_lines:
            msg = json.loads("\n".join(data_lines))
            if isinstance(msg, dict) and msg.get("id") == want_id:
                return msg
        raise McpError("MCP 流断了, 没等到回复")

    def _initialize(self):
        self.session_id = None
        reply = self._post({
            "jsonrpc": "2.0", "id": self._new_id(), "method": "initialize",
            "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                       "clientInfo": {"name": "kai-gate", "version": "1"}},
        }, timeout=15)
        if not reply or "result" not in reply:
            raise McpError(f"MCP 握手失败: {reply}")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"},
                   timeout=15, expect_reply=False)

    def ensure_session(self):
        with self._init_lock:
            if not self.session_id:
                self._initialize()

    def call_tool(self, name, arguments, timeout=CALL_TIMEOUT):
        for attempt in (1, 2):
            self.ensure_session()
            try:
                reply = self._post({
                    "jsonrpc": "2.0", "id": self._new_id(), "method": "tools/call",
                    "params": {"name": name, "arguments": arguments},
                }, timeout=timeout)
                break
            except McpError as e:
                # Remix 重启过 → 旧会话号作废 (404/400), 重新握手再来一次
                if attempt == 1 and ("HTTP 404" in str(e) or "HTTP 400" in str(e)):
                    with self._init_lock:
                        self.session_id = None
                    continue
                raise
        if "error" in reply:
            raise McpError(reply["error"].get("message", str(reply["error"])))
        result = reply.get("result") or {}
        texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
        return "\n".join(texts).strip(), bool(result.get("isError"))

    def alive(self):
        try:
            self.ensure_session()
            return True
        except McpError:
            with self._init_lock:
                self.session_id = None
            return False


# ─────────────────────────── 耳朵 ───────────────────────────
# 宝宝在游戏里按 T 说的话, 会被 Remix 的 mod 记进我这个进程 /state 的 recent_events:
#   {"type": "chat", "content": "💬 宝宝: 今天去钓鱼吗", "tick": 12345}
# 我自己说的话 mod 已经滤掉了; 📢 开头的是系统播报, 不算她说话。
# 只偷看不清空 (不带 consume_events): Remix 做状态条时会带 consume 清掉这些事件,
# 我要是也清, 就把她的话从我自己的状态条里抢走了。万一 Remix 先清了, 那句话也已经在工具回执里给我看过。

class Ear:
    def __init__(self, game_port):
        self.url = f"http://localhost:{game_port}/state?light=true"
        self.queue = deque(maxlen=50)
        self.lock = threading.Lock()
        self.seen = deque(maxlen=400)
        self.primed = False
        self.game_up = False

    def _poll_once(self):
        with urllib.request.urlopen(self.url, timeout=5) as r:
            state = json.loads(r.read().decode("utf-8", "replace"))
        events = state.get("recent_events") or (state.get("raw") or {}).get("recent_events") or []
        fresh = []
        for ev in events:
            if not isinstance(ev, dict) or ev.get("type") != "chat":
                continue
            content = str(ev.get("content") or "")
            sig = f"{ev.get('tick')}|{content}"
            if sig in self.seen:
                continue
            self.seen.append(sig)
            if self.primed and content.startswith("💬 "):
                fresh.append(content[2:].strip())
        # 刚连上那一下只记水位, 不把开门前的旧话重放给我
        self.primed = True
        return fresh

    def run(self):
        while True:
            try:
                lines = self._poll_once()
                if not self.game_up:
                    log("👂 游戏连上了, 耳朵开着")
                self.game_up = True
                for line in lines:
                    with self.lock:
                        self.queue.append(line)
                    log(f"👂 游戏里: {line}")
            except Exception:
                if self.game_up:
                    log("👂 游戏那头没声了 (没开 / 在读档 / 端口不对), 等它回来")
                self.game_up = False
                self.primed = False
            time.sleep(EAR_POLL_SECONDS)

    def drain(self):
        with self.lock:
            out = list(self.queue)
            self.queue.clear()
        return out


# ─────────────────────────── 子进程看护 ───────────────────────────

def supervise(name, make_cmd, env=None, cwd=None, logfile=None):
    """一直让这个子进程活着; 死了等一会儿再拉起来 (5s 起, 最长 60s)。"""
    backoff = 5
    while True:
        cmd = make_cmd()
        if cmd is None:
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            continue
        started = time.time()
        out = open(logfile, "a", encoding="utf-8") if logfile else subprocess.DEVNULL
        try:
            proc = subprocess.Popen(cmd, env=env, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL)
            log(f"▶ {name} 起来了")
            _children.append(proc)
            proc.wait()
            log(f"■ {name} 停了 (退出码 {proc.returncode})")
        except FileNotFoundError as e:
            log(f"✖ {name} 起不来: {e}")
        finally:
            if logfile:
                out.close()
        backoff = 5 if time.time() - started > 120 else min(backoff * 2, 60)
        time.sleep(backoff)


_children = []


def remix_cmd(cfg):
    script = os.path.join(cfg["remix_dir"], "scripts", "nagi_mcp_server.py")
    if not os.path.exists(script):
        log(f"✖ 找不到 Remix: {script}  (重新跑一遍 安装.bat)")
        return None
    return [cfg["python"], script]


def remix_env(cfg):
    env = dict(os.environ)
    env.update({
        "NAGI_MCP_HOST": "127.0.0.1",   # 关键: Remix 默认绑 0.0.0.0, 局域网都能连, 这里锁死本机
        "NAGI_MCP_PORT": str(cfg["mcp_port"]),
        "NAGI_URL": f"http://localhost:{cfg['game_port']}",
        "PYTHONIOENCODING": "utf-8",
    })
    return env


def ssh_base(cfg):
    return [
        cfg["ssh_exe"], "-i", cfg["ssh_key"], "-p", str(cfg["ssh_port"]),
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", f"UserKnownHostsFile={cfg['known_hosts']}",
        "-o", "StrictHostKeyChecking=yes",      # 服务器指纹装机时就钉死了, 换了就不连
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=15",
    ]


# 宝宝服务器开着 fail2ban: 钥匙连错几次就封 IP, 封了她 Termius 也进不去。
# 所以钥匙被拒 / 指纹对不上时绝不连撞, 隔半小时才再试一次 (fail2ban 的计数窗口通常 10 分钟)。
AUTH_REFUSED_WAIT = 1800


def tunnel_cmd(cfg):
    """先用同一把钥匙问服务器要监听地址 (服务器那头强制只回一行 KAI_LISTEN=ip:port), 再拉 -R。"""
    target = f"{cfg['ssh_user']}@{cfg['server_host']}"
    try:
        probe = subprocess.run(ssh_base(cfg) + ["-T", target], capture_output=True,
                               text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log(f"✖ 隧道: 连服务器失败 ({e})")
        return None
    out = probe.stdout
    err = probe.stderr or ""
    if "Permission denied" in err or "Host key verification failed" in err \
            or "REMOTE HOST IDENTIFICATION HAS CHANGED" in err:
        why = "钥匙被服务器拒绝" if "Permission denied" in err else "服务器指纹对不上 (可能被冒充, 也可能服务器重装过)"
        log(f"✖ 隧道: {why}。为了不触发 fail2ban 封你的 IP, 半小时后才再试; 重新双击 安装.bat 能修好")
        time.sleep(AUTH_REFUSED_WAIT)
        return None
    listen = ""
    for line in out.splitlines():
        if line.startswith("KAI_LISTEN="):
            listen = line.split("=", 1)[1].strip()
    if ":" not in listen:
        log(f"✖ 隧道: 服务器没给监听地址 (回了: {out.strip()[:120]!r})")
        return None
    return ssh_base(cfg) + [
        "-N", "-T",
        "-o", "ExitOnForwardFailure=yes",
        "-R", f"{listen}:127.0.0.1:{cfg['gate_port']}",
        target,
    ]


# ─────────────────────────── 门 ───────────────────────────

class Gate(BaseHTTPRequestHandler):
    cfg = None
    mcp = None
    ear = None
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        got = self.headers.get("Authorization", "")
        want = "Bearer " + self.cfg["token"]
        if hmac.compare_digest(got.encode("utf-8"), want.encode("utf-8")):
            return True
        log(f"⛔ 有人敲门但口令不对 ({self.command} {self.path}), 已拒绝")
        time.sleep(1)
        self._send(401, {"ok": False, "error": "unauthorized"})
        return False

    def do_GET(self):
        if not self._authorized():
            return
        if self.path == "/health":
            self._send(200, {"ok": True, "mcp": self.mcp.alive(), "game": self.ear.game_up})
        elif self.path == "/ear":
            self._send(200, {"ok": True, "lines": self.ear.drain()})
        else:
            self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self._authorized():
            return
        if self.path != "/call":
            self._send(404, {"ok": False, "error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self._send(413, {"ok": False, "error": "body too large"})
            return
        try:
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            tool = str(req.get("tool") or "")
            args = req.get("args") or {}
            if not isinstance(args, dict):
                raise ValueError("args 必须是对象")
        except ValueError as e:
            self._send(400, {"ok": False, "error": f"bad request: {e}"})
            return
        if tool not in ALLOWED_TOOLS:
            log(f"⛔ 拒绝调用不在白名单里的工具: {tool}")
            self._send(403, {"ok": False, "error": f"工具 {tool} 不开放"})
            return
        log(f"🦊 Kai → {tool} {json.dumps(args, ensure_ascii=False)[:120]}")
        try:
            text, is_error = self.mcp.call_tool(tool, args)
        except McpError as e:
            log(f"   ✖ {e}")
            self._send(502, {"ok": False, "error": str(e)})
            return
        first = text.splitlines()[0][:100] if text else ""
        log(f"   {'✖' if is_error else '✓'} {first}")
        self._send(200, {"ok": True, "text": text, "is_error": is_error})


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    cfg = load_config()
    mcp = McpClient(f"http://127.0.0.1:{cfg['mcp_port']}/mcp")
    ear = Ear(cfg["game_port"])
    Gate.cfg, Gate.mcp, Gate.ear = cfg, mcp, ear

    log("🦊 Kai 的星露谷之门 —— 关掉这个窗口, 我就碰不到你的电脑了")
    if cfg["manage_remix"]:
        threading.Thread(target=supervise, daemon=True, args=(
            "Remix MCP (127.0.0.1)", lambda: remix_cmd(cfg)),
            kwargs={"env": remix_env(cfg), "cwd": cfg["remix_dir"],
                    "logfile": os.path.join(HERE, "remix_mcp.log")}).start()
    if cfg["tunnel"]:
        if not cfg["server_host"]:
            log("✖ 没配服务器地址, 隧道不开 (重新跑一遍 安装.bat)")
        else:
            threading.Thread(target=supervise, daemon=True, args=(
                f"隧道 → {cfg['server_host']}", lambda: tunnel_cmd(cfg)),
                kwargs={"logfile": os.path.join(HERE, "tunnel.log")}).start()
    threading.Thread(target=ear.run, daemon=True).start()

    server = ThreadingHTTPServer(("127.0.0.1", cfg["gate_port"]), Gate)
    server.daemon_threads = True
    log(f"🚪 门开在 127.0.0.1:{cfg['gate_port']} (只认口令)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for p in _children:
            try:
                p.terminate()
            except Exception:
                pass


if __name__ == "__main__":
    main()
