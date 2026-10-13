# -*- coding: utf-8 -*-
"""Local fake upstream for the model-settings end-to-end verification.

Why this exists: the Android emulator used for verification has NO internet
access (no DNS, no default route), so a "real 401 from a real endpoint" cannot
be reached from inside the emulator. The fix is `adb reverse tcp:8899 tcp:8899`,
which maps the DEVICE's 127.0.0.1:8899 back to this server on the host.
`AndroidManifest.xml` already sets android:usesCleartextTraffic="true", so the
app is allowed to speak plain HTTP to 127.0.0.1.

Routes (OpenAI-compatible shapes):
  GET  /v1/models            -> 200 + {"object":"list","data":[...]}   (real list)
  GET  /err/v1/models        -> 401  (so the "fetch failed" branch is reachable)
  POST /v1/chat/completions  -> 401 with an OpenAI-style error body
                                (a genuine HTTP 401, so the app's Chinese
                                 error translation and the
                                 "registered even though the test failed"
                                 path are both exercised for real)

Every request is printed to stdout (the runner redirects it to a log file),
which is the evidence that the device really talked to this server.

Usage:  python install/pool401_server.py [port]
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899

MODELS = [
    {
        "id": "verify-alpha",
        "display_name": "Verify Alpha",
        "context_length": 131072,
        "supported_endpoints": ["/v1/chat/completions"],
    },
    {
        "id": "verify-beta",
        "display_name": "Verify Beta",
        "context_length": 32768,
        "supported_endpoints": ["/v1/chat/completions"],
    },
]

UNAUTHORIZED = {
    "error": {
        "message": "Invalid API Key",
        "type": "invalid_request_error",
        "code": "invalid_api_key",
    }
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, code):
        auth = self.headers.get("Authorization", "-")
        print(
            "[pool401] %s %s -> %d  UA=%s  auth=%s"
            % (
                self.command,
                self.path,
                code,
                self.headers.get("User-Agent", "-"),
                (auth[:14] + "...") if len(auth) > 14 else auth,
            ),
            flush=True,
        )

    def do_GET(self):
        if self.path.startswith("/err/"):
            self._send(401, UNAUTHORIZED)
            self._log(401)
            return
        if self.path.rstrip("/").endswith("/models"):
            self._send(200, {"object": "list", "data": MODELS})
            self._log(200)
            return
        self._send(404, {"error": {"message": "not found"}})
        self._log(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        # A genuine 401: the app must translate it into Chinese and must still
        # keep the models it already registered.
        self._send(401, UNAUTHORIZED)
        self._log(401)

    def log_message(self, fmt, *args):  # silence the default stderr noise
        pass


if __name__ == "__main__":
    print("[pool401] listening on 127.0.0.1:%d" % PORT, flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
