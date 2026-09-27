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

# Build the observed RK356x mount graph without emulating delivery functions.
# Arguments: source for the mounted SSD; it must name a fixture block partition.
write_real_machine_storage_topology() {
  local target_source=$1
  mkdir -p "$FIXTURE_ROOT/root/sys/class/block/loop0/loop" \
    "$FIXTURE_ROOT/root/sys/class/block/mmcblk1/device" \
    "$FIXTURE_ROOT/root/sys/class/block/nvme0n1/device" \
    "$FIXTURE_ROOT/root/sys/dev/block" \
    "$FIXTURE_ROOT/root/sys/devices/platform/mmc/mmcblk1/mmcblk1p2" \
    "$FIXTURE_ROOT/root/sys/devices/pci0000:00/nvme/nvme0n1/nvme0n1p1"
  rm -rf "$FIXTURE_ROOT/root/sys/class/block/mmcblk1p2" \
    "$FIXTURE_ROOT/root/sys/class/block/nvme0n1p1"
  ln -s ../../devices/platform/mmc/mmcblk1/mmcblk1p2 \
    "$FIXTURE_ROOT/root/sys/class/block/mmcblk1p2"
  ln -s ../../devices/pci0000:00/nvme/nvme0n1/nvme0n1p1 \
    "$FIXTURE_ROOT/root/sys/class/block/nvme0n1p1"
  : > "$FIXTURE_ROOT/root/sys/devices/platform/mmc/mmcblk1/mmcblk1p2/partition"
  : > "$FIXTURE_ROOT/root/sys/devices/pci0000:00/nvme/nvme0n1/nvme0n1p1/partition"
  : > "$FIXTURE_ROOT/root/sys/class/block/loop0/loop/backing_file"
  printf '/mmcblk1p2\n' > "$FIXTURE_ROOT/root/sys/class/block/loop0/loop/backing_file"
  # Fixture-only mapping for 179:2; the real device did not provide this symlink.
  ln -s ../../class/block/mmcblk1p2 "$FIXTURE_ROOT/root/sys/dev/block/179:2"
  cat > "$FIXTURE_ROOT/root/proc/self/mountinfo" <<EOF
@MNT_ID@ 27 0:28 / /mnt/ssd rw,relatime - btrfs $target_source rw,ssd,discard=async,space_cache=v2,subvolid=5,subvol=/
17 27 179:2 / /rom rw,relatime - squashfs /dev/root ro,errors=continue
24 27 7:0 / /overlay rw,noatime - f2fs /dev/loop0 rw,lazytime,background_gc=on
27 1 0:24 / / rw,noatime - overlay overlayfs:/overlay rw,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work
EOF
}

# Fixture-only conflict: a real root path shadows the /name block alias and appears mounted on NVMe.
write_root_backing_conflict() {
  local path_kind=$1
  case "$path_kind" in
    regular-file) : > "$FIXTURE_ROOT/root/mmcblk1p2" ;;
    dangling-symlink) ln -s missing-backing "$FIXTURE_ROOT/root/mmcblk1p2" ;;
    *) return 1 ;;
  esac
  cat >> "$FIXTURE_ROOT/root/proc/self/mountinfo" <<'EOF'
88 27 259:1 / /mmcblk1p2 rw,relatime - ext4 /dev/nvme0n1p1 rw
EOF
}

# Fixture-only unambiguous file backing: no sysfs block node is named image.
write_root_file_backing() {
  : > "$FIXTURE_ROOT/root/image"
  printf '/image\n' > "$FIXTURE_ROOT/root/sys/class/block/loop0/loop/backing_file"
  cat >> "$FIXTURE_ROOT/root/proc/self/mountinfo" <<'EOF'
89 27 179:2 / /image rw,relatime - ext4 /dev/mmcblk1p2 rw
EOF
}

case_real_machine_storage_topology() {
  scenario 'guard accepts a separate NVMe through the observed RK356x storage graph'
  if ! docker_ready; then skip 'Docker daemon unavailable; real storage topology not run'; return; fi

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/nvme0n1p1
  assert_true 'separate NVMe btrfs target remains eligible through overlay, loop, and /dev/root' \
    run_guard_expect 0 prepare
  assert_true 'eligible separate NVMe creates the anchored PhotoPrism tree' \
    test -d "$FIXTURE_SSD/PhotoPrism/secrets"
  fixture_cleanup

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/nvme0n1p1; write_root_file_backing
  assert_true 'unambiguous root file backing recurses through mountinfo to system eMMC' \
    run_guard_expect 0 prepare
  assert_true 'unambiguous root file backing creates the anchored PhotoPrism tree' \
    test -d "$FIXTURE_SSD/PhotoPrism/secrets"
  fixture_cleanup

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/mmcblk1p2
  assert_true 'same eMMC target alias is rejected despite its UUID matching fstab' \
    run_guard_expect 1 prepare
  assert_true 'same eMMC target rejection leaves no PhotoPrism tree' \
    test ! -e "$FIXTURE_SSD/PhotoPrism"
  fixture_cleanup

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/nvme0n1p1
  rm -f "$FIXTURE_ROOT/root/sys/dev/block/179:2"
  assert_true 'unmapped /dev/root major:minor fails closed rather than accepting the SSD' \
    run_guard_expect 1 prepare
  assert_true 'unmapped /dev/root major:minor rejection leaves no PhotoPrism tree' \
    test ! -e "$FIXTURE_SSD/PhotoPrism"
  fixture_cleanup

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/nvme0n1p1
  write_root_backing_conflict regular-file
  assert_true 'root file named as the eMMC block alias is never followed to candidate NVMe' \
    run_guard_expect 1 prepare
  assert_true 'root file/block-name conflict leaves no PhotoPrism tree' \
    test ! -e "$FIXTURE_SSD/PhotoPrism"
  fixture_cleanup

  fixture_new; fixture_write_state; write_real_machine_storage_topology /dev/nvme0n1p1
  write_root_backing_conflict dangling-symlink
  assert_true 'dangling root symlink named as the eMMC block alias is never treated as a block alias' \
    run_guard_expect 1 prepare
  assert_true 'dangling root symlink conflict leaves no PhotoPrism tree' \
    test ! -e "$FIXTURE_SSD/PhotoPrism"
  fixture_cleanup
}
