# -*- coding: utf-8 -*-
"""本地假模型端点（0.14：验证「产物只装真正产生的文件」）。

为什么要这个：判断产物对不对**必须让模型真的跑一次工具** —— 真模型不可控，
所以这里自己当模型，一轮里发两条 `bash`：

  1. **真产出一个文件**：在会话 cwd（= 工作区）里写 `测试产物.md`，
     并把它的**绝对路径**打到输出里（工具输出里带路径是常态）。
     → 修后：产物列表里出现且仅出现这一个，点开能预览。

  2. **只打印那份技能文档里的示例占位名**（`输出.png` / `参考图.png`），
     **不创建任何文件**。这一条就是用户实测踩到的坑的原样复现：
     修前这两个名字会立刻变成两张点不开的"产物"卡片。

期望结果（设备端逐条可看）：
    * 顶栏 `产物 1`（不是 3）；
    * 产物列表里只有 `测试产物.md`，没有 `输出.png` / `参考图.png`；
    * 点那张卡片能真的打开预览（路径是核实过的，不再按名字重扫）。

用法：python install/fix14_fake_produce.py [port]
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8891
MODEL_ID = "agnes-model"

# 1) 真产出：写文件 + 打印绝对路径
PRODUCE_CMD = (
    'cd "$PWD" && printf \'泡泡猫产物测试\\n\' > 测试产物.md '
    '&& ls -l "$PWD/测试产物.md" && echo "已生成：$PWD/测试产物.md"'
)
# 2) 只回声示例（不建文件）——修前的假产物就是从这里来的
ECHO_CMD = (
    'echo \'用法示例：node "$DSH_ANDROID_TOOLBOX/make-image.mjs" "提示词" "输出.png" '
    '--ref "参考图.png"\''
)

COMMANDS = [
    ("call_fix14_produce", PRODUCE_CMD, "生成一份测试文档"),
    ("call_fix14_decoy", ECHO_CMD, "打印 make-image 用法示例"),
]


def _tool_calls():
    return [
        {
            "index": i,
            "id": cid,
            "type": "function",
            "function": {
                "name": "bash",
                "arguments": json.dumps(
                    {"command": cmd, "description": desc}, ensure_ascii=False
                ),
            },
        }
        for i, (cid, cmd, desc) in enumerate(COMMANDS)
    ]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8", "replace"))
        except Exception:
            return {}

    def _send_json(self, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for c in chunks:
            self.wfile.write(
                ("data: " + json.dumps(c, ensure_ascii=False) + "\n\n").encode("utf-8")
            )
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    @staticmethod
    def _chunk(delta, finish=None):
        return {
            "id": "chatcmpl-fix14",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": MODEL_ID,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send_json(
                {
                    "object": "list",
                    "data": [{"id": MODEL_ID, "object": "model", "owned_by": "fix14"}],
                }
            )
            print("[fix14] GET %s -> 200 (models)" % self.path, flush=True)
            return
        self._send_json({"error": {"message": "not found"}})

    def do_POST(self):
        body = self._body()
        msgs = body.get("messages") or []
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]
        stream = bool(body.get("stream"))
        print(
            "[fix14] POST %s stream=%s messages=%d tool_results=%d"
            % (self.path, stream, len(msgs), len(tool_msgs)),
            flush=True,
        )
        for m in tool_msgs:
            content = m.get("content")
            if not isinstance(content, str):
                content = json.dumps(content, ensure_ascii=False)
            print("[fix14] ---- 工具结果 ----", flush=True)
            print(content, flush=True)
            print("[fix14] ------------------", flush=True)

        if tool_msgs:
            text = (
                "两条命令都跑完了：一条真的在工作区里写了 `测试产物.md`，"
                "另一条只是把 make-image 的用法示例回声出来（没有创建文件）。"
                "现在产物里应该只有前者的那个文件。"
            )
            if stream:
                self._sse(
                    [
                        self._chunk({"role": "assistant", "content": ""}),
                        self._chunk({"content": text}),
                        self._chunk({}, "stop"),
                    ]
                )
            else:
                self._send_json(
                    {
                        "id": "chatcmpl-fix14",
                        "object": "chat.completion",
                        "created": int(time.time()),
                        "model": MODEL_ID,
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": text},
                                "finish_reason": "stop",
                            }
                        ],
                    }
                )
            return

        if stream:
            self._sse(
                [
                    self._chunk({"role": "assistant", "content": ""}),
                    self._chunk({"content": "我先生成一份文件，再确认一下文档里的示例写法。\n"}),
                    self._chunk({"tool_calls": _tool_calls()}),
                    self._chunk({}, "tool_calls"),
                ]
            )
        else:
            self._send_json(
                {
                    "id": "chatcmpl-fix14",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": MODEL_ID,
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "",
                                "tool_calls": [
                                    {
                                        "id": c[0],
                                        "type": "function",
                                        "function": {
                                            "name": "bash",
                                            "arguments": json.dumps(
                                                {"command": c[1], "description": c[2]},
                                                ensure_ascii=False,
                                            ),
                                        },
                                    }
                                    for c in COMMANDS
                                ],
                            },
                            "finish_reason": "tool_calls",
                        }
                    ],
                }
            )

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("[fix14] listening on 127.0.0.1:%d" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
