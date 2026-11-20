#!/usr/bin/env python3
"""Follow CraftBot's live step status for the bar widget.

Each decision reply carries a short "status" line (what the step does, for
the user: "Reading the project README..."). CraftBot only sends it live, in
the `agent_stream` messages on its /ws socket, and never stores it, so this
joins the socket the way CraftBot's own UI does and prints one JSON line per
change:

    {"event": "connected"}
    {"sessionId": "main", "status": "Reading the project README..."}
    {"sessionId": "main", "status": ""}          # the run ended

Standard library only (the shell has no WebSocket module). The socket guard
wants CraftBot's UI origin and the per-process session token; the token is
read from /api/session-token and never printed. Loopback addresses only.

Usage: stream.py http://127.0.0.1:7926
"""

import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys
import urllib.request

URL_RE = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})$")
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,256}$")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE = 32 * 1024 * 1024
MAX_STATUS = 160
# CraftBot pings every 30 s; silence well past that means the socket is gone.
READ_TIMEOUT = 75


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def status_line(value):
    """The first line, flattened and bounded, as CraftBot's chat shows it."""
    if not isinstance(value, str):
        return ""
    line = value.strip().split("\n", 1)[0]
    line = re.sub(r"[\x00-\x1f\x7f-\x9f]+", " ", line)
    line = re.sub(r"\s+", " ", line).strip()
    return line[: MAX_STATUS - 1] + "…" if len(line) > MAX_STATUS else line


def read_exact(stream, n):
    data = stream.read(n)
    if data is None or len(data) < n:
        raise EOFError("socket closed")
    return data


def send_frame(sock, opcode, payload=b""):
    """A single masked client frame (control frames: pong, close)."""
    mask = os.urandom(4)
    n = len(payload)
    header = bytes([0x80 | opcode])
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack("!H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack("!Q", n)
    body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(header + mask + body)


def read_frame(stream):
    b1, b2 = read_exact(stream, 2)
    fin, opcode = b1 & 0x80, b1 & 0x0F
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(stream, 8))[0]
    if length > MAX_MESSAGE:
        raise ValueError("frame too large")
    mask = read_exact(stream, 4) if b2 & 0x80 else None
    payload = read_exact(stream, length)
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bool(fin), opcode, payload


def session_token(base):
    # No Origin header: CraftBot serves the token to non-browser callers.
    req = urllib.request.Request(base + "/api/session-token", headers={"Cache-Control": "no-store"})
    with urllib.request.urlopen(req, timeout=3) as resp:
        token = json.loads(resp.read(4096).decode("utf-8")).get("token", "")
    if not TOKEN_RE.match(str(token)):
        raise ValueError("unexpected session token")
    return token


def connect(base, host, port):
    token = session_token(base)
    sock = socket.create_connection(("::1" if host == "[::1]" else host, port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    hostport = f"{host}:{port}"
    request = (
        "GET /ws HTTP/1.1\r\n"
        f"Host: {hostport}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Origin: http://{hostport}\r\n"
        f"Sec-WebSocket-Protocol: craftbot, craftbot-auth.{token}\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("ascii"))
    stream = sock.makefile("rb")

    status = stream.readline(1024).decode("latin-1")
    if " 101 " not in status:
        raise ConnectionError("handshake refused: " + status.strip()[:80])
    headers = {}
    while True:
        line = stream.readline(8192).decode("latin-1")
        if line in ("\r\n", "\n", ""):
            break
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    if headers.get("sec-websocket-accept") != accept:
        raise ConnectionError("bad handshake accept")
    sock.settimeout(READ_TIMEOUT)
    return sock, stream


def follow(sock, stream):
    current = {}

    def update(session_id, line):
        if not isinstance(session_id, str) or not SESSION_RE.match(session_id):
            return
        if current.get(session_id, "") == line:
            return
        if line:
            current[session_id] = line
        else:
            current.pop(session_id, None)
        emit({"sessionId": session_id, "status": line})

    def handle(text):
        try:
            message = json.loads(text)
        except ValueError:
            return
        if not isinstance(message, dict) or not isinstance(message.get("data"), dict):
            return
        kind, data = message.get("type"), message["data"]
        session_id = data.get("sessionId")
        if kind == "agent_stream" and "status" in data:
            line = status_line(data.get("status"))
            # A complete line replaces the last; "end" with none clears it,
            # exactly as CraftBot's chat keeps it (streamSlice.ts).
            if line:
                update(session_id, line)
            elif data.get("phase") == "end":
                update(session_id, "")
        elif kind == "session_busy":
            state = data.get("state") or ("running" if data.get("busy") else "idle")
            if state == "idle":
                update(session_id, "")
        elif kind in ("session_cleared", "chat_clear"):
            update(session_id, "")

    pieces, opcode_of_message = [], None
    while True:
        fin, opcode, payload = read_frame(stream)
        if opcode == 0x9:  # ping
            send_frame(sock, 0xA, payload)
        elif opcode == 0x8:  # close
            try:
                send_frame(sock, 0x8, payload[:2])
            except OSError:
                pass
            return
        elif opcode in (0x1, 0x2, 0x0):
            if opcode != 0x0:
                pieces, opcode_of_message = [], opcode
            pieces.append(payload)
            if sum(len(p) for p in pieces) > MAX_MESSAGE:
                raise ValueError("message too large")
            if fin:
                if opcode_of_message == 0x1:
                    handle(b"".join(pieces).decode("utf-8", "replace"))
                pieces, opcode_of_message = [], None


def main():
    base = (sys.argv[1] if len(sys.argv) > 1 else "").strip().rstrip("/")
    match = URL_RE.match(base)
    if not match or not 0 < int(match.group(2)) < 65536:
        print("stream.py: expected a loopback URL like http://127.0.0.1:7926", file=sys.stderr)
        return 2
    try:
        sock, stream = connect(base, match.group(1), int(match.group(2)))
        emit({"event": "connected"})
        follow(sock, stream)
    except (OSError, EOFError, ValueError, ConnectionError) as e:
        print(f"stream.py: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
