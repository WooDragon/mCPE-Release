#!/usr/bin/env bash
# Worker ownership/driver/lifecycle regression fixture. Delivery functions are sourced unchanged.

worker_fixture_new() {
  fixture_new
  export WF_ROOT=default
  export WF_ALT=
  export WF_DAEMON=0
  export WF_DEFAULT_EMPTY=1
  export WF_BOOT=0
  export WF_UCI_WRITES="$FIXTURE_ROOT/uci-writes.log"
  : > "$WF_UCI_WRITES"
  cat > "$FIXTURE_BIN/uci" <<'SHIM'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
case "$1" in
  -q) [ "$2" = get ] || exit 0; case "$3" in
    dockerd.globals.data_root) [ "$WF_ROOT" = absent ] || { [ "$WF_ROOT" = default ] && printf '/opt/docker/\n' || printf '%s\n' "$WF_ROOT"; } ;;
    dockerd.globals.alt_config_file) printf '%s\n' "$WF_ALT" ;;
  esac ;;
  set|delete|commit) printf 'uci %s\n' "$*" >> "$WF_UCI_WRITES" ;;
esac
SHIM
  cat > "$FIXTURE_ROOT/dockerd.init" <<'SHIM'
#!/bin/sh
printf 'dockerd-init %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
case "$1" in running) [ "$WF_DAEMON" = 1 ];; enabled) [ "$WF_BOOT" = 1 ];; esac
SHIM
  cat > "$FIXTURE_BIN/pidof" <<'SHIM'
#!/bin/sh
[ "$WF_DAEMON" = 1 ]
SHIM
  chmod +x "$FIXTURE_BIN/uci" "$FIXTURE_ROOT/dockerd.init" "$FIXTURE_BIN/pidof"
}

run_worker_source() {
  local body=$1
  docker run --rm --user 0:0 \
    -e "PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e WF_ROOT -e WF_ALT -e WF_DAEMON -e WF_DEFAULT_EMPTY -e WF_BOOT -e WF_UCI_WRITES=/fixture/uci-writes.log \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$FIXTURE_ROOT/dockerd.init:/etc/init.d/dockerd:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    alpine:3.20 /bin/sh -c "$body"
}

no_uci_write() { ! grep -q '^uci \(set\|delete\|commit\)' "$WF_UCI_WRITES"; }

# shellcheck disable=SC2016 # The quoted body runs unchanged in the fixture container.
case_worker_claim_matrix() {
  scenario 'worker ownership claim accepts only empty default Docker and preserves existing ownership'
  worker_fixture_new
  assert_true 'empty default root claims managed root and enables dockerd boot' run_worker_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; target_anchor_healthy(){ :; }; default_root_empty(){ [ "$WF_DEFAULT_EMPTY" = 1 ]; }; claim_root_locked
  '
  assert_true 'claim writes managed root and enables boot' grep -q 'data_root=/mnt/ssd/PhotoPrism/docker' "$WF_UCI_WRITES"
  fixture_cleanup

  for rejection in custom nonempty daemon alt; do
    worker_fixture_new
    case "$rejection" in custom) export WF_ROOT=/srv/docker;; nonempty) export WF_DEFAULT_EMPTY=0;; daemon) export WF_DAEMON=1;; alt) export WF_ALT=/etc/docker/external.json;; esac
    assert_true "$rejection ownership rejects without UCI mutation" run_worker_source '
      set --; . /usr/libexec/photoprism/worker.sh ""; target_anchor_healthy(){ :; }; default_root_empty(){ [ "$WF_DEFAULT_EMPTY" = 1 ]; }; ! claim_root_locked
    '
    assert_true "$rejection ownership leaves UCI untouched" no_uci_write
    fixture_cleanup
  done
}

