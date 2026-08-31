#!/usr/bin/env python3
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading


def jwt(claims: dict) -> str:
    payload = base64.urlsafe_b64encode(
        json.dumps(claims, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"e30.{payload}.signature"


def run(binary: str, token: str, api_url: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [binary, "--token", token, "--api-url", api_url, *args, "--json"],
        check=False,
        capture_output=True,
        text=True,
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/mcp/comments?"):
            overflow_case = "ticket_number=HTPR-2" in self.path
            self.respond(200, {
                "success": True,
                "comments": [{"id": 1, "text": "first"}],
                "total": 9_223_372_036_854_775_807 if overflow_case else 2,
                "limit": 1,
                "offset": 9_223_372_036_854_775_807 if overflow_case else 0,
            })
            return
        if self.path.startswith("/mcp/tasks?"):
            self.respond(404, {
                "success": False,
                "error": "Task not found",
            })
            return
        self.respond(500, {"success": False, "error": f"unexpected path: {self.path}"})

    def respond(self, status: int, body: dict) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        pass


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    binary = str(Path(sys.argv[1]).resolve())
    token = jwt({
        "agentId": "agent-test",
        "exp": 1_788_614_666,
    })
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    api_url = f"http://127.0.0.1:{server.server_port}"

    try:
        status = run(binary, token, api_url, "status")
        expect(status.returncode == 0, f"status failed: {status.stderr}")
        status_json = json.loads(status.stdout)
        expect(status_json.get("identity") == "agent", f"missing agent identity: {status.stdout}")
        expect(status_json.get("agentId") == "agent-test", f"missing agentId: {status.stdout}")
        expect(
            status_json.get("expiresAt") == "2026-09-05T13:24:26.000Z",
            f"missing expiry: {status.stdout}",
        )

        huge_expiry = run(binary, jwt({"exp": 9_223_372_036_854_775_807}), api_url, "status")
        expect(huge_expiry.returncode == 0, f"huge expiry crashed: {huge_expiry.stderr}")
        expect(json.loads(huge_expiry.stdout).get("expiresAt") is None, huge_expiry.stdout)

        comments = run(binary, token, api_url, "comment", "list", "HTPR-1")
        expect(comments.returncode == 0, f"comment list failed: {comments.stderr}")
        comments_json = json.loads(comments.stdout)
        expect(comments_json.get("has_more") is True, f"missing has_more: {comments.stdout}")

        overflow_comments = run(binary, token, api_url, "comment", "list", "HTPR-2")
        expect(overflow_comments.returncode == 0, f"large offset crashed: {overflow_comments.stderr}")
        expect(json.loads(overflow_comments.stdout).get("has_more") is False, overflow_comments.stdout)

        missing = run(binary, token, api_url, "tasks", "get", "HTPR-404")
        expect(missing.returncode == 4, f"not-found exit was {missing.returncode}")
        expect(missing.stderr == "", f"error leaked to stderr: {missing.stderr!r}")
        expect(json.loads(missing.stdout)["error"] == "Task not found", missing.stdout)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    print("output parity regression tests passed")


if __name__ == "__main__":
    main()
