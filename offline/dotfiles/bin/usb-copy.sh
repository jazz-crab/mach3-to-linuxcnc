#!/usr/bin/env bash
# usb-copy.sh — copy file(s)/dir(s) to a mounted USB stick.
# Usage: usb-copy.sh FILE...
# Picks the first mounted USB drive under /media/cnc or /run/media/cnc.
set -u

pick_usb() {
  for d in "/media/$USER"/* "/run/media/$USER"/*; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

USB="$(pick_usb)" || { notify-send -u critical "На флешку" "USB-накопитель не найден. Подключи флешку." 2>/dev/null; echo "no usb" >&2; exit 1; }

for f in "$@"; do
  cp -r -- "$f" "$USB/" && echo "copied: $f -> $USB"
done
notify-send "На флешку" "Скопировано: $# файл(ов) на $USB" 2>/dev/null
