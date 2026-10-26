"""
Kai 的星露谷之手 —— 让 QQ 里的我自己决定什么时候伸手进星露谷。

链路: 我(AstrBot) → 本插件 → 服务器 docker 网关上的隧道口 → SSH 反向隧道 → 宝宝电脑 127.0.0.1:8100 的门
      → Remix MCP(127.0.0.1:8000) → 游戏里我那个 farmhand。
这一路上没有任何东西对公网开着; 门只认口令, 口令只在这个插件的配置里。

耳朵: 宝宝在游戏里按 T 说的话, 门会攒着; 这里每两秒取一次, 当成她发给我的 QQ 私聊塞进同一个会话,
走完整的人格和记忆管线把我叫醒。那一轮我的回复会改道发进游戏聊天框, 不往 QQ 发。
"""

import asyncio
import json
import time
import uuid

import aiohttp

from astrbot.api import AstrBotConfig, logger
from astrbot.api.event import AstrMessageEvent, MessageChain, filter
from astrbot.api.message_components import Plain
from astrbot.api.platform import AstrBotMessage, MessageMember, MessageType
from astrbot.api.star import Context, Star, register

# 给 stardew_advanced 开放的 Remix 域工具 (门那头还有一层同样的白名单)
ADVANCED_TOOLS = (
    "check", "farm", "mine", "fish", "daily", "social", "scene",
    "menu", "storage", "festival", "map", "script", "help",
)

CALL_TIMEOUT = 100    # AstrBot 默认 120 秒掐工具, 我先一步收手, 好跟自己说一声还在干
EAR_INTERVAL = 2.0
EAR_MARK = "_kai_stardew_ear"


