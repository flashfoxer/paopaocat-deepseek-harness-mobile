# -*- coding: utf-8 -*-
"""轮换池（rotate pool）验证用的假上游：**第一个成员永远 429，第二个正常**。

为什么要它：用户怀疑「轮换池没有起作用」。要证伪/证实，就必须造出
"第一个成员被限流"这个**只有池子能救**的场景，然后看：
  * 假上游这边：先收到 /aaa 的 429 请求，紧接着收到 /bbb 的请求 → 真的换人了；
  * App 那边：会话页能拿到正常回答（不是 429 报错）。

路径约定（同一个端口，靠前缀区分两个"厂家"）：
  POST /aaa/v1/chat/completions  → 429（照 Agnes 那句限流原文写）
  POST /bbb/v1/chat/completions  → 200 正常回答（SSE）
  GET  /aaa/v1/models            → 200（列模型，供 App 的「获取模型」用）
  GET  /bbb/v1/models            → 200

用法：python install/fix13_fake_rot.py [port]      （默认 8891）
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8891

LIMIT_BODY = {
    "code": "",
    "message": "您已达到免费用户的 API 速率限制。升级 Token Plan 即可解锁更高限额，"
               "继续不间断使用 API。 (request-id: fake-aaa-429)",
    "type": "AgnesAI_error",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
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

    def do_GET(self):
        which = "aaa" if self.path.startswith("/aaa/") else ("bbb" if self.path.startswith("/bbb/") else "?")
        print("[rot-fake] GET %s -> 200 (models, %s)" % (self.path, which), flush=True)
        self._json(200, {"object": "list", "data": [{"id": "%s-model" % which, "object": "model"}]})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            body = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            body = {}
        model = body.get("model")
        which = "aaa" if self.path.startswith("/aaa/") else ("bbb" if self.path.startswith("/bbb/") else "?")

        if which == "aaa":
            print("[rot-fake] POST %s model=%s -> 429（故意的，看池子会不会换人）" % (self.path, model), flush=True)
            self._json(429, LIMIT_BODY)
            return

        print("[rot-fake] POST %s model=%s -> 200 正常回答" % (self.path, model), flush=True)
        text = "轮换池第二个成员（bbb/%s）答的：我顶上了。" % model
        if body.get("stream"):
            self._sse([
                {"id": "c1", "object": "chat.completion.chunk", "created": int(time.time()),
                 "model": model, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]},
                {"id": "c1", "object": "chat.completion.chunk", "created": int(time.time()),
                 "model": model, "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}]},
                {"id": "c1", "object": "chat.completion.chunk", "created": int(time.time()),
                 "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ])
        else:
            self._json(200, {"id": "c1", "object": "chat.completion", "created": int(time.time()),
                             "model": model,
                             "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                          "finish_reason": "stop"}]})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("[rot-fake] listening on 127.0.0.1:%d（/aaa=永远429，/bbb=正常）" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
