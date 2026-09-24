#!/bin/sh
# One bounded lifecycle worker. dockerd remains a global daemon.

PROJECT=mcpe-photoprism
MANAGED_ROOT=/mnt/ssd/PhotoPrism/docker
DEFAULT_ROOT=/opt/docker/
GUARD=/usr/libexec/photoprism/storage-guard.sh
BOUNDED=/usr/libexec/photoprism/bounded.sh
IMAGE_HELPER=/usr/libexec/photoprism/image-helper.sh
LOCK=/var/run/photoprism.lock
OWNERSHIP_LOCK=/var/run/photoprism.ownership.lock
CANCEL=/var/run/photoprism.cancel
STOPPING=/var/run/photoprism.stopping
PID=/var/run/photoprism.worker.pid
CHILD=
CHILD_SPAWNING=0
CANCEL_PENDING=0

notice() { logger -t photoprism "$*"; }
docker_local() ( unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock "$@"; )
anchor_path() { printf '%s/PhotoPrism/%s\n' "$TARGET_FD_ROOT" "$1"; }
cancelled() { [ "$CANCEL_PENDING" = 1 ] || [ -e "$CANCEL" ] || [ -e "$STOPPING" ]; }

valid_lan_ip() {
    value=$1
    case "$value" in *[!0-9./]*|*/*/*|'') return 1;; esac
    address=${value%/*}; prefix=${value#*/}
    if [ "$address" = "$value" ]; then prefix=33; else
        [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null || return 1
    fi
    printf '%s/%s\n' "$address" "$prefix" | awk -F'[./]' '
        NF != 5 { exit 1 } { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i>255) exit 1 }
        $1==0 || $1==127 || $1>=224 || ($5==33 && $4==255) { exit 1 }
        $5 != 33 { a=(($1*256+$2)*256+$3)*256+$4; s=2^(32-$5); n=int(a/s)*s; if (a==n || a==n+s-1) exit 1 } { exit 0 }
    '
}

valid_secret() {
    secret_file=$1
    [ -f "$secret_file" ] && [ ! -L "$secret_file" ] && [ "$(stat -c %u "$secret_file" 2>/dev/null)" = 0 ] && \
        [ "$(stat -c %a "$secret_file" 2>/dev/null)" = 600 ] && [ "$(wc -l < "$secret_file" 2>/dev/null)" -eq 1 ] && \
        grep -Eq '^PHOTOPRISM_ADMIN_PASSWORD=[0-9a-f]{32}$' "$secret_file"
}
credential_gate() {
    db_path=$(anchor_path storage/index.db); secret_path=$(anchor_path secrets/photoprism.env)
    [ ! -e "$db_path" ] || { valid_secret "$secret_path"; return; }
    if [ -e "$secret_path" ] || [ -L "$secret_path" ]; then valid_secret "$secret_path"; return; fi
    umask 077; tmp=$(mktemp "$(anchor_path secrets/.photoprism.env.XXXXXX)") || return 1
    password=$(LC_ALL=C tr -dc '0-9a-f' < /dev/urandom | dd bs=32 count=1 2>/dev/null) || { rm -f "$tmp"; return 1; }
    if [ "${#password}" -ne 32 ] || ! printf 'PHOTOPRISM_ADMIN_PASSWORD=%s\n' "$password" > "$tmp" || \
        ! chown 0:0 "$tmp" || ! chmod 600 "$tmp" || ! valid_secret "$tmp" || ! mv -f "$tmp" "$secret_path"; then
        rm -f "$tmp"
        return 1
    fi
}

