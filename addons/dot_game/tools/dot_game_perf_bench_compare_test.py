#!/usr/bin/env python3
"""A reference profile with Fatal Contact's legacy system prefix lines up with a run that has the FC one."""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("perf_compare", os.path.join(_HERE, "dot_game_perf_bench_compare.py"))
compare = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(compare)


def _report(prefix):
    return {"frames": 10, "phases": {"physics": 50.0},
            "systems": [{"system": prefix + "physics", "ms": 20.0, "calls": 20},
                        {"system": prefix + "bot_brain", "ms": 8.0, "calls": 20}]}


class RenamedPrefix(unittest.TestCase):
    def _load(self, prefix):
        with tempfile.TemporaryDirectory() as t:
            path = os.path.join(t, "r.json")
            with open(path, "w") as f:
                json.dump(_report(prefix), f)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rows = compare.load(path)[3]
        return rows, err.getvalue()

    def test_fc_prefix_is_read_as_is(self):
        rows, err = self._load("fc.")
        self.assertIn("fc.bot_brain", rows)
        self.assertIn("engine.physics_outside_game", rows)
        self.assertEqual(err, "")

    def test_legacy_prefix_is_read_as_fc_with_a_warning(self):
        legacy = next(iter(compare.RENAMED_PREFIXES))
        rows, err = self._load(legacy)
        self.assertIn("fc.bot_brain", rows)
        self.assertIn("fc.physics", rows)
        self.assertFalse(any(k.startswith(legacy) for k in rows))
        self.assertAlmostEqual(rows["engine.physics_outside_game"]["ms"], 3.0)
        self.assertIn("WRN", err)
        self.assertIn(repr(legacy), err)

    def test_another_game_keeps_its_prefix(self):
        rows, err = self._load("zz.")
        self.assertIn("zz.bot_brain", rows)
        self.assertEqual(err, "")


if __name__ == "__main__":
    unittest.main()
