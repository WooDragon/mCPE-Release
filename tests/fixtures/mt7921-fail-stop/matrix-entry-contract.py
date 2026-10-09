#!/usr/bin/env python3
"""Check the delivered matrix count boundary using only runner process interfaces."""
import argparse
import ast
import json
import shutil
import subprocess
import tempfile
from pathlib import Path


SUMMARY = 'runner_contract ran=13 passed=13 failed=0 expected=13\n'
CASES = (
    ('complete-summary', SUMMARY, 0, True),
    ('definition-only-real-runner', '', 0, False),
    ('zero-summary', 'runner_contract ran=0 passed=0 failed=0 expected=13\n', 0, False),
    ('partial-summary', 'runner_contract ran=12 passed=12 failed=0 expected=13\n', 0, False),
    ('complete-summary-nonzero', SUMMARY, 1, False),
)


def prepare(repo, target, guard_mutant):
    """Copy actual matrix/library bytes; mutate only its shared guard when requested."""
    matrix = target / 'tests/bdd-matrix-build.sh'
    library = target / 'scripts/build-lib.sh'
    matrix.parent.mkdir(parents=True)
    library.parent.mkdir(parents=True)
    shutil.copyfile(repo / 'tests/bdd-matrix-build.sh', matrix)
    shutil.copyfile(repo / 'scripts/build-lib.sh', library)
    if guard_mutant:
        text = matrix.read_text()
        guard = '''  if [ "$matches" -ne 1 ]; then
    printf 'COUNT_CONTRACT: expected unique summary: %s (matches=%s)\\n' "$expected" "$matches" >&2
    return 1
  fi
'''
        assert text.count(guard) == 1, 'Delivered counted-command guard anchor drift'
        matrix.write_text(text.replace(guard, '  return 0 # disposable missing-count-guard mutant\n'))
    return matrix


def scenario(repo, case, guard_mutant):
    """Execute the real --runner-contract-only route with declared stdout/exit leaves."""
    name, stdout, child_exit, accept = case
    with tempfile.TemporaryDirectory() as temporary:
        target = Path(temporary) / 'repo'
        matrix = prepare(repo, target, guard_mutant)
        runner = target / 'tests/fixtures/mt7921-fail-stop/runner-contract.py'
        runner.parent.mkdir(parents=True)
        if name == 'definition-only-real-runner':
            original = (repo / 'tests/fixtures/mt7921-fail-stop/runner-contract.py').read_text()
            marker = "if __name__ == '__main__':"
            assert original.count(marker) == 1
            source = original.split(marker, 1)[0]
            ast.parse(source)  # Real valid Python with all definitions, no entry call.
        else:
            protocol = json.dumps({'stdout': stdout, 'exit': child_exit})
            source = (f'import json, sys\nprotocol = json.loads({protocol!r})\n'
                      'sys.stdout.write(protocol["stdout"])\n'
                      'raise SystemExit(protocol["exit"])\n')
        runner.write_text(source)
        argv = ['/bin/bash', str(matrix), '--runner-contract-only']
        result = subprocess.run(argv, capture_output=True, text=True)
        print('MATRIX_ENTRY_LOG ' + json.dumps({'case': name, 'argv': argv,
              'guard_mutant': guard_mutant, 'exit': result.returncode,
              'stdout': result.stdout, 'stderr': result.stderr}), flush=True)
        if result.stdout != stdout:
            return False
        if accept:
            return result.returncode == 0
        if child_exit:
            return result.returncode == child_exit
        return result.returncode != 0 and 'COUNT_CONTRACT: expected unique summary:' in result.stderr


def main(args):
    """Execute all five registered inputs and report actual pass/fail counts."""
    passed = 0
    for case in CASES:
        ok = scenario(args.repo, case, args.guard_mutant)
        passed += ok
        print(('PASS ' if ok else 'FAIL ') + case[0], flush=True)
    print(f'matrix_runner_contract ran={len(CASES)} passed={passed} '
          f'failed={len(CASES)-passed} expected=5', flush=True)
    return 0 if len(CASES) == 5 and passed == 5 else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--guard-mutant', action='store_true')
    raise SystemExit(main(parser.parse_args()))
