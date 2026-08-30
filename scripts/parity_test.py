#!/usr/bin/env python3
"""Small, read-only parity checks for the Node and Zig Hypertask CLIs."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NODE_CLI = "hypertask"
ZIG_CLI = str(ROOT / "zig-out" / "bin" / "hypertask")


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)


def leaf_catalog(document: dict) -> list[tuple[str, tuple[str, ...], tuple[str, ...]]]:
    leaves: list[tuple[str, tuple[str, ...], tuple[str, ...]]] = []

    def visit(command: dict, parents: tuple[str, ...]) -> None:
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
        leaves.append((" ".join(path), arguments, options))

    for command in document["commands"]:
        visit(command, ())
    return leaves


def capabilities() -> None:
    node = run([NODE_CLI, "capabilities", "--json"])
    zig = run([ZIG_CLI, "capabilities", "--json"])
    if node.returncode or zig.returncode:
        raise AssertionError(
            f"capabilities failed: node={node.returncode} zig={zig.returncode}\n"
            f"node stderr: {node.stderr}\nzig stderr: {zig.stderr}"
        )
    node_leaves = leaf_catalog(json.loads(node.stdout))
    zig_leaves = leaf_catalog(json.loads(zig.stdout))
    if node_leaves != zig_leaves:
        node_names = {leaf[0] for leaf in node_leaves}
        zig_names = {leaf[0] for leaf in zig_leaves}
        raise AssertionError(
            "capability catalogs differ\n"
            f"missing in Zig: {sorted(node_names - zig_names)}\n"
            f"extra in Zig: {sorted(zig_names - node_names)}"
        )
    print(f"capability parity passed ({len(zig_leaves)} leaves)")


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


def read_only_parity() -> None:
    cases = [
        ["status"],
        ["capabilities"],
        ["context"],
        ["project", "list", "--limit", "1"],
        ["section", "list", "--project", "15"],
        ["task", "list", "--project", "15", "--limit", "1"],
        ["inbox", "list"],
        ["time", "running"],
    ]
    failures: list[str] = []
    for case in cases:
        node = run([NODE_CLI, *case, "--json"])
        zig = run([ZIG_CLI, *case, "--json"])
        if node.returncode != zig.returncode:
            failures.append(
                f"{' '.join(case)}: node={node.returncode}, zig={zig.returncode}; "
                f"zig stderr={zig.stderr.strip()!r}"
            )
    if failures:
        raise AssertionError("read-only exit-code mismatches:\n" + "\n".join(failures))
    print(f"read-only parity passed ({len(cases)} commands)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capabilities-only", action="store_true")
    parser.add_argument("--architecture-only", action="store_true")
    options = parser.parse_args()
    try:
        if options.capabilities_only:
            capabilities()
        elif options.architecture_only:
            architecture()
        else:
            read_only_parity()
    except (AssertionError, json.JSONDecodeError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