# shellcheck disable=SC2016 # The quoted body runs unchanged in the fixture container.
case_worker_rollback_matrix() {
  scenario 'worker rollback restores only its managed claim under the same ownership conditions'
  worker_fixture_new
  export WF_ROOT=/mnt/ssd/PhotoPrism/docker
  assert_true 'managed claimed root restores absent prior root and prior disabled boot' run_worker_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; CLAIMED_HERE=1; CLAIM_HAD_ROOT=0; CLAIM_BOOT_ENABLED=0; rollback_claim
  '
  assert_true 'rollback deletes root then commits and restores disabled boot' bash -c 'grep -q "uci delete dockerd.globals.data_root" "$1" && grep -q "uci commit dockerd" "$1" && grep -q "dockerd-init disable" "$2"' _ "$WF_UCI_WRITES" "$FIXTURE_LOG"
  fixture_cleanup

  worker_fixture_new
  export WF_ROOT=/srv/admin-docker
  assert_true 'custom root conflict refuses rollback without UCI write' run_worker_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; CLAIMED_HERE=1; CLAIM_HAD_ROOT=0; CLAIM_BOOT_ENABLED=0; ! rollback_claim
  '
  assert_true 'custom root conflict leaves UCI untouched' no_uci_write
  fixture_cleanup

  worker_fixture_new
  export WF_ROOT=/mnt/ssd/PhotoPrism/docker
  export WF_ALT=/etc/docker/external.json
  assert_true 'alt config conflict refuses rollback without UCI write' run_worker_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; CLAIMED_HERE=1; CLAIM_HAD_ROOT=0; CLAIM_BOOT_ENABLED=0; ! rollback_claim
  '
  assert_true 'alt config conflict leaves UCI untouched' no_uci_write
  fixture_cleanup
}

case_worker_driver_matrix() {
  scenario 'driver gate admits managed supported pairs and rejects vfs without ownership rollback'
  worker_fixture_new
  for pair in 'ext4 overlay2' 'btrfs overlay2' 'btrfs btrfs'; do
    fs=${pair%% *}; driver=${pair#* }
    assert_true "$fs/$driver driver gate accepts managed storage" run_worker_source "set --; . /usr/libexec/photoprism/worker.sh ''; TARGET_RECORD_FS=$fs; driver_supported $driver"
  done
  assert_true 'vfs driver gate rejects' run_worker_source "set --; . /usr/libexec/photoprism/worker.sh ''; TARGET_RECORD_FS=ext4; ! driver_supported vfs"
  fixture_cleanup
}

worker_cli_fixture_new() {
  fixture_new
  fixture_write_state
  printf 'absent\n' > "$FIXTURE_ROOT/uci-state"
  : > "$FIXTURE_ROOT/alt-state"
  printf '0\n' > "$FIXTURE_ROOT/boot-state"
  export WF_DOCKER_DRIVER=overlay2 WF_INFO_MODE=wait WF_WAIT_PHASE=readiness
  : > "$FIXTURE_ROOT/worker-events.log"
  : > "$FIXTURE_ROOT/compose.yaml"
  cat > "$FIXTURE_BIN/uci" <<'SHIM'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
state=/fixture/uci-state
case "$1" in
  -q)
    [ "$2" = get ] || exit 1
    case "$3" in
      fstab.outdoor_backup_target.target) printf '/mnt/ssd\n' ;;
      fstab.outdoor_backup_target.uuid) printf '%s\n' "$FIXTURE_UUID" ;;
      fstab.outdoor_backup_target.enabled|photoprism.main.enabled) printf '1\n' ;;
      network.lan.ipaddr) printf '192.168.233.1\n' ;;
      dockerd.globals.data_root) value=$(cat "$state"); [ "$value" = absent ] && exit 1; printf '%s\n' "$value" ;;
      dockerd.globals.alt_config_file) cat /fixture/alt-state ;;
    esac
    ;;
  set)
    case "$2" in dockerd.globals.data_root=*) printf '%s\n' "${2#*=}" > "$state";; *) exit 2;; esac
    ;;
  delete) [ "$2" = dockerd.globals.data_root ] && printf 'absent\n' > "$state" ;;
  commit) [ "$2" = dockerd ] || exit 2 ;;
  *) exit 2 ;;
esac
SHIM
  cat > "$FIXTURE_ROOT/dockerd.init" <<'SHIM'
