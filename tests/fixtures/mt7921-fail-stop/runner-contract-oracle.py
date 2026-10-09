#!/usr/bin/env python3
"""Validate complete CSA results; signals/timeouts never prove behavior rejection."""
import argparse
import re
from pathlib import Path


def validate(stdout, stderr, result, expected, red):
    """Accept only exact counts and classified per-child behavior/contract outcomes."""
    summaries = re.findall(r'^partition=CSA ran=(\d+) passed=(\d+) failed=(\d+) expected=(\d+)$', stdout, re.M)
    classifications = re.findall(r'^CSA_CLASSIFICATION ran=(\d+) expected=(\d+) undecidable=(\d+)$', stdout, re.M)
    outcomes = re.findall(r'^CSA_OUTCOME (.+) kind=(\w+) exit=(-?\d+) signal=(\d+)$', stdout, re.M)
    if len(summaries) != 1 or classifications != [(str(expected), str(expected), '0')]:
        return False
    ran, passed, failed, declared = map(int, summaries[0])
    if ran != expected or declared != expected or passed + failed != ran:
        return False
    if result != int(red) or (red and failed == 0) or (not red and failed != 0):
        return False
    if len(outcomes) != expected or len({name for name, *_ in outcomes}) != expected:
        return False
    allowed = {('pass', '0', '0'), ('behavior', '1', '0'), ('contract', '3', '0')}
    if any((kind, code, sig) not in allowed for _, kind, code, sig in outcomes):
        return False
    if sum(kind == 'pass' for _, kind, _, _ in outcomes) != passed:
        return False
    # Defense at the outer boundary as well, even if a child runner emits a marker.
    if re.search(r'(?:signal=|signal=\s*)(?!0(?:\D|$))\d+', stdout + '\n' + stderr):
        return False
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('stdout', type=Path)
    parser.add_argument('stderr', type=Path)
    parser.add_argument('result', type=int)
    parser.add_argument('expected', type=int)
    parser.add_argument('--red', action='store_true')
    args = parser.parse_args()
    ok = validate(args.stdout.read_text(), args.stderr.read_text(), args.result, args.expected, args.red)
    if not ok:
        print('CSA_UNDECIDABLE_OR_INVALID: incomplete, timeout, signal, or unclassified termination')
    raise SystemExit(0 if ok else 2)
