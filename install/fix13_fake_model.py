# -*- coding: utf-8 -*-
"""本地假模型端点（0.13：验证「会话里到底能不能跑命令」）。

为什么要这个：模拟器里的 App 指向 127.0.0.1:8891（`adb reverse` 到这台电脑），
而"模型让它跑一条命令"这件事**必须由模型发起**。真模型做不到可控复现，
所以这里自己当模型：第一轮直接回一个 `bash` 工具调用，第二轮把工具结果原样念一遍。
于是整条链路都能被端到端看到：

    提示词 -> DSH acp -> 假模型(tool_call) -> DSH bash 工具
           -> android-exec-shim -> /system/bin/sh -> 结果 -> 假模型 -> 界面

服务器每收到一次请求都打一行日志；第二轮会打印**工具结果原文** ——
那串输出就是"命令真的跑了"的证据（修前必然是 `spawn bash ENOENT`）。

用法：python install/fix13_fake_model.py [port]
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8891

# 三条命令，分别钉死三件事：
#   1. bash -c 被改写成了 /system/bin/sh（否则根本跑不起来）；
#   2. prelude 里的 DSH_ANDROID_* / 工具箱路径真的导出到了 shell 里；
#   3. shell 里的 `node` 能通过函数找到随包的 libnode 并真的跑起来。
COMMANDS = [
    (
        "call_fix13_1",
        'echo DSH_SHIM_OK; echo "TOOLBOX=$DSH_ANDROID_TOOLBOX"; '
        'echo "EXEC_SHIM=$DSH_ANDROID_EXEC_SHIM"; echo "TMPDIR=$TMPDIR"; uname -a',
        "打印执行环境自检信息",
    ),
    (
        "call_fix13_2",
        'node -e "console.log(\'NODE_OK \' + process.version)"',
        "用 shell 里的 node 打印版本",
    ),
    (
        "call_fix13_3",
        'ls -l "$DSH_ANDROID_TOOLBOX" | head -20',
        "列出内置工具箱脚本",
    ),
]

MODEL_ID = "agnes-model"


def _tool_calls():
    out = []
    for i, (cid, cmd, desc) in enumerate(COMMANDS):
        out.append(
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
        )
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---------------------------------------------------------------- helpers
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
            self.wfile.write(("data: " + json.dumps(c, ensure_ascii=False) + "\n\n").encode("utf-8"))
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    @staticmethod
    def _chunk(delta, finish=None):
        return {
            "id": "chatcmpl-fix13",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": MODEL_ID,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }

    # ------------------------------------------------------------------ routes
    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send_json(
                {
                    "object": "list",
                    "data": [
                        {"id": MODEL_ID, "object": "model", "owned_by": "fix13"},
                        {"id": "agnes-model2", "object": "model", "owned_by": "fix13"},
                    ],
                }
            )
            print("[fix13] GET %s -> 200 (models)" % self.path, flush=True)
            return
        self._send_json({"error": {"message": "not found"}})
        print("[fix13] GET %s -> 404" % self.path, flush=True)

    def do_POST(self):
        body = self._body()
        msgs = body.get("messages") or []
        tools = [t.get("function", {}).get("name") for t in (body.get("tools") or [])]
        tool_msgs = [m for m in msgs if m.get("role") == "tool"]
        stream = bool(body.get("stream"))
        print(
            "[fix13] POST %s stream=%s messages=%d tools=%s tool_results=%d"
            % (self.path, stream, len(msgs), tools, len(tool_msgs)),
            flush=True,
        )
        for m in tool_msgs:
            content = m.get("content")
            if not isinstance(content, str):
                content = json.dumps(content, ensure_ascii=False)
            print("[fix13] ---- 工具结果原文 ----", flush=True)
            print(content, flush=True)
            print("[fix13] ----------------------", flush=True)

        if tool_msgs:
            text = (
                "工具结果已经回来了（服务器侧也打印了原文）。"
                "如果你在上面的结果里看到 DSH_SHIM_OK / NODE_OK / 工具箱文件列表，"
                "说明会话里真的能跑命令了。"
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
                        "id": "chatcmpl-fix13",
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

        # 第一轮：让模型"主动"跑三条命令
        if stream:
            self._sse(
                [
                    self._chunk({"role": "assistant", "content": ""}),
                    self._chunk({"content": "我来跑几条命令自检一下。\n"}),
                    self._chunk({"tool_calls": _tool_calls()}),
                    self._chunk({}, "tool_calls"),
                ]
            )
        else:
            self._send_json(
                {
                    "id": "chatcmpl-fix13",
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
    print("[fix13] listening on 127.0.0.1:%d" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