#!/bin/sh
printf 'dockerd-init %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
case "$1" in
  start) exit 0 ;;
  enable) printf '1\n' > /fixture/boot-state; exit 0 ;;
  disable) printf '0\n' > /fixture/boot-state; exit 0 ;;
  running) exit 1 ;;
  enabled) [ "$(cat /fixture/boot-state)" = 1 ] ;;
  *) exit 2 ;;
esac
SHIM
  cat > "$FIXTURE_BIN/pidof" <<'SHIM'
#!/bin/sh
exit 1
SHIM
  cat > "$FIXTURE_BIN/docker" <<'SHIM'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$PHOTOPRISM_TEST_LOG"
for argument in "$@"; do
  case "$argument" in info) action=info;; compose) action=compose;; '{{.DockerRootDir}}') format=root;; '{{.Driver}}') format=driver;; esac
done
case "${format:-}" in
  root) printf '/mnt/ssd/PhotoPrism/docker\n'; exit 0 ;;
  driver) printf '%s\n' "$WF_DOCKER_DRIVER"; exit 0 ;;
esac
case "${action:-}" in
  info)
    [ "$WF_INFO_MODE" = immediate ] || [ "$WF_WAIT_PHASE" = compose ] && exit 0
    printf '%s\n' "$$" > /fixture/bounded-child.pid
    trap 'printf term > /fixture/bounded-term; exit 143' TERM INT
    while :; do sleep 1; done
    ;;
  compose)
    printf reached > /fixture/compose-reached
    if [ "$WF_WAIT_PHASE" = deadline ]; then
      (
        trap '' TERM INT
        # Leave a full second beyond deadline + TERM grace; this must never run.
        sleep 3
        printf late > /fixture/late-event
      ) &
      printf '%s\n' "$!" > /fixture/bounded-child.pid
      wait "$!"
      exit 0
    fi
    [ "$WF_WAIT_PHASE" = compose ] || exit 0
    printf '%s\n' "$$" > /fixture/bounded-child.pid
    trap 'printf term > /fixture/bounded-term; exit 143' TERM INT
    while :; do sleep 1; done
    ;;
  *) exit 2 ;;
esac
SHIM
  cat > "$FIXTURE_BIN/setsid" <<'SHIM'
#!/bin/sh
# Delay only watchdog session creation to deterministically exercise its startup handshake.
if [ "${WF_DELAY_WATCHDOG:-0}" = 1 ] && [ "${2:-}" = watchdog ]; then sleep 1; fi
exec /usr/bin/setsid "$@"
SHIM
  chmod +x "$FIXTURE_BIN/uci" "$FIXTURE_ROOT/dockerd.init" "$FIXTURE_BIN/pidof" "$FIXTURE_BIN/docker" "$FIXTURE_BIN/setsid"
}

