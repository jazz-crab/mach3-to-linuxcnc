#!/usr/bin/env bash
# launch-linuxcnc.sh — start LinuxCNC: with the machine config if present,
# otherwise open the config chooser. Used by SUPER+L and by login autostart.
set -u

cfg=""
for ini in "$HOME"/linuxcnc/configs/*/*.ini; do
  [ -f "$ini" ] && cfg="$ini" && break
done

if [ -n "$cfg" ]; then
  exec linuxcnc "$cfg"
else
  exec linuxcnc
fi
