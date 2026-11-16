#!/bin/sh
set -eu
umask 077

dir=$(dirname "$(readlink -f "$0")")
port=/dev/virtio-ports/org.hish.waypipe.0

fail() {
  echo "HiSH Wayland: $*" >&2
  exit 1
}

action=${1-}
case $action in
  status) [ "$#" -eq 1 ] || fail 'Usage: /run/hish-wayland status' ;;
  run) shift; [ "$#" -gt 0 ] || fail 'Specify a Wayland application.' ;;
  *) fail 'Usage: /run/hish-wayland {status|run PROGRAM [ARG...]}' ;;
esac

[ ! -d "$dir/active" ] || fail 'A Wayland application is running.'
[ ! -e "$dir/used" ] || fail 'Restart HiSH in Wayland mode to start another connection.'
[ -c "$port" ] || fail 'The Wayland virtio port is unavailable.'
command -v socat >/dev/null || fail 'Install socat with apk add socat.'
if [ "$action" = status ]; then
  echo 'HiSH Wayland is ready.'
  exit 0
fi
command -v "$1" >/dev/null || fail "Application not found: $1"

runtime="$dir/active"
mkdir "$runtime" || fail 'A Wayland application is running.'
bridge=''
cleanup() {
  if [ -n "$bridge" ]; then
    kill "$bridge" 2>/dev/null || true
    wait "$bridge" 2>/dev/null || true
  fi
  rm -rf "$runtime"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
[ ! -e "$dir/used" ] || fail 'Restart HiSH in Wayland mode to start another connection.'

socat "UNIX-LISTEN:$runtime/peer" "OPEN:$port" &
bridge=$!
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -S "$runtime/peer" ] || break
  kill -0 "$bridge" 2>/dev/null || fail 'Could not start the Wayland transport.'
  sleep 0.1
done
[ -S "$runtime/peer" ] || fail 'The Wayland transport did not become ready.'

: > "$dir/used"
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
export XDG_RUNTIME_DIR="$runtime" XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland
"$dir/waypipe" --no-gpu --oneshot --compress=none --socket "$runtime/peer" server "$@"