run_worker_cli_cancellation() {
  local phase=$1 script="$FIXTURE_ROOT/worker-cli-cancel.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set -u
/usr/libexec/photoprism/worker.sh start &
worker=$!
for _ in $(seq 1 100); do [ -s /fixture/bounded-child.pid ] && break; sleep 0.05; done
[ -s /fixture/bounded-child.pid ] || { kill -TERM "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; exit 1; }
# The worker already passed `timeout 5 flock 8`; a separate open file description
# must still fail to lock while its readiness child is active.
if ( exec 6>/var/run/photoprism.lock; flock -n 6 ); then printf unexpected-lock > /fixture/lock-during; else printf held > /fixture/lock-during; fi
child=$(cat /fixture/bounded-child.pid)
if [ ! -e "/proc/$child/fd/7" ] && [ ! -e "/proc/$child/fd/8" ] && [ ! -e "/proc/$child/fd/9" ]; then
  printf closed > /fixture/child-fds
else
  printf inherited > /fixture/child-fds
fi
kill -TERM "$worker"
wait "$worker"; status=$?
printf '%s\n' "$status" > /fixture/worker-status
if kill -0 "$child" 2>/dev/null; then printf alive > /fixture/child-state; else printf gone > /fixture/child-state; fi
[ ! -e /var/run/photoprism.worker.pid ] && printf cleared > /fixture/pid-state
if ( exec 6>/var/run/photoprism.lock; flock -n 6 ); then printf reacquired > /fixture/lock-after; else printf retained > /fixture/lock-after; fi
exit 0
SH
  chmod +x "$script"
  docker run --rm --user 0:0 \
    -e 'PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    -e PHOTOPRISM_TEST_ROOT=/fixture/root -e PHOTOPRISM_TEST_LOG=/fixture/calls.log \
    -e PHOTOPRISM_TARGET_HELPER=/opt/outdoor-backup/scripts/target.sh \
    -e PHOTOPRISM_MOUNTINFO_FIXTURE=/fixture/root/proc/self/mountinfo \
    -e FIXTURE_UUID -e FIXTURE_BLOCK_UUID -e FIXTURE_FS -e WF_DOCKER_DRIVER -e WF_INFO_MODE -e WF_WAIT_PHASE="$phase" \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_SSD:/mnt/ssd" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$FIXTURE_ROOT/dockerd.init:/etc/init.d/dockerd:ro" \
    -v "$FIXTURE_TARGET_HELPER:/opt/outdoor-backup/scripts/target.sh:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$FIXTURE_ROOT/compose.yaml:/usr/share/photoprism/compose.yaml:ro" \
    alpine:3.20 /bin/sh /fixture/worker-cli-cancel.sh
}

case_worker_cli_cancellation() {
  scenario 'real worker CLI cancellation retains parent lock and cleans its bounded readiness child'
  if ! docker_ready; then skip 'Docker daemon unavailable; worker CLI cancellation integration not run'; return; fi
  worker_cli_fixture_new
  assert_true 'real worker CLI reaches bounded readiness through guard, UCI, init, and Docker seams' run_worker_cli_cancellation readiness
  assert_true 'timeout-acquired FD8 remains locked by worker parent during readiness' grep -qx held "$FIXTURE_ROOT/lock-during"
  assert_true 'bounded readiness command does not inherit worker FD7, FD8, or FD9' grep -qx closed "$FIXTURE_ROOT/child-fds"
  assert_true 'TERM exits the actual worker through its cancellation trap' grep -qx 143 "$FIXTURE_ROOT/worker-status"
  assert_true 'TERM leaves no readiness child process alive' grep -qx gone "$FIXTURE_ROOT/child-state"
  assert_true 'TERM clears the worker PID file' grep -qx cleared "$FIXTURE_ROOT/pid-state"
  assert_true 'FD8 lock is reacquirable only after worker exit' grep -qx reacquired "$FIXTURE_ROOT/lock-after"
  assert_true 'TERM before readiness prevents later compose execution' test ! -e "$FIXTURE_ROOT/compose-reached"
  fixture_cleanup
}

case_worker_cli_compose_cancellation() {
  scenario 'real worker CLI cancellation reaps the bounded Compose process group'
  if ! docker_ready; then skip 'Docker daemon unavailable; Compose cancellation integration not run'; return; fi
  worker_cli_fixture_new
  assert_true 'real worker CLI reaches the bounded Compose seam after readiness' run_worker_cli_cancellation compose
  assert_true 'Compose was reached exactly before cancellation' grep -qx reached "$FIXTURE_ROOT/compose-reached"
  assert_true 'worker parent retains FD8 while Compose child is active' grep -qx held "$FIXTURE_ROOT/lock-during"
  assert_true 'bounded Compose command does not inherit worker FD7, FD8, or FD9' grep -qx closed "$FIXTURE_ROOT/child-fds"
  assert_true 'TERM exits worker through its cancellation trap during Compose' grep -qx 143 "$FIXTURE_ROOT/worker-status"
  assert_true 'TERM reaps the Compose descendant' grep -qx gone "$FIXTURE_ROOT/child-state"
  assert_true 'Compose cancellation clears the worker PID file' grep -qx cleared "$FIXTURE_ROOT/pid-state"
  assert_true 'FD8 is reacquirable after Compose cancellation' grep -qx reacquired "$FIXTURE_ROOT/lock-after"
  fixture_cleanup
}

run_bounded_natural_deadline() {
  local script="$FIXTURE_ROOT/natural-deadline.sh"
  cat > "$script" <<'SH'
#!/bin/sh
set --
. /usr/libexec/photoprism/worker.sh ''
run_bounded 1 sh -c 'unset DOCKER_HOST DOCKER_CONTEXT; exec docker -H unix:///var/run/docker.sock compose --project-name mcpe-photoprism -f /usr/share/photoprism/compose.yaml up -d'
status=$?
printf '%s\n' "$status" > /fixture/deadline-status
sleep 3
child=$(cat /fixture/bounded-child.pid)
if kill -0 "$child" 2>/dev/null; then printf alive > /fixture/deadline-child; else printf gone > /fixture/deadline-child; fi
# The target naturally exits at the deadline/grace boundary but must not turn timeout into success.
run_bounded 1 sh -c 'trap "" TERM; sleep 2; exit 0'
printf '%s\n' "$?" > /fixture/deadline-grace-status
# The delayed real setsid watchdog must be ready before fast commands run or they wait whole deadlines.
started=$(date +%s)
run_bounded 5 sh -c 'exit 0'
printf '%s\n' "$?" > /fixture/quick-zero-status
run_bounded 5 sh -c 'exit 7'
printf '%s\n' "$?" > /fixture/quick-seven-status
printf '%s\n' "$(( $(date +%s) - started ))" > /fixture/quick-elapsed
watchdog_state=gone
for process in /proc/[0-9]*; do
  [ -r "$process/cmdline" ] || continue
  command=$(tr '\000' ' ' < "$process/cmdline" 2>/dev/null)
  case "$command" in *'/usr/libexec/photoprism/bounded.sh watchdog'*) watchdog_state=alive;; esac
done
printf '%s\n' "$watchdog_state" > /fixture/watchdog-state
SH
  chmod +x "$script"
  docker run --rm --user 0:0 \
    -e 'PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e WF_DOCKER_DRIVER -e WF_INFO_MODE -e WF_WAIT_PHASE=deadline -e WF_DELAY_WATCHDOG=1 \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$FIXTURE_ROOT/compose.yaml:/usr/share/photoprism/compose.yaml:ro" \
    alpine:3.20 /bin/sh /fixture/natural-deadline.sh
}

