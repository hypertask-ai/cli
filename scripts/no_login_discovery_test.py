#!/usr/bin/env python3
"""HTPR-7119: discovery commands work with no token; login says where to get one."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

URL = "https://app.hypertask.ai/agents"


def run(binary, home, *args):
    env = {"PATH": os.environ.get("PATH", ""), "HOME": home}
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=30)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as home:
        for args in (["capabilities", "--json"], ["capabilities"], ["commands"], ["--help"], []):
            result = run(binary, home, *args)
            assert result.returncode == 0, (args, result.returncode, result.stderr)
            assert "authentication token is missing" not in result.stderr, args
        assert run(binary, home, "capabilities", "--json").stdout.lstrip().startswith("{")
        login = run(binary, home, "login")
        assert login.returncode != 0
        assert URL in login.stderr and "hypertask login --token" in login.stderr, login.stderr
        status = run(binary, home, "task", "list")
        assert status.returncode == 2, status.returncode
        assert URL in status.stderr, status.stderr
    print("no-login discovery tests passed")


main()
