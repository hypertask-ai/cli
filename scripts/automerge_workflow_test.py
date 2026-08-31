#!/usr/bin/env python3
"""Behavioral tests for the default-branch auto-merge evaluator."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "automerge.yml"


def workflow_script() -> str:
    contents = WORKFLOW.read_text(encoding="utf-8")
    marker = "        run: |\n"
    _, separator, script = contents.partition(marker)
    if not separator:
        raise AssertionError("auto-merge workflow has no run script")
    return textwrap.dedent(script)


class AutoMergeWorkflowTest(unittest.TestCase):
    def run_evaluator(
        self,
        check_state: str,
        *,
        check_type: str = "CheckRun",
        workflow_name: str = "CI",
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory(prefix="hypertask-automerge-test-") as directory:
            root = Path(directory)
            binary_dir = root / "bin"
            runner_temp = root / "runner"
            merge_log = root / "merges"
            binary_dir.mkdir()
            runner_temp.mkdir()

            gh = binary_dir / "gh"
            gh.write_text(
                """#!/usr/bin/env bash
set -u
if [ "$1 $2" = "pr view" ]; then
  if [[ " $* " == *" --json mergeable "* ]]; then echo MERGEABLE; exit 0; fi
  if [[ " $* " == *" --json labels -q "* ]]; then exit 0; fi
  if [ "$CHECK_STATE" = "MISSING" ]; then checks='[]';
  else checks=$(jq -cn --arg state "$CHECK_STATE" --arg type "$CHECK_TYPE" --arg workflow "$WORKFLOW_NAME" '[{__typename:$type,workflowName:$workflow,name:"test",conclusion:$state,startedAt:"2026-08-31T10:00:00Z"}]'); fi
  printf '{"number":42,"isDraft":false,"isCrossRepository":false,"mergeable":"MERGEABLE","baseRefName":"main","headRefOid":"%040d","headRepositoryOwner":{"login":"owner"},"labels":[],"statusCheckRollup":%s}\n' 0 "$checks"
  exit 0
fi
if [ "$1 $2" = "pr diff" ]; then echo src/main.zig; exit 0; fi
if [ "$1 $2" = "pr merge" ]; then printf 'merge %s\n' "$*" >> "$MERGE_LOG"; exit 0; fi
if [ "$1 $2" = "workflow run" ]; then printf 'dispatch %s\n' "$*" >> "$MERGE_LOG"; exit 0; fi
echo "unexpected gh call: $*" >&2
exit 2
""",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            sleep = binary_dir / "sleep"
            sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            sleep.chmod(0o755)

            result = subprocess.run(
                ["bash", "-c", workflow_script()],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{binary_dir}:{os.environ['PATH']}",
                    "REPO": "owner/repository",
                    "EVENT": "workflow_dispatch",
                    "DISP_PR": "42",
                    "RUN_BRANCH": "",
                    "RUN_REPO": "",
                    "RUNNER_TEMP": str(runner_temp),
                    "CHECK_STATE": check_state,
                    "CHECK_TYPE": check_type,
                    "WORKFLOW_NAME": workflow_name,
                    "MERGE_LOG": str(merge_log),
                },
                text=True,
                capture_output=True,
                check=False,
            )
            merges = merge_log.read_text(encoding="utf-8") if merge_log.exists() else ""
            return result, merges

    def test_successful_required_check_merges_exact_head(self) -> None:
        result, merges = self.run_evaluator("SUCCESS")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MERGED #42", result.stdout)
        self.assertIn("--match-head-commit 0000000000000000000000000000000000000000", merges)
        self.assertIn("dispatch workflow run install-fleet.yml", merges)

    def test_non_green_required_check_blocks_merge(self) -> None:
        for state in ("FAILURE", "PENDING", "MISSING"):
            with self.subTest(state=state):
                result, merges = self.run_evaluator(state)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"check test = {state}", result.stdout)
                self.assertIn("skip: not all required checks green", result.stdout)
                self.assertEqual(merges, "")

    def test_forged_or_wrong_workflow_success_does_not_satisfy_gate(self) -> None:
        for check_type, workflow_name in (("StatusContext", ""), ("CheckRun", "Other")):
            with self.subTest(check_type=check_type, workflow_name=workflow_name):
                result, merges = self.run_evaluator(
                    "SUCCESS", check_type=check_type, workflow_name=workflow_name
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("check test = MISSING", result.stdout)
                self.assertEqual(merges, "")

    def test_install_workflow_reconciles_undispatched_main_commits(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "install-fleet.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn('cron: "*/5 * * * *"', workflow)
        self.assertIn("installed-commit", workflow)
        self.assertIn("grep -Fxq \"$GITHUB_SHA\"", workflow)
        self.assertIn("Record installed commit", workflow)


if __name__ == "__main__":
    unittest.main()