deadline_statuses_are_precise() {
  test "$(cat "$FIXTURE_ROOT/deadline-status")" -ne 0 &&
    test "$(cat "$FIXTURE_ROOT/deadline-grace-status")" -ne 0 &&
    test "$(cat "$FIXTURE_ROOT/quick-zero-status")" -eq 0 &&
    test "$(cat "$FIXTURE_ROOT/quick-seven-status")" -eq 7 &&
    test "$(cat "$FIXTURE_ROOT/quick-elapsed")" -lt 4 &&
    grep -qx gone "$FIXTURE_ROOT/watchdog-state"
}

case_worker_natural_deadline() {
  scenario 'natural bounded deadline reaps a stubborn Compose grandchild before it can start late'
  if ! docker_ready; then skip 'Docker daemon unavailable; natural deadline integration not run'; return; fi
  worker_cli_fixture_new
  assert_true 'real run_bounded executes the short deadline against a forking Compose command' run_bounded_natural_deadline
  assert_true 'deadline is nonzero, preserves quick exits, and never waits for watchdog deadline' deadline_statuses_are_precise
  assert_true 'deadline kills the stubborn Compose grandchild' grep -qx gone "$FIXTURE_ROOT/deadline-child"
  assert_true 'deadline leaves no delayed Compose side effect' test ! -e "$FIXTURE_ROOT/late-event"
  fixture_cleanup
}

run_worker_cli_source() {
  local body=$1
  docker run --rm --user 0:0 \
    -e 'PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    -e PHOTOPRISM_TEST_LOG=/fixture/calls.log -e WF_DOCKER_DRIVER -e WF_INFO_MODE \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$FIXTURE_ROOT/dockerd.init:/etc/init.d/dockerd:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    alpine:3.20 /bin/sh -c "$body"
}