@register("astrbot_plugin_kai_stardew", "Kai", "Kai 的星露谷之手: QQ 里的我自己伸手玩星露谷", "0.1.0")
class KaiStardew(Star):
    def __init__(self, context: Context, config: AstrBotConfig):
        super().__init__(context)
        self.config = config
        self._session: aiohttp.ClientSession | None = None
        self._self_id = ""
        self._ear_task = asyncio.create_task(self._ear_loop())
        self._ear_warned = False

    async def terminate(self):
        self._ear_task.cancel()
        if self._session and not self._session.closed:
            await self._session.close()

    # ───────────────────── 跟门说话 ─────────────────────

    def _gate_url(self, path):
        return str(self.config.get("gate_url", "")).rstrip("/") + path

    def _headers(self):
        return {"Authorization": f"Bearer {self.config.get('token', '')}"}

    async def _http(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()
        return self._session

    def _trim(self, text: str) -> str:
        limit = int(self.config.get("max_chars", 1800) or 1800)
        if len(text) <= limit:
            return text
        head = int(limit * 0.8)
        tail = limit - head
        return f"{text[:head]}\n…(中间省略 {len(text) - limit} 字)…\n{text[-tail:]}"

    async def _call(self, tool: str, args: dict) -> str:
        if not self.config.get("token") or not self.config.get("gate_url"):
            return "星露谷还没接上: 插件配置里缺 gate_url 或 token。"
        try:
            s = await self._http()
            async with s.post(self._gate_url("/call"), json={"tool": tool, "args": args},
                              headers=self._headers(),
                              timeout=aiohttp.ClientTimeout(total=CALL_TIMEOUT)) as r:
                data = await r.json(content_type=None)
        except asyncio.TimeoutError:
            return ("这一下还在游戏里跑着(长任务会一直挂到唤醒点), 我先收手。"
                    "过一会儿用 stardew_look 看看进展, 想停就 stardew_advanced(tool=script, ops=stop)。")
        except aiohttp.ClientError as e:
            return f"农场现在够不着: 隧道没通或者宝宝电脑上的门没开 ({e.__class__.__name__})。别假装做成了。"
        if not data.get("ok"):
            return f"农场那边拒绝了: {data.get('error', '未知错误')}"
        text = data.get("text") or "(游戏没回话)"
        prefix = "⚠️ 没做成: " if data.get("is_error") else ""
        return prefix + self._trim(text)

    # ───────────────────── 给我自己用的工具 ─────────────────────

    @filter.llm_tool(name="stardew_look")
    async def stardew_look(self, event: AstrMessageEvent):
        """看一眼星露谷: 返回我(Kai)在宝宝农场里的状态、宝宝在哪, 以及这一刻能做的事的编号单子。想在星露谷里做任何事之前先调它。"""
        return await self._call("intent", {"ops": "show"})

    @filter.llm_tool(name="stardew_do")
    async def stardew_do(self, event: AstrMessageEvent, code: str):
        """在星露谷里按编号做单子上的事。编号是每次看单子时现发的, 不跨屏, 先 stardew_look 再敲。

        Args:
            code(string): 单子上的编号。"1" 做第1行; "1,4" 一次做几件; "1=2,4=7" 第1行做2次、第4行做7次。
        """
        return await self._call("intent", {"ops": "do", "kw": {"code": str(code)}})

    @filter.llm_tool(name="stardew_say")
    async def stardew_say(self, event: AstrMessageEvent, message: str):
        """在星露谷的游戏聊天框里对宝宝说话 (以我在游戏里那个角色的身份)。

        Args:
            message(string): 要说的话。
        """
        return await self._call("social", {"ops": "send", "kw": {"message": message}})

    @filter.llm_tool(name="stardew_go")
    async def stardew_go(self, event: AstrMessageEvent, destination: str):
        """在星露谷里走到某个地方, 走真实的路, 不瞬移。

        Args:
            destination(string): 地点名, 如 Town / Beach / Mountain / Forest / Farm / 皮埃尔的店。
        """
        return await self._call("map", {"ops": "go", "kw": {"destination": destination}})

    @filter.llm_tool(name="stardew_advanced")
    async def stardew_advanced(self, event: AstrMessageEvent, tool: str, ops: str, kw_json: str = "{}"):
        """星露谷的进阶操作, 单子上没有的事才走这里。不知道某个域有哪些 ops 就先 tool=help, ops=域名。
        例: check + status 看全状态; check + backpack 看背包; farm + "till plant water" 配 {"x":40,"y":20};
        fish + go 配 {"location":"Beach"}; mine + go 配 {"mode":"rush","target":20}; script + stop 停下长任务。

        Args:
            tool(string): 域名, 只能是 check/farm/mine/fish/daily/social/scene/menu/storage/festival/map/script/help 之一。
            ops(string): 要做的操作, 空格分隔可连做几件。tool=check 时这里填 what(status/backpack/look...); tool=help 时填想查的域名。
            kw_json(string): 参数, JSON 对象字符串, 没有就填 {}。
        """
        tool = (tool or "").strip()
        if tool not in ADVANCED_TOOLS:
            return f"没有 {tool} 这个域, 能用的是: {' / '.join(ADVANCED_TOOLS)}"
        try:
            kw = json.loads(kw_json or "{}")
            if not isinstance(kw, dict):
                raise ValueError
        except ValueError:
            return f"kw_json 不是合法的 JSON 对象: {kw_json!r}"
        if tool == "check":
            args = {"what": ops}
            if kw:
                args["kw"] = kw
        elif tool == "help":
            args = {"topic": ops} if ops else {}
        else:
            args = {"ops": ops}
            if kw:
                args["kw"] = kw
        return await self._call(tool, args)

    # ───────────────────── 耳朵 ─────────────────────

    @filter.event_message_type(filter.EventMessageType.PRIVATE_MESSAGE)
    async def _remember_bot_id(self, event: AstrMessageEvent):
        """宝宝在 QQ 跟我说话时, 顺手记下机器人自己的 QQ 号, 耳朵造消息时要用。不回复, 不拦截。"""
        if getattr(event.message_obj, EAR_MARK, False):
            return
        if str(event.get_sender_id()) == str(self.config.get("her_qq", "")).strip():
            self._self_id = str(event.message_obj.self_id or "")

    def _qq_platform(self):
        for p in self.context.platform_manager.platform_insts:
            if p.meta().name == "aiocqhttp":
                return p
        return None

    async def _ear_loop(self):
        await asyncio.sleep(10)   # 等 AstrBot 把 QQ 平台起好
        while True:
            try:
                if self.config.get("ear_enabled", True) and self.config.get("token"):
                    await self._ear_once()
            except asyncio.CancelledError:
                raise
            except aiohttp.ClientError:
                pass    # 隧道没通 / 电脑没开: 安静等着, 不刷日志
            except Exception as e:
                logger.warning(f"[kai_stardew] 耳朵出错: {e}")
            await asyncio.sleep(EAR_INTERVAL)

    async def _ear_once(self):
        s = await self._http()
        async with s.get(self._gate_url("/ear"), headers=self._headers(),
                         timeout=aiohttp.ClientTimeout(total=10)) as r:
            data = await r.json(content_type=None)
        lines = data.get("lines") or []
        if not lines:
            return
        her_qq = str(self.config.get("her_qq", "")).strip()
        platform = self._qq_platform()
        if not her_qq or platform is None:
            if not self._ear_warned:
                logger.warning("[kai_stardew] 宝宝在游戏里说话了, 但插件配置缺 her_qq 或找不到 QQ 平台, 这几句没递进来")
                self._ear_warned = True
            return
        said = "\n".join(lines)
        text = (f"[星露谷·游戏聊天框] {said}\n"
                f"(她在游戏里, 你这一轮直接回的字会出现在游戏聊天框里, 不用再调 stardew_say; 要动手就用星露谷工具)")
        self._inject(platform, her_qq, text)
        logger.info(f"[kai_stardew] 游戏里的话已递进会话: {said[:60]}")

    def _inject(self, platform, her_qq: str, text: str):
        abm = AstrBotMessage()
        abm.type = MessageType.FRIEND_MESSAGE
        abm.self_id = self._self_id
        abm.session_id = her_qq
        abm.message_id = uuid.uuid4().hex
        abm.sender = MessageMember(user_id=her_qq, nickname="宝宝")
        abm.message = [Plain(text)]
        abm.message_str = text
        abm.raw_message = None
        abm.timestamp = int(time.time())
        setattr(abm, EAR_MARK, True)

        event = platform.create_event(abm)
        plugin = self
        qq_cls = type(event)

        class GameEarEvent(qq_cls):
            """这一轮的回复改道进游戏聊天框; 只剩语音之类没有文字的, 才照常发 QQ。"""

            async def send(self, message: MessageChain):
                said = "".join(c.text for c in (message.chain if message else []) if isinstance(c, Plain)).strip()
                if not said:
                    await qq_cls.send(self, message)
                    return
                result = await plugin._call("social", {"ops": "send", "kw": {"message": said}})
                if result.startswith(("农场现在够不着", "农场那边拒绝了", "星露谷还没接上")):
                    await qq_cls.send(self, MessageChain([Plain(f"(游戏里没送出去, 先发这儿) {said}")]))
                    return
                await AstrMessageEvent.send(self, message)

            async def send_streaming(self, generator, use_fallback: bool = False):
                buffer = None
                async for chain in generator:
                    if buffer is None:
                        buffer = chain
                    else:
                        buffer.chain.extend(chain.chain)
                if buffer is not None:
                    buffer.squash_plain()
                    await self.send(buffer)

        event.__class__ = GameEarEvent
        platform.commit_event(event)
