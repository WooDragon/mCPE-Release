#!/usr/bin/env python3
"""Prepare the real patch stack and emit complete CSA functions with bindings."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
from pathlib import Path


def sha(path):
    """Return the identity of an existing source/input file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(repo, fixture, output, patch):
    """Execute original package patches, then the actual strict post-prepare hook."""
    source = output / 'prepared'
    shutil.copytree(fixture / 'upstream/mt76', source)
    for original in sorted((fixture / 'upstream/package/patches').glob('*.patch')):
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(source), '-i', str(original)], check=True)
    pristine = output / 'package-patched'
    shutil.copytree(source, pristine)
    inputs = repo / 'devices/r5s-outdoor/patches/mt76'
    stage = output / 'mcpe-fail-stop'
    stage.mkdir()
    for name in ('source.sha256', 'fail-stop.mk'):
        shutil.copyfile(inputs / name, stage / name)
    shutil.copyfile(patch, stage / '990-mt7921-pcie-recovery-fail-stop.patch')
    makefile = output / 'prepare.mk'
    makefile.write_text(f'CURDIR := {output}\nPKG_BUILD_DIR := {source}\n'
                        f'include {stage}/fail-stop.mk\n'
                        'prepare:\n\t$(foreach hook,$(Hooks/Prepare/Post),$(call $(hook)))\n'
                        f'\ttouch {output}/prepared.stamp\n')
    subprocess.run(['make', '--no-print-directory', '-f', str(makefile), 'prepare'], check=True)
    assert (output / 'prepared.stamp').exists()
    return source, pristine


def contract(extractor, fixture):
    """Bind modeled lifecycle stages to their original full source definitions."""
    backports = fixture / 'upstream/backports/net/mac80211'
    stop = extractor.function((backports / 'iface.c').read_text(), 'ieee80211_do_stop')
    required = ['lockdep_assert_wiphy', 'synchronize_rcu();', 'ieee80211_mgd_stop(sdata);',
                'drv_remove_interface(local, sdata);', 'memset(sdata->vif.drv_priv, 0, local->hw.vif_data_size);']
    positions = [stop.index(item) for item in required]
    if positions != sorted(positions):
        raise ValueError('framework stop/grace/remove/memset ordering drift')
    add = extractor.function((fixture / 'upstream/mt76/mt7921/main.c').read_text(), 'mt7921_add_interface')
    for marker in ('INIT_WORK(&mvif->csa_work, mt7921_csa_work);', 'timer_setup(&mvif->csa_timer, mt792x_csa_timer, 0);'):
        if marker not in add:
            raise ValueError('successful add no longer initializes CSA objects')
    # This model executes the real remove/iterate and uses the above stop stages.
    # It does not execute all unrelated ieee80211_do_stop or parse beacon IEs.
    return {'lifecycle_stages': required, 'do_stop_sha256': hashlib.sha256(stop.encode()).hexdigest(),
            'double_boundary': 'modeled do_stop stages; real drv_remove/iterate/process_chanswitch/completion/disassoc/drop/mgd_stop bodies; radio/BSS/packet-parser leaves'}


