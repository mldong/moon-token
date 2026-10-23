#!/usr/bin/env python3
"""Exercise the checker, actual workflow run blocks and local gate with fake moon."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
EXPECTED = 134  # Keep fixtures aligned with the explicit CI/local matrix, not observed results.


def summary(total=EXPECTED, passed=EXPECTED, failed=0):
    return "Total tests: {}, passed: {}, failed: {}.\n".format(total, passed, failed)


def workflow_run(name):
    verify = (REPO / ".github/workflows/publish.yml").read_text(encoding="utf-8").split("\n  publish:")[0]
    match = re.search(r"^      - name: " + re.escape(name)
                      + r"\n        run: \|\n((?:          [^\n]*\n|\n)+)", verify, re.M)
    if not match:
        raise AssertionError("Cannot extract verify run block: " + name)
    return textwrap.dedent(match.group(1))


def write(path, text):
    path.write_bytes(text.encode("utf-8"))  # LF even on Windows/Git Bash.


class TestGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="moon-token-test-gate-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        scripts = self.work / "scripts"
        scripts.mkdir()
        for name in ("gate.sh", "check-test-result.py"):
            shutil.copyfile(REPO / "scripts" / name, scripts / name)
        # The copied gate invokes a stub to avoid recursively running this suite.
        write(scripts / "test_test_gate.py",
              "import os, pathlib, sys\npathlib.Path('self-tests-ran').touch()\n"
              "sys.exit(int(os.environ.get('SELF_TEST_EXIT', '0')))\n")
        for name in ("docs-check.sh", "readme-check.sh", "page-install-check.sh"):
            write(scripts / name, "exit 0\n")
        self.env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONDONTWRITEBYTECODE="1",
                        FAKE_TEST_OUTPUT=summary(), FAKE_TEST_EXIT="0", FAKE_TARGET="wasm",
                        FAKE_CHECK_OUTPUT="Finished.\n", FAKE_CHECK_EXIT="0", SELF_TEST_EXIT="0")

    def run_checker(self, output, expected=EXPECTED, stdin=False):
        log = self.work / "test.txt"
        write(log, output)
        return subprocess.run([sys.executable, str(REPO / "scripts/check-test-result.py"),
                               str(expected), "-" if stdin else str(log)],
                              input=output if stdin else None, capture_output=True, text=True,
                              encoding="utf-8", env=self.env, timeout=30)

    def run_shell(self, entry, **environment):
        marker = self.work / "publish-replacement-ran"
        if marker.exists():
            marker.unlink()
        if entry == "local":
            command = "bash scripts/gate.sh\n"
        else:
            write(self.work / "step.sh", workflow_run(entry))
            command = "bash -e step.sh\n"
        write(self.work / "runner.sh", '''moon() {
  printf '%s\\n' "$*" >> moon-calls.txt
  if [ "$1" = check ]; then
    printf '%s' "$FAKE_CHECK_OUTPUT" >&2
    return "$FAKE_CHECK_EXIT"
  fi
  if [ "$1" = test ]; then
    if [ "$3" = "$FAKE_TARGET" ]; then
      printf '%s' "$FAKE_TEST_OUTPUT"
      return "$FAKE_TEST_EXIT"
    fi
    printf '%s' "$GOOD_SUMMARY"
    return 0
  fi
  return 99
}
export -f moon
''' + command + "printf 'ran\\n' > publish-replacement-ran\n")
        env = dict(self.env, GOOD_SUMMARY=summary(), **environment)
        # Resolve PATH explicitly: Windows CreateProcess otherwise prefers the WSL bash shim.
        result = subprocess.run([shutil.which("bash"), "-e", "runner.sh"], cwd=str(self.work), env=env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assertEqual(marker.exists(), result.returncode == 0, result.stdout + result.stderr)
        return result

    def test_checker_accepts_exact_plain_ansi_and_stdin(self):
        for output in (summary(), "build output\n" + summary().rstrip(".\n") + "\n",
                       "\x1b[32mTotal tests: \x1b[0m" + summary().split(": ", 1)[1].replace("\n", "\r\n")):
            for stdin in (False, True):
                with self.subTest(output=repr(output), stdin=stdin):
                    result = self.run_checker(output, stdin=stdin)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_rejects_bad_summaries(self):
        cases = {
            "real failure": summary(passed=EXPECTED - 1, failed=1),
            "ANSI failure": "\x1b[31m" + summary(passed=EXPECTED - 1, failed=1) + "\x1b[0m",
            "wrong total": summary(total=EXPECTED + 1, passed=EXPECTED + 1),
            "prefix total": summary(total=EXPECTED * 10, passed=EXPECTED * 10),
            "zero tests": summary(0, 0, 0),
            "wrong passed": summary(passed=EXPECTED - 1),
            "missing": "Finished.\n",
            "empty": "",
            "duplicate": summary() * 2,
            "failed then passed": summary(passed=EXPECTED - 1, failed=1) + summary(),
            "incomplete": "Total tests: {}\n".format(EXPECTED),
            "valid plus malformed": summary() + "Total tests: unknown\n",
            "prefix text": "not a summary: " + summary(),
            "suffix text": summary().rstrip() + " ignored\n",
        }
        for name, output in cases.items():
            with self.subTest(name=name):
                result = self.run_checker(output)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("TEST GATE FAIL", result.stderr)

    def test_checker_rejects_nonpositive_expectation(self):
        for expected in (0, -1):
            with self.subTest(expected=expected):
                result = self.run_checker(summary(0, 0, 0), expected=expected)
                self.assertEqual(result.returncode, 2)
                self.assertIn("expected must be positive", result.stderr)

    def test_checker_reports_missing_file(self):
        result = subprocess.run([sys.executable, str(REPO / "scripts/check-test-result.py"),
                                 str(EXPECTED), str(self.work / "missing.txt")],
                                capture_output=True, text=True, encoding="utf-8", env=self.env, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn("TEST GATE FAIL", result.stderr)

    def test_workflow_and_local_all_green(self):
        for entry in ("Test", "local"):
            with self.subTest(entry=entry):
                result = self.run_shell(entry)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.work / "self-tests-ran").exists())
        for target in ("wasm", "native"):
            self.assertEqual((self.work / (target + "-test.txt")).read_text(encoding="utf-8"), summary())

    def test_workflow_rejects_bad_summaries_on_each_target(self):
        for target in ("wasm", "native"):
            for output in (summary(passed=EXPECTED - 1, failed=1), summary(EXPECTED + 1, EXPECTED + 1),
                           summary(0, 0, 0), "Finished.\n", summary() * 2):
                with self.subTest(target=target, output=repr(output)):
                    result = self.run_shell("Test", FAKE_TARGET=target, FAKE_TEST_OUTPUT=output)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn("TEST GATE FAIL", result.stderr)

    def test_workflow_exit_2_with_passing_summary_stops_before_publish(self):
        for target in ("wasm", "native"):
            with self.subTest(target=target):
                result = self.run_shell("Test", FAKE_TARGET=target, FAKE_TEST_EXIT="2")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual((self.work / (target + "-test.txt")).read_text(encoding="utf-8"), summary())
                self.assertNotIn("TEST GATE PASS", result.stdout)

    def test_local_command_substitution_still_rejects_exit_2(self):
        result = self.run_shell("local", FAKE_TEST_EXIT="2")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotIn("TEST GATE PASS", result.stdout)

    def test_local_rejects_bad_summaries(self):
        for output in (summary(passed=EXPECTED - 1, failed=1), summary(EXPECTED + 1, EXPECTED + 1),
                       summary(0, 0, 0), "Finished.\n", summary() * 2):
            with self.subTest(output=repr(output)):
                result = self.run_shell("local", FAKE_TEST_OUTPUT=output)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("TEST GATE FAIL", result.stderr)

    def test_warning_gate_success_warning_and_exit_2(self):
        for entry in ("Assert zero warnings", "local"):
            for output, code, expected in (("Finished.\n", "0", 0),
                                           ("Warning: example\n", "0", 1),
                                           ("Finished.\n", "2", 2)):
                with self.subTest(entry=entry, code=code, output=output):
                    result = self.run_shell(entry, FAKE_CHECK_OUTPUT=output, FAKE_CHECK_EXIT=code)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_self_tests_are_blocking_in_both_entrypoints(self):
        for entry in ("Test gate self-tests", "local"):
            for code in ("0", "2"):
                with self.subTest(entry=entry, code=code):
                    result = self.run_shell(entry, SELF_TEST_EXIT=code)
                    self.assertEqual(result.returncode, int(code), result.stdout + result.stderr)
                    self.assertTrue((self.work / "self-tests-ran").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