dockerd_running() { /etc/init.d/dockerd running >/dev/null 2>&1 || pidof dockerd >/dev/null 2>&1; }
default_root_empty() { [ ! -e "$DEFAULT_ROOT" ] && [ ! -L "$DEFAULT_ROOT" ] || { [ -d "$DEFAULT_ROOT" ] && [ ! -L "$DEFAULT_ROOT" ] && [ -z "$(find "$DEFAULT_ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; }; }
root_is_set() { uci -q get dockerd.globals.data_root >/dev/null 2>&1; }
current_root() { uci -q get dockerd.globals.data_root || printf '%s\n' "$DEFAULT_ROOT"; }
external_docker_configured() { [ -n "$(uci -q get dockerd.globals.alt_config_file)" ]; }

claim_root_locked() {
    cancelled && return 1; target_anchor_healthy || return 1; external_docker_configured && return 2
    root=$(current_root); [ "$root" = "$MANAGED_ROOT" ] && return 0
    [ "$root" = "$DEFAULT_ROOT" ] && ! dockerd_running && default_root_empty || return 2
    CLAIM_HAD_ROOT=0; root_is_set && { CLAIM_HAD_ROOT=1; CLAIM_PREVIOUS_ROOT=$(uci -q get dockerd.globals.data_root); }
    CLAIM_BOOT_ENABLED=0; /etc/init.d/dockerd enabled >/dev/null 2>&1 && CLAIM_BOOT_ENABLED=1
    uci set "dockerd.globals.data_root=$MANAGED_ROOT" && uci commit dockerd && /etc/init.d/dockerd enable || return 1
    CLAIMED_HERE=1; return 0
}
claim_root() {
    exec 7>"$OWNERSHIP_LOCK" || return 1; timeout 5 flock 7 || { exec 7>&-; return 1; }
    claim_root_locked; result=$?; flock -u 7; exec 7>&-; return "$result"
}
rollback_claim_locked() {
    [ "${CLAIMED_HERE:-0}" = 1 ] || { notice 'rollback conflict: not this worker claim'; return 1; }
    [ "$(current_root)" = "$MANAGED_ROOT" ] || { notice 'rollback conflict: root changed'; return 1; }
    external_docker_configured && { notice 'rollback conflict: alt config appeared'; return 1; }
    if [ "$CLAIM_HAD_ROOT" = 1 ]; then uci set "dockerd.globals.data_root=$CLAIM_PREVIOUS_ROOT"; else uci delete dockerd.globals.data_root; fi
    uci commit dockerd || return 1
    if [ "$CLAIM_BOOT_ENABLED" = 1 ]; then /etc/init.d/dockerd enable; else /etc/init.d/dockerd disable; fi
}
rollback_claim() {
    exec 7>"$OWNERSHIP_LOCK" || return 1
    timeout 5 flock 7 || { exec 7>&-; return 1; }
    rollback_claim_locked
    result=$?
    flock -u 7
    exec 7>&-
    return "$result"
}

docker_root() { docker_local info --format '{{.DockerRootDir}}' 2>/dev/null; }
docker_driver() { docker_local info --format '{{.Driver}}' 2>/dev/null; }
driver_supported() { case "$TARGET_RECORD_FS:$1" in ext4:overlay2|btrfs:overlay2|btrfs:btrfs) return 0;; *) return 1;; esac; }

# bounded.sh is the session supervisor: it owns the deadline and descendant cleanup.
run_bounded() {
    limit=$1; shift
    cancelled && return 143
    CHILD_SPAWNING=1
    setsid "$BOUNDED" "$limit" "$@" &
    CHILD=$!
    CHILD_SPAWNING=0
    [ "$CANCEL_PENDING" = 1 ] && { terminate_worker; return 143; }
    wait "$CHILD"
    result=$?
    CHILD=
    return "$result"
}

# Ask only our still-live session supervisor to clean its own process group.
terminate_worker() {
    if [ -n "$CHILD" ]; then
        kill -USR1 "$CHILD" 2>/dev/null || :
        sleep 2
        if kill -0 "$CHILD" 2>/dev/null; then
            kill -KILL -"$CHILD" 2>/dev/null || :
        fi
        wait "$CHILD" 2>/dev/null || :
        CHILD=
    elif [ "$CHILD_SPAWNING" = 1 ]; then
        CANCEL_PENDING=1
        return 0
    fi
    rm -f "$PID"
    guard_close
    exit 143
}

