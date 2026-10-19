#!/usr/bin/env python3
"""Loopback-only command/output and capabilities checks for comment routing."""
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
LOG = {"success": True, "routedTo": "log", "activity": {
    "id": "activity-1", "runId": "run-1", "type": "comment", "text": "Test", "createdAt": "2026-09-30T00:00:00Z",
}}
COMMENT = {"success": True, "comment": {"id": 7, "text": "Test"}}
NOTICE = "Saved to the agent log (no comment, nobody notified). Use --kind question|qa|done to post a comment for people.\n"


class Handler(BaseHTTPRequestHandler):
    requests = []
    response = LOG

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, body))
        raw = json.dumps(self.response).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    passed = 0
    try:
        with tempfile.TemporaryDirectory(prefix="hypertask-comment-kind-") as directory:
            env = os.environ.copy()
            for key in ("HT_TOKEN", "HT_AGENT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
                env.pop(key, None)
            env.update(HOME=directory, VCC_HELPER="0", VCC_HELPER_PROC_ROOT=str(Path(directory) / "no-proc"))
            base = [str(BINARY), "--token", "test-token", "--api-url", f"http://127.0.0.1:{server.server_port}"]

            def run(*args):
                return subprocess.run([*base, *args], env=env, capture_output=True, text=True, timeout=30)

            def add(*flags):
                Handler.requests = []
                return run("comment", "add", "HTPR-7341", "--text", "<p>Test</p>", *flags)

            for kind in ("question", "qa", "done"):
                Handler.response = {**COMMENT, "routedTo": "comments"}
                result = add("--kind", kind, "--json")
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout) == Handler.response
                assert Handler.requests == [("/mcp/comments", {
                    "ticket_number": "HTPR-7341", "text": "<p>Test</p>", "kind": kind,
                })], Handler.requests
                passed += 1

            for kind in ("chatter", "Question", ""):
                result = add("--kind", kind, "--improve", "--project", "15")
                assert result.returncode == 2, result.stderr
                assert "--kind must be one of: question, qa, done" in result.stderr
                assert not Handler.requests and not result.stdout, (Handler.requests, result)
                passed += 1

            result = add("--kind")
            assert result.returncode == 2 and "missing value for --kind" in result.stderr, result
            assert not Handler.requests
            passed += 1

            Handler.response = LOG
            for flags, expected in (((), NOTICE), (("--human",), NOTICE),
                                    (("--json",), json.dumps(LOG) + "\n"),
                                    (("--human", "--json"), json.dumps(LOG) + "\n")):
                result = add(*flags)
                assert result.returncode == 0 and result.stdout == expected, result
                assert Handler.requests == [("/mcp/comments", {
                    "ticket_number": "HTPR-7341", "text": "<p>Test</p>",
                })], Handler.requests
                passed += 1

            for flags in ((), ("--json",)):
                result = add("--attach", "https://example.test/a.png", *flags)
                assert result.returncode == 0, result.stderr
                assert result.stdout == (json.dumps(LOG) + "\n" if flags else NOTICE), result
                assert "Attachments were not uploaded" in result.stderr
                assert len(Handler.requests) == 1, Handler.requests
                passed += 1

            for response in (COMMENT, {**COMMENT, "routedTo": "comments"}):
                Handler.response = response
                for flags in ((), ("--json",), ("--human",)):
                    result = add(*flags)
                    assert result.returncode == 0, result.stderr
                    if flags == ("--human",):
                        assert "id: 7" in result.stdout and "Saved to the agent log" not in result.stdout, result
                    else:
                        assert result.stdout == json.dumps(response) + "\n", result
                    passed += 1

            catalog = run("capabilities", "--json")
            assert catalog.returncode == 0, catalog.stderr
            source = json.loads((ROOT / "src/capabilities.json").read_text())
            assert json.loads(catalog.stdout) == source
            comment = next(c for c in source["commands"] if c["name"] == "comment")
            command = next(c for c in comment["commands"] if c["name"] == "add")
            option = next(o for o in command["options"] if o["flags"] == "--kind <question|qa|done>")
            assert not option["required"] and "omitted kind" in option["description"]
            for alias in ("comment", "comments"):
                help_result = run(alias, "add", "--help")
                assert help_result.returncode == 0 and option["flags"] in help_result.stdout, help_result
                assert option["description"] in help_result.stdout
            assert "comment add --kind question|qa|done" in (ROOT / "README.md").read_text()
            passed += 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"comment kind tests: {passed} passed, 0 failed (including capabilities consistency)")


if __name__ == "__main__":
    main()
