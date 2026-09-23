#!/usr/bin/env bash
# Runtime BDD cases. Delivery functions execute unchanged; only external OS/CLI seams vary.
# shellcheck source=runtime-fixture.sh disable=SC1091
. "$FIXTURE_DIR/runtime-fixture.sh"

# shellcheck disable=SC2153 # fixture_new initializes this temporary bind path.
source_target_in_container() {
  docker run --rm --user 0:0 -v "$FIXTURE_SSD:/mnt/ssd" \
    -v "$FIXTURE_TARGET_HELPER:/opt/outdoor-backup/scripts/target.sh:ro" alpine:3.20 /bin/sh -c '
      . /opt/outdoor-backup/scripts/target.sh
      target_open /mnt/ssd && test -d "$TARGET_FD_ROOT" && \
        target_prepare_directory PhotoPrism/fd9-proof && test -d "$TARGET_FD_ROOT/PhotoPrism/fd9-proof" && target_close
    '
}

missing_target_in_container() {
  docker run --rm --user 0:0 -v "$FIXTURE_TARGET_HELPER:/opt/outdoor-backup/scripts/target.sh:ro" \
    alpine:3.20 /bin/sh -c '. /opt/outdoor-backup/scripts/target.sh; ! target_open /mnt/ssd'
}

run_guard_expect() {
  local expected=$1 mode=$2
  if fixture_run_guard "$mode" "$RUNTIME_DIR" "$FIXTURE_TARGET_HELPER"; then result=0; else result=1; fi
  [ "$result" = "$expected" ]
}

case_upstream_target_fd9() {
  scenario 'upstream target helper opens and writes through FD9 in unprivileged Linux'
  fixture_new
  if ! docker_ready; then skip 'Docker daemon unavailable; cannot execute Linux FD9 integration'; else
    assert_true 'real upstream target.sh opened FD9 and created anchor-relative directory' source_target_in_container
    assert_true 'FD9-created directory exists only in temporary bind fixture' test -d "$FIXTURE_SSD/PhotoPrism/fd9-proof"
    assert_true 'target helper did not create host /mnt/ssd path' test ! -e /mnt/ssd/PhotoPrism/fd9-proof
  fi
  fixture_cleanup
}

case_upstream_target_missing_mount() {
  scenario 'upstream target helper rejects absent target mount without writes'
  fixture_new
  if ! docker_ready; then skip 'Docker daemon unavailable; cannot execute Linux missing-mount integration'; else
    assert_true 'real upstream target.sh rejects absent /mnt/ssd' missing_target_in_container
    assert_true 'absent target did not create application tree' test ! -e "$FIXTURE_SSD/PhotoPrism"
  fi
  fixture_cleanup
}

case_guard_storage_matrix() {
  scenario 'guard consumes synthetic kernel observations while real target FD9 remains live'
  local filesystem
  if ! docker_ready; then skip 'Docker daemon unavailable; guard matrix not run'; return; fi
  for filesystem in ext4 btrfs; do
    fixture_new; FIXTURE_FS=$filesystem; fixture_write_state
    assert_true "$filesystem synthetic mountinfo reaches real guard prepare" run_guard_expect 0 prepare
    assert_true "$filesystem prepare creates anchored application tree" test -d "$FIXTURE_SSD/PhotoPrism/secrets"
    assert_true "$filesystem guard consumed UCI seam" fixture_has_call 'uci -q get fstab.outdoor_backup_target.target'
    fixture_cleanup
  done
}

