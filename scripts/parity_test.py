#!/usr/bin/env python3
"""Read-only behavioral parity checks for the Node and Zig Hypertask CLIs."""

from __future__ import annotations

import argparse
import base64
import difflib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ZIG_CLI = ROOT / "zig-out" / "bin" / "hypertask"
PROJECT = os.environ.get("HYPERTASK_PARITY_PROJECT", "15")
TICKET = os.environ.get("HYPERTASK_PARITY_TICKET", "HTPR-5783")
DERIVED_NODE_FIELDS = frozenset({"has_more", "next_offset", "link", "uniqueIndex"})
STABLE_SCALAR_FIELDS = frozenset({"authenticated", "hasToken", "identity", "success"})
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")

@dataclass(frozen=True)
class ReadCase:
    args: tuple[str, ...]
    ignored_fields: frozenset[str] = DERIVED_NODE_FIELDS

    @property
    def name(self) -> str:
        return " ".join(self.args)

READ_CASES = (
    ReadCase(("context",)),
    ReadCase(("teams", "list")),
    ReadCase(("agents", "list")),
    ReadCase(("project", "list", "--limit", "2")),
    ReadCase(("project", "show", PROJECT)),
    ReadCase(("project", "manifest", PROJECT)),
    ReadCase(("project", "playbook", PROJECT)),
    ReadCase(("project", "instructions", PROJECT)),
    ReadCase(("project", "members", PROJECT)),
    ReadCase(("project", "sections", PROJECT)),
    ReadCase(("project", "labels", PROJECT), DERIVED_NODE_FIELDS | {"projectId"}),
    ReadCase(("labels", "list", "--project", PROJECT), DERIVED_NODE_FIELDS | {"projectId"}),
    ReadCase(("section", "list", "--project", PROJECT)),
    ReadCase(("fields", "list", "--project", PROJECT)),
    ReadCase(("task", "list", "--project", PROJECT, "--limit", "2")),
    ReadCase(("task", "get", TICKET)),
    ReadCase(("task", "context", TICKET, "--project", PROJECT, "--summary")),
    ReadCase(("task", "tree", "--ticket", TICKET)),
    ReadCase(("task", "relations", TICKET)),
    ReadCase(("task", "related", TICKET)),
    ReadCase(("search", TICKET, "--project", PROJECT), DERIVED_NODE_FIELDS | {"limit", "offset"}),
    ReadCase(("comment", "list", TICKET)),
    ReadCase(("pages", "list", "--project", PROJECT)),
    ReadCase(("skills", "list")),
    ReadCase(("inbox", "list")),
    ReadCase(("inbox", "composition", "--project", PROJECT)),
    ReadCase(("report", "list", "--project", PROJECT)),
    ReadCase(("time", "running")),
    ReadCase(("time", "report")),
    ReadCase(("view", "list", "--project", PROJECT)),
)


