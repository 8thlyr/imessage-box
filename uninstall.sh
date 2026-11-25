#!/usr/bin/env bash
# Remove the box: stop the VM, remove its systemd unit and kvm setting, delete state/.
#   ./uninstall.sh                 asks before deleting
#   ./uninstall.sh --yes           no questions
#   ./uninstall.sh --purge-cache   also delete the download cache (macOS recovery, BlueBubbles, OSX-KVM)
# Host packages (qemu, mtools, ...) are left installed.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

YES=0 PURGE=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --purge-cache) PURGE=1 ;;
    *) die "unknown option: $a" ;;
  esac
done
SUDO=sudo; [[ $EUID -eq 0 ]] && SUDO=""

echo "This deletes $STATE_DIR: the macOS disk, the signed-in iMessage session, and this box's"
echo "Mac identity (serial/MLB/ROM). A later install gets a new identity, which Apple sees as a new Mac."
if [[ "$YES" != 1 ]]; then
  read -r -p "Type the VM name ($VM_NAME) to confirm: " ans
  [[ "$ans" == "$VM_NAME" ]] || die "not confirmed; nothing removed"
fi

unit="/etc/systemd/system/$VM_NAME.service"
if [[ -f "$unit" ]]; then
  $SUDO systemctl disable --now "$VM_NAME.service" || true
  $SUDO rm -f "$unit"
  $SUDO systemctl daemon-reload
  ok "removed $VM_NAME.service"
fi
"$BOX_DIR/vm.sh" stop 90 || true
if pid="$(vm_pid)"; then kill -9 "$pid" || true; fi
if [[ -f /etc/modprobe.d/imessage-box-kvm.conf ]]; then
  $SUDO rm -f /etc/modprobe.d/imessage-box-kvm.conf
  ok "removed /etc/modprobe.d/imessage-box-kvm.conf (kvm ignore_msrs reverts at the next reboot)"
fi
if [[ -d "$STATE_DIR" ]]; then
  [[ -f "$VMD/base.qcow2" ]] && chmod u+w "$VMD/base.qcow2"
  rm -rf "$STATE_DIR"
  ok "deleted $STATE_DIR"
fi
if [[ "$PURGE" == 1 && -d "$CACHE_DIR" ]]; then
  rm -rf "$CACHE_DIR"
  ok "deleted $CACHE_DIR"
else
  log "download cache kept in $CACHE_DIR ($(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)); --purge-cache removes it"
fi
