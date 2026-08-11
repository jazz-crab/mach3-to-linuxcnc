#!/usr/bin/env bash
#
# setup-machine.sh — offline provisioning: existing Debian Trixie -> working
# LinuxCNC box, "as after a fresh install".
#
# Run from a USB stick (data USB, not bootable):
#     sudo bash setup-machine.sh [--yes] [--reboot] [--dry-run] [--skip-clean]
#
# Flags:
#   --yes         no interactive confirmations (destructive steps)
#   --reboot      reboot at the end (after installing the RT kernel)
#   --dry-run     print what would be done, change nothing
#   --skip-clean  do not purge other DEs / other users / old configs
#
# Idempotent: safe to run more than once. Log: /var/log/linuxcnc-setup.log
#
# This is the project's own script (MIT). The .deb packages in ./debs are
# downloaded by fetch-packages.py from the public Debian archive.
#
set -euo pipefail

LOG=/var/log/linuxcnc-setup.log
DO_REBOOT=0
ASSUME_YES=0
SKIP_CLEAN=0
DRY_RUN=0

# parse flags
for a in "$@"; do
  case "$a" in
    --yes) ASSUME_YES=1 ;;
    --reboot) DO_REBOOT=1 ;;
    --skip-clean) SKIP_CLEAN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
warn() { echo "[WARN] $*" | tee -a "$LOG"; }
die() { echo "[ERR] $*" | tee -a "$LOG" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: $*"; return 0; fi
  log "run: $*"
  "$@" >>"$LOG" 2>&1 || { log "FAILED: $*"; return 1; }
}

confirm() { # confirm "question" -> yes/no
  [ "$ASSUME_YES" = 1 ] && return 0
  local ans
  printf "%s [y/N] " "$1" >&2
  read -r ans </dev/tty
  [[ "$ans" =~ ^[yY] ]]
}

