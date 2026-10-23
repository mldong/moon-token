#!/usr/bin/env python3
"""Require one complete, all-passed moon test summary for an explicit count."""
import argparse
import re
import sys
from pathlib import Path


# Strip ANSI SGR (colour/style) only; other control sequences fail exact matching.
SGR = re.compile(r"\x1b\[[0-9;]*m")
SUMMARY = re.compile(r"Total tests: ([0-9]+), passed: ([0-9]+), failed: ([0-9]+)\.?")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", type=int)
    parser.add_argument("log", help="UTF-8 log path, or - for stdin")
    args = parser.parse_args()
    if args.expected <= 0:
        parser.error("expected must be positive")
    try:
        text = sys.stdin.read() if args.log == "-" else Path(args.log).read_text(encoding="utf-8")
        lines = [line.strip() for line in SGR.sub("", text).splitlines() if "Total tests:" in line]
        if len(lines) != 1:
            raise ValueError("expected exactly one summary, found {}".format(len(lines)))
        match = SUMMARY.fullmatch(lines[0])
        if not match:
            raise ValueError("malformed summary: " + repr(lines[0]))
        counts = tuple(map(int, match.groups()))
        if counts != (args.expected, args.expected, 0):
            raise ValueError("expected total={}, passed={}, failed=0; got {}".format(
                args.expected, args.expected, lines[0]))
    except (OSError, UnicodeError, ValueError) as exc:
        print("TEST GATE FAIL: {}: {}".format(args.log, exc), file=sys.stderr)
        return 1
    print("TEST GATE PASS: " + lines[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
