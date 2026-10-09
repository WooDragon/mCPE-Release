#!/usr/bin/env bash
# Explicit CSA partition only. Classified behavior/contract failures prove red;
# compile errors, signals and safety timeouts are always undecidable.
set -euo pipefail
REPO_ROOT=$1
MODE=$2
PATCH=$3
MUTATION=${4:-}
MUTATION_ARGS=()
if [ -n "$MUTATION" ]; then MUTATION_ARGS=(--mutation "$MUTATION"); fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
FIXTURE="$REPO_ROOT/tests/fixtures/mt7921-fail-stop"
python3 -B "$FIXTURE/csa-source.py" --repo "$REPO_ROOT" --mode "$MODE" \
    --patch "$PATCH" --output "$TMP_DIR" "${MUTATION_ARGS[@]}"
cc -std=gnu11 -pthread -Wall -Wextra -Werror -Wno-unused-function \
    -Wno-unused-parameter -Wno-unused-variable -Wno-unused-value \
    -I"$TMP_DIR" -I"$FIXTURE" "$FIXTURE/csa-scenarios.c" "$FIXTURE/csa-double.c" \
    -o "$TMP_DIR/csa-scenarios"
printf 'COMPILED CSA complete-source harness mode=%s mutation=%s\n' "$MODE" "${MUTATION:-none}"
set +e
"$TMP_DIR/csa-scenarios" > "$TMP_DIR/scenarios.stdout" 2> "$TMP_DIR/scenarios.stderr"
TEST_EXIT=$?
set -e
python3 -B - "$TMP_DIR" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
print((root / 'scenarios.stdout').read_text(), end='')
print((root / 'scenarios.stderr').read_text(), end='', file=sys.stderr)
PY
EXPECTED=48
ORACLE_ARGS=()
case "$MODE" in
    original) EXPECTED=6; ORACLE_ARGS=(--red) ;;
    wip) EXPECTED=1; ORACLE_ARGS=(--red) ;;
    patched) if [ -n "$MUTATION" ]; then ORACLE_ARGS=(--red); fi ;;
    *) exit 2 ;;
esac
python3 -B "$FIXTURE/runner-contract-oracle.py" "$TMP_DIR/scenarios.stdout" \
    "$TMP_DIR/scenarios.stderr" "$TEST_EXIT" "$EXPECTED" "${ORACLE_ARGS[@]}" || exit 2
if [ "$MODE" = patched ] && [ -n "$MUTATION" ]; then
    printf 'CSA_BEHAVIOR_REJECTED mutation=%s actual_exit=1 expected=48\n' "$MUTATION"
    exit 1
fi
case "$MODE" in
    original)
        [ "$TEST_EXIT" -eq 1 ]
        grep -qx 'partition=CSA ran=6 passed=0 failed=6 expected=6' "$TMP_DIR/scenarios.stdout"
        printf 'EXPECTED CSA RED: six original runtime behavior failures, no compile/signal substitute.\n' ;;
    wip)
        [ "$TEST_EXIT" -eq 1 ]
        grep -qx 'partition=CSA ran=1 passed=0 failed=1 expected=1' "$TMP_DIR/scenarios.stdout"
        grep -qx 'TRACE actual WIP: destroyed=1 timer/work lifetime faults=2' "$TMP_DIR/scenarios.stdout"
        printf 'EXPECTED CSA RED: actual WIP callback touched cleared timer/work.\n' ;;
    patched)
        [ "$TEST_EXIT" -eq 0 ]
        grep -qx 'partition=CSA ran=48 passed=48 failed=0 expected=48' "$TMP_DIR/scenarios.stdout"
        printf 'CSA PARTITION ONLY: non-CSA 28-case suite has not run here.\n' ;;
    *) exit 2 ;;
esac
