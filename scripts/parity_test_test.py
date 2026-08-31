#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import os
import sys
import unittest
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "parity_test", Path(__file__).with_name("parity_test.py")
)
assert SPEC is not None and SPEC.loader is not None
parity_test = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = parity_test
SPEC.loader.exec_module(parity_test)


class ParityTest(unittest.TestCase):
    def test_normalize_ignores_values_but_keeps_keys_and_types(self) -> None:
        left = {"success": True, "task": {"id": 1, "title": "control"}}
        right = {"success": True, "task": {"id": 2, "title": "zig"}}
        wrong = {"success": True, "task": {"id": "2", "title": "zig"}}

        self.assertEqual(
            parity_test.normalize(left, frozenset()),
            parity_test.normalize(right, frozenset()),
        )
        self.assertNotEqual(
            parity_test.normalize(left, frozenset()),
            parity_test.normalize(wrong, frozenset()),
        )

    def test_write_round_trip_runs_every_write_and_archives(self) -> None:
        responses = [
            {"success": True, "task": {"ticketNumber": "HTPR-1"}},
            {"success": True, "comment": {"id": 1}},
            {"success": True},
            {"success": True},
            {"success": True},
            {"success": True},
        ]
        with mock.patch.object(parity_test, "run_json", side_effect=responses) as run_json:
            result = parity_test.write_round_trip(["cli"], "token", "throwaway", "test")

        self.assertEqual(
            list(result), ["create", "comment", "move", "assign", "update", "archive"]
        )
        self.assertEqual(
            run_json.call_args_list[-1].args[1],
            ["tasks", "update", "HTPR-1", "--status", "Archive", "--json"],
        )

    def test_write_round_trip_archives_after_an_intermediate_failure(self) -> None:
        responses = [
            {"success": True, "task": {"ticketNumber": "HTPR-2"}},
            AssertionError("comment failed"),
            {"success": True},
        ]
        with mock.patch.object(parity_test, "run_json", side_effect=responses) as run_json:
            with self.assertRaisesRegex(AssertionError, "comment failed"):
                parity_test.write_round_trip(["cli"], "token", "throwaway", "test")

        self.assertEqual(
            run_json.call_args_list[-1].args[1],
            ["tasks", "update", "HTPR-2", "--status", "Archive", "--json"],
        )

    def test_write_parity_rejects_a_shape_difference(self) -> None:
        node = {"create": {"success": True, "task": {"link": {"url": "x"}}}}
        zig = {"create": {"success": True, "task": {}}}
        with mock.patch.object(parity_test, "write_round_trip", side_effect=[node, zig]):
            with self.assertRaisesRegex(AssertionError, "create: JSON shape differs"):
                parity_test.write_parity(["node"], ["zig"], "token")

    def test_write_mode_requires_an_explicit_token(self) -> None:
        environment = {"HT_TOKEN": "", "HYPERTASKS_JWT_TOKEN": ""}
        with mock.patch.dict(os.environ, environment, clear=False):
            with mock.patch.object(sys, "argv", ["parity_test.py", "--write"]):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        parity_test.main()

        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
