#!/bin/sh
# Source this library from a long-lived caller. guard_open keeps FD 9 anchored.

PHOTOPRISM_ROOT=${PHOTOPRISM_TEST_ROOT:-}
TARGET_HELPER=${PHOTOPRISM_TARGET_HELPER:-/opt/outdoor-backup/scripts/target.sh}
FSTAB_SECTION=outdoor_backup_target
SSD_MOUNT=/mnt/ssd
PHOTOPRISM_PATH=/mnt/ssd/PhotoPrism

notice() { logger -t photoprism-storage "$*"; }
uci_get() { uci -q get "$1"; }
proc_file() { printf '%s/proc/%s\n' "$PHOTOPRISM_ROOT" "$1"; }
sys_file() { printf '%s/sys/%s\n' "$PHOTOPRISM_ROOT" "$1"; }

# Return the longest mount covering a path: fstype, source, device, point, VFS, and super options.
mount_record_for_path() {
    awk -v wanted="$1" '
        function covered(path, mount) { return mount == "/" || path == mount || index(path, mount "/") == 1 }
        covered(wanted, $5) && length($5) > longest {
            for (i = 7; i <= NF; i++) if ($i == "-") {
                fstype=$(i + 1); source=$(i + 2); device=$3; point=$5
                vfs_options=$6; super_options=$(i + 3); longest=length($5); break
            }
        }
        END {
            if (longest) print fstype "\t" source "\t" device "\t" point "\t" vfs_options "\t" super_options
            else exit 1
        }
    ' "$(proc_file self/mountinfo)"
}

# Resolve a block partition to its physical parent. Virtual block classes fail closed.
physical_parent() {
    source=$1
    case "$source" in /dev/*) name=${source#/dev/};; *) return 1;; esac
    class=$(sys_file "class/block/$name")
    [ -e "$class" ] || return 1
    case "$name" in loop*|dm-*|md*) return 1;; esac
    if [ -e "$class/partition" ]; then
        parent=$(basename "$(dirname "$(readlink -f "$class")")") || return 1
    else
        parent=$name
    fi
    [ -e "$(sys_file "class/block/$parent/device")" ] || return 1
    printf '/dev/%s\n' "$parent"
}

# Return success only for a single sysfs block-device name.
block_name_is_valid() {
    case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
}

# Resolve mountinfo major:minor through the canonical sysfs block-device link.
physical_parent_for_major_minor() {
    case "$1" in
        ''|*[!0-9:]*|*:*:*|:*|*:) return 1;;
        [0-9]*:[0-9]*) ;;
        *) return 1;;
    esac
    device_link=$(sys_file "dev/block/$1")
    [ -L "$device_link" ] || return 1
    canonical=$(readlink -f "$device_link") || return 1
    name=$(basename "$canonical")
    block_name_is_valid "$name" || return 1
    class=$(sys_file "class/block/$name")
    [ -e "$class" ] || return 1
    [ "$(readlink -f "$class")" = "$canonical" ] || return 1
    physical_parent "/dev/$name"
}

# Resolve a root-level loop backing file without confusing paths with block aliases.
# Arguments: absolute backing path, current recursion depth.
disk_for_root_backing() {
    backing=$1 depth=$2
    name=${backing#/}
    block_name_is_valid "$name" || return 1
    root_backing=$PHOTOPRISM_ROOT$backing
    [ -L "$root_backing" ] && return 1
    if [ -e "$root_backing" ]; then
        class=$(sys_file "class/block/$name")
        [ ! -e "$class" ] && [ ! -L "$class" ] || return 1
        disk_for_path "$backing" $((depth + 1))
    else
        physical_parent "/dev/$name"
    fi
}

# Follow a loop backing file or overlay upperdir to an underlying physical disk.
# Arguments: path, recursion depth (maximum 8). Unknown layers intentionally fail closed.
disk_for_path() {
    path=$1 depth=${2:-0}
    [ "$depth" -lt 8 ] || return 1
    record=$(mount_record_for_path "$path") || return 1
    IFS="$(printf '\t')" read -r fstype source device _ vfs_options super_options <<EOF
$record
EOF
    case "$fstype" in
        overlay)
            upper=$(printf '%s\n' "$vfs_options,$super_options" | tr ',' '\n' | sed -n 's/^upperdir=//p')
            [ -n "$upper" ] || return 1
            disk_for_path "$upper" $((depth + 1))
            ;;
        *)
            case "$source" in
                /dev/loop*)
                    name=${source#/dev/}
                    block_name_is_valid "$name" || return 1
                    backing=$(cat "$(sys_file "class/block/$name/loop/backing_file")" 2>/dev/null) || return 1
                    [ -n "$backing" ] || return 1
                    case "$backing" in
                        /dev/*)
                            name=${backing#/dev/}
                            block_name_is_valid "$name" || return 1
                            physical_parent "/dev/$name"
                            ;;
                        /*/*) disk_for_path "$backing" $((depth + 1));;
                        /*) disk_for_root_backing "$backing" "$depth";;
                        *)
                            block_name_is_valid "$backing" || return 1
                            physical_parent "/dev/$backing"
                            ;;
                    esac
                    ;;
                /dev/root) physical_parent_for_major_minor "$device";;
                /dev/*) physical_parent "$source";;
                *) return 1;;
            esac
            ;;
    esac
}

# Reject an SSD that shares any provable physical parent with root, rom, or overlay.
not_system_disk() {
    candidate=$1
    for system_mount in / /rom /overlay; do
        system_disk=$(disk_for_path "$system_mount") || return 1
        [ "$candidate" = "$system_disk" ] && return 1
    done
    return 0
}

# Return the block device carrying the configured UUID. btrfs mountinfo may use 0:N.
source_for_uuid() {
    mount_source=$1 expected=$2
    case "$mount_source" in
        /dev/*)
            block info "$mount_source" 2>/dev/null | awk -v dev="$mount_source" -v uuid="$expected" '
                $1 == dev ":" && index($0, "UUID=\"" uuid "\"") { print dev; found++ }
                END { exit found == 1 ? 0 : 1 }
            '
            ;;
        *)
            block info 2>/dev/null | awk -v uuid="$expected" '
                index($0, "UUID=\"" uuid "\"") { sub(/:.*/, "", $1); print $1; found++ }
                END { exit found == 1 ? 0 : 1 }
            '
            ;;
    esac
}

