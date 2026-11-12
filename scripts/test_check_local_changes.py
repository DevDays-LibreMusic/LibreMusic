"""Focused-check selection must be read-only by default and fail honestly."""
import contextlib
import io
from pathlib import Path
import unittest
from unittest.mock import patch

import check_local_changes as checks


class FocusedChecksTest(unittest.TestCase):
    def test_default_only_lists(self):
        with patch.object(checks.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(checks.main(["lastfm"]), 0)
        run.assert_not_called()

    def test_failure_stops_and_uses_repository_root(self):
        with patch.object(checks.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            run.return_value.returncode = 7
            self.assertEqual(checks.main(["--run", "playback"]), 7)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs["cwd"], checks.ROOT)

    def test_build_checks_are_explicit_android_process_modules(self):
        patterns = [Path(command[-1]).name for command in checks.commands("build")]
        self.assertEqual(patterns, [
            "test_check_local_changes.py", "test_deliver_android_debug.py",
            "test_build_android.py", "test_check_backend_apk.py",
        ])
        self.assertNotIn("test_*.py", patterns)

    def test_selected_dart_paths_exist_and_tests_are_explicit(self):
        for area in checks.TESTS:
            for command in checks.commands(area):
                for arg in command:
                    if arg.endswith(".dart"):
                        self.assertTrue((checks.ROOT / arg).is_file(), arg)
            test_command = checks.commands(area)[-1]
            self.assertEqual(test_command[:4], ["fvm", "flutter", "test", "--no-pub"])
            self.assertGreater(len(test_command), 4)


if __name__ == "__main__":
    unittest.main()
