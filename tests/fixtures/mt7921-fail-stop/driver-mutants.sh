#!/usr/bin/env bash
# Compile and execute each temporary real-source mutation, never the repo patch.
set -euo pipefail
REPO_ROOT="$1"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
RAN=0
REJECTED=0
for mutation in rfkill-sync stop-join-cleanup lose-pm-barrier removed-skip-cleanup repeat-park irq-outside-lock; do
    printf 'MUTATION_BEGIN %s\n' "$mutation"
    set +e
    bash "$REPO_ROOT/tests/bdd-mt7921-fail-stop.sh" --repo "$REPO_ROOT" \
        --driver-mutation "$mutation" > "$TMP_DIR/$mutation.stdout" 2> "$TMP_DIR/$mutation.stderr"
    result=$?
    set -e
    python3 -B - "$TMP_DIR/$mutation.stdout" "$TMP_DIR/$mutation.stderr" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).read_text(), end='')
print(Path(sys.argv[2]).read_text(), end='', file=sys.stderr)
PY
    RAN=$((RAN+1))
    [ "$result" -ne 0 ] || { printf 'ESCAPED %s\n' "$mutation" >&2; exit 1; }
    grep -q '^COMPILED complete-source driver harness mode=patched$' "$TMP_DIR/$mutation.stdout"
    grep -Eq '^ran=28 passed=[0-9]+ failed=[1-9][0-9]* expected=28$' "$TMP_DIR/$mutation.stdout"
    if grep -q 'signal=14' "$TMP_DIR/$mutation.stderr"; then
        printf 'REJECT: timeout is not an exact mutation oracle: %s\n' "$mutation" >&2
        exit 1
    fi
    REJECTED=$((REJECTED+1))
    printf 'REJECTED %s actual_exit=%s\n' "$mutation" "$result"
done
printf 'driver_mutations ran=%s rejected=%s escaped=%s expected=6\n' "$RAN" "$REJECTED" "$((RAN-REJECTED))"
[ "$RAN" -eq 6 ] && [ "$REJECTED" -eq 6 ]