# Open, validate, and retain the target FD in the current shell.
guard_open() {
    [ -r "$TARGET_HELPER" ] || { notice "missing target helper: $TARGET_HELPER"; return 1; }
    # shellcheck source=/dev/null
    . "$TARGET_HELPER" || return 1
    target=$(uci_get "fstab.$FSTAB_SECTION.target")
    uuid=$(uci_get "fstab.$FSTAB_SECTION.uuid")
    enabled=$(uci_get "fstab.$FSTAB_SECTION.enabled")
    [ "$target" = "$SSD_MOUNT" ] && [ -n "$uuid" ] && [ "$enabled" = 1 ] || {
        notice 'fstab target/uuid/enabled rejected'; return 1;
    }
    target_open "$SSD_MOUNT" || return 1
    # shellcheck disable=SC2034 # target_anchor_healthy consumes this sourced-library state.
    TARGET_BACKUP_PATH=$PHOTOPRISM_PATH
    [ "$TARGET_RECORD_FS" = ext4 ] || [ "$TARGET_RECORD_FS" = btrfs ] || {
        notice "unsupported filesystem: $TARGET_RECORD_FS"; target_close; return 1;
    }
    source=$(source_for_uuid "$TARGET_RECORD_SOURCE" "$uuid") || {
        notice 'mount source has no unique block UUID evidence'; target_close; return 1;
    }
    disk=$(physical_parent "$source") || {
        notice 'mount source has no provable physical disk'; target_close; return 1;
    }
    not_system_disk "$disk" || {
        notice 'SSD is or cannot be proven separate from system storage'; target_close; return 1;
    }
    target_anchor_healthy || { target_close; return 1; }
}

guard_prepare() {
    guard_open || return 1
    for directory in PhotoPrism PhotoPrism/docker PhotoPrism/originals PhotoPrism/storage PhotoPrism/secrets; do
        target_prepare_directory "$directory" || { target_close; return 1; }
    done
    target_anchor_healthy || { target_close; return 1; }
}

guard_verify() {
    guard_open || return 1
    target_anchor_healthy || { target_close; return 1; }
}

guard_close() {
    command -v target_close >/dev/null 2>&1 && target_close || :
}

# Standalone mode intentionally closes the anchor after the one-shot check.
case "${1:-}" in
    '') ;;
    verify) guard_verify; result=$?; guard_close; exit "$result";;
    prepare) guard_prepare; result=$?; guard_close; exit "$result";;
    *) printf 'usage: %s [prepare|verify]\n' "$0" >&2; exit 2;;
esac
