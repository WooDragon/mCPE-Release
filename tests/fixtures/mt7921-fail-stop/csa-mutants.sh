#!/usr/bin/env bash
# Mutants must compile and execute all CSA cases; build failures do not kill one.
set -euo pipefail
REPO_ROOT=$1
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
RAN=0
REJECTED=0
for MUTATION in timer-silent skip-timer-join skip-work-join reset-wiphy callback-wiphy drop-rcu lose-pm-wake mt7925-terminal; do
    set +e
    bash "$REPO_ROOT/tests/bdd-mt7921-fail-stop.sh" --repo "$REPO_ROOT" --csa-mutation "$MUTATION" \
        > "$TMP_DIR/$MUTATION.stdout" 2> "$TMP_DIR/$MUTATION.stderr"
    TEST_EXIT=$?
    set -e
    python3 -B - "$TMP_DIR" "$MUTATION" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
name = sys.argv[2]
print('MUTANT_BEGIN ' + name, flush=True)
print((root / (name + '.stdout')).read_text(), end='', flush=True)
print((root / (name + '.stderr')).read_text(), end='', file=sys.stderr, flush=True)
PY
    RAN=$((RAN + 1))
    if [ "$TEST_EXIT" -eq 1 ] && \
       grep -qx "COMPILED CSA complete-source harness mode=patched mutation=$MUTATION" "$TMP_DIR/$MUTATION.stdout" && \
       grep -qx "CSA_BEHAVIOR_REJECTED mutation=$MUTATION actual_exit=1 expected=48" "$TMP_DIR/$MUTATION.stdout" && \
       python3 -B "$REPO_ROOT/tests/fixtures/mt7921-fail-stop/runner-contract-oracle.py" \
           "$TMP_DIR/$MUTATION.stdout" "$TMP_DIR/$MUTATION.stderr" "$TEST_EXIT" 48 --red; then
        REJECTED=$((REJECTED + 1))
        printf 'MUTANT_REJECTED %s runner_exit=%s\n' "$MUTATION" "$TEST_EXIT"
    else
        printf 'MUTANT_UNDECIDABLE_OR_ESCAPED %s runner_exit=%s\n' "$MUTATION" "$TEST_EXIT" >&2
        exit 1
    fi
done
printf 'mutations ran=%s rejected=%s escaped=%s expected=8\n' "$RAN" "$REJECTED" "$((RAN - REJECTED))"
[ "$RAN" -eq 8 ] && [ "$REJECTED" -eq 8 ]
