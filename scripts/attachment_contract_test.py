#!/usr/bin/env python3
"""Exercise repeated attachments and named failures against a local MCP stub."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "zig-out/bin/hypertask"
LIMIT = 3 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    requests = []
    mode = "complete"

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, body))
        if self.path == "/mcp/comments":
            response = {"success": True, "comment": {"id": 7, "attachments": []}}
            code = 200
        else:
            assert self.path == "/mcp/tasks/attachments"
            files = body["files"]
            too_large = sum(len(base64.b64decode(f.get("data", ""))) for f in files) > LIMIT
            if too_large or (self.mode == "http" and files[0]["filename"] == "b.png"):
                response = {"success": False, "error": "inline limit or rejected file"}
                code = 400
            elif self.mode == "empty":
                response, code = {"success": True, "attachments": []}, 200
            elif self.mode == "logical":
                response, code = {"success": False, "error": "storage failed"}, 200
            elif self.mode == "invalid":
                response, code = {"success": True, "attachments": [{"id": 0}]}, 200
            elif self.mode == "malformed":
                response, code = "not JSON", 200
            elif self.mode == "payload":
                response, code = "Request Entity Too Large", 413
            else:
                response = {"success": True, "attachments": [
                    {"id": len(self.requests), "fileName": f["filename"]} for f in files
                ]}
                code = 200
        raw = response.encode() if isinstance(response, str) else json.dumps(response).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="hypertask-attach-") as directory:
            home = Path(directory)
            a, b, c = (home / name for name in ("a.png", "b.png", "c.webm"))
            a.write_bytes(b"\x89PNG" + b"a" * (2 * 1024 * 1024))
            b.write_bytes(b"\x89PNG" + b"b" * (2 * 1024 * 1024))
            c.write_bytes(b"\x1a\x45\xdf\xa3webm")
            large = home / "too-large.webm"
            large.write_bytes(b"x" * (LIMIT + 1))
            missing = home / "missing.png"
            env = os.environ.copy()
            for name in ("HT_TOKEN", "HT_AGENT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
                env.pop(name, None)
            env.update(HOME=str(home), HT_TOKEN="test-token", HYPERTASKS_API_URL=f"http://127.0.0.1:{server.server_port}")

            def run(files, mode="complete"):
                Handler.requests = []
                Handler.mode = mode
                args = [str(BINARY), "comment", "add", "HTPR-6834", "--text", "<p>stub test</p>", "--json"]
                for file in files:
                    args.extend(("--attach", str(file)))
                return subprocess.run(args, env=env, capture_output=True, text=True, timeout=30)

            result = run((a, b, c))
            assert result.returncode == 0, result.stderr
            uploaded = json.loads(result.stdout)["attachments_uploaded"]
            assert uploaded["success"] is True
            assert [f["fileName"] for f in uploaded["attachments"]] == ["a.png", "b.png", "c.webm"]
            assert len(Handler.requests) == 4
            for (_, body), file in zip(Handler.requests[1:], (a, b, c)):
                assert body["comment_id"] == 7 and body["ticket_number"] == "HTPR-6834"
                assert len(body["files"]) == 1
                assert base64.b64decode(body["files"][0]["data"]) == file.read_bytes()
            assert Handler.requests[-1][1]["files"][0]["content_type"] == "application/octet-stream"

            for file in (missing, large):
                result = run((a, file))
                assert result.returncode != 0 and str(file) in result.stderr, result
                assert not result.stdout and not Handler.requests
            assert "3 MiB" in result.stderr and "https URL" in result.stderr

            for mode in ("http", "empty", "logical", "invalid", "malformed", "payload"):
                result = run((a, b), mode)
                failing = b if mode == "http" else a
                assert result.returncode != 0 and str(failing) in result.stderr, (mode, result)
                if result.stdout:
                    if mode == "payload":
                        assert result.stdout.strip() == "Request Entity Too Large"
                    else:
                        assert json.loads(result.stdout).get("success") is not True, (mode, result.stdout)
                assert "may already exist" in result.stderr
                assert len(Handler.requests) == (3 if mode == "http" else 2)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("attachment contract tests passed")


if __name__ == "__main__":
    main()
