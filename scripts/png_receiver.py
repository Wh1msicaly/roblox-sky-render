"""Tiny localhost receiver that turns pixel data posted from Roblox Studio into PNG files.

    python png_receiver.py <output_dir> [port]

Studio (see export_png.luau) posts base64 RGBA in chunks to
    POST /chunk?name=<name>&w=<w>&h=<h>&i=<index>&n=<count>
and when the last chunk for a name arrives, <output_dir>/<name>.png is written.
Listens on 127.0.0.1 only. Stop it with Ctrl+C / by killing the process, or GET /quit.
"""
import base64
import os
import re
import struct
import sys
import threading
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

out_dir = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
pending = {}


def write_png(path, w, h, rgba):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    stride = w * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlparse(self.path).path == "/quit":
            self.reply(200, "bye")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
        else:
            self.reply(200, "png_receiver ok -> " + out_dir)

    def do_POST(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            name = re.sub(r"[^A-Za-z0-9_.-]", "_", q["name"])[:80] or "render"
            w, h, i, n = int(q["w"]), int(q["h"]), int(q["i"]), int(q["n"])
            data = base64.b64decode(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except Exception as e:  # malformed request
            return self.reply(400, "bad request: %s" % e)

        parts = pending.setdefault(name, {})
        parts[i] = data
        if len(parts) < n:
            return self.reply(200, "chunk %d/%d" % (len(parts), n))

        rgba = b"".join(parts[k] for k in sorted(parts))
        del pending[name]
        if len(rgba) != w * h * 4:
            return self.reply(400, "size mismatch: got %d bytes, expected %d" % (len(rgba), w * h * 4))
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, name + ".png")
        write_png(path, w, h, rgba)
        print("wrote", path, flush=True)
        self.reply(200, "saved " + path)

    def log_message(self, *args):
        pass


print("png_receiver listening on http://127.0.0.1:%d -> %s" % (port, out_dir), flush=True)
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
