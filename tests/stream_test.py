#!/usr/bin/env python3
"""Regression tests for stream.py's loopback-only token request.

Runs stream.py against tests/fake_craftbot.py:
- a normal backend: connects and reports the scripted status line;
- a token endpoint that redirects elsewhere: the redirect is refused;
- a bogus proxy in the environment: ignored, the connection stays direct.

Usage: python3 tests/stream_test.py
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
STREAM = os.path.join(HERE, "..", "stream.py")
FAKE = os.path.join(HERE, "fake_craftbot.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class StreamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.tmp.name, "state.json")
        self.script = os.path.join(self.tmp.name, "script.jsonl")
        with open(self.state, "w") as f:
            f.write("{}")
        with open(self.script, "w") as f:
            f.write(json.dumps({"type": "agent_stream", "data": {
                "sessionId": "main", "phase": "update", "status": "Reading the project README..."}}) + "\n")
        self.servers = []

    def tearDown(self):
        for server in self.servers:
            server.kill()
            server.wait()
            server.stdout.close()
        self.tmp.cleanup()

    def serve(self, *extra):
        port = free_port()
        server = subprocess.Popen([sys.executable, FAKE, str(port), self.state, self.script, *extra],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.servers.append(server)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.1).close()
                return port
            except OSError:
                time.sleep(0.05)
        self.fail("fake server did not start")

    def run_stream(self, port, env=None, seconds=3):
        try:
            out = subprocess.run([sys.executable, "-I", STREAM, f"http://127.0.0.1:{port}"],
                                 capture_output=True, text=True, timeout=seconds, env=env)
            return out.returncode, out.stdout, out.stderr
        except subprocess.TimeoutExpired as e:  # still connected: that's the success case
            stdout = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
            return None, stdout, ""

    def test_normal_backend_streams_status(self):
        code, out, _ = self.run_stream(self.serve())
        self.assertIsNone(code)
        self.assertIn('"event": "connected"', out)
        self.assertIn("Reading the project README...", out)

    def test_token_redirect_is_refused(self):
        target = self.serve()  # a second loopback server the redirect points at
        port = self.serve("--redirect-token", f"http://127.0.0.1:{target}/api/session-token")
        code, out, err = self.run_stream(port)
        self.assertEqual(code, 1)
        self.assertNotIn("connected", out)
        self.assertIn("redirects are not followed", err)

    def test_proxy_environment_is_ignored(self):
        env = dict(os.environ, http_proxy="http://127.0.0.1:9", HTTP_PROXY="http://127.0.0.1:9",
                   all_proxy="http://127.0.0.1:9", no_proxy="")
        code, out, _ = self.run_stream(self.serve(), env=env)
        self.assertIsNone(code)
        self.assertIn('"event": "connected"', out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
