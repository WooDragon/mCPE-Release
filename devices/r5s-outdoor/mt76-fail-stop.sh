#!/usr/bin/env bash
# Install the fixed mt76 prepare hook into one explicitly supplied OpenWrt tree.
# All recipe/input checks precede writes; duplicate installation is an error.

mcpe_mt76_fail_stop() {
    local openwrt_root="$1" helper_dir recipe inputs destination count
    helper_dir="$(dirname -- "${BASH_SOURCE[0]}")"
    recipe="$openwrt_root/package/kernel/mt76/Makefile"
    inputs="$helper_dir/patches/mt76"
    destination="$openwrt_root/package/kernel/mt76/mcpe-fail-stop"
    [ -s "$recipe" ] || { printf 'ERROR [mt76]: missing recipe: %s\n' "$recipe" >&2; return 1; }
    local input
    for input in source.sha256 fail-stop.mk 990-mt7921-pcie-recovery-fail-stop.patch; do
        [ -s "$inputs/$input" ] || { printf 'ERROR [mt76]: missing production input: %s\n' "$input" >&2; return 1; }
    done
    count=$(grep -Ec '^[[:space:]]*PKG_SOURCE_VERSION[[:space:]]*[:?+]?=' "$recipe" || true)
    if [ "$count" -ne 1 ] || ! grep -Fxq 'PKG_SOURCE_VERSION:=eb567bc7f9b692bbf1ddfe31dd740861c58ec85b' "$recipe"; then
        printf 'ERROR [mt76]: expected one exact fixed PKG_SOURCE_VERSION\n' >&2
        return 1
    fi
    # shellcheck disable=SC2016 # Match the literal Make expression, not shell expansion.
    count=$(grep -Fxc 'include $(INCLUDE_DIR)/cmake.mk' "$recipe" || true)
    [ "$count" -eq 1 ] || { printf 'ERROR [mt76]: missing or duplicate cmake include seam\n' >&2; return 1; }
    if [ -e "$destination" ] || grep -Fq 'mcpe-fail-stop' "$recipe"; then
        printf 'ERROR [mt76]: fail-stop hook is already installed\n' >&2
        return 1
    fi
    local line seam_seen=0
    # shellcheck disable=SC2016 # These comparisons consume literal Make source lines.
    while IFS= read -r line; do
        [ "$line" != 'include $(INCLUDE_DIR)/cmake.mk' ] || seam_seen=1
        if [[ "$line" == *'$(eval $(call KernelPackage,'* ]] && [ "$seam_seen" -eq 0 ]; then
            printf 'ERROR [mt76]: cmake seam is after KernelPackage evaluation\n' >&2
            return 1
        fi
    done < "$recipe"
    # Reuse the project's fail-loud primitive; never silently lose an injection.
    . "$helper_dir/../../scripts/diy-lib.sh"
    mkdir -p "$destination" || return 1
    cp "$inputs/source.sha256" "$inputs/fail-stop.mk" \
        "$inputs/990-mt7921-pcie-recovery-fail-stop.patch" "$destination/" || return 1
    # shellcheck disable=SC2016 # These are literal OpenWrt make expressions.
    sed_required 'mt76: install fixed recovery fail-stop prepare hook' \
        '/^include $(INCLUDE_DIR)\/cmake\.mk$/a\
include $(CURDIR)/mcpe-fail-stop/fail-stop.mk' "$recipe"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    [ "$#" -eq 1 ] || { printf 'Usage: %s <openwrt-root>\n' "$0" >&2; exit 2; }
    mcpe_mt76_fail_stop "$1"
fi
