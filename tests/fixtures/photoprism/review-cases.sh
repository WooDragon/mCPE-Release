#!/usr/bin/env bash
# Regressions for review-driven runtime changes. Delivery functions execute unchanged.

no_stop_call() { ! grep -Fq 'docker -H unix:///var/run/docker.sock stop' "$FIXTURE_LOG"; }

write_stop_docker_shim() {
  cat > "$FIXTURE_BIN/docker" <<'SHIM'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
for argument in "$@"; do case "$argument" in ps) action=ps;; stop) action=stop;; esac; done
case "$action" in ps) if [ "${FIXTURE_IDS+x}" = x ]; then printf '%s\n' "$FIXTURE_IDS"; else printf 'photo-id\n'; fi;; esac
SHIM
  chmod +x "$FIXTURE_BIN/docker"
}

case_stop_uses_labelled_id() {
  scenario 'worker stop finds only the labelled project container and stops its unique ID'
  fixture_new
  write_stop_docker_shim
  local script="$FIXTURE_ROOT/stop-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/worker.sh ''
stop_locked
SH
  chmod +x "$script"
  assert_true 'delivery stop succeeds for exactly one project/service label ID' \
    docker run --rm --user 0:0 -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e FIXTURE_IDS=photo-id -v "$FIXTURE_ROOT:/fixture" \
      -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/stop-test.sh'
  assert_true 'delivery queried both fixed Compose labels' fixture_has_call 'docker -H unix:///var/run/docker.sock ps -aq --filter label=com.docker.compose.project=mcpe-photoprism --filter label=com.docker.compose.service=photoprism'
  assert_true 'delivery stopped only the resolved project ID with ten-second timeout' fixture_has_call 'docker -H unix:///var/run/docker.sock stop --time 10 photo-id'
  fixture_cleanup

  fixture_new; write_stop_docker_shim; script="$FIXTURE_ROOT/stop-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/worker.sh ''
stop_locked
SH
  chmod +x "$script"
  assert_true 'delivery stop treats an absent labelled container as success' \
    docker run --rm --user 0:0 -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e FIXTURE_IDS= -v "$FIXTURE_ROOT:/fixture" \
      -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/stop-test.sh'
  assert_true 'absent labelled container never invokes docker stop' no_stop_call
  fixture_cleanup

  fixture_new; write_stop_docker_shim; script="$FIXTURE_ROOT/stop-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/worker.sh ''
! stop_locked
SH
  chmod +x "$script"
  assert_true 'delivery rejects ambiguous multiple project/service IDs' \
    docker run --rm --user 0:0 -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e 'FIXTURE_IDS=one
two' -v "$FIXTURE_ROOT:/fixture" \
      -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/stop-test.sh'
  assert_true 'ambiguous labels never invoke docker stop' no_stop_call
  fixture_cleanup
}

case_loop_bare_block_parent() {
  scenario 'storage guard resolves overlay loop backing bare partition to physical parent'
  fixture_new
  mkdir -p "$FIXTURE_ROOT/root/sys/class/block/loop0/loop" \
    "$FIXTURE_ROOT/root/sys/class/block/mmcblk0/device" \
    "$FIXTURE_ROOT/root/sys/devices/platform/mmc/mmcblk0/mmcblk0p2/device"
  rm -rf "$FIXTURE_ROOT/root/sys/class/block/mmcblk0p2"
  ln -s ../../devices/platform/mmc/mmcblk0/mmcblk0p2 "$FIXTURE_ROOT/root/sys/class/block/mmcblk0p2"
  : > "$FIXTURE_ROOT/root/sys/devices/platform/mmc/mmcblk0/mmcblk0p2/partition"
  : > "$FIXTURE_ROOT/root/sys/class/block/loop0/loop/backing_file"
  printf 'mmcblk0p2\n' > "$FIXTURE_ROOT/root/sys/class/block/loop0/loop/backing_file"
  cat > "$FIXTURE_ROOT/root/proc/self/mountinfo" <<'EOF'
1 0 0:1 / / rw - overlay overlay rw,upperdir=/overlay/upper
2 1 7:0 / /overlay rw - ext4 /dev/loop0 rw
3 1 179:2 / /rom rw - ext4 /dev/mmcblk0p2 rw
EOF
  local script="$FIXTURE_ROOT/loop-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/storage-guard.sh
[ "$(disk_for_path /)" = /dev/mmcblk0 ] && [ "$(disk_for_path /overlay)" = /dev/mmcblk0 ] && \
  ! not_system_disk /dev/mmcblk0 && not_system_disk /dev/vda
SH
  chmod +x "$script"
  assert_true 'delivery guard follows overlay to loop bare mmc partition and rejects same disk' \
    docker run --rm --user 0:0 -e PHOTOPRISM_TEST_ROOT=/fixture/root -v "$FIXTURE_ROOT:/fixture" \
      -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/loop-test.sh'
  fixture_cleanup
}