# Retry in the worker so no looping shell survives a bounded command cancellation.
wait_for_docker() {
    elapsed=0
    while :; do
        run_bounded 5 sh -c 'unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock info' && return 0
        result=$?
        [ "$result" -eq 143 ] && return 143
        [ "$elapsed" -lt 60 ] || return 1
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

start_worker() {
    [ ! -e "$STOPPING" ] || { notice 'stop in progress'; return 1; }
    printf '%s\n' "$$" > "$PID"; [ "$(uci -q get photoprism.main.enabled)" = 1 ] || return 0
    # shellcheck source=/dev/null
    . "$GUARD" || return 1; guard_prepare || return 1; cancelled && return 1
    credential_gate || { notice 'credential gate rejected'; return 1; }; cancelled && return 1
    CLAIMED_HERE=0; claim_root || { notice 'existing Docker ownership; PhotoPrism refused'; return 1; }
    target_anchor_healthy || return 1; /etc/init.d/dockerd start || return 1; wait_for_docker || { notice 'dockerd readiness timed out'; return 1; }
    actual_root=$(docker_root) || return 1
    if [ "$actual_root" != "$MANAGED_ROOT" ]; then notice 'dockerd actual root rejected'; rollback_claim || :; return 1; fi
    driver=$(docker_driver) || return 1
    driver_supported "$driver" || { notice 'dockerd driver rejected; retaining managed root'; return 1; }
    # shellcheck source=/dev/null
    . "$IMAGE_HELPER" || { notice 'PhotoPrism image helper unavailable'; return 1; }
    photoprism_image_ready || return 1
    cancelled && return 1; target_anchor_healthy || return 1
    lan=$(uci -q get network.lan.ipaddr); valid_lan_ip "$lan" || { notice 'LAN IPv4 rejected'; return 1; }
    PHOTOPRISM_HTTP_HOST=${lan%/*}; PHOTOPRISM_HTTP_PORT=2342; PHOTOPRISM_IMAGE=$PHOTOPRISM_IMAGE_LOCAL
    export PHOTOPRISM_HTTP_HOST PHOTOPRISM_HTTP_PORT PHOTOPRISM_IMAGE
    run_bounded 180 sh -c 'unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock compose --project-name mcpe-photoprism -f /usr/share/photoprism/compose.yaml up -d' || { unset PHOTOPRISM_HTTP_HOST PHOTOPRISM_HTTP_PORT PHOTOPRISM_IMAGE; notice 'compose up failed or timed out'; return 1; }
    unset PHOTOPRISM_HTTP_HOST PHOTOPRISM_HTTP_PORT PHOTOPRISM_IMAGE; target_anchor_healthy || { notice 'storage anchor changed after compose'; return 1; }
}

project_id() {
    ids=$(docker_local ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=photoprism') || return 1
    count=$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)
    [ "$count" -eq 0 ] && return 2; [ "$count" -eq 1 ] || return 1; printf '%s\n' "$ids"
}
# shellcheck disable=SC2016 # The child shell expands its positional argument.
stop_locked() { id=$(project_id); result=$?; [ "$result" -eq 2 ] && return 0; [ "$result" -eq 0 ] || return 1; run_bounded 30 sh -c 'unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock stop --time 10 "$1"' sh "$id"; }
container_status() { id=$(project_id); result=$?; [ "$result" -eq 0 ] || { printf '%s\n' absent; return 1; }; running=$(docker_local inspect -f '{{.State.Running}}' "$id" 2>/dev/null) || return 1; [ "$running" = true ] && { printf 'running\n'; return 0; }; printf 'stopped\n'; return 1; }
status_worker() { printf 'enabled=%s\n' "$(uci -q get photoprism.main.enabled)"; [ -r "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && printf 'worker=running\n' || printf 'worker=idle\n'; [ -e "$STOPPING" ] && printf 'stopping=yes\n' || printf 'stopping=no\n'; container=$(container_status); result=$?; printf 'container=%s\n' "$container"; return "$result"; }

case "${1:-}" in
    '') : ;;
    start) exec 8>"$LOCK" || exit 1; timeout 5 flock 8 || exit 1; trap 'terminate_worker' INT TERM; trap 'rm -f "$PID"; guard_close' EXIT; start_worker ;;
    stop) exec 8>"$LOCK" || exit 1; timeout 15 flock 8 || exit 1; stop_locked ;;
    status) status_worker ;;
    *) printf 'usage: %s start|stop|status\n' "$0" >&2; exit 2;;
esac
