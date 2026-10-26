"""
测试替身: 假的 Remix MCP 服务器 (真 FastMCP, Streamable HTTP, 和 Remix 同一套协议)
+ 假的游戏 /state (recent_events 里能塞宝宝的话)。不开游戏也能把门从头到尾跑一遍。

python fake_remix.py <mcp_port> <game_port>
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mcp.server.fastmcp import FastMCP

MCP_PORT = int(sys.argv[1])
GAME_PORT = int(sys.argv[2])

mcp = FastMCP("NagiBridge", host="127.0.0.1", port=MCP_PORT)


@mcp.tool()
def intent(ops: str = "show", kw: dict | None = None) -> str:
    if ops == "do":
        return f"✅ 做了第 {(kw or {}).get('code')} 行"
    return "🏠 自家小屋\n 1  开 冰箱\n 2  存 土豆×20 → 冰箱\n" + "状态条" * 2000


@mcp.tool()
def social(ops: str = "", kw: dict | None = None) -> str:
    return f"💬 已发送: {(kw or {}).get('message')}"


@mcp.tool()
def check(what: str, kw: dict | None = None) -> str:
    return f"🔍 {what}"


@mcp.tool()
def settings(ops: str = "", kw: dict | None = None) -> str:
    return "不该被调到"


EVENTS = [{"type": "chat", "content": "💬 宝宝: 开门前的旧话", "tick": 1}]


class Game(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = json.dumps({"recent_events": EVENTS}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):   # 测试脚本往这里塞新聊天
        n = int(self.headers["Content-Length"])
        EVENTS.append(json.loads(self.rfile.read(n)))
        self.send_response(204)
        self.end_headers()


threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", GAME_PORT), Game).serve_forever,
                 daemon=True).start()
mcp.run(transport="streamable-http")
