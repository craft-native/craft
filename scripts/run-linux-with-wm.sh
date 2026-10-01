#!/bin/sh
set -eu

# A bare Xvfb server cannot apply transient-window stacking or focus policy.
# Run desktop smokes under a real window manager on the same virtual display.
exec xvfb-run -a dbus-run-session -- sh -c '
  openbox --sm-disable >/dev/null 2>&1 &
  attempt=0
  until wmctrl -m 2>/dev/null | grep -q "^Name: Openbox"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
      echo "Openbox did not become ready on the virtual display" >&2
      exit 1
    fi
    sleep 0.1
  done
  exec "$@"
' craft-window-manager "$@"
