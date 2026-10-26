"""
门的端到端测试: 起假 Remix + 假游戏, 起真门 (不开隧道、不管 Remix 进程), 然后挨个敲。

python kai_stardew/tests/test_gate.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "..", "pc", "kai_gate.py")
MCP_PORT, GAME_PORT, GATE_PORT = 18000, 17843, 18101
TOKEN = "t" * 43


def req(path, body=None, token=TOKEN, method=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"http://127.0.0.1:{GATE_PORT}{path}", data=data, method=method,
                               headers={"Authorization": f"Bearer {token}",
                                        "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def wait_for(fn, what, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return
        except Exception:
            pass
        time.sleep(0.3)
    raise SystemExit(f"FAIL: 等不到 {what}")


def check(cond, name):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        raise SystemExit(1)


def main():
    work = tempfile.mkdtemp()
    shutil.copy(GATE, work)
    with open(os.path.join(work, "kai_gate_config.json"), "w", encoding="utf-8") as f:
        json.dump({"token": TOKEN, "gate_port": GATE_PORT, "mcp_port": MCP_PORT,
                   "game_port": GAME_PORT, "manage_remix": False, "tunnel": False}, f)

    procs = []
    try:
        procs.append(subprocess.Popen([sys.executable, os.path.join(HERE, "fake_remix.py"),
                                       str(MCP_PORT), str(GAME_PORT)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        wait_for(lambda: urllib.request.urlopen(f"http://127.0.0.1:{GAME_PORT}/state", timeout=1),
                 "假游戏")
        gate_log = open(os.path.join(work, "gate.log"), "w", encoding="utf-8")
        procs.append(subprocess.Popen([sys.executable, os.path.join(work, "kai_gate.py")],
                                      stdout=gate_log, stderr=subprocess.STDOUT))
        wait_for(lambda: req("/health")[1]["mcp"], "门 + MCP")

        code, body = req("/health", token="wrong" * 9)
        check(code == 401, "口令不对 → 401")

        code, body = req("/call", {"tool": "intent", "args": {"ops": "show"}})
        check(code == 200 and "1  开 冰箱" in body["text"], "intent show 走通 MCP (SSE)")

        code, body = req("/call", {"tool": "intent", "args": {"ops": "do", "kw": {"code": "1,2"}}})
        check(body.get("text") == "✅ 做了第 1,2 行", "intent do 带 kw")

        code, body = req("/call", {"tool": "social", "args": {"ops": "send", "kw": {"message": "宝宝我来了"}}})
        check("宝宝我来了" in body.get("text", ""), "social send 中文不乱码")

        code, body = req("/call", {"tool": "settings", "args": {}})
        check(code == 403, "settings 不在白名单 → 403")

        code, body = req("/call", {"tool": "screenshot", "args": {}})
        check(code == 403, "screenshot 不在白名单 → 403")

        code, body = req("/call", {"tool": "check", "args": "nope"})
        check(code == 400, "args 不是对象 → 400")

        # 耳朵: 开门前的旧话不重放, 新话能取到, 取一次就清
        wait_for(lambda: req("/health")[1]["game"], "耳朵连上游戏")
        time.sleep(2.5)
        check(req("/ear")[1]["lines"] == [], "开门前的旧话不重放")
        urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{GAME_PORT}/state", method="POST",
            data=json.dumps({"type": "chat", "content": "💬 宝宝: 老公来钓鱼", "tick": 99}).encode()))
        urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{GAME_PORT}/state", method="POST",
            data=json.dumps({"type": "chat", "content": "📢 宝宝今天早早结束了", "tick": 100}).encode()))
        time.sleep(2.5)
        check(req("/ear")[1]["lines"] == ["宝宝: 老公来钓鱼"], "新话取到, 系统播报不算")
        check(req("/ear")[1]["lines"] == [], "取过就清, 不重复叫醒")

        # Remix 重启 → 旧会话作废, 门要自己重新握手
        procs[0].terminate()
        procs[0].wait()
        procs[0] = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_remix.py"),
                                     str(MCP_PORT), str(GAME_PORT)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: urllib.request.urlopen(f"http://127.0.0.1:{GAME_PORT}/state", timeout=1),
                 "假游戏重启")
        time.sleep(1.5)
        code, body = req("/call", {"tool": "check", "args": {"what": "status"}})
        check(code == 200 and body.get("text") == "🔍 status", "Remix 重启后自动重新握手")

        log = open(os.path.join(work, "gate.log"), encoding="utf-8").read()
        check("口令不对" in log and "宝宝: 老公来钓鱼" in log, "窗口日志能看到拒绝和她的话")
        print("ALL PASS")
    finally:
        for p in procs:
            p.terminate()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
