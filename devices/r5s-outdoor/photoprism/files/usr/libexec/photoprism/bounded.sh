#!/bin/sh
# Run one command in a private session and reap all descendants on timeout/cancel.

case "${1:-}" in
  watchdog)
    supervisor=$2
    supervisor_start=$3
    limit=$4
    ready_fifo=$5
    go_fifo=$6
    supervisor_is_current() {
      [ -r "/proc/$supervisor/stat" ] || return 1
      # shellcheck disable=SC2046 # Deliberately split the three numeric proc fields.
      set -- $(awk '{print $5, $6, $22}' "/proc/$supervisor/stat")
      [ "$1" = "$supervisor" ] && [ "$2" = "$supervisor" ] && [ "$3" = "$supervisor_start" ]
    }
    # Do not create sleep until the parent has recorded this session as safe to kill by PGID.
    exec 3>"$ready_fifo"
    printf 'ready\n' >&3
    exec 3>&-
    IFS= read -r go < "$go_fifo" || exit 0
    [ "$go" = go ] || exit 0
    sleep "$limit"
    supervisor_is_current || exit 0
    kill -USR1 "$supervisor" 2>/dev/null || :
    exit 0
    ;;
esac

limit=$1
shift
exec 7>&-
exec 8>&-
exec 9<&-
watchdog=
watchdog_ready=0
watchdog_dir=
ready_fifo=
go_fifo=

remove_watchdog_handshake() {
  [ -z "$watchdog_dir" ] || { rm -f "$ready_fifo" "$go_fifo"; rmdir "$watchdog_dir" 2>/dev/null || :; }
  watchdog_dir=
  ready_fifo=
  go_fifo=
}

stop_watchdog() {
  [ -n "$watchdog" ] || { remove_watchdog_handshake; return; }
  if [ "$watchdog_ready" = 1 ]; then
    kill -KILL -"$watchdog" 2>/dev/null || :
  else
    # Before ready, watchdog is blocked in the handshake and has no sleep child.
    kill -KILL "$watchdog" 2>/dev/null || :
  fi
  wait "$watchdog" 2>/dev/null || :
  watchdog=
  remove_watchdog_handshake
}

# shellcheck disable=SC2329 # Invoked by the USR1 and TERM traps below.
cleanup() {
  trap '' TERM USR1
  stop_watchdog
  kill -TERM -"$$" 2>/dev/null || :
  sleep 1
  kill -0 "$$" 2>/dev/null || exit 1
  kill -KILL -"$$" 2>/dev/null || exit 1
}

trap cleanup USR1 TERM
supervisor_start=$(awk '{print $22}' "/proc/$$/stat") || exit 1
watchdog_dir=$(mktemp -d /tmp/photoprism-watchdog.XXXXXX) || exit 1
ready_fifo=$watchdog_dir/ready
go_fifo=$watchdog_dir/go
mkfifo "$ready_fifo" "$go_fifo" || { remove_watchdog_handshake; exit 1; }
setsid "$0" watchdog "$$" "$supervisor_start" "$limit" "$ready_fifo" "$go_fifo" &
watchdog=$!
# shellcheck disable=SC2016 # The child shell reads its positional FIFO path.
if ! timeout 5 sh -c 'IFS= read -r ready < "$1"; [ "$ready" = ready ]' sh "$ready_fifo"; then
  stop_watchdog
  exit 1
fi
watchdog_ready=1
printf 'go\n' > "$go_fifo" || { stop_watchdog; exit 1; }
remove_watchdog_handshake
"$@" &
target=$!
wait "$target"
result=$?
stop_watchdog
exit "$result"
