#!/usr/bin/env python3
"""HTPR-7119: discovery commands work with no token; login says where to get one."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from htpr_7323_url_formats_test import EXPECTED_URL_FORMATS

URL = "https://app.hypertask.ai/agents"


def run(binary, home, *args):
    env = {"PATH": os.environ.get("PATH", ""), "HOME": home}
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=30)


def main():
    binary = str(Path(sys.argv[1]).resolve())
    passed = 0
    with tempfile.TemporaryDirectory() as home:
        for args in (["capabilities", "--json"], ["commands", "--json"], ["capabilities"], ["commands"], ["--help"], []):
            result = run(binary, home, *args)
            assert result.returncode == 0, (args, result.returncode, result.stderr)
            assert "authentication token is missing" not in result.stderr, args
            if "--json" in args:
                assert json.loads(result.stdout)["urlFormats"] == EXPECTED_URL_FORMATS
            passed += 1
        login = run(binary, home, "login")
        assert login.returncode != 0
        assert URL in login.stderr and "hypertask login --token" in login.stderr, login.stderr
        passed += 1
        status = run(binary, home, "task", "list")
        assert status.returncode == 2, status.returncode
        assert URL in status.stderr, status.stderr
        passed += 1
    print(f"no-login discovery passed: {passed} passed, 0 failed")


main()
