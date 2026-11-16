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
[ -c "$port" ] || fail 'The Wayland virtio port is unavailable.'
if [ "$action" = status ]; then
  echo 'HiSH Wayland is ready.'
  exit 0
fi
command -v "$1" >/dev/null || fail "Application not found: $1"

runtime="$dir/active"
mkdir "$runtime" || fail 'A Wayland application is running.'
trap 'rm -rf "$runtime"' EXIT
trap 'exit 1' HUP INT TERM

unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
export XDG_RUNTIME_DIR="$runtime" XDG_SESSION_TYPE=wayland GDK_BACKEND=wayland
"$dir/waypipe" --no-gpu --oneshot --compress=none --socket "$port" server "$@"
