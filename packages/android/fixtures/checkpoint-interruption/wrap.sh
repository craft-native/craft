#!/system/bin/sh
HERE=$(dirname "$0")
export LD_PRELOAD="$HERE/libcraft-checkpoint-probe.so"
exec "$@"