case_guard_rejections_zero_write() {
  scenario 'guard rejects wrong UUID, filesystem, system disk, and child mount before writes'
  if ! docker_ready; then skip 'Docker daemon unavailable; guard rejection matrix not run'; return; fi
  fixture_new; export FIXTURE_BLOCK_UUID=WRONG; fixture_write_state
  assert_true 'wrong UUID rejects prepare' run_guard_expect 1 prepare
  assert_true 'wrong UUID leaves no application tree' test ! -e "$FIXTURE_SSD/PhotoPrism"; fixture_cleanup
  fixture_new; export FIXTURE_FS=xfs; fixture_write_state
  assert_true 'unsupported filesystem rejects prepare' run_guard_expect 1 prepare
  assert_true 'unsupported filesystem leaves no application tree' test ! -e "$FIXTURE_SSD/PhotoPrism"; fixture_cleanup
  fixture_new; export FIXTURE_SYSTEM_DISK=1; fixture_write_state
  assert_true 'same physical system disk rejects prepare' run_guard_expect 1 prepare
  assert_true 'system disk rejection leaves no application tree' test ! -e "$FIXTURE_SSD/PhotoPrism"; fixture_cleanup
  fixture_new; export FIXTURE_CHILD_MOUNT=1; fixture_write_state
  assert_true 'child mount covering PhotoPrism rejects prepare' run_guard_expect 1 prepare
  assert_true 'child mount rejection leaves no application tree' test ! -e "$FIXTURE_SSD/PhotoPrism"; fixture_cleanup
}

case_worker_pure_lan_validation() {
  scenario 'worker valid_lan_ip rejects reserved and CIDR network/broadcast inputs'
  if ! docker_ready; then skip 'Docker daemon unavailable; worker function unit not run'; return; fi
  fixture_new
  local script="$FIXTURE_ROOT/lan-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/worker.sh ''
valid_lan_ip 192.168.233.1/24 && valid_lan_ip 192.168.233.1 && \
! valid_lan_ip 192.168.233.0/24 && ! valid_lan_ip 192.168.233.255/24 && \
! valid_lan_ip 192.168.1.255 && ! valid_lan_ip 0.1.1.1 && ! valid_lan_ip 127.0.0.1 && \
! valid_lan_ip 225.1.1.1 && ! valid_lan_ip 192.168.1.1/33
SH
  chmod +x "$script"
  assert_true 'delivery valid_lan_ip accepts valid hosts and rejects all reserved/broadcast partitions' \
    docker run --rm --user 0:0 -v "$FIXTURE_ROOT:/fixture" -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/lan-test.sh'
  fixture_cleanup
}

case_credential_four_states() {
  scenario 'credential gate enforces four database/secret states through a real FD9 anchor'
  if ! docker_ready; then skip 'Docker daemon unavailable; credential unit not run'; return; fi
  fixture_new
  local script="$FIXTURE_ROOT/credential-test.sh"
  cat > "$script" <<'SH'
#!/bin/sh
exec 9</mnt/ssd
TARGET_FD_ROOT=/proc/$$/fd/9
set --
. /usr/libexec/photoprism/worker.sh ''
target_anchor_healthy() { return 0; }
mkdir -p "$TARGET_FD_ROOT/PhotoPrism/storage" "$TARGET_FD_ROOT/PhotoPrism/secrets"
secret="$TARGET_FD_ROOT/PhotoPrism/secrets/photoprism.env"
db="$TARGET_FD_ROOT/PhotoPrism/storage/index.db"
credential_gate && test -f "$secret" && test "$(stat -c %u "$secret")" = 0 && test "$(stat -c %a "$secret")" = 600 && grep -Eq '^PHOTOPRISM_ADMIN_PASSWORD=[0-9a-f]{32}$' "$secret" || exit 1
hash=$(sha256sum "$secret" | cut -d ' ' -f 1)
credential_gate && test "$hash" = "$(sha256sum "$secret" | cut -d ' ' -f 1)" || exit 1
rm -f "$secret"; : > "$db"; ! credential_gate || exit 1
printf 'PHOTOPRISM_ADMIN_PASSWORD=bad\n' > "$secret"; chmod 600 "$secret"; ! credential_gate || exit 1
printf 'PHOTOPRISM_ADMIN_PASSWORD=0123456789abcdef0123456789abcdef\n' > "$secret"; chmod 600 "$secret"; credential_gate
SH
  chmod +x "$script"
  assert_true 'delivery credential_gate creates/reuses/rejects/reaccepts all four states' \
    docker run --rm --user 0:0 -v "$FIXTURE_SSD:/mnt/ssd" -v "$FIXTURE_ROOT:/fixture" -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" alpine:3.20 /bin/sh -c '. /fixture/credential-test.sh'
  fixture_cleanup
}
