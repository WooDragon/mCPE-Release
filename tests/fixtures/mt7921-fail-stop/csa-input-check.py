#!/usr/bin/env python3
"""Check strict prepare inputs and actual default full partition execution."""
import argparse
import importlib.util
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


def main(repo):
    """Execute strict prepare and reject hash/context drift without a stamp."""
    fixture = repo / 'tests/fixtures/mt7921-fail-stop'
    spec = importlib.util.spec_from_file_location('csa_source', fixture / 'csa-source.py')
    source = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(source)
    inputs = repo / 'devices/r5s-outdoor/patches/mt76'
    patch = inputs / '990-mt7921-pcie-recovery-fail-stop.patch'
    ran = 0
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        positive = output / 'positive'
        positive.mkdir()
        _, original = source.prepare(repo, fixture, positive, patch)
        print('PASS strict real post-prepare hook after original package stack', flush=True)
        ran += 1
        for kind in ('source-drift', 'context-drift'):
            root = output / kind
            root.mkdir()
            tree = root / 'prepared'
            shutil.copytree(original, tree)
            stage = root / 'mcpe-fail-stop'
            shutil.copytree(positive / 'mcpe-fail-stop', stage)
            if kind == 'source-drift':
                with (tree / 'mt7921/main.c').open('a') as target:
                    target.write('\n/* upstream context drift */\n')
            else:
                target = stage / patch.name
                text = target.read_text()
                anchor = ' \tMT76_STATE_WED_RESET,'
                assert text.count(anchor) == 1
                target.write_text(text.replace(anchor, ' \tMT76_STATE_IMPOSSIBLE_CONTEXT,'))
            makefile = root / 'prepare.mk'
            makefile.write_text(f'CURDIR := {root}\nPKG_BUILD_DIR := {tree}\n'
                                f'include {stage}/fail-stop.mk\n'
                                'prepare:\n\t$(foreach hook,$(Hooks/Prepare/Post),$(call $(hook)))\n'
                                f'\ttouch {root}/prepared.stamp\n')
            result = subprocess.run(['make', '--no-print-directory', '-f', str(makefile), 'prepare'],
                                    text=True, capture_output=True)
            print('INPUT_BEGIN ' + kind, flush=True)
            print(result.stdout, end='', flush=True)
            print(result.stderr, end='', flush=True)
            assert result.returncode != 0 and not (root / 'prepared.stamp').exists()
            if kind == 'source-drift':
                assert 'mt7921/main.c: FAILED' in result.stdout
            else:
                assert re.search(r'Hunk #\d+ FAILED', result.stdout)
            print('PASS ' + kind + ' fails before prepared stamp', flush=True)
            ran += 1
        full = subprocess.run(['bash', str(repo / 'tests/bdd-mt7921-fail-stop.sh'), '--repo', str(repo)],
                              text=True, capture_output=True)
        print('INPUT_BEGIN default-full-execution', flush=True)
        print(full.stdout, end='', flush=True)
        print(full.stderr, end='', flush=True)
        assert full.returncode == 0
        assert re.search(r'^partition=driver ran=28 passed=28 failed=0 expected=28$', full.stdout, re.M)
        assert re.search(r'^partition=CSA ran=48 passed=48 failed=0 expected=48$', full.stdout, re.M)
        assert re.search(r'^partition=full ran=76 passed=76 failed=0 expected=76$', full.stdout, re.M)
        print('PASS default full mode executes both complete-source partitions', flush=True)
        ran += 1
    print(f'input_constraints ran={ran} passed={ran} failed=0 expected=4', flush=True)
    assert ran == 4


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    main(parser.parse_args().repo)