def run(
    cli: list[str],
    args: list[str] | tuple[str, ...],
    *,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [*cli, *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def resolve_node_cli(explicit: str | None) -> list[str]:
    configured = explicit or os.environ.get("HYPERTASK_NODE_BIN")
    if configured:
        return shlex.split(configured)

    installed = shutil.which("hypertask-node")
    if installed:
        return [installed]

    cli_root = Path.home() / "projects" / "hypertask-mcp" / "CLI"
    tsx = cli_root / "node_modules" / ".bin" / "tsx"
    source = cli_root / "cli_anything" / "hypertask" / "hypertask_cli.ts"
    if tsx.is_file() and source.is_file():
        return [str(tsx), str(source)]

    raise AssertionError(
        "Node CLI not found; set HYPERTASK_NODE_BIN to its executable command"
    )


def resolve_zig_cli(explicit: str | None) -> list[str]:
    cli = Path(explicit).expanduser() if explicit else DEFAULT_ZIG_CLI
    if not cli.is_file():
        raise AssertionError(f"Zig CLI not found at {cli}; run `zig build` first")
    return [str(cli.resolve())]


def reject_same_executable(node_cli: list[str], zig_cli: list[str]) -> None:
    node_executable = shutil.which(node_cli[0]) or node_cli[0]
    if Path(node_executable).resolve() == Path(zig_cli[0]).resolve():
        raise AssertionError("Node and Zig CLI commands resolve to the same executable")


def parse_json(process: subprocess.CompletedProcess[str], label: str) -> Any:
    if process.returncode != 0:
        raise AssertionError(
            f"{label} exited {process.returncode}\n"
            f"stdout: {process.stdout.strip()}\n"
            f"stderr: {process.stderr.strip()}"
        )
    try:
        return json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"{label} did not print JSON: {process.stdout!r}") from error


def run_json(cli: list[str], args: list[str], label: str) -> Any:
    process = run(cli, args)
    for delay in (5, 10):
        if "rate limit exceeded" not in (process.stdout + process.stderr).lower():
            break
        time.sleep(delay)
        process = run(cli, args)
    return parse_json(process, label)


def leaf_catalog(document: dict[str, Any]) -> dict[str, tuple[tuple[str, ...], tuple[str, ...]]]:
    leaves: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {}

    def visit(command: dict[str, Any], parents: tuple[str, ...]) -> None:
        path = parents + (command["name"],)
        children = command.get("commands", [])
        if children:
            for child in children:
                visit(child, path)
            return
        arguments = tuple(
            f"{arg['name']}:{arg['required']}:{arg['variadic']}"
            for arg in command.get("arguments", [])
        )
        options = tuple(option["flags"] for option in command.get("options", []))
        leaves[" ".join(path)] = (arguments, options)

    for command in document["commands"]:
        visit(command, ())
    return leaves


def capabilities(node_cli: list[str], zig_cli: list[str]) -> None:
    node = leaf_catalog(run_json(node_cli, ["capabilities", "--json"], "Node capabilities"))
    zig = leaf_catalog(run_json(zig_cli, ["capabilities", "--json"], "Zig capabilities"))
    missing = sorted(node.keys() - zig.keys())
    changed = sorted(name for name in node.keys() & zig.keys() if node[name] != zig[name])
    if missing or changed:
        raise AssertionError(
            "capability catalogs differ\n"
            f"missing in Zig: {missing}\n"
            f"different arguments/options: {changed}"
        )
    print(
        f"capability parity passed ({len(node)} Node leaves, "
        f"{len(zig) - len(node)} additional Zig leaves)"
    )


def architecture() -> None:
    required = [
        "src/args.zig",
        "src/json_util.zig",
        "src/http.zig",
        "src/resolve.zig",
        "src/router.zig",
        "src/commands/auth.zig",
        "src/commands/meta.zig",
        "src/commands/decision.zig",
        "src/commands/agents.zig",
        "src/commands/webhook.zig",
        "src/commands/admin.zig",
        "src/commands/user.zig",
        "src/commands/project.zig",
        "src/commands/section.zig",
        "src/commands/fields.zig",
        "src/commands/task.zig",
        "src/commands/draft.zig",
        "src/commands/comment.zig",
        "src/commands/pages.zig",
        "src/commands/skills.zig",
        "src/commands/ai.zig",
        "src/commands/inbox.zig",
        "src/commands/report.zig",
        "src/commands/time.zig",
        "src/commands/view.zig",
    ]
    missing = [path for path in required if not (ROOT / path).is_file()]
    if missing:
        raise AssertionError(f"missing architecture files: {missing}")
    print("architecture check passed")


def is_dynamic_field(key: str) -> bool:
    lowered = key.lower()
    if lowered in {"id", "ids", "configpath", "correlationid"}:
        return True
    if key.endswith(("Id", "Ids", "At", "Date", "Time", "Timestamp")):
        return True
    return lowered.endswith(("_id", "_ids", "_at", "_date", "_time", "_timestamp"))


def json_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def normalize(value: Any, ignored_fields: frozenset[str], key: str = "") -> Any:
    if is_dynamic_field(key):
        return f"<{json_type(value)}>"
    if isinstance(value, dict):
        return {
            child_key: normalize(child, ignored_fields, child_key)
            for child_key, child in sorted(value.items())
            if child_key not in ignored_fields
        }
    if isinstance(value, list):
        children = [normalize(child, ignored_fields, key) for child in value]
        unique = {json.dumps(child, sort_keys=True): child for child in children}
        return [unique[encoded] for encoded in sorted(unique)]
    if key in STABLE_SCALAR_FIELDS:
        return value
    return f"<{json_type(value)}>"


def json_diff(node: Any, zig: Any) -> str:
    node_lines = json.dumps(node, indent=2, sort_keys=True).splitlines()
    zig_lines = json.dumps(zig, indent=2, sort_keys=True).splitlines()
    lines = list(difflib.unified_diff(node_lines, zig_lines, fromfile="Node", tofile="Zig", lineterm=""))
    if len(lines) > 120:
        lines = [*lines[:120], f"... diff truncated ({len(lines) - 120} more lines)"]
    return "\n".join(lines)


def read_only_parity(node_cli: list[str], zig_cli: list[str]) -> None:
    failures: list[str] = []
    for case in READ_CASES:
        try:
            node = normalize(run_json(node_cli, [*case.args, "--json"], f"Node {case.name}"), case.ignored_fields)
            zig = normalize(run_json(zig_cli, [*case.args, "--json"], f"Zig {case.name}"), case.ignored_fields)
            if node != zig:
                failures.append(f"{case.name}: JSON differs\n{json_diff(node, zig)}")
        except AssertionError as error:
            failures.append(f"{case.name}: {error}")
    if failures:
        raise AssertionError("read-only parity failures:\n\n" + "\n\n".join(failures))
    print(f"read-only JSON parity passed ({len(READ_CASES)} commands)")


def jwt(agent_id: str) -> str:
    payload = base64.urlsafe_b64encode(
        json.dumps({"agentId": agent_id, "exp": 2_000_000_000}, separators=(",", ":")).encode()
    ).decode().rstrip("=")
    return f"e30.{payload}.signature"


def isolated_env(home: Path, **overrides: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in ("HT_TOKEN", "HYPERTASKS_JWT_TOKEN", "HYPERTASKS_API_URL"):
        env.pop(key, None)
    env["HOME"] = str(home)
    env.update(overrides)
    return env


def assert_status(
    cli: list[str],
    home: Path,
    expected_agent: str,
    expected_api: str,
    *,
    args: tuple[str, ...] = (),
    env_overrides: dict[str, str] | None = None,
) -> None:
    status = parse_json(
        run(cli, [*args, "status", "--json"], env=isolated_env(home, **(env_overrides or {}))),
        f"status for {expected_agent}",
    )
    if status.get("agentId") != expected_agent or status.get("apiUrl") != expected_api:
        raise AssertionError(
            f"status selected agent/api {status.get('agentId')!r}/{status.get('apiUrl')!r}; "
            f"expected {expected_agent!r}/{expected_api!r}"
        )


def write_config(home: Path, agent_id: str, api_url: str) -> None:
    config_dir = home / ".hypertask"
    config_dir.mkdir()
    (config_dir / "config.json").write_text(
        json.dumps({"token": jwt(agent_id), "apiUrl": api_url}), encoding="utf-8"
    )


def auth_matrix(node_cli: list[str], zig_cli: list[str]) -> None:
    saved_api = "https://saved.example.test/api"
    argument_api = "https://argument.example.test/api"
    environment_api = "https://environment.example.test/api"
    shared_cases = (
        ("saved", saved_api, (), {}),
        (
            "argument",
            argument_api,
            ("--token", jwt("argument"), "--api-url", argument_api),
            {"HT_TOKEN": jwt("ht-environment"), "HYPERTASKS_JWT_TOKEN": jwt("jwt-environment")},
        ),
        ("jwt-environment", saved_api, (), {"HYPERTASKS_JWT_TOKEN": jwt("jwt-environment")}),
        ("saved", saved_api, (), {"HT_TOKEN": "", "HYPERTASKS_API_URL": ""}),
        ("saved", environment_api, (), {"HYPERTASKS_API_URL": environment_api}),
    )
    with tempfile.TemporaryDirectory(prefix="hypertask-parity-") as directory:
        home = Path(directory)
        write_config(home, "saved", saved_api)
        for cli in (node_cli, zig_cli):
            for agent_id, api_url, args, environment in shared_cases:
                assert_status(cli, home, agent_id, api_url, args=args, env_overrides=environment)
        assert_status(
            zig_cli,
            home,
            "ht-environment",
            saved_api,
            env_overrides={"HT_TOKEN": jwt("ht-environment"), "HYPERTASKS_JWT_TOKEN": jwt("jwt-environment")},
        )
    print("authentication source matrix passed")


def assert_not_json_object(process: subprocess.CompletedProcess[str], label: str) -> None:
    if process.returncode != 0:
        raise AssertionError(f"{label} exited {process.returncode}: {process.stderr.strip()}")
    try:
        parsed = json.loads(process.stdout)
    except json.JSONDecodeError:
        return
    if isinstance(parsed, dict):
        raise AssertionError(f"{label} printed a JSON object")


def human_output(zig_cli: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="hypertask-parity-") as directory:
        home = Path(directory)
        write_config(home, "human", "https://saved.example.test/api")
        env = isolated_env(home)
        assert_not_json_object(run(zig_cli, ["--human", "status"], env=env), "--human status")
        assert_not_json_object(run(zig_cli, ["capabilities"], env=env), "bare capabilities")
    print("human output checks passed")


def error_shape(stderr: str) -> str:
    cleaned = ANSI_ESCAPE.sub("", stderr)
    missing = re.search(r"missing required argument ['\"]?([^'\"\s]+)", cleaned, re.IGNORECASE)
    if not missing:
        missing = re.search(r"required argument:\s*([^\s]+)", cleaned, re.IGNORECASE)
    if missing:
        return f"missing-required-argument:{missing.group(1)}"
    if re.search(r"unknown command|UnknownCommand|not a valid subcommand", cleaned, re.IGNORECASE):
        return "unknown-command"
    return "unclassified"


def negative_cases(node_cli: list[str], zig_cli: list[str]) -> None:
    cases = (
        ("task", "get"),
        ("project", "show"),
        ("comment", "list"),
        ("task", "does-not-exist"),
    )
    with tempfile.TemporaryDirectory(prefix="hypertask-parity-") as directory:
        home = Path(directory)
        write_config(home, "negative", "https://saved.example.test/api")
        env = isolated_env(home)
        failures: list[str] = []
        for case in cases:
            node = run(node_cli, [*case, "--json"], env=env)
            zig = run(zig_cli, [*case, "--json"], env=env)
            node_shape = error_shape(node.stderr)
            zig_shape = error_shape(zig.stderr)
            if node.returncode != zig.returncode or node_shape != zig_shape or node_shape == "unclassified":
                failures.append(
                    f"{' '.join(case)}: Node={node.returncode}/{node_shape}, "
                    f"Zig={zig.returncode}/{zig_shape}"
                )
        if failures:
            raise AssertionError("negative parity failures:\n" + "\n".join(failures))
    print(f"negative parity passed ({len(cases)} cases)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capabilities-only", action="store_true")
    parser.add_argument("--architecture-only", action="store_true")
    parser.add_argument("--node-cli", help="Node CLI executable command")
    parser.add_argument("--zig-cli", help="Zig CLI executable path")
    options = parser.parse_args()
    try:
        if options.architecture_only:
            architecture()
            return 0
        node_cli = resolve_node_cli(options.node_cli)
        zig_cli = resolve_zig_cli(options.zig_cli)
        reject_same_executable(node_cli, zig_cli)
        capabilities(node_cli, zig_cli)
        if not options.capabilities_only:
            read_only_parity(node_cli, zig_cli)
            auth_matrix(node_cli, zig_cli)
            human_output(zig_cli)
            negative_cases(node_cli, zig_cli)
    except (AssertionError, json.JSONDecodeError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
