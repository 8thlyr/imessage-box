#!/usr/bin/env bash
# imessage-box VM control.
#   ./vm.sh start            boot the VM (daemonized qemu; the systemd unit calls this)
#   ./vm.sh stop [SECONDS]   clean shutdown (guest ssh, then ACPI, then quit), default 150 s
#   ./vm.sh restart
#   ./vm.sh ssh [CMD...]     shell in the guest as the box user
#   ./vm.sh shot [NAME]      screenshot to state/shots/NAME.png
#   ./vm.sh vnc              print VNC address and password file
#   ./vm.sh reset            go back to the clean post-install image (signs out of iMessage)
# BOOT_MODE=install|recovery|run (default: state/vm/boot-mode, else run) selects the OpenCore image.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

qemu_args() {
  local mode="$1" osk mac oc
  osk="$(cat "$VMD/osk")"
  mac="$(cat "$SECRETS/smbios-rom-mac")"   # NIC MAC == OpenCore ROM, required for iMessage
  oc="$VMD/opencore-$mode.qcow2"
  # shellcheck disable=SC2054  # commas belong to qemu option values
  ARGS=(
    -name "$VM_NAME" -daemonize -pidfile "$PIDFILE"
    -enable-kvm -m "$RAM_MB"
    -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check
    -machine q35
    -smp "$CPUS,cores=$CPUS,sockets=1,threads=1"
    -device qemu-xhci,id=xhci
    -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0
    -device "isa-applesmc,osk=$osk"
    -drive "if=pflash,format=raw,readonly=on,file=$VMD/OVMF_CODE_4M.fd"
    -drive "if=pflash,format=raw,file=$VMD/OVMF_VARS.fd"
    -smbios type=2
    -device ich9-ahci,id=sata
    -drive "id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=$oc"
    -device ide-hd,bus=sata.2,drive=OpenCoreBoot
    -drive "id=MacHDD,if=none,file=$VMD/disk.qcow2,format=qcow2,discard=unmap"
    -device ide-hd,bus=sata.4,drive=MacHDD,rotation_rate=1
    -netdev "user,id=net0,hostfwd=tcp:$BIND_ADDR:$BB_PORT-:1234,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device "virtio-net-pci,netdev=net0,id=net0,mac=$mac"
    -device vmware-svga
    -display none
    -vnc "$BIND_ADDR:$((VNC_PORT - 5900)),password=on" -k en-us
    -qmp "unix:$QMP_SOCK,server=on,wait=off"
    -qmp "unix:$QMP_TOOL,server=on,wait=off"
    -monitor none
    -serial "file:$VMD/serial.log"
  )
  if [[ "$mode" != run ]]; then
    # shellcheck disable=SC2054
    ARGS+=(-drive "id=InstallMedia,if=none,snapshot=on,format=raw,file=$INSTALLER_IMG"
           -device ide-hd,bus=sata.3,drive=InstallMedia)
  fi
}

port_free() { ! ss -Hltn "sport = :$2" 2>/dev/null | awk '{print $4}' | grep -qE "^(\[?$1\]?|0\.0\.0\.0|\*|\[::\]):$2$"; }

