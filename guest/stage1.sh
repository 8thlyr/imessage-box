#!/bin/bash
# Stage 1, runs as root in macOS Recovery (typed into Recovery Terminal by install.sh).
# Erases the VM disk and installs macOS with startosinstall. No GUI clicks.
# Usage: bash stage1.sh http://10.0.2.2:PORT/TOKEN
B="$1"
r() { curl -fsS -m 15 -G "$B/report" --data-urlencode "s=$1" --data-urlencode "m=${2:-}" >/dev/null 2>&1 || true; }
fail() { r stage1-error "$1"; echo "imessage-box stage1 failed: $1"; exit 1; }

r stage1-start "recovery $(sw_vers -productVersion 2>/dev/null)"
curl -fsS -m 30 "$B/f/box.env" -o /tmp/box.env || fail "cannot fetch box.env"
# shellcheck source=/dev/null
. /tmp/box.env

# The VM disk is the physical disk whose size is exactly DISK_BYTES.
target=""
for d in $(diskutil list physical | awk '/^\/dev\/disk[0-9]+/{print $1}'); do
  bytes=$(diskutil info "$d" | awk -F'(' '/Disk Size/{split($2, a, " "); print a[1]}')
  if [ "$bytes" = "$DISK_BYTES" ]; then target="$d"; fi
done
[ -n "$target" ] || fail "no disk of $DISK_BYTES bytes: $(diskutil list physical | tr '\n' ' ')"
r disk-found "$target"

INST=""
for i in /Install\ macOS*.app; do [ -d "$i" ] && INST="$i"; done
[ -n "$INST" ] || fail "no Install macOS app in Recovery"
r installer "$INST"

if [ "${STAGE1_DRYRUN:-0}" = 1 ]; then
  r stage1-dryrun-ok "would erase $target and run $INST startosinstall"
  exit 0
fi

diskutil eraseDisk APFS "Macintosh HD" GPT "$target" >/tmp/erase.log 2>&1 || fail "erase: $(tail -3 /tmp/erase.log | tr '\n' ' ')"
r erased "$target"

# startosinstall downloads macOS from Apple (~12 GB), stages it, then reboots into the installer.
# --pidtosignal: it sends us SIGUSR1 when staging is done; we answer with SIGUSR1 to reboot at once.
LOGF=/tmp/startosinstall.log
trap 'touch /tmp/prepared' USR1
"$INST/Contents/Resources/startosinstall" --agreetolicense --nointeraction \
  --volume "/Volumes/Macintosh HD" --pidtosignal $$ >"$LOGF" 2>&1 &
SP=$!
r installing "startosinstall pid $SP"
last=""; still=0
while kill -0 "$SP" 2>/dev/null; do
  sleep 30
  if [ -f /tmp/prepared ]; then
    r prepared "staging done, rebooting into the installer"
    kill -USR1 "$SP" 2>/dev/null
    sleep 90
    reboot
  fi
  cur=$(tail -c 300 "$LOGF" | tr '\r' '\n' | grep -v '^ *$' | tail -1)
  if [ "$cur" != "$last" ]; then r progress "$cur"; last="$cur"; still=0; else still=$((still + 30)); fi
  # Seen once: staging finished at "164.8%" and nothing rebooted. Staged data present + 20 min idle = reboot.
  if [ "$still" -ge 1200 ] && [ -d "/Volumes/Macintosh HD/macOS Install Data" ]; then
    r stall-reboot "$cur"
    reboot
  fi
done
wait "$SP"; rc=$?
if [ -f /tmp/prepared ] || { [ "$rc" = 0 ] && [ -d "/Volumes/Macintosh HD/macOS Install Data" ]; }; then
  r prepared "startosinstall exited $rc after staging, rebooting"
  reboot
fi
fail "startosinstall exited $rc: $(tail -c 400 "$LOGF" | tr '\r\n' '  ')"
