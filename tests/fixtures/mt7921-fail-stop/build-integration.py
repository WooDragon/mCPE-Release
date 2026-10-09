#!/usr/bin/env python3
"""Execute the device hook selector and strict helper/prepare input partitions."""
import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def sha(path):
    """Fingerprint an existing input/output without using content equality as no-write proof."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(repo, root):
    """Use the real fixed recipe and existing dockerd original, never a fake recipe."""
    recipe = root / 'package/kernel/mt76/Makefile'
    recipe.parent.mkdir(parents=True)
    shutil.copyfile(repo / 'tests/fixtures/mt7921-fail-stop/upstream/package/Makefile', recipe)
    docker = root / 'feeds/packages/utils/dockerd/files/dockerd.init'
    docker.parent.mkdir(parents=True)
    shutil.copyfile(repo / 'tests/fixtures/photoprism/dockerd.init.upstream', docker)
    return recipe


def run(command, root, env=None):
    """Retain all child output, including expected input rejections."""
    result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
    print(result.stdout, end='', flush=True)
    print(result.stderr, end='', file=sys.stderr, flush=True)
    return result


def check(repo):
    """One integration partition; this does not run/fix the full existing matrix suite."""
    fixture = repo / 'tests/fixtures/mt7921-fail-stop'
    helper = repo / 'devices/r5s-outdoor/mt76-fail-stop.sh'
    inputs = repo / 'devices/r5s-outdoor/patches/mt76'
    diy = (repo / 'diy-part2.sh').read_text()
    selector = diy[diy.index('# --- Device-specific post-feeds hook ---'):]
    assert 'DEVICE_HOOK=' in selector and '. "$DEVICE_HOOK"' in selector
    records = []
    with tempfile.TemporaryDirectory() as temporary:
        output = Path(temporary)
        for device in ('r2s', 'r3s', 'r5s', 'r5s-outdoor', 'r68s', 'x86'):
            root = output / device
            recipe = tree(repo, root)
            before = sha(recipe)
            env = dict(os.environ, DEVICE=device, MCPE_REPO_ROOT=str(repo))
            assert run(['bash', '-e', '-c', selector], root, env).returncode == 0
            destination = recipe.parent / 'mcpe-fail-stop'
            if device == 'r5s-outdoor':
                for name in ('source.sha256', 'fail-stop.mk', '990-mt7921-pcie-recovery-fail-stop.patch'):
                    assert sha(destination / name) == sha(inputs / name)
                text = recipe.read_text()
                include = 'include $(CURDIR)/mcpe-fail-stop/fail-stop.mk'
                assert text.count(include) == 1
                assert text.index(include) < text.index('$(eval $(call KernelPackage,')
                assert (root / 'package/base-files/files/etc/init.d/r5s-outdoor-boot').exists()
                assert (root / 'package/base-files/files/etc/uci-defaults/99-wireless-r5s-outdoor').exists()
                photo = repo / 'devices/r5s-outdoor/photoprism/files'
                for source in photo.rglob('*'):
                    if source.is_file():
                        assert sha(source) == sha(root / 'package/base-files/files' / source.relative_to(photo))
            else:
                assert sha(recipe) == before and not destination.exists()
                assert not (root / 'package/base-files').exists()
            records.append(device)
            print('PASS actual diy device selector: ' + device, flush=True)
        transforms = {
            'missing-recipe': lambda recipe: recipe.unlink(),
            'wrong-version': lambda recipe: recipe.write_text(recipe.read_text().replace('eb567bc7f9b692bbf1ddfe31dd740861c58ec85b', '0' * 40)),
            'duplicate-version': lambda recipe: recipe.write_text(recipe.read_text() + '\nPKG_SOURCE_VERSION:=eb567bc7f9b692bbf1ddfe31dd740861c58ec85b\n'),
            'missing-seam': lambda recipe: recipe.write_text(recipe.read_text().replace('include $(INCLUDE_DIR)/cmake.mk', '# removed seam')),
            'duplicate-seam': lambda recipe: recipe.write_text(recipe.read_text() + '\ninclude $(INCLUDE_DIR)/cmake.mk\n'),
            'eval-before-seam': lambda recipe: recipe.write_text('$(eval $(call KernelPackage,mt76))\n' + recipe.read_text()),
            'already-included': lambda recipe: recipe.write_text(recipe.read_text() + '\ninclude $(CURDIR)/mcpe-fail-stop/fail-stop.mk\n'),
        }
        for name, change in transforms.items():
            root = output / name
            recipe = tree(repo, root)
            change(recipe)
            before = sha(recipe) if recipe.exists() else None
            print('INPUT_BEGIN ' + name, flush=True)
            assert run(['bash', str(helper), str(root)], root).returncode != 0
            assert not (recipe.parent / 'mcpe-fail-stop').exists()
            assert not (root / 'package/base-files').exists()
            assert (sha(recipe) if recipe.exists() else None) == before
            records.append(name)
            print('PASS fail-before-write: ' + name, flush=True)
        for missing in ('source.sha256', 'fail-stop.mk', '990-mt7921-pcie-recovery-fail-stop.patch'):
            root = output / ('missing-' + missing)
            recipe = tree(repo, root)
            isolated = root / 'repo/devices/r5s-outdoor'
            isolated.mkdir(parents=True)
            shutil.copyfile(helper, isolated / helper.name)
            shutil.copytree(inputs, isolated / 'patches/mt76')
            (isolated / 'patches/mt76' / missing).unlink()
            before = sha(recipe)
            print('INPUT_BEGIN missing-' + missing, flush=True)
            assert run(['bash', str(isolated / helper.name), str(root)], root).returncode != 0
            assert sha(recipe) == before and not (recipe.parent / 'mcpe-fail-stop').exists()
            records.append('missing-' + missing)
            print('PASS missing production input: ' + missing, flush=True)
        root = output / 'duplicate-install'
        recipe = tree(repo, root)
        assert run(['bash', str(helper), str(root)], root).returncode == 0
        before = {str(path): sha(path) for path in recipe.parent.rglob('*') if path.is_file()}
        assert run(['bash', str(helper), str(root)], root).returncode != 0
        assert before == {str(path): sha(path) for path in recipe.parent.rglob('*') if path.is_file()}
        records.append('duplicate-install')
        print('PASS duplicate helper invocation leaves all existing inputs unchanged', flush=True)
        spec = importlib.util.spec_from_file_location('source', fixture / 'csa-source.py')
        source = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(source)
        prepared = output / 'prepare'
        prepared.mkdir()
        source.prepare(repo, fixture, prepared, inputs / '990-mt7921-pcie-recovery-fail-stop.patch')
        before = {str(path): sha(path) for path in (prepared / 'prepared').rglob('*') if path.is_file()}
        result = run(['make', '--no-print-directory', '-f', str(prepared / 'prepare.mk'), 'prepare'], prepared)
        assert result.returncode != 0
        assert before == {str(path): sha(path) for path in (prepared / 'prepared').rglob('*') if path.is_file()}
        records.append('duplicate-prepare')
        print('PASS second strict prepare rejects patched source before a second patch', flush=True)
    expected = 6 + len(transforms) + 3 + 1 + 1
    assert len(records) == expected == 18
    binding = {'cases': records, 'selector_sha256': hashlib.sha256(selector.encode()).hexdigest(),
               'helper_sha256': sha(helper), 'patch_sha256': sha(inputs / '990-mt7921-pcie-recovery-fail-stop.patch'),
               'recipe_sha256': sha(fixture / 'upstream/package/Makefile'),
               'dockerd_original_sha256': sha(repo / 'tests/fixtures/photoprism/dockerd.init.upstream')}
    print('BUILD_INPUT_BINDING ' + json.dumps(binding, sort_keys=True), flush=True)
    print(f'build_integration ran={expected} passed={expected} failed=0 expected={expected}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    check(parser.parse_args().repo)
