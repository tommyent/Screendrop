#!/usr/bin/env python3
"""Disposable loopback chat stub; exits after five requests or 60 seconds."""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

class Stub(BaseHTTPRequestHandler):
    count = 0

    def log_message(self, *_):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/chat/completions"
        assert payload["stream"] is False
        assert payload["response_format"] == {"type": "json_object"}
        assert [item["role"] for item in payload["messages"]] == ["system", "user"]
        Stub.count += 1
        if payload["model"] == "http-error":
            self.send_response(503)
            self.end_headers()
            return
        content = "invalid JSON" if payload["model"] == "bad-json" else json.dumps({
            "title": "Export settings", "summary": "The narration explains how to export the recording."
        })
        data = json.dumps({"choices": [{"message": {"content": content}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

with HTTPServer(("127.0.0.1", 0), Stub) as server:
    server.timeout = 1
    print(f"http://localhost:{server.server_port}/v1", flush=True)
    deadline = time.monotonic() + 60
    while Stub.count < 5 and time.monotonic() < deadline:
        server.handle_request()
    assert Stub.count == 5, f"Expected five client requests, received {Stub.count}"
    print("PASS: five OpenAI-style requests received and validated", flush=True)
