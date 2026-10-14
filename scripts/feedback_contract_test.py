#!/usr/bin/env python3
"""Loopback-only checks for anonymous feedback filing and error handling."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CLI = Path(sys.argv[1]).resolve()
RESULT = {"success": True, "ticketNumber": "TEST-1", "url": "https://example.test/1", "deduped": False, "count": 1}


class Handler(BaseHTTPRequestHandler):
    status = 200
    response: object = RESULT
    requests: list[tuple[str, str | None, str | None, object]] = []

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, self.headers.get("Authorization"), self.headers.get("Content-Type"), body))
        encoded = json.dumps(self.response).encode()
        self.send_response(self.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory() as directory:
            env = os.environ.copy()
            env["HOME"] = directory
            env.update(VCC_HELPER="0", VCC_HELPER_PROC_ROOT=str(Path(directory) / "no-proc"))
            for key in ("HT_TOKEN", "HT_AGENT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
                env.pop(key, None)
            base = [str(CLI), "--token", "test-token", "--api-url", f"http://127.0.0.1:{server.server_port}/api"]

            def run(*args: str) -> subprocess.CompletedProcess[str]:
                return subprocess.run([*base, *args], env=env, text=True, capture_output=True, check=False)

            filed = run("feedback", "Unexpected failure")
            assert filed.returncode == 0, filed.stderr
            assert filed.stdout == "Filed TEST-1: https://example.test/1\n", filed.stdout
            assert Handler.requests == [("/api/mcp/feedback", "Bearer test-token", "application/json", {
                "surface": "cli", "client": "hypertask-cli", "category": "other", "note": "Unexpected failure",
            })], Handler.requests

            categories = ("call_failed", "empty_result", "unexpected_result", "auth_failed", "slow",
                          "user_reported_broken", "other")
            for flags, category in [((), "other"), *((('--category', value), value) for value in categories)]:
                category_only = run("feedback", *flags)
                assert category_only.returncode == 0, category_only.stderr
                assert Handler.requests[-1][3] == {
                    "surface": "cli", "client": "hypertask-cli", "category": category,
                }, Handler.requests[-1]

            Handler.response = {**RESULT, "deduped": True, "count": 3}
            deduped = run("feedback", "Unexpected failure")
            assert deduped.returncode == 0, deduped.stderr
            assert deduped.stdout == "Added to TEST-1 (seen 3 times): https://example.test/1\n", deduped.stdout

            raw = run("feedback", 'Failed "again"\n', "--category", "call_failed", "--tool", "task get", "--status", "503",
                      "--error-code", "upstream-error", "--error", "Unavailable", "--surface", "agent", "--json")
            assert raw.returncode == 0, raw.stderr
            assert raw.stdout == json.dumps(Handler.response) + "\n", raw.stdout
            raw_with_human = run("feedback", "Unexpected failure", "--human", "--json")
            assert raw_with_human.returncode == 0, raw_with_human.stderr
            assert raw_with_human.stdout == json.dumps(Handler.response) + "\n", raw_with_human.stdout
            assert Handler.requests[-2][3] == {
                "surface": "agent", "client": "hypertask-cli", "category": "call_failed", "tool": "task get", "status": 503,
                "errorCode": "upstream-error", "error": "Unavailable", "note": 'Failed "again"\n',
            }, Handler.requests[-2]

            Handler.status = 400
            for key, message in (
                ("error", "tool must not contain credentials"),
                ("error", "client must not contain credentials"),
                ("error", "errorCode must not contain credentials"),
                ("message", "Invalid feedback metadata"),
            ):
                Handler.response = {"success": False, key: message}
                for flags in ((), ("--json",)):
                    rejected = run("feedback", "--category", "call_failed", *flags)
                    assert rejected.returncode == 2, (rejected.returncode, rejected.stderr)
                    assert f"hypertask feedback: {message}\n" in rejected.stderr, rejected.stderr
                    assert json.loads(rejected.stdout) == Handler.response, rejected.stdout
                    assert "Filed" not in rejected.stdout and "Added to" not in rejected.stdout

            for status, message in ((404, "Feedback is not enabled for this account"),
                                    (429, "Feedback rate limit reached, try again later")):
                Handler.status = status
                Handler.response = {"success": False, "error": "fixture failure"}
                for flags in ((), ("--json",)):
                    failed = run("feedback", "Unexpected failure", *flags)
                    assert failed.returncode == 4, (failed.returncode, failed.stdout, failed.stderr)
                    assert message in failed.stderr, failed.stderr
                    assert "Filed" not in failed.stdout and "Added to" not in failed.stdout, failed.stdout

            for status in (200, 500):
                Handler.status = status
                failed = run("feedback", "Unexpected failure")
                assert failed.returncode == 4, (failed.returncode, failed.stdout, failed.stderr)
                assert "Filed" not in failed.stdout and "Added to" not in failed.stdout, failed.stdout

            Handler.status = 200
            Handler.response = {}
            malformed = run("feedback", "Unexpected failure")
            assert malformed.returncode == 4, (malformed.returncode, malformed.stdout, malformed.stderr)

            requests_before = len(Handler.requests)
            for args, message in (
                (("feedback", "--category"), "missing value for --category"),
                *(((("feedback", "--category", value), "valid categories:")
                  for value in ("", "broken", "CALL_FAILED", "call-failed"))),
                (("feedback", "failure", "extra"), "unexpected argument: extra"),
                (("feedback", "failure", "--tool"), "missing value for --tool"),
                (("feedback", "failure", "--surface", "web"), "valid surfaces: cli, agent"),
                (("feedback", "failure", "--status", "abc"), "invalid integer for status"),
                (("feedback", "failure", "--status", "600"), "status must be an HTTP status"),
                (("feedback", "failure", "--bogus"), "unknown option: --bogus"),
            ):
                invalid = run(*args)
                assert invalid.returncode == 2, (args, invalid.returncode, invalid.stderr)
                assert message in invalid.stderr, (args, invalid.stderr)
            assert len(Handler.requests) == requests_before, Handler.requests

            unauthenticated = subprocess.run(
                [str(CLI), "--api-url", base[4], "feedback", "failure"],
                env=env, text=True, capture_output=True, check=False,
            )
            assert unauthenticated.returncode != 0, unauthenticated.stdout
            assert len(Handler.requests) == requests_before, Handler.requests

            for args in ((), ("feedback", "--help")):
                help_output = run(*args)
                assert help_output.returncode == 0, help_output.stderr
                assert "on your own when a hypertask command fails unexpectedly" in help_output.stdout
                assert "Never include task, board or comment content" in help_output.stdout
                assert "Free text (note and error) is not stored; agents should pick a category" in help_output.stdout
                if args:
                    assert "Usage: hypertask feedback [note] [options]" in help_output.stdout
                    assert all(category in help_output.stdout for category in categories)
            catalog = run("capabilities", "--json")
            assert catalog.returncode == 0, catalog.stderr
            feedback = next(command for command in json.loads(catalog.stdout)["commands"] if command["name"] == "feedback")
            assert {option["flags"] for option in feedback["options"]} == {
                "--category <value>", "--tool <command name>", "--status <http status>", "--error-code <slug>",
                "--error <message>", "--surface <cli|agent>", "--json",
            }, feedback
            assert feedback["arguments"] == [{"name": "note", "required": False, "variadic": False}], feedback
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    print("feedback contract checks passed")


if __name__ == "__main__":
    main()