def mutate(tree, name):
    """Change one prepared CSA rule; never write a mutated implementation to repo."""
    rules = {
        'timer-silent': ('mt792x_core.c', '\t\tmt792x_csa_complete(mvif, false);\n', ''),
        'skip-timer-join': ('mt7921/main.c', '\tdel_timer_sync(&mvif->csa_timer);\n', ''),
        'skip-work-join': ('mt7921/main.c', '\tcancel_work_sync(&mvif->csa_work);\n', ''),
        'reset-wiphy': ('mt7921/pci.c', '\tcancel_delayed_work(&dev->pm.ps_work);',
                        '\tmutex_lock(&mt76_hw(dev)->wiphy->mtx);\n\tmutex_unlock(&mt76_hw(dev)->wiphy->mtx);\n\tcancel_delayed_work(&dev->pm.ps_work);'),
        'callback-wiphy': ('mt792x.h', '\trcu_read_lock();',
                           '\tmutex_lock(&mvif->phy->mt76->hw->wiphy->mtx);\n\tmutex_unlock(&mvif->phy->mt76->hw->wiphy->mtx);\n\trcu_read_lock();'),
        'lose-pm-wake': ('mt7921/main.c', '\tmt76_connac_pm_wake(&dev->mphy, &dev->pm);\n', ''),
        'mt7925-terminal': ('mt792x_core.c', 'is_mt7921(&dev->mt76) && mt76_is_dead(mvif->phy->mt76)',
                            'mt76_is_dead(mvif->phy->mt76)'),
    }
    if name == 'drop-rcu':
        path = tree / 'mt792x.h'
        text = path.read_text()
        begin = text.index('static inline void mt792x_csa_complete')
        end = text.index('\n}\n', begin) + 3
        body = text[begin:end].replace('\trcu_read_lock();\n', '').replace('\trcu_read_unlock();\n', '')
        path.write_text(text[:begin] + body + text[end:])
        return
    path_name, old, new = rules[name]
    path = tree / path_name
    text = path.read_text()
    # Multiple original abort/removal and PM sites exist: mutate only the named
    # complete target function, not another caller sharing the same leaf call.
    target = {'skip-timer-join': 'mt7921_remove_interface', 'skip-work-join': 'mt7921_remove_interface',
              'lose-pm-wake': 'mt7921_csa_work', 'callback-wiphy': 'mt792x_csa_complete',
              'reset-wiphy': 'mt7921e_stop_deferred_work', 'timer-silent': 'mt792x_csa_timer',
              'mt7925-terminal': 'mt792x_csa_timer'}[name]
    begin = text.index(target + '(')
    end = text.index('\n}\n', begin) + 3
    body = text[begin:end]
    if body.count(old) != 1:
        raise ValueError(f'{name}: mutation anchor drift')
    path.write_text(text[:begin] + body.replace(old, new) + text[end:])


