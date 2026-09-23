#!/usr/bin/env bash
# External OS seams for BDD. Delivery scripts themselves are mounted read-only.

fixture_new() {
  FIXTURE_ROOT="$(mktemp -d)"
  FIXTURE_BIN="$FIXTURE_ROOT/bin"
  FIXTURE_LOG="$FIXTURE_ROOT/calls.log"
  FIXTURE_SSD="$FIXTURE_ROOT/ssd"
  mkdir -p "$FIXTURE_BIN" "$FIXTURE_SSD" "$FIXTURE_ROOT/root/proc/self" \
    "$FIXTURE_ROOT/root/sys/class/block/vda/device" \
    "$FIXTURE_ROOT/root/sys/class/block/vdb/device"
  : > "$FIXTURE_LOG"
  export FIXTURE_UUID=PHOTO-SSD-UUID
  export FIXTURE_BLOCK_UUID=$FIXTURE_UUID
  export FIXTURE_FS=ext4
  FIXTURE_SYSTEM_DISK=0
  FIXTURE_CHILD_MOUNT=0
  fixture_write_shims
}

fixture_cleanup() {
  [ -z "${FIXTURE_ROOT:-}" ] || rm -rf "$FIXTURE_ROOT"
  unset FIXTURE_ROOT FIXTURE_BIN FIXTURE_LOG FIXTURE_SSD FIXTURE_UUID FIXTURE_BLOCK_UUID FIXTURE_FS
  unset FIXTURE_SYSTEM_DISK FIXTURE_CHILD_MOUNT
}

# Kernel-observation fixture. @MNT_ID@ is replaced by awk shim with actual FD9 id.
fixture_write_state() {
  local disk_source=/dev/vda system_source=/dev/vdb child=
  [ "$FIXTURE_SYSTEM_DISK" = 1 ] && system_source=$disk_source
  [ "$FIXTURE_CHILD_MOUNT" = 1 ] && child='99 42 8:9 / /mnt/ssd/PhotoPrism rw - ext4 /dev/vdc rw'
  cat > "$FIXTURE_ROOT/root/proc/self/mountinfo" <<EOF
@MNT_ID@ 1 259:1 / /mnt/ssd rw - $FIXTURE_FS /dev/vda rw
1 0 259:2 / / rw - ext4 $system_source rw
2 1 259:2 / /rom rw - ext4 $system_source rw
3 1 259:2 / /overlay rw - ext4 $system_source rw
$child
EOF
}

fixture_write_shims() {
  cat > "$FIXTURE_BIN/uci" <<'SHIM'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
case "$1 $2" in
  '-q get') case "$3" in
    fstab.outdoor_backup_target.target) printf '/mnt/ssd\n' ;;
    fstab.outdoor_backup_target.uuid) printf '%s\n' "$FIXTURE_UUID" ;;
    fstab.outdoor_backup_target.enabled) printf '1\n' ;;
  esac ;;
esac
SHIM
  cat > "$FIXTURE_BIN/block" <<'SHIM'
#!/bin/sh
printf 'block %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
if [ "$#" -gt 1 ]; then
  printf '%s: UUID="%s" TYPE="%s"\n' "$2" "$FIXTURE_BLOCK_UUID" "$FIXTURE_FS"
else
  printf '/dev/vda: UUID="%s" TYPE="%s"\n' "$FIXTURE_BLOCK_UUID" "$FIXTURE_FS"
fi
SHIM
  cat > "$FIXTURE_BIN/logger" <<'SHIM'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
printf 'fixture logger: %s\n' "$*" >&2
SHIM
  cat > "$FIXTURE_BIN/awk" <<'SHIM'
#!/bin/sh
# Replace only the target helper's kernel mountinfo input. All awk program logic stays real.
for argument in "$@"; do last=$argument; done
case "$last" in
  /proc/[0-9]*/mountinfo)
    pid=${last#/proc/}; pid=${pid%/mountinfo}
    mount_id=$(/usr/bin/awk '$1 == "mnt_id:" { print $2; exit }' "/proc/$pid/fdinfo/9") || exit 1
    [ -n "$mount_id" ] || exit 1
    temporary=$(mktemp) || exit 1
    sed "s/@MNT_ID@/$mount_id/g" "$PHOTOPRISM_MOUNTINFO_FIXTURE" > "$temporary" || exit 1
    command_line=
    for argument in "$@"; do
      [ "$argument" = "$last" ] && argument=$temporary
      escaped=$(printf '%s' "$argument" | /bin/sed "s/'/'\\\\''/g")
      command_line="$command_line '$escaped'"
    done
    # The argv came from the delivery helper; quote every element before exec.
    eval "exec /usr/bin/awk$command_line"
    ;;
  *) exec /usr/bin/awk "$@" ;;
esac
SHIM
  chmod +x "$FIXTURE_BIN"/*
}

# Actual upstream target.sh owns FD9. Only OS reads and external commands are seams.
fixture_run_guard() {
  local mode=$1 runtime_root=$2 target_helper=$3
  docker run --rm --user 0:0 \
    -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e PHOTOPRISM_TEST_ROOT=/fixture/root -e PHOTOPRISM_TEST_LOG=/fixture/calls.log \
    -e PHOTOPRISM_TARGET_HELPER=/opt/outdoor-backup/scripts/target.sh \
    -e PHOTOPRISM_MOUNTINFO_FIXTURE=/fixture/root/proc/self/mountinfo \
    -e FIXTURE_UUID -e FIXTURE_BLOCK_UUID -e FIXTURE_FS \
    -v "$FIXTURE_SSD:/mnt/ssd" -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$runtime_root/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$target_helper:/opt/outdoor-backup/scripts/target.sh:ro" \
    alpine:3.20 /bin/sh /usr/libexec/photoprism/storage-guard.sh "$mode"
}

fixture_has_call() { grep -Fq -- "$1" "$FIXTURE_LOG"; }
