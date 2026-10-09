#!/usr/bin/env python3
"""Exercise delivered runners using disposable input mutations, never production writes."""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


CSA_CASES = {
    'alarm': 'alarm(1); for (;;) pause();',
    'abort': 'raise(SIGABRT);',
    'segv': 'raise(SIGSEGV);',
    'unexpected-exit': '_exit(7);',
    'unattributed-contract-exit': '_exit(3);',
    'contract-then-alarm': 'fprintf(stderr,"CONTRACT: before timeout\\n"); fflush(stderr); alarm(1); for (;;) pause();',
}


def clone(repo, target):
    """Copy only the test runners and fixed prepare inputs into writable tmp."""
    fixture = Path('tests/fixtures/mt7921-fail-stop')
    shutil.copytree(repo / fixture, target / fixture)
    inputs = Path('devices/r5s-outdoor/patches/mt76')
    shutil.copytree(repo / inputs, target / inputs)
    shutil.copyfile(repo / 'tests/bdd-mt7921-fail-stop.sh', target / 'tests/bdd-mt7921-fail-stop.sh')
    return target / fixture


def inject(text, function, code):
    """Inject one test-only child fault into an existing scenario, not driver code."""
    anchor = f'static bool {function}(void)\n{{'
    assert text.count(anchor) == 1
    return text.replace(anchor, anchor + '\n    ' + code)


def execute(argv, case):
    """Persist actual outputs as JSON and show the subprocess exit without reinterpretation."""
    result = subprocess.run(argv, capture_output=True, text=True)
    print('RUNNER_CONTRACT_LOG ' + json.dumps({'case': case, 'argv': argv,
          'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}), flush=True)
    return result


def csa_case(repo, case, oracle_mutant):
    """Invoke the real outer runner; all uncertain terminations must fail without a kill."""
    with tempfile.TemporaryDirectory() as temporary:
        target = Path(temporary) / 'repo'
        fixture = clone(repo, target)
        path = fixture / 'csa-scenarios.c'
        text = path.read_text()
        if case in CSA_CASES:
            text = inject(text, 'terminal_pre', CSA_CASES[case])
        elif case == 'prior-child-contract-is-not-provenance':
            text = inject(text, 'terminal_pre', 'fprintf(stderr,"CONTRACT: first child\\n"); fflush(stderr); _exit(3);')
            text = inject(text, 'terminal_producer', '_exit(3);')
        elif case == 'parent-signal':
            text = text.replace('int main(void)\n{', 'int main(void)\n{\n    raise(SIGTERM);')
        elif case == 'compile-error':
            text += '\n#error runner_contract_compile_failure\n'
        elif case == 'short-count':
            text = text.replace('run("C01 terminal pre rejects transaction", terminal_pre);', '')
        elif case == 'alarm-child-runner-bypass':
            text = inject(text, 'terminal_pre', CSA_CASES['alarm'])
            runner = fixture / 'csa-run.sh'
            body = runner.read_text()
            begin = body.index('python3 -B "$FIXTURE/runner-contract-oracle.py"')
            end = body.index('if [ "$MODE" = patched ]', begin)
            runner.write_text(body[:begin] + body[end:])
        else:
            raise ValueError(case)
        path.write_text(text)
        if oracle_mutant:
            oracle = fixture / 'runner-contract-oracle.py'
            body = oracle.read_text()
            anchor = '    summaries = re.findall('
            assert body.count(anchor) == 1
            oracle.write_text(body.replace(anchor, '    return True  # disposable accept-all mutant\n' + anchor))
        result = execute(['bash', str(fixture / 'csa-mutants.sh'), str(target)], case)
        compiled = 'COMPILED CSA complete-source harness' in result.stdout
        if case == 'compile-error':
            return result.returncode != 0 and not compiled and 'runner_contract_compile_failure' in result.stderr
        complete = re.search(r'^partition=CSA ran=48 .* expected=48$', result.stdout, re.M)
        if case not in ('parent-signal', 'short-count') and not complete:
            return False
        return result.returncode != 0 and 'MUTANT_REJECTED ' not in result.stdout and compiled


def driver_case(repo, case):
    """Restore each weak NAPI rule in a tmp model; the new actual-poll cases must fail."""
    with tempfile.TemporaryDirectory() as temporary:
        target = Path(temporary) / 'repo'
        fixture = clone(repo, target)
        path = fixture / 'driver-sync.h'
        text = path.read_text()
        if case == 'napi-running-only':
            assert text.count('while (napi->sched) {') == 1
            text = text.replace('while (napi->sched) {', 'while (napi->sched && napi->running) {')
            expected = (28, 24, 4, 28)
        else:
            anchor = 'assert(napi->enabled); napi_synchronize(napi);'
            assert text.count(anchor) == 1
            text = text.replace(anchor, 'assert(napi->enabled); napi->sched=false; napi_synchronize(napi);')
            expected = (28, 26, 2, 28)
        path.write_text(text)
        result = execute(['bash', str(target / 'tests/bdd-mt7921-fail-stop.sh'),
                          '--repo', str(target), '--driver'], case)
        counts = re.findall(r'^ran=(\d+) passed=(\d+) failed=(\d+) expected=(\d+)$', result.stdout, re.M)
        return result.returncode == 1 and 'COMPILED complete-source driver harness mode=patched' in result.stdout and \
            len(counts) == 1 and tuple(map(int, counts[0])) == expected and 'signal=' not in result.stderr


def main(args):
    """Run every declared case and enforce actual/expected counts."""
    cases = list(CSA_CASES) + ['prior-child-contract-is-not-provenance', 'parent-signal',
                             'compile-error', 'short-count', 'alarm-child-runner-bypass']
    if not args.oracle_mutant:
        cases += ['napi-running-only', 'napi-disable-clears-sched']
    if args.case:
        if args.case not in cases:
            raise ValueError(args.case)
        cases = [args.case]
    passed = 0
    for case in cases:
        ok = driver_case(args.repo, case) if case.startswith('napi-') else csa_case(args.repo, case, args.oracle_mutant)
        passed += ok
        print(('PASS ' if ok else 'FAIL ') + case, flush=True)
    print(f'runner_contract ran={len(cases)} passed={passed} failed={len(cases)-passed} expected={len(cases)}', flush=True)
    return 0 if passed == len(cases) else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--case')
    parser.add_argument('--oracle-mutant', action='store_true')
    raise SystemExit(main(parser.parse_args()))
