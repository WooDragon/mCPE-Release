#!/usr/bin/env bash
# BDD for PhotoPrism delivery runtime. Never copy delivery business logic here.

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SELF_DIR")"
FIXTURE_DIR="$SELF_DIR/fixtures/photoprism"
RUNTIME_DIR="$REPO_ROOT/devices/r5s-outdoor/photoprism/files"

SCENARIOS=0
ASSERTIONS=0
PASS=0
FAIL=0
SKIP=0

scenario() {
  SCENARIOS=$((SCENARIOS + 1))
  printf '\nScenario P%02d — %s\n' "$SCENARIOS" "$1"
}
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
skip() { printf '  SKIP: %s\n' "$1"; SKIP=$((SKIP + 1)); }
assert_true() {
  local description=$1
  shift
  ASSERTIONS=$((ASSERTIONS + 1))
  if "$@"; then pass "$description"; else fail "$description"; fi
}
docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

require_file() { [ -f "$1" ]; }
contains() { grep -Fq -- "$1" "$2"; }

case_fixture_provenance() {
  scenario 'pinned upstream fixtures retain exact provenance'
  local dockerd="$FIXTURE_DIR/dockerd.init.upstream" target="$FIXTURE_DIR/target.sh.upstream"
  assert_true 'dockerd fixture exists' require_file "$dockerd"
  assert_true 'target fixture exists' require_file "$target"
  assert_true 'dockerd fixture hash is pinned v24.10.6' test "$(shasum -a 256 "$dockerd" | cut -d ' ' -f 1)" = 36573a8260be9392a9adc1e19a5874480a133681bcfcf08b41a214d2ffbad49b
  assert_true 'target fixture hash is pinned upstream source' test "$(shasum -a 256 "$target" | cut -d ' ' -f 1)" = e6603855c45401ce3c40fedeec5a2fcba8e139d79446aa6cb2d7ac171cadbaf4
}

case_delivery_parse() {
  scenario 'all shipped shell delivery paths parse'
  local path
  for path in \
    "$RUNTIME_DIR/usr/libexec/photoprism/storage-guard.sh" \
    "$RUNTIME_DIR/usr/libexec/photoprism/bounded.sh" \
    "$RUNTIME_DIR/usr/libexec/photoprism/worker.sh" \
    "$RUNTIME_DIR/usr/libexec/photoprism/dockerd-guard-exec" \
    "$RUNTIME_DIR/etc/init.d/photoprism" \
    "$RUNTIME_DIR/etc/uci-defaults/97-photoprism"; do
    assert_true "parse $(basename "$path")" sh -n "$path"
  done
}

case_static_delivery_contracts() {
  scenario 'delivery keeps fixed project, local Docker socket, and fail-loud patch sites'
  local worker="$RUNTIME_DIR/usr/libexec/photoprism/worker.sh" hook="$REPO_ROOT/devices/r5s-outdoor/post-feeds.sh"
  assert_true 'worker uses fixed project label' contains 'PROJECT=mcpe-photoprism' "$worker"
  assert_true 'worker pins Docker CLI to local Unix socket' contains 'unix:///var/run/docker.sock' "$worker"
  assert_true 'worker clears inherited Docker host/context' contains 'unset DOCKER_HOST DOCKER_CONTEXT' "$worker"
  assert_true 'hook has config-file dockerd guard patch' contains 'dockerd: guard config-file command' "$hook"
  assert_true 'hook has default dockerd guard patch' contains 'dockerd: guard default command' "$hook"
}

case_fixture_provenance
case_delivery_parse
case_static_delivery_contracts

# shellcheck disable=SC1091 source=tests/fixtures/photoprism/runtime-fixture.sh
. "$FIXTURE_DIR/runtime-fixture.sh"
# shellcheck disable=SC1091 source=tests/fixtures/photoprism/behavior-cases.sh
. "$FIXTURE_DIR/behavior-cases.sh"
# shellcheck disable=SC2034 # Consumed by the sourced behavior, wrapper, and worker fixtures.
FIXTURE_TARGET_HELPER="$FIXTURE_DIR/target.sh.upstream"
case_upstream_target_fd9
case_upstream_target_missing_mount
case_guard_storage_matrix
case_guard_rejections_zero_write
case_worker_pure_lan_validation
case_credential_four_states
# shellcheck disable=SC1091 source=tests/fixtures/photoprism/review-cases.sh
. "$FIXTURE_DIR/review-cases.sh"
case_stop_uses_labelled_id
case_loop_bare_block_parent
# shellcheck disable=SC1091 source=tests/fixtures/photoprism/wrapper-cases.sh
. "$FIXTURE_DIR/wrapper-cases.sh"
case_wrapper_nonmanaged_transparent
case_wrapper_managed_json_and_term
case_wrapper_managed_json_rejections
# shellcheck disable=SC1091 source=tests/fixtures/photoprism/worker-cases.sh
. "$FIXTURE_DIR/worker-cases.sh"
case_worker_claim_matrix
case_worker_rollback_matrix
case_worker_driver_matrix
case_worker_cli_cancellation
case_worker_cli_compose_cancellation
case_worker_natural_deadline
case_worker_rollback_and_driver_lifecycle

printf '\n============================================================\n'
printf 'PhotoPrism BDD result: scenarios=%d assertions=%d pass=%d fail=%d skip=%d\n' \
  "$SCENARIOS" "$ASSERTIONS" "$PASS" "$FAIL" "$SKIP"
printf '============================================================\n'

[ "$SCENARIOS" -eq 21 ] || { printf 'FAIL: runner integrity expected 21 scenarios, got %d\n' "$SCENARIOS" >&2; exit 2; }
[ "$ASSERTIONS" -eq 98 ] || { printf 'FAIL: runner integrity expected 98 assertions, got %d\n' "$ASSERTIONS" >&2; exit 2; }
[ "$FAIL" -eq 0 ]
