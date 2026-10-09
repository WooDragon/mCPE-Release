#!/usr/bin/env python3
"""Prepare the delivered input and extract complete non-CSA driver/core functions."""
import argparse
import hashlib
import importlib.util
import json
import re
from pathlib import Path


SELECTION = {
    'mt76.h': ['mt76_is_dead'],
    'mt76_connac.h': ['is_mt7920', 'is_mt7922', 'is_mt7921', 'mt76_connac_irq_enable',
                     'mt76_connac_pm_ref', 'mt76_connac_pm_unref',
                     'mt76_connac_mutex_acquire', 'mt76_connac_mutex_release'],
    'mt76_connac_mac.c': ['mt76_connac_pm_wake', 'mt76_connac_power_save_sched',
                         'mt76_connac_pm_queue_skb', 'mt76_connac_free_pending_tx_skbs',
                         'mt76_connac_pm_dequeue_skbs'],
    'mt792x_core.c': ['mt792x_stop', 'mt792x_tx_worker', 'mt792x_mcu_drv_pmctrl',
                      'mt792x_mcu_fw_pmctrl', 'mt792x_roc_timer'],
    'mt792x_mac.c': ['mt792x_mac_work', 'mt792x_reset', 'mt792x_pm_wake_work',
                     'mt792x_pm_power_save_work'],
    'mt792x_dma.c': ['mt792x_irq_handler', 'mt792x_irq_tasklet', 'mt792x_poll_tx',
                     'mt792x_poll_rx', 'mt792x_rx_poll_complete', 'mt792x_dma_cleanup'],
    'mt7921/mac.c': ['mt7921_mac_reset_work', 'mt7921_coredump_work', 'mt7921_set_ipv6_ns_work'],
    'mt7921/pci.c': ['mt7921e_rfkill_stop_work', 'mt7921e_publish_failed',
                     'mt7921e_drain_mcu', 'mt7921e_stop_deferred_work', 'mt7921e_reset_failed',
                     'mt7921e_unregister_device', 'mt7921_pci_probe',
                     'mt7921_pci_suspend', 'mt7921_pci_resume', 'mt7921_pci_remove', 'mt7921_pci_shutdown'],
    'mt7921/pci_mac.c': ['mt7921e_mac_reset'],
    'mt7921/pci_mcu.c': ['mt7921_mcu_send_message'],
    'mt7921/mcu.c': ['mt7921_mcu_parse_response'],
    'mt7921/main.c': ['__mt7921_start', 'mt7921_stop', 'mt7921_suspend', 'mt7921_resume',
                      'mt7921_rfkill_poll', 'mt7921_scan_work', 'mt7921_roc_work'],
    'mcu.c': ['mt76_mcu_get_response', 'mt76_mcu_skb_send_and_get_msg'],
    'dma.c': ['mt76_dma_cleanup'],
}
FRAMEWORK = {
    'upstream/backports/net/mac80211/driver-ops.c': ['drv_stop'],
    'upstream/backports/net/mac80211/driver-ops.h': ['drv_rfkill_poll'],
    'upstream/backports/net/mac80211/cfg.c': ['ieee80211_rfkill_poll'],
    'upstream/backports/net/wireless/rdev-ops.h': ['rdev_rfkill_poll'],
    'upstream/backports/net/wireless/core.c': ['cfg80211_rfkill_poll', 'wiphy_rfkill_start_polling'],
    'upstream/backports/include/net/cfg80211.h': ['wiphy_rfkill_stop_polling'],
    'upstream/linux/net/rfkill/core.c': ['rfkill_poll', 'rfkill_pause_polling',
                                       'rfkill_resume_polling', 'rfkill_suspend', 'rfkill_resume'],
}


