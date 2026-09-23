#!/usr/bin/env bash
# Real dockerd-guard-exec entrypoint tests; only UCI, jsonfilter, and daemon are external.

write_wrapper_shims() {
  cat > "$FIXTURE_BIN/uci" <<'SHIM'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
case "$1 $2 $3" in
  '-q get fstab.outdoor_backup_target.target') printf '/mnt/ssd\n' ;;
  '-q get fstab.outdoor_backup_target.uuid') printf '%s\n' "$FIXTURE_UUID" ;;
  '-q get fstab.outdoor_backup_target.enabled') printf '1\n' ;;
  '-q get dockerd.globals.data_root') printf '%s\n' "$FIXTURE_DOCKER_ROOT" ;;
  '-q get dockerd.globals.alt_config_file') printf '%s\n' "$FIXTURE_ALT_CONFIG" ;;
esac
SHIM
  cat > "$FIXTURE_BIN/jsonfilter" <<'SHIM'
#!/bin/sh
printf 'jsonfilter %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
[ "$1" = -i ] && [ "$2" = "$FIXTURE_JSON_PATH" ] && [ "$3" = -e ] && [ "$4" = '@["data-root"]' ] || exit 2
printf '%s\n' "$FIXTURE_JSON_ROOT"
SHIM
  cat > "$FIXTURE_ROOT/dockerd" <<'SHIM'
#!/bin/sh
printf 'dockerd %s\n' "$*" >> "$DUMMY_LOG"
case "$*" in *--anything*) exit 0;; esac
wrapper_pid=$PPID
[ -d "/proc/$wrapper_pid/fd/9" ] && printf 'fd9-live\n' >> "$DUMMY_LOG" || exit 21
trap 'sleep 1; if [ -d "/proc/$wrapper_pid/fd/9" ]; then printf "fd9-held-during-term\n" >> "$DUMMY_LOG"; else printf "fd9-closed-early\n" >> "$DUMMY_LOG"; fi; printf "term\n" >> "$DUMMY_LOG"; exit 0' TERM INT
printf 'started\n' >> "$DUMMY_LOG"
while :; do sleep 1; done
SHIM
  chmod +x "$FIXTURE_BIN/uci" "$FIXTURE_BIN/jsonfilter" "$FIXTURE_ROOT/dockerd"
}

run_wrapper_container() {
  local mode=$1
  docker run --rm --user 0:0 \
    -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e PHOTOPRISM_TEST_ROOT=/fixture/root -e PHOTOPRISM_TEST_LOG=/fixture/calls.log \
    -e PHOTOPRISM_TARGET_HELPER=/opt/outdoor-backup/scripts/target.sh \
    -e PHOTOPRISM_MOUNTINFO_FIXTURE=/fixture/root/proc/self/mountinfo \
    -e FIXTURE_UUID -e FIXTURE_BLOCK_UUID -e FIXTURE_FS -e FIXTURE_DOCKER_ROOT \
    -e FIXTURE_ALT_CONFIG -e FIXTURE_JSON_PATH -e FIXTURE_JSON_ROOT -e DUMMY_LOG=/fixture/dummy.log \
    -v "$FIXTURE_SSD:/mnt/ssd" -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$FIXTURE_TARGET_HELPER:/opt/outdoor-backup/scripts/target.sh:ro" \
    -v "$FIXTURE_ROOT/config.json:/tmp/dockerd/daemon.json:ro" \
    -v "$FIXTURE_ROOT/dockerd:/usr/bin/dockerd:ro" alpine:3.20 /bin/sh -c "$mode"
}

wrapper_rejects() { ! run_wrapper_container "$1"; }

setup_wrapper_fixture() {
  fixture_new
  export FIXTURE_DOCKER_ROOT=/mnt/ssd/PhotoPrism/docker
  export FIXTURE_ALT_CONFIG=
  export FIXTURE_JSON_PATH=/tmp/dockerd/daemon.json
  export FIXTURE_JSON_ROOT=/mnt/ssd/PhotoPrism/docker
  : > "$FIXTURE_ROOT/config.json"
  mkdir -p "$FIXTURE_SSD/PhotoPrism/docker"
  ln -s config.json "$FIXTURE_ROOT/config-link"
  fixture_write_state
  write_wrapper_shims
}

case_wrapper_nonmanaged_transparent() {
  scenario 'dockerd wrapper transparently executes nonmanaged Docker without guard'
  setup_wrapper_fixture
  export FIXTURE_DOCKER_ROOT=/srv/existing-docker
  assert_true 'nonmanaged wrapper execs argv directly rather than requiring JSON or storage guard' \
    run_wrapper_container 'exec /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --anything'
  assert_true 'nonmanaged daemon received original argv' grep -Fq 'dockerd --anything' "$FIXTURE_ROOT/dummy.log"
  fixture_cleanup
}

case_wrapper_managed_json_and_term() {
  scenario 'managed wrapper validates linked JSON, holds FD9, and forwards TERM to dummy daemon'
  setup_wrapper_fixture
  # shellcheck disable=SC2016 # Inner script intentionally expands inside container sh -c.
  assert_true 'managed wrapper starts linked JSON daemon and forwards TERM after FD9 opens' \
    run_wrapper_container '
      /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file=/tmp/dockerd/daemon.json &
      wrapper=$!
      tries=20
      while [ "$tries" -gt 0 ] && ! grep -q started /fixture/dummy.log 2>/dev/null; do sleep 1; tries=$((tries - 1)); done
      grep -q fd9-live /fixture/dummy.log && kill -TERM "$wrapper"
      wait "$wrapper" || :
      tries=20
      while [ "$tries" -gt 0 ] && ! grep -q term /fixture/dummy.log 2>/dev/null; do sleep 1; tries=$((tries - 1)); done
      grep -q fd9-held-during-term /fixture/dummy.log && grep -q term /fixture/dummy.log
    '
  assert_true 'managed wrapper queried exact JSON data-root through jsonfilter' fixture_has_call 'jsonfilter -i /tmp/dockerd/daemon.json -e @["data-root"]'
  fixture_cleanup
}

case_wrapper_managed_json_rejections() {
  scenario 'managed wrapper rejects mismatched data-root and unrelated config symlink without daemon'
  setup_wrapper_fixture
  export FIXTURE_JSON_ROOT=/wrong/docker
  assert_true 'mismatched JSON root rejects wrapper before daemon start' \
    wrapper_rejects 'exec /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file=/tmp/dockerd/daemon.json'
  assert_true 'mismatched JSON root never executes dummy daemon' test ! -e "$FIXTURE_ROOT/dummy.log"
  fixture_cleanup

  setup_wrapper_fixture
  : > "$FIXTURE_ROOT/other.json"
  assert_true 'unrelated argv config rejects wrapper before daemon start' \
    wrapper_rejects 'exec /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file=/fixture/other.json'
  assert_true 'unrelated argv config never executes dummy daemon' test ! -e "$FIXTURE_ROOT/dummy.log"
  fixture_cleanup

  setup_wrapper_fixture
  : > "$FIXTURE_ROOT/external.json"
  export FIXTURE_ALT_CONFIG=/fixture/external.json
  assert_true 'managed external alt_config_file rejects default generated JSON path' \
    wrapper_rejects 'exec /usr/libexec/photoprism/dockerd-guard-exec /usr/bin/dockerd --config-file=/tmp/dockerd/daemon.json'
  assert_true 'managed external alt_config_file never executes dummy daemon' test ! -e "$FIXTURE_ROOT/dummy.log"
  fixture_cleanup
}
