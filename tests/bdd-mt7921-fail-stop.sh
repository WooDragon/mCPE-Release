#!/usr/bin/env bash
# Run fixed-source driver scenarios. A compiler error is not a behavior-red baseline.
set -euo pipefail

SCRIPT_DIR=$(dirname -- "${BASH_SOURCE[0]}")
REPO_ROOT="$SCRIPT_DIR/.."
MODE=patched
PARTITION=full
CSA_MODE=patched
PATCH_PATH=
CSA_MUTATION=
DRIVER_MUTATION=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) REPO_ROOT="$2"; shift 2 ;;
        --red-baseline) MODE=baseline; shift ;;
        --driver) PARTITION=driver; shift ;;
        --driver-mutation) PARTITION=driver; DRIVER_MUTATION="$2"; shift 2 ;;
        --csa) PARTITION=csa; shift ;;
        --csa-red-original) PARTITION=csa; CSA_MODE=original; shift ;;
        --csa-red-wip) PARTITION=csa; CSA_MODE=wip; shift ;;
        --patch-path) PATCH_PATH="$2"; shift 2 ;;
        --csa-mutation) PARTITION=csa; CSA_MUTATION="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

FIXTURE="$REPO_ROOT/tests/fixtures/mt7921-fail-stop"
if [ "$PARTITION" = csa ]; then
    [ "$MODE" = patched ] || { printf 'CSA and legacy baseline modes cannot be combined.\n' >&2; exit 2; }
    if [ -z "$PATCH_PATH" ]; then
        PATCH_PATH="$REPO_ROOT/devices/r5s-outdoor/patches/mt76/990-mt7921-pcie-recovery-fail-stop.patch"
    fi
    exec bash "$FIXTURE/csa-run.sh" "$REPO_ROOT" "$CSA_MODE" "$PATCH_PATH" "$CSA_MUTATION"
fi
[ -z "$PATCH_PATH" ] || { printf 'Alternate patch is only allowed in explicit CSA mode.\n' >&2; exit 2; }
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
[ -z "$DRIVER_MUTATION" ] || [ "$MODE" = patched ] || { printf 'Driver mutations require patched mode.\n' >&2; exit 2; }
export FIXTURE TMP_DIR MODE DRIVER_MUTATION

python3 -B - <<'PY'
import importlib.util
import os
from pathlib import Path

fixture = Path(os.environ['FIXTURE']).resolve()
output = Path(os.environ['TMP_DIR'])
specification = importlib.util.spec_from_file_location('extract_source', fixture / 'extract-source.py')
extractor = importlib.util.module_from_spec(specification)
specification.loader.exec_module(extractor)
extractor.verify_fixture(fixture)
if os.environ['MODE'] == 'baseline':
    selection = {'mt7921/mac.c': ['mt7921_mac_reset_work'],
                 'mt792x_mac.c': ['mt792x_pm_wake_work']}
    extractor.emit(fixture / 'upstream/mt76', selection, output / 'actual-source.c')
    print('Extracted complete original reset and PM worker functions; fixture hashes verified.')
else:
    from argparse import Namespace
    spec = importlib.util.spec_from_file_location('driver_source', fixture / 'driver-source.py')
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    repo = fixture.parents[2]
    driver.emit(Namespace(repo=repo, output=output,
        patch=repo / 'devices/r5s-outdoor/patches/mt76/990-mt7921-pcie-recovery-fail-stop.patch',
        mutation=os.environ['DRIVER_MUTATION'] or None))
PY

cc -std=gnu11 -pthread -Wall -Wextra -Werror -Wno-unused-function \
    -Wno-unused-parameter -Wno-unused-variable -Wno-unused-value -Wno-sign-compare \
    -I"$TMP_DIR" -I"$FIXTURE" "$FIXTURE/scenarios.c" -o "$TMP_DIR/scenarios"
printf 'COMPILED complete-source driver harness mode=%s\n' "$MODE"
set +e
"$TMP_DIR/scenarios" > "$TMP_DIR/scenarios.stdout" 2> "$TMP_DIR/scenarios.stderr"
TEST_EXIT=$?
set -e
python3 -B - <<'PY'
import os
import sys
from pathlib import Path
root = Path(os.environ['TMP_DIR'])
print((root / 'scenarios.stdout').read_text(), end='')
print((root / 'scenarios.stderr').read_text(), end='', file=sys.stderr)
PY
if [ "$MODE" = baseline ]; then
    [ "$TEST_EXIT" -eq 1 ] || { printf 'Expected executed behavior-red exit 1, got %s\n' "$TEST_EXIT" >&2; exit 1; }
    grep -q '^ran=5 passed=3 failed=2 expected=5$' "$TMP_DIR/scenarios.stdout"
    printf 'EXPECTED RED: both runtime defects reproduced; three normal recovery boundaries pass.\n'
else
    [ "$TEST_EXIT" -eq 0 ] || exit "$TEST_EXIT"
    grep -q '^ran=28 passed=28 failed=0 expected=28$' "$TMP_DIR/scenarios.stdout"
    printf 'partition=driver ran=28 passed=28 failed=0 expected=28\n'
    if [ "$PARTITION" = full ]; then
        bash "$FIXTURE/csa-run.sh" "$REPO_ROOT" patched \
            "$REPO_ROOT/devices/r5s-outdoor/patches/mt76/990-mt7921-pcie-recovery-fail-stop.patch" ''
        printf 'partition=full ran=76 passed=76 failed=0 expected=76\n'
    fi
fi