def load(path, name):
    """Load the existing extractor/prepare implementation without copying it."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def mutate(tree, extractor, name):
    """Change one real rule only in the disposable prepared source tree."""
    rules = {
        'rfkill-sync': ('mt7921/pci.c', 'mt7921e_reset_failed',
            '\t\tqueue_work(system_unbound_wq, &dev->rfkill_work);',
            '\t\twiphy_rfkill_stop_polling(mt76_hw(dev)->wiphy);'),
        'stop-join-cleanup': ('mt792x_core.c', 'mt792x_stop',
            '\tcancel_work_sync(&dev->reset_work);',
            '\tcancel_work_sync(&dev->reset_work);\n\tflush_work(&dev->rfkill_work);'),
        'lose-pm-barrier': ('mt7921/pci.c', 'mt7921e_drain_mcu',
            '\tmutex_lock(&dev->mt76.mutex);', ''),
        'removed-skip-cleanup': ('mt7921/pci.c', 'mt7921e_rfkill_stop_work',
            '\t/* REMOVED still owns a live wiphy until removal joins this work. */',
            '\tif (test_bit(MT76_REMOVED, &dev->mphy.state))\n\t\treturn;'),
        'repeat-park': ('dma.c', 'mt76_dma_cleanup',
            '\tif (!test_bit(MT76_STATE_RECOVERY_FAILED, &dev->phy.state))\n\t\tmt76_worker_disable(&dev->tx_worker);',
            '\tmt76_worker_disable(&dev->tx_worker);'),
    }
    if name == 'irq-outside-lock':
        path = tree / 'mt76_connac.h'
        text = path.read_text()
        body = extractor.function(text, 'mt76_connac_irq_enable')
        changed = body.replace('\tunsigned long flags;', '\tunsigned long flags;\n\tbool schedule = false;')
        changed = changed.replace('\t\ttasklet_schedule(&dev->irq_tasklet);', '\t\tschedule = true;')
        changed = changed.replace('\tspin_unlock_irqrestore(&dev->mmio.irq_lock, flags);',
            '\tspin_unlock_irqrestore(&dev->mmio.irq_lock, flags);\n\tif (schedule)\n\t\ttasklet_schedule(&dev->irq_tasklet);')
        assert changed != body and text.count(body) == 1
        path.write_text(text.replace(body, changed))
        return
    relative, function, old, replacement = rules[name]
    path = tree / relative
    text = path.read_text()
    body = extractor.function(text, function)
    assert body.count(old) == 1 and text.count(body) == 1
    changed = body.replace(old, replacement)
    if name == 'lose-pm-barrier':
        assert changed.count('\tmutex_unlock(&dev->mt76.mutex);') == 1
        changed = changed.replace('\tmutex_unlock(&dev->mt76.mutex);', '')
    path.write_text(text.replace(body, changed))


def emit(args):
    """Extract whole functions; bind input hashes and each original function body."""
    fixture = args.repo / 'tests/fixtures/mt7921-fail-stop'
    extractor = load(fixture / 'extract-source.py', 'extractor')
    preparation = load(fixture / 'csa-source.py', 'preparation')
    extractor.verify_fixture(fixture)
    source, original = preparation.prepare(args.repo, fixture, args.output, args.patch)
    if getattr(args, 'mutation', None):
        mutate(source, extractor, args.mutation)
    definitions, records = [], []
    main_text = (source / 'mt7921/main.c').read_text()
    for member, expected in (('stop', 'mt7921_stop'), ('suspend', 'mt7921_suspend'),
                             ('resume', 'mt7921_resume'), ('rfkill_poll', 'mt7921_rfkill_poll')):
        if re.findall(r'\.' + member + r'\s*=\s*(\w+)', main_text) != [expected]:
            raise ValueError(f'mt7921_ops.{member}: actual registration drift')
    probe = extractor.function((source / 'mt7921/pci.c').read_text(), 'mt7921_pci_probe')
    for member, expected in (('reset', 'mt7921e_mac_reset'), ('reset_failed', 'mt7921e_reset_failed')):
        if re.findall(r'\.' + member + r'\s*=\s*(\w+)', probe) != [expected]:
            raise ValueError(f'PCIe HIF.{member}: actual registration drift')
    for tree, selection, layer in ((source, SELECTION, 'prepared-mt76'),
                                   (fixture, FRAMEWORK, 'original-framework')):
        for relative, names in selection.items():
            text = (tree / relative).read_text()
            for name in names:
                body = extractor.function(text, name)
                definitions.append(body)
                records.append({'file': relative, 'function': name, 'layer': layer,
                                'sha256': hashlib.sha256(body.encode()).hexdigest()})
    macros = []
    header = (source / 'mt792x.h').read_text()
    for name in ('mt792x_dev_reset', '__mt792x_mcu_drv_pmctrl', '__mt792x_mcu_fw_pmctrl'):
        found = re.findall(r'^#define[ \t]+' + name + r'\([^\n]*', header, re.M)
        if len(found) != 1:
            raise ValueError(f'{name}: expected one complete single-line HIF macro')
        macros.append(found[0])
        records.append({'file': 'mt792x.h', 'macro': name, 'layer': 'prepared-mt76',
                        'sha256': hashlib.sha256(found[0].encode()).hexdigest()})
    packet_text = (source / 'mt76_connac_mcu.h').read_text()
    packets = []
    for name in ('mt76_connac2_mcu_rxd', 'mt76_connac_mcu_uni_event', 'mt76_connac_mcu_reg_event'):
        found = re.findall(r'struct ' + name + r'\s*\{.*?\n\}[^;]*;', packet_text, re.S)
        if len(found) != 1:
            raise ValueError(f'{name}: ambiguous original packet declaration')
        packets.append(found[0])
        records.append({'file': 'mt76_connac_mcu.h', 'declaration': name, 'layer': 'prepared-mt76',
                        'sha256': hashlib.sha256(found[0].encode()).hexdigest()})
    (args.output / 'driver-packet.h').write_text('\n\n'.join(packets) + '\n')
    prototypes = [body.split('{', 1)[0].rstrip() + ';' for body in definitions]
    state = extractor.state_enum((source / 'mt76.h').read_text())
    (args.output / 'driver-state.h').write_text(state + '\n')
    (args.output / 'actual-source.c').write_text('\n\n'.join(
        ['#define WIRELESS_PATCHED 1', '#include "driver-state.h"',
         '#include "driver-double.h"'] + macros + prototypes + ['#include "driver-leaves.h"'] +
        definitions + ['#include "driver-fixture.h"']) + '\n')
    binding = {'mutation': getattr(args, 'mutation', None), 'patch_sha256': preparation.sha(args.patch),
               'source_sha256_sha256': preparation.sha(args.repo / 'devices/r5s-outdoor/patches/mt76/source.sha256'),
               'fixture_manifest_sha256': preparation.sha(fixture / 'source-manifest.json'),
               'functions': records, 'scope': 'non-CSA complete function partition; CSA uses existing separate partition'}
    (args.output / 'driver-source-binding.json').write_text(json.dumps(binding, indent=2) + '\n')
    print('SOURCE_BINDING ' + json.dumps(binding, sort_keys=True), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True)
    parser.add_argument('--mutation', choices=('rfkill-sync', 'stop-join-cleanup', 'lose-pm-barrier',
                                              'removed-skip-cleanup', 'repeat-park', 'irq-outside-lock'))
    emit(parser.parse_args())