cmd_start() {
  local mode="${BOOT_MODE:-}" pid
  [[ -n "$mode" ]] || mode="$(cat "$VMD/boot-mode" 2>/dev/null || echo run)"
  if pid="$(vm_pid)"; then log "$VM_NAME already running (pid $pid)"; return 0; fi
  [[ -f "$VMD/disk.qcow2" && -f "$VMD/opencore-$mode.qcow2" ]] || die "VM not built yet; run ./install.sh"
  if [[ "$BIND_ADDR" != 127.0.0.1 && "$BIND_ADDR" != 0.0.0.0 ]]; then
    # e.g. a tailnet IP: wait for it to come up at boot
    for _ in $(seq 1 60); do ip -o addr show | grep -q "inet6\? $BIND_ADDR/" && break; sleep 2; done
    ip -o addr show | grep -q "inet6\? $BIND_ADDR/" || die "BIND_ADDR $BIND_ADDR is not on any interface"
  fi
  port_free "$BIND_ADDR" "$BB_PORT" || die "port $BIND_ADDR:$BB_PORT is in use (set BB_PORT in box.conf)"
  port_free "$BIND_ADDR" "$VNC_PORT" || die "port $BIND_ADDR:$VNC_PORT is in use (set VNC_PORT in box.conf)"
  port_free 127.0.0.1 "$SSH_PORT" || die "port 127.0.0.1:$SSH_PORT is in use (set SSH_PORT in box.conf)"
  qemu_args "$mode"
  rm -f "$QMP_SOCK" "$QMP_TOOL"
  log "starting $VM_NAME ($mode mode): BlueBubbles $BIND_ADDR:$BB_PORT, VNC $BIND_ADDR:$VNC_PORT"
  nice -n "$NICE" qemu-system-x86_64 "${ARGS[@]}"
  for _ in $(seq 1 50); do [[ -S "$QMP_SOCK" ]] && break; sleep 0.2; done
  # VNC refuses every client until a password is set.
  boxctl vnc-password "$QMP_SOCK" "$SECRETS/vnc-password"
}

cmd_stop() {
  local t="${1:-150}" pid i
  pid="$(vm_pid)" || { log "$VM_NAME is not running"; return 0; }
  if timeout 15 "${GSSH[@]}" true >/dev/null 2>&1; then
    timeout 20 "${GSSH[@]}" "sudo -n /sbin/shutdown -h now" >/dev/null 2>&1 || true
    log "guest shutdown requested over ssh"
  else
    boxctl powerdown "$QMP_SOCK" 2>/dev/null || true
    log "guest ssh unreachable; sent ACPI power button"
  fi
  for ((i = 0; i < t; i++)); do
    kill -0 "$pid" 2>/dev/null || { log "$VM_NAME stopped after ${i}s"; return 0; }
    if (( i == 60 )); then boxctl powerdown "$QMP_SOCK" 2>/dev/null || true; fi
    sleep 1
  done
  warn "still running after ${t}s; forcing quit"
  boxctl quit "$QMP_SOCK" 2>/dev/null || kill "$pid" 2>/dev/null || true
  sleep 3
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  return 0
}

cmd_reset() {
  [[ -f "$VMD/base.qcow2" ]] || die "no clean base image (SNAPSHOT=0 or install not finished)"
  local svc=0
  if systemctl is-active --quiet "$VM_NAME.service" 2>/dev/null; then svc=1; sudo systemctl stop "$VM_NAME.service"; fi
  cmd_stop
  (cd "$VMD" && rm -f disk.qcow2 && qemu-img create -q -f qcow2 -b base.qcow2 -F qcow2 disk.qcow2)
  cp "$VMD/OVMF_VARS.base.fd" "$VMD/OVMF_VARS.fd"
  ok "disk reset to the clean post-install image"
  if (( svc )); then sudo systemctl start "$VM_NAME.service"; else cmd_start; fi
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop "${2:-150}" ;;
  restart)
    if systemctl is-enabled --quiet "$VM_NAME.service" 2>/dev/null; then sudo systemctl restart "$VM_NAME.service"
    else cmd_stop; cmd_start; fi ;;
  ssh) shift; guest_ssh "$@" ;;
  shot) mkdir -p "$SHOTS"; boxctl shot "$QMP_TOOL" "$SHOTS/${2:-$(date +%H%M%S)}.png" ;;
  vnc) echo "VNC: $BIND_ADDR:$VNC_PORT  password file: $SECRETS/vnc-password"
       [[ "$BIND_ADDR" == 127.0.0.1 ]] && echo "From another machine: ssh -L $VNC_PORT:127.0.0.1:$VNC_PORT $(id -un)@$(hostname), then VNC to localhost:$VNC_PORT" ;;
  reset) cmd_reset ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
