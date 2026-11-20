#!/usr/bin/env python3
"""A stand-in CraftBot backend for testing the widget and stream.py.

Serves GET /api/state (from a JSON file), GET /api/session-token, and /ws.
The socket checks the Origin and the token like CraftBot's ws_auth, sends a
ping (the client must answer), then replays a script of messages, one line
of JSON per message, waiting `--gap` seconds between them, and stays open.

Usage: fake_craftbot.py PORT STATE_JSON SCRIPT_JSONL [--gap SECONDS] [--loop]
                        [--redirect-token URL]   (answer the token request with a 302)
"""

import base64
import hashlib
import json
import socketserver
import struct
import sys
import threading
import time

TOKEN = "f" * 64
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def frame(opcode, payload=b""):
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack("!H", n)
    else:
        head += bytes([127]) + struct.pack("!Q", n)
    return head + payload


def read_client_frame(rfile):
    b1, b2 = rfile.read(2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack("!H", rfile.read(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", rfile.read(8))[0]
    mask = rfile.read(4)
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(rfile.read(n)))
    return b1 & 0x0F, data


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(4096).decode("latin-1")
        path = line.split(" ")[1] if line.count(" ") >= 2 else ""
        headers = {}
        while True:
            h = self.rfile.readline(8192).decode("latin-1")
            if h in ("\r\n", "\n", ""):
                break
            k, _, v = h.partition(":")
            headers[k.strip().lower()] = v.strip()

        if path == "/api/state":
            return self.http(200, open(self.server.state_path, "rb").read())
        if path == "/api/session-token":
            if self.server.redirect_token:
                self.server.log.append("token-redirect-sent")
                self.wfile.write(("HTTP/1.1 302 Found\r\nLocation: " + self.server.redirect_token
                                  + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").encode())
                return
            return self.http(200, json.dumps({"token": TOKEN}).encode())
        if path == "/ws":
            host = headers.get("host", "")
            if headers.get("origin") != f"http://{host}" or f"craftbot-auth.{TOKEN}" not in headers.get("sec-websocket-protocol", ""):
                self.server.log.append("rejected")
                return self.http(403, b"forbidden")
            accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
            self.wfile.write(
                ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                 f"Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: craftbot\r\n\r\n").encode())
            self.wfile.write(frame(0x9, b"hb"))
            opcode, data = read_client_frame(self.rfile)
            self.server.log.append("pong" if opcode == 0xA and data == b"hb" else f"bad-pong:{opcode}")
            self.wfile.write(frame(0x1, json.dumps({"type": "init", "data": {"x": "y" * 70000}}).encode()))
            while True:
                for msg in self.server.script:
                    time.sleep(self.server.gap)
                    self.wfile.write(frame(0x1, json.dumps(msg).encode()))
                    self.wfile.flush()
                if not self.server.loop:
                    break
            while True:  # stay open, pinging like aiohttp's heartbeat
                time.sleep(5)
                self.wfile.write(frame(0x9, b"hb"))
                read_client_frame(self.rfile)
        return self.http(404, b"not found")

    def http(self, code, body):
        reason = {200: "OK", 403: "Forbidden", 404: "Not Found"}[code]
        self.wfile.write(f"HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\n"
                         f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)


def main():
    port, state_path, script_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    gap = float(sys.argv[sys.argv.index("--gap") + 1]) if "--gap" in sys.argv else 0.05
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    server = socketserver.ThreadingTCPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.state_path, server.gap, server.loop, server.log = state_path, gap, "--loop" in sys.argv, []
    server.script = [json.loads(l) for l in open(script_path) if l.strip()]
    server.redirect_token = sys.argv[sys.argv.index("--redirect-token") + 1] if "--redirect-token" in sys.argv else ""
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(0.5)
            if server.log:
                print("server:", ", ".join(server.log), flush=True)
                server.log.clear()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
