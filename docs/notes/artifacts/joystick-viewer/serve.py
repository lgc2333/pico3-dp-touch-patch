"""Serve `web/` on http://127.0.0.1:8788 and accept canvas snapshots.

Usage:
  uv run python serve.py [--port 8788]

POST /shot?name=<file> with a `data:image/png;base64,...` body writes
`web/shots/<file>.png`.  The page calls it from `window.shot()` so an automated
check can save a render without a screen capture.
"""

import argparse
import base64
import os
import re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
SHOTS = os.path.join(WEB, "shots")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=WEB, **kw)

    def do_POST(self):
        if not self.path.startswith("/shot"):
            self.send_error(404)
            return
        name = re.sub(
            r"[^A-Za-z0-9_.-]",
            "_",
            self.path.split("name=")[-1].split("&")[0] or "shot",
        )[:60]
        if not name.endswith(".png"):
            name += ".png"
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("ascii", "replace")
        b64 = body.split(",", 1)[1] if "," in body else body
        os.makedirs(SHOTS, exist_ok=True)
        with open(os.path.join(SHOTS, name), "wb") as f:
            f.write(base64.b64decode(b64))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="serve the joystick viewer")
    ap.add_argument("--port", type=int, default=8788)
    args = ap.parse_args()
    print(f"[i] http://127.0.0.1:{args.port}/")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