installed() { dpkg -s "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || die "run me as root: sudo bash $(basename "$0")"
[ -r /etc/os-release ] || die "no /etc/os-release"
. /etc/os-release
[ "${VERSION_CODENAME:-}" = "trixie" ] || warn "expected Debian trixie, got: ${VERSION_CODENAME:-unknown}"
[ "$(dpkg --print-architecture 2>/dev/null)" = "amd64" ] || warn "expected amd64, got $(dpkg --print-architecture)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS="$SCRIPT_DIR/debs"
DOTFILES="$SCRIPT_DIR/dotfiles"
[ -d "$DEBS" ] || die "no debs/ next to this script (run fetch-packages.py first)"
[ -d "$DOTFILES" ] || warn "no dotfiles/ found — desktop keybinds/autostart will not be installed"

log "== linuxcnc setup, USB at $SCRIPT_DIR, debs: $(ls "$DEBS"/*.deb 2>/dev/null | wc -l)"

free_mb=$(df -Pm / | awk 'NR==2{print $4}')
[ "$free_mb" -gt 1500 ] || warn "less than 1.5 GB free on / ($free_mb MB)"

# ------------------------------------------------------------------ clean
if [ "$SKIP_CLEAN" != 1 ]; then
  log "== Phase 0: clean to 'as after fresh install'"
  # 0.1 purge heavy/foreign DE + apps
  if installed gnome-shell || installed plasma-desktop || installed cinnamon || installed xfce4-session || installed mate-desktop-environment; then
    log "purging other desktop environments..."
    if confirm "Purge other DEs/apps (GNOME/KDE/Cinnamon/Mate/Xfce, browsers, office)?"; then
      mapfile -t to_purge < <(dpkg -l | awk '/^ii/{print $2}' | grep -E '^(gnome|kde|kde5|kde6|cinnamon|mate|xfce|xfce4|nautilus|nemo|caja|gedit|totem|evolution|rhythmbox|cheese|shotwell|thunderbird|firefox|firefox-esr|libreoffice)' || true)
      if [ "${#to_purge[@]}" -gt 0 ]; then
        log "purging: ${to_purge[*]}"
        run apt-get remove --purge -y "${to_purge[@]}" || true
        run apt-get autoremove --purge -y || true
      fi
    fi
  else
    log "no heavy DE found, nothing to purge"
  fi

  # 0.2 other users -> remove (keep root, keep cnc)
  mapfile -t others < <(awk -F: '$3>=1000 && $1!="nobody" {print $1}' /etc/passwd | grep -v '^cnc$' || true)
  if [ "${#others[@]}" -gt 0 ]; then
    log "non-root users found: ${others[*]}"
    if confirm "Remove these users and their /home? (cnc is kept): ${others[*]}"; then
      for u in "${others[@]}"; do
        run userdel -r "$u" 2>/dev/null || run userdel "$u" 2>/dev/null || warn "could not remove $u"
      done
    fi
  fi

  # 0.3 reset /etc/skel
  run rm -rf /etc/skel
  run install -d -m 0755 /etc/skel/.config
fi

# ---------------------------------------------------------------- packages
log "== Phase 1: install packages from USB (offline)"
aptget_opts=(-y --allow-change-held-packages)
if run apt-get install "${aptget_opts[@]}" "$DEBS"/*.deb; then
  log "packages installed"
else
  log "apt install failed, trying apt-cache fallback..."
  cp "$DEBS"/*.deb /var/cache/apt/archives/ 2>/dev/null || true
  run apt-get install -f -y || warn "apt-get -f install could not fix dependencies"
fi

# ------------------------------------------------------------- parallel port
log "== Phase 2: free the parallel port for LinuxCNC"
run bash -c "echo 'blacklist lp' > /etc/modprobe.d/blacklist-lp.conf"

# ------------------------------------------------------------- linuxcnc dir
log "== Phase 3: user cnc"
if ! id -u cnc >/dev/null 2>&1; then
  run useradd -m -s /bin/bash -G sudo,dialout,plugdev,video,input,audio cnc
else
  log "user cnc already exists"
fi
run bash -c "echo 'cnc:cnc' | chpasswd"
run usermod -aG sudo,dialout,plugdev,video,input,audio cnc

# if the home dir exists but was never provisioned, clean it
if [ "$SKIP_CLEAN" != 1 ] && [ -d /home/cnc ] && [ ! -f /home/cnc/.provisioned ]; then
  log "cleaning existing /home/cnc for a fresh start"
  run rm -rf /home/cnc
  run mkdir -p /home/cnc
  run chown cnc:cnc /home/cnc
fi

run install -d -o cnc -g cnc /home/cnc/linuxcnc/configs
run install -d -o cnc -g cnc /home/cnc/linuxcnc/projects
run install -d -o cnc -g cnc /home/cnc/bin

# ---------------------------------------------------------------- dotfiles
if [ -d "$DOTFILES" ]; then
  log "== Phase 4: install desktop configs (openbox, lightdm, thunar)"
  run install -d -o cnc -g cnc /home/cnc/.config/openbox
  [ -f "$DOTFILES/openbox/rc.xml" ]     && run install -o cnc -g cnc "$DOTFILES/openbox/rc.xml"     /home/cnc/.config/openbox/rc.xml
  [ -f "$DOTFILES/openbox/menu.xml" ]   && run install -o cnc -g cnc "$DOTFILES/openbox/menu.xml"   /home/cnc/.config/openbox/menu.xml
  [ -f "$DOTFILES/openbox/autostart" ]  && run install -o cnc -g cnc "$DOTFILES/openbox/autostart"  /home/cnc/.config/openbox/autostart
  [ -f "$DOTFILES/xinitrc" ]            && run install -o cnc -g cnc "$DOTFILES/xinitrc"            /home/cnc/.xinitrc
  [ -f "$DOTFILES/bashrc" ]             && run install -o cnc -g cnc "$DOTFILES/bashrc"             /home/cnc/.bashrc
  [ -f "$DOTFILES/bash_profile" ]       && run install -o cnc -g cnc "$DOTFILES/bash_profile"       /home/cnc/.bash_profile

  run install -d -o cnc -g cnc /home/cnc/.config/Thunar
  [ -f "$DOTFILES/Thunar/uca.xml" ]     && run install -o cnc -g cnc "$DOTFILES/Thunar/uca.xml"     /home/cnc/.config/Thunar/uca.xml

  # helper scripts
  run install -d -o cnc -g cnc /home/cnc/bin
  for h in "$DOTFILES"/bin/*; do
    [ -f "$h" ] && run install -m 0755 -o cnc -g cnc "$h" /home/cnc/bin/
  done

  # lightdm: greeter + openbox session, no autologin
  run install -d /etc/lightdm/lightdm.conf.d
  if [ -f "$DOTFILES/lightdm/01-cnc.conf" ]; then
    run install -m 0644 "$DOTFILES/lightdm/01-cnc.conf" /etc/lightdm/lightdm.conf.d/01-cnc.conf
  fi
  run systemctl enable lightdm 2>/dev/null || true
fi

run bash -c "touch /home/cnc/.provisioned"
run chown -R cnc:cnc /home/cnc

# ------------------------------------------------------ RT kernel + grub
log "== Phase 5: ensure RT kernel + grub default"
if installed linux-image-rt-amd64; then
  run update-grub 2>/dev/null || true
  rt_entry=$(grep -oP "(?<=menuentry ')[^']*-rt-[^']*(?=')" /boot/grub/grub.cfg | head -1 || true)
  if [ -n "$rt_entry" ]; then
    log "RT kernel menuentry: $rt_entry"
    if confirm "Set $rt_entry as default boot entry?"; then
      run bash -c "sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\"Advanced options for Debian GNU/Linux>$rt_entry\"/' /etc/default/grub"
      run update-grub 2>/dev/null || true
    fi
  else
    warn "no -rt- menuentry found in grub.cfg"
  fi
else
  warn "linux-image-rt-amd64 is not installed — check Phase 1 log"
fi

# ------------------------------------------------------------- linuxcnc boot
log "== Phase 6: linuxcnc autostart on login (launch-linuxcnc.sh handles absence of config)"
# (handled by openbox/autostart + bin/launch-linuxcnc.sh from dotfiles)

# ---------------------------------------------------------------- report
log ""
log "== DONE =="
log "RT kernel present:    $(installed linux-image-rt-amd64 && echo yes || echo no)"
log "LinuxCNC present:     $(installed linuxcnc-uspace && echo yes || echo no)"
log "openbox:              $(installed openbox && echo yes || echo no)"
log "lightdm:              $(installed lightdm && echo yes || echo no)"
log "neovim:               $(installed neovim && echo yes || echo no)"
log ""
log "Next:"
log " 1. Reboot (or: sudo reboot). Login as cnc / cnc."
log " 2. First time: run StepConf  ->  SUPER+F1 or 'stepconf' in a terminal,"
log "    enter the machine pinout (machines/ra0306/linuxcnc-ra0306-guide.md §7)."
log " 3. After that, LinuxCNC starts automatically at login."
log "    SUPER+Q terminal | SUPER+E files | SUPER+L linuxcnc | SUPER+C close"

if [ "$DO_REBOOT" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  log "rebooting in 5 seconds..."
  sleep 5
  reboot
fi
exit 0