run_worker_cli_driver_rejection() {
  docker run --rm --user 0:0 \
    -e 'PATH=/fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    -e PHOTOPRISM_TEST_ROOT=/fixture/root -e PHOTOPRISM_TEST_LOG=/fixture/calls.log \
    -e PHOTOPRISM_TARGET_HELPER=/opt/outdoor-backup/scripts/target.sh \
    -e PHOTOPRISM_MOUNTINFO_FIXTURE=/fixture/root/proc/self/mountinfo \
    -e FIXTURE_UUID -e FIXTURE_BLOCK_UUID -e FIXTURE_FS -e WF_DOCKER_DRIVER -e WF_INFO_MODE \
    -v "$FIXTURE_ROOT:/fixture" -v "$FIXTURE_SSD:/mnt/ssd" -v "$FIXTURE_BIN:/fixture/bin:ro" \
    -v "$FIXTURE_ROOT/dockerd.init:/etc/init.d/dockerd:ro" \
    -v "$FIXTURE_TARGET_HELPER:/opt/outdoor-backup/scripts/target.sh:ro" \
    -v "$RUNTIME_DIR/usr/libexec/photoprism:/usr/libexec/photoprism:ro" \
    -v "$FIXTURE_ROOT/compose.yaml:/usr/share/photoprism/compose.yaml:ro" \
    alpine:3.20 /bin/sh -c '! /usr/libexec/photoprism/worker.sh start && [ "$(cat /fixture/uci-state)" = /mnt/ssd/PhotoPrism/docker ]'
}

# shellcheck disable=SC2016 # The quoted body runs unchanged in the fixture container.
case_worker_rollback_and_driver_lifecycle() {
  scenario 'claim rollback conflicts occur under FD7 and driver rejection retains the managed root'
  if ! docker_ready; then skip 'Docker daemon unavailable; ownership lifecycle integration not run'; return; fi

  worker_cli_fixture_new
  assert_true 'custom-root rollback conflict follows a successful locked claim and performs no rollback mutation' run_worker_cli_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; target_anchor_healthy(){ :; }; claim_root &&
    [ "$(cat /fixture/uci-state)" = /mnt/ssd/PhotoPrism/docker ] || exit 1
    : > /fixture/calls.log; printf /srv/admin-docker > /fixture/uci-state
    ! rollback_claim && grep -Fq "rollback conflict: root changed" /fixture/calls.log &&
      ! grep -Eq "^uci (set|delete|commit)" /fixture/calls.log
  '
  fixture_cleanup

  worker_cli_fixture_new
  assert_true 'alt-config rollback conflict follows a successful locked claim and performs no rollback mutation' run_worker_cli_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; target_anchor_healthy(){ :; }; claim_root || exit 1
    : > /fixture/calls.log; printf /etc/docker/external.json > /fixture/alt-state
    ! rollback_claim && grep -Fq "rollback conflict: alt config appeared" /fixture/calls.log &&
      ! grep -Eq "^uci (set|delete|commit)" /fixture/calls.log
  '
  fixture_cleanup

  worker_cli_fixture_new
  printf '/opt/docker/\n' > "$FIXTURE_ROOT/uci-state"
  assert_true 'normal locked rollback restores explicit prior root and original disabled boot state' run_worker_cli_source '
    set --; . /usr/libexec/photoprism/worker.sh ""; target_anchor_healthy(){ :; }; claim_root && rollback_claim &&
      [ "$(cat /fixture/uci-state)" = /opt/docker/ ] && [ "$(cat /fixture/boot-state)" = 0 ]
  '
  fixture_cleanup

  worker_cli_fixture_new
  export WF_DOCKER_DRIVER=vfs WF_INFO_MODE=immediate
  assert_true 'actual CLI worker rejects vfs after real guard/claim but retains managed Docker root' run_worker_cli_driver_rejection
  fixture_cleanup
}