def emit(args):
    """Generate one CSA translation unit; preserve every selected body verbatim."""
    fixture = args.repo / 'tests/fixtures/mt7921-fail-stop'
    spec = importlib.util.spec_from_file_location('extractor', fixture / 'extract-source.py')
    extractor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extractor)
    extractor.verify_fixture(fixture)
    prepared, original = prepare(args.repo, fixture, args.output, args.patch)
    if args.mutation:
        if args.mode != 'patched':
            raise ValueError('mutations require the actual patched CSA partition')
        mutate(prepared, args.mutation)
    tree = original if args.mode == 'original' else prepared
    mode_header = [f'#define CSA_MODE_{args.mode.upper()} 1']
    definitions = []
    records = []

    def take(path, names, layer):
        """Append complete definitions and record their exact byte identity."""
        text = path.read_text()
        for name in names:
            body = extractor.function(text, name)
            definitions.append(body)
            records.append({'source': str(path), 'function': name, 'layer': layer,
                            'sha256': hashlib.sha256(body.encode()).hexdigest()})

    take(prepared / 'mt76.h', ['mt76_is_dead'], 'production-state-helper')
    take(tree / 'mt76_connac.h', ['is_mt7920', 'is_mt7922', 'is_mt7921',
                                 'mt76_connac_mutex_acquire', 'mt76_connac_mutex_release'], 'mt76')
    if args.mode == 'patched':
        take(tree / 'mt792x.h', ['mt792x_csa_complete'], 'production')
    take(tree / 'mt792x_core.c', ['mt792x_remove_interface', 'mt792x_csa_timer', 'mt792x_unassign_vif_chanctx'], 'mt76')
    take(tree / 'mt7921/main.c', ['mt7921_csa_work', 'mt7921_pre_channel_switch', 'mt7921_channel_switch',
                                 'mt7921_abort_channel_switch', 'mt7921_channel_switch_rx_beacon'], 'mt76')
    if args.mode == 'patched':
        take(tree / 'mt7921/main.c', ['mt7921_remove_interface'], 'production')
    if args.mode == 'wip':
        take(tree / 'mt7921/pci.c', ['mt7921e_stop_vif_work'], 'unsafe-wip')
    if args.mode != 'original':
        take(tree / 'mt7921/pci.c', ['mt7921e_stop_deferred_work'], 'production')
    core = fixture / 'upstream/backports/net/mac80211'
    take(core / 'util.c', ['__iterate_interfaces', 'ieee80211_iterate_interfaces'], 'backports-6.12.61-package-patched')
    take(core / 'driver-ops.c', ['drv_add_interface', 'drv_remove_interface'], 'backports-6.12.61-package-patched')
    csa_enum = re.findall(r'enum ieee80211_csa_source\s*\{[^{}]*\};', (core / 'mlme.c').read_text())
    if len(csa_enum) != 1:
        raise ValueError('ambiguous original CSA source enum')
    mode_header.append(csa_enum[0])
    take(core / 'mlme.c', ['ieee80211_sta_process_chanswitch', 'ieee80211_chswitch_done', 'ieee80211_set_disassoc', '__ieee80211_disconnect',
                          'ieee80211_csa_connection_drop_work', 'ieee80211_mgd_stop', 'ieee80211_mgd_stop_link'], 'backports-6.12.61-package-patched')
    main = (tree / 'mt7921/main.c').read_text()
    binding = re.findall(r'\.remove_interface\s*=\s*(\w+)', main)
    if len(binding) != 1:
        raise ValueError('ambiguous remove ops binding')
    expected_binding = 'mt7921_remove_interface' if args.mode == 'patched' else 'mt792x_remove_interface'
    if binding[0] != expected_binding:
        raise ValueError('CSA remove binding drift')
    if re.findall(r'\.channel_switch\s*=\s*(\w+)', main) != ['mt7921_channel_switch']:
        raise ValueError('CSA producer binding drift')
    other_chip = (prepared / 'mt7925/main.c').read_bytes()
    if other_chip != (fixture / 'upstream/mt76/mt7925/main.c').read_bytes():
        raise ValueError('mt7925 source changed by production prepare')
    if re.findall(rb'\.remove_interface\s*=\s*(\w+)', other_chip) != [b'mt792x_remove_interface']:
        raise ValueError('mt7925 remove binding drift')
    mode_header.append(f'#define ACTUAL_REMOVE {binding[0]}')
    prototypes = [body.split('{', 1)[0].rstrip() + ';' for body in definitions]
    state = extractor.state_enum((prepared / 'mt76.h').read_text())
    (args.output / 'csa-state.h').write_text(state + '\n')
    (args.output / 'csa-actual.c').write_text('\n\n'.join(
        ['#include "csa-state.h"', '#include "csa-double.h"'] + mode_header + prototypes + definitions) + '\n')
    evidence = {'mode': args.mode, 'mutation': args.mutation, 'patch_sha256': sha(args.patch),
                'source_sha256_sha256': sha(args.repo / 'devices/r5s-outdoor/patches/mt76/source.sha256'),
                'fixture_manifest_sha256': sha(fixture / 'source-manifest.json'),
                'functions': records, 'contracts': contract(extractor, fixture)}
    (args.output / 'csa-source-binding.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('SOURCE_BINDING ' + json.dumps(evidence, sort_keys=True), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True)
    parser.add_argument('--mode', choices=('original', 'wip', 'patched'), required=True)
    parser.add_argument('--mutation', choices=('timer-silent', 'skip-timer-join', 'skip-work-join',
                        'reset-wiphy', 'callback-wiphy', 'drop-rcu', 'lose-pm-wake', 'mt7925-terminal'))
    emit(parser.parse_args())
