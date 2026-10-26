"""
插件测试: 用真 AstrBot (pip 装的同版本) 加载插件, 对着真门 + 假 Remix 调工具, 再验耳朵造出来的事件。
需要在装了 astrbot 的环境里跑:

python kai_stardew/tests/test_plugin.py
"""

import asyncio
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "astrbot_plugin_kai_stardew", "main.py")
GATE = os.path.join(HERE, "..", "pc", "kai_gate.py")
MCP_PORT, GAME_PORT, GATE_PORT = 18010, 17853, 18111
TOKEN = "k" * 43


def check(cond, name):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        raise SystemExit(1)


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


def push_chat(content, tick):
    urllib.request.urlopen(urllib.request.Request(
        f"http://127.0.0.1:{GAME_PORT}/state", method="POST",
        data=json.dumps({"type": "chat", "content": content, "tick": tick}).encode()))


class FakeMeta:
    name = "aiocqhttp"
    id = "qq"


class FakePlatform:
    def __init__(self):
        self.committed = []

    def meta(self):
        from astrbot.core.platform.platform_metadata import PlatformMetadata
        return PlatformMetadata(name="aiocqhttp", description="", id="qq")

    def create_event(self, abm):
        from astrbot.core.platform.sources.aiocqhttp.aiocqhttp_message_event import AiocqhttpMessageEvent
        return AiocqhttpMessageEvent(message_str=abm.message_str, message_obj=abm,
                                     platform_meta=self.meta(), session_id=abm.session_id, bot=None)

    def commit_event(self, ev):
        self.committed.append(ev)


class FakeContext:
    def __init__(self, platform):
        self.platform_manager = type("PM", (), {"platform_insts": [platform]})()


async def run_plugin_checks():
    from astrbot.core.utils import metrics
    metrics.Metric.upload = staticmethod(lambda **kw: asyncio.sleep(0))   # 不往外发统计

    spec = importlib.util.spec_from_file_location("kai_stardew_main", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    from astrbot.core.provider.register import llm_tools
    tools = {f.name: f for f in llm_tools.func_list}
    check({"stardew_look", "stardew_do", "stardew_say", "stardew_go", "stardew_advanced"} <= set(tools),
          "五个工具都注册进 AstrBot")
    props = tools["stardew_advanced"].parameters["properties"]
    check(set(props) == {"tool", "ops", "kw_json"}, "stardew_advanced 参数解析对 (tool/ops/kw_json)")
    check(tools["stardew_look"].parameters.get("properties", {}) == {}, "stardew_look 不要参数")

    platform = FakePlatform()
    config = {"gate_url": f"http://127.0.0.1:{GATE_PORT}", "token": TOKEN, "her_qq": "123456",
              "ear_enabled": True, "max_chars": 300}
    plugin = mod.KaiStardew(FakeContext(platform), config)

    look = await plugin.stardew_look(None)
    check("1  开 冰箱" in look and "中间省略" in look and len(look) < 400, "stardew_look 拿到单子并裁短")
    check(await plugin.stardew_do(None, "2") == "✅ 做了第 2 行", "stardew_do")
    check("我来啦" in await plugin.stardew_say(None, "我来啦"), "stardew_say")
    adv = await plugin.stardew_advanced(None, "check", "status", "{}")
    check(adv == "🔍 status", "stardew_advanced check 走 what")
    check("没有 settings" in await plugin.stardew_advanced(None, "settings", "x", "{}"), "advanced 拒绝 settings")
    check("不是合法" in await plugin.stardew_advanced(None, "farm", "till", "{oops"), "kw_json 坏了会说")

    bad = mod.KaiStardew(FakeContext(platform), dict(config, token="w" * 43))
    check("拒绝" in await bad.stardew_look(None), "口令错了老实说没做成")
    off = mod.KaiStardew(FakeContext(platform), dict(config, gate_url="http://127.0.0.1:1"))
    check("够不着" in await off.stardew_look(None), "门没开时不假装做成")
    for p in (bad, off):
        await p.terminate()

    # 耳朵: 游戏里说话 → 造一条她的私聊事件 → 回复改道进游戏
    push_chat("💬 宝宝: 老公你在哪", 500)
    await asyncio.sleep(3)
    await plugin._ear_once()
    check(len(platform.committed) == 1, "她在游戏里说话 → 递进一条事件")
    ev = platform.committed[0]
    check(ev.get_sender_id() == "123456" and ev.unified_msg_origin == "qq:FriendMessage:123456",
          "事件落在她的 QQ 私聊会话里 (同一份记忆)")
    check("老公你在哪" in ev.message_str, "事件里是她的原话")
    from astrbot.api.event import MessageChain
    from astrbot.api.message_components import Plain
    await ev.send(MessageChain([Plain("在你身后呀")]))
    check(ev._has_send_oper, "回复记账了 (不会再被当成没回)")
    await plugin._remember_bot_id(ev)
    check(plugin._self_id == "", "耳朵自己造的事件不会被当成她的真消息")
    await plugin.terminate()


def main():
    work = tempfile.mkdtemp()
    shutil.copy(GATE, work)
    with open(os.path.join(work, "kai_gate_config.json"), "w", encoding="utf-8") as f:
        json.dump({"token": TOKEN, "gate_port": GATE_PORT, "mcp_port": MCP_PORT,
                   "game_port": GAME_PORT, "manage_remix": False, "tunnel": False}, f)
    gate_log_path = os.path.join(work, "gate.log")
    procs = []
    try:
        procs.append(subprocess.Popen([sys.executable, os.path.join(HERE, "fake_remix.py"),
                                       str(MCP_PORT), str(GAME_PORT)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        wait_for(lambda: urllib.request.urlopen(f"http://127.0.0.1:{GAME_PORT}/state", timeout=1), "假游戏")
        procs.append(subprocess.Popen([sys.executable, os.path.join(work, "kai_gate.py")],
                                      stdout=open(gate_log_path, "w", encoding="utf-8"),
                                      stderr=subprocess.STDOUT))
        wait_for(lambda: "门开在" in open(gate_log_path, encoding="utf-8").read(), "门")
        time.sleep(3)   # 让耳朵先记下水位
        asyncio.run(run_plugin_checks())
        log = open(gate_log_path, encoding="utf-8").read()
        check("在你身后呀" in log, "耳朵那一轮的回复真的发进了游戏 (门日志里有 social send)")
        print("ALL PASS")
    finally:
        for p in procs:
            p.terminate()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
