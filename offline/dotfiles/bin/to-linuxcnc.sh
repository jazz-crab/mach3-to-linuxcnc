#!/usr/bin/env bash
# to-linuxcnc.sh — copy file(s)/dir(s) into ~/linuxcnc/projects (G-code etc).
# Usage: to-linuxcnc.sh FILE...
set -u

dest="$HOME/linuxcnc/projects"
mkdir -p "$dest"
for f in "$@"; do
  cp -r -- "$f" "$dest/" && echo "copied: $f -> $dest"
done
notify-send "В linuxcnc" "Скопировано: $# файл(ов) в $dest" 2>/dev/null
