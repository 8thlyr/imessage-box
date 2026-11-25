#!/usr/bin/env bash
# imessage-box installer: Linux + KVM host -> macOS VM running BlueBubbles, ready for ./signin.sh.
# Idempotent and resumable: re-run it after any failure and it continues where it stopped.
#
#   ./install.sh               full install (about 45 min, no clicks)
#   ./install.sh --check       host checks only, changes nothing
#   ./install.sh --dry-run     print what would run, change nothing
#   ./install.sh --smoke-test  build everything, boot macOS Recovery and prove the automation
#                              reaches its Terminal; erases and installs nothing (a few minutes)
#   ./install.sh --no-service  do not install the systemd unit; start the VM directly
#
# Settings: copy box.conf.example to box.conf. Log: state/logs/install-*.log
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

MODE=install SERVICE=1
for a in "$@"; do
  case "$a" in
    --check) MODE=check ;;
    --dry-run) DRY_RUN=1 ;;
    --smoke-test) MODE=smoke ;;
    --no-service) SERVICE=0 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option: $a (see --help)" ;;
  esac
done

ensure_state_dirs
LOG="$LOGS/install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
log "imessage-box install ($MODE$([[ "$DRY_RUN" == 1 ]] && echo ', dry run')) log: $LOG"

SUDO=sudo
[[ $EUID -eq 0 ]] && SUDO=""
GB=$((1024 * 1024 * 1024))
DISK_BYTES=$((DISK_GB * GB))

# ------------------------------------------------------------------ host checks
detect_pm() {
  if have pacman; then echo pacman; elif have apt-get; then echo apt; elif have dnf; then echo dnf
  elif have zypper; then echo zypper; else echo unknown; fi
}

preflight() {
  step "Checking the host"
  local fail=0 virt cpu flags avail_mb free_gb
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "needs Linux on x86_64 (found $(uname -s) $(uname -m))"
  flags="$(grep -m1 '^flags' /proc/cpuinfo)"
  cpu="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  log "CPU: $cpu; distro: $(. /etc/os-release; echo "${PRETTY_NAME:-?}"); package manager: $(detect_pm)"
  if ! grep -qwE 'vmx|svm' <<<"$flags"; then
    if [[ -n "$virt" && "$virt" != none ]]; then
      die "this machine is itself a VM ($virt) without nested virtualization. Turn on nested virtualization for it in your hypervisor or cloud (for example a GCP instance with --enable-nested-virtualization, an Azure Dv3/Ev3+ size, Proxmox 'cpu: host', or a bare-metal instance), then re-run."
    fi
    die "the CPU does not expose Intel VT-x or AMD-V; enable virtualization in the BIOS/UEFI"
  fi
  grep -qw avx2 <<<"$flags" || die "the CPU lacks AVX2, which macOS Ventura needs"
  grep -qw GenuineIntel /proc/cpuinfo || warn "AMD host: OSX-KVM reports modern Ryzen works, but imessage-box is only tested on Intel"
  if [[ ! -e /dev/kvm ]]; then
    if [[ "$MODE" != check ]]; then
      if grep -qw vmx <<<"$flags"; then run $SUDO modprobe kvm_intel || true; else run $SUDO modprobe kvm_amd || true; fi
    fi
    [[ -e /dev/kvm || "$DRY_RUN" == 1 ]] || die "/dev/kvm is missing (kvm module not loaded${virt:+; host is a $virt VM, so nested virtualization may be off})"
  fi
  if [[ -e /dev/kvm && ! ( -r /dev/kvm && -w /dev/kvm ) ]]; then
    if [[ "$MODE" == check ]]; then warn "no read/write access to /dev/kvm (install adds you to the kvm group)"; fail=1
    else
      run $SUDO usermod -aG kvm "$(id -un)"
      if have setfacl; then run $SUDO setfacl -m "u:$(id -un):rw" /dev/kvm; fi
      [[ -w /dev/kvm || "$DRY_RUN" == 1 ]] || die "added you to the kvm group; log out and back in, then re-run"
    fi
  fi
  avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if (( avail_mb < RAM_MB + 512 )); then
    warn "only ${avail_mb} MB RAM available; the VM wants $RAM_MB MB (+ ~512 MB qemu overhead)"; fail=1
  fi
  free_gb=$(( $(df -P -k "$STATE_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
  # An install peaks around 45 GB; a resumed one has already used part of that.
  local used_gb=0 need_gb
  [[ -f "$VMD/disk.qcow2" ]] && used_gb=$(( $(du -k "$VMD/disk.qcow2" | cut -f1) / 1024 / 1024 ))
  need_gb=$(( 45 - used_gb )); (( need_gb < 5 )) && need_gb=5
  if ! is_done macos-installed && (( free_gb < need_gb )); then
    warn "${free_gb} GB free under $STATE_DIR; the install needs about $need_gb GB more (about 16 GB stays in use afterwards)"; fail=1
  fi
  if ! vm_running; then
    local p
    for p in "$BIND_ADDR:$BB_PORT" "$BIND_ADDR:$VNC_PORT" "127.0.0.1:$SSH_PORT" "127.0.0.1:$PROV_PORT"; do
      if ss -Hltn "sport = :${p##*:}" 2>/dev/null | awk '{print $4}' | grep -qE "^(${p%:*}|0\.0\.0\.0|\*|\[::\]):${p##*:}$"; then
        warn "port $p is already in use; set a different one in box.conf"; fail=1
      fi
    done
  fi
  (( VNC_PORT >= 5900 && VNC_PORT <= 5999 )) || { warn "VNC_PORT must be 5900-5999"; fail=1; }
  [[ "$MACOS" == ventura ]] || warn "MACOS=$MACOS is untested; Ventura is the tested version"
  if (( fail )); then
    [[ "$MODE" == check ]] && die "host checks found problems (above)"
    [[ "${FORCE:-0}" == 1 ]] || die "fix the problems above, or re-run with FORCE=1 to ignore them"
  fi
  ok "host looks fine: KVM, AVX2, ${avail_mb} MB RAM free, ${free_gb} GB disk free"
}

# ------------------------------------------------------------------ packages
# pkg_for PM COMMAND: the package that provides COMMAND.
pkg_for() {
  case "$1:$2" in
    pacman:qemu-system-x86_64) echo qemu-base ;;  apt:qemu-system-x86_64) echo qemu-system-x86 ;;
    dnf:qemu-system-x86_64) echo qemu-system-x86-core ;;  zypper:qemu-system-x86_64) echo qemu-x86 ;;
    apt:qemu-img) echo qemu-utils ;;  zypper:qemu-img) echo qemu-tools ;;  *:qemu-img) echo qemu-img ;;
    *:mcopy) echo mtools ;;
    pacman:python3) echo python ;;  *:python3) echo python3 ;;
    pacman:ssh*|zypper:ssh*) echo openssh ;;  apt:ssh*) echo openssh-client ;;  dnf:ssh*) echo openssh-clients ;;
    dnf:ss) echo iproute ;;  *:ss) echo iproute2 ;;
    *) echo "$2" ;;
  esac
}

deps() {
  step "Installing host packages"
  local pkgs=() c pm p
  pm="$(detect_pm)"
  for c in qemu-system-x86_64 qemu-img mcopy python3 curl git ssh ssh-keygen ss; do
    have "$c" && continue
    p="$(pkg_for "$pm" "$c")"
    [[ " ${pkgs[*]} " == *" $p "* ]] || pkgs+=("$p")
  done
  if (( ${#pkgs[@]} )); then
    # Only what is missing: no upgrades of installed packages (no partial upgrades on Arch).
    log "installing: ${pkgs[*]}"
    case "$pm" in
      pacman) run $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
      apt) run $SUDO apt-get update; run $SUDO apt-get install -y "${pkgs[@]}" ;;
      dnf) run $SUDO dnf install -y "${pkgs[@]}" ;;
      zypper) run $SUDO zypper --non-interactive install "${pkgs[@]}" ;;
      *) die "unknown distro; install these yourself: qemu (system-x86_64 + qemu-img), mtools, python3, curl, git, openssh client, iproute2" ;;
    esac
  fi
  [[ "$DRY_RUN" == 1 ]] && return 0
  for c in qemu-system-x86_64 qemu-img mcopy python3 curl git ssh ss; do have "$c" || die "$c is still missing after installing packages"; done
  local devs
  devs="$(qemu-system-x86_64 -device help 2>/dev/null)"
  grep -q '"isa-applesmc"' <<<"$devs" || die "this qemu build has no isa-applesmc device (RHEL/CentOS qemu-kvm strips it; use upstream or Fedora/Debian/Arch qemu)"
  grep -q '"vmware-svga"' <<<"$devs" || die "this qemu build has no vmware-svga device"
  ok "packages: $(qemu-system-x86_64 --version | head -1)"
}

kvm_tuning() {
  # macOS touches MSRs KVM does not emulate; without ignore_msrs the guest crashes at boot.
  if [[ "$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null)" == Y ]]; then return 0; fi
  step "Setting kvm ignore_msrs=1"
  if ! grep -qs 'ignore_msrs=1' /etc/modprobe.d/*.conf; then
    run $SUDO tee /etc/modprobe.d/imessage-box-kvm.conf >/dev/null <<<"options kvm ignore_msrs=1 report_ignored_msrs=0"
  fi
  if [[ "$DRY_RUN" == 1 ]]; then run "echo 1 > /sys/module/kvm/parameters/ignore_msrs"
  else echo 1 | $SUDO tee /sys/module/kvm/parameters/ignore_msrs >/dev/null; fi
}

# ------------------------------------------------------------------ downloads (cached)
fetch() { # URL OUT SHA256
  local url="$1" out="$2" sha="$3"
  if [[ -f "$out" ]] && echo "$sha  $out" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  log "downloading $url"
  run curl -fL --retry 3 -C - -o "$out.part" "$url"
  [[ "$DRY_RUN" == 1 ]] && return 0
  echo "$sha  $out.part" | sha256sum -c --quiet - || { rm -f "$out.part"; die "checksum mismatch for $url"; }
  mv "$out.part" "$out"
}

downloads() {
  step "Downloading (cached in $CACHE_DIR)"
  if [[ ! -f "$OSXKVM/OpenCore/OpenCore.qcow2" ]]; then
    log "OSX-KVM @ ${OSXKVM_COMMIT:0:12}"
    run rm -rf "$OSXKVM.tmp"
    run git init -q "$OSXKVM.tmp"
    run git -C "$OSXKVM.tmp" fetch -q --depth 1 "$OSXKVM_REPO" "$OSXKVM_COMMIT"
    run git -C "$OSXKVM.tmp" checkout -q FETCH_HEAD
    run mv "$OSXKVM.tmp" "$OSXKVM"
  fi
  fetch "https://github.com/acidanthera/OpenCorePkg/releases/download/$OPENCORE_VERSION/OpenCore-$OPENCORE_VERSION-RELEASE.zip" \
    "$CACHE_DIR/OpenCore-$OPENCORE_VERSION-RELEASE.zip" "$OPENCORE_SHA256"
  if [[ ! -x "$CACHE_DIR/macserial" && "$DRY_RUN" != 1 ]]; then
    python3 - "$CACHE_DIR/OpenCore-$OPENCORE_VERSION-RELEASE.zip" "$CACHE_DIR/macserial" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as f:
    f.write(z.read("Utilities/macserial/macserial.linux"))
EOF
    chmod 755 "$CACHE_DIR/macserial"
  fi
  fetch "https://github.com/BlueBubblesApp/bluebubbles-server/releases/download/v$BB_VERSION/BlueBubbles-$BB_VERSION-mac.zip" \
    "$BB_ZIP" "$BB_SHA256"
  if [[ ! -f "$INSTALLER_IMG" ]]; then
    mkdir -p "$MACOS_DIR"
    if [[ ! -f "$MACOS_DIR/BaseSystem.dmg.ok" ]]; then
      log "macOS $MACOS recovery image from Apple (~700 MB, verified against Apple's chunklist)"
      run rm -f "$MACOS_DIR/BaseSystem.dmg" "$MACOS_DIR/BaseSystem.chunklist"
      run boxctl fetch-macos "$OSXKVM/fetch-macOS-v2.py" "$MACOS" "$MACOS_DIR" > "$LOGS/fetch-macos.log" 2>&1 \
        || die "macOS download failed; see $LOGS/fetch-macos.log"
      grep -q 'Image verification complete' "$LOGS/fetch-macos.log" || [[ "$DRY_RUN" == 1 ]] \
        || die "macOS recovery image failed verification; see $LOGS/fetch-macos.log"
      run touch "$MACOS_DIR/BaseSystem.dmg.ok"
    fi
    convert_installer
  fi
  ok "downloads ready"
}

convert_installer() {
  local dmg="$MACOS_DIR/BaseSystem.dmg" out="$INSTALLER_IMG"
  log "converting BaseSystem.dmg to a raw disk image"
  [[ "$DRY_RUN" == 1 ]] && { run qemu-img convert -f dmg -O raw "$dmg" "$out"; return 0; }
  if qemu-img convert -f dmg -O raw "$dmg" "$out.part" 2>"$LOGS/convert.log"; then mv "$out.part" "$out"; return 0; fi
  rm -f "$out.part"
  log "qemu-img cannot read this dmg ($(tail -1 "$LOGS/convert.log")); using dmg2img"
  if ! have dmg2img && [[ ! -x "$CACHE_DIR/dmg2img/dmg2img" ]]; then
    case "$(detect_pm)" in
      apt) $SUDO apt-get install -y dmg2img ;;
      dnf) $SUDO dnf install -y dmg2img ;;
      *) # not packaged (Arch: AUR only): build it
        if ! have gcc || ! have make; then die "need gcc and make to build dmg2img (Arch: sudo pacman -S --needed base-devel)"; fi
        rm -rf "$CACHE_DIR/dmg2img"
        git clone -q --depth 1 https://github.com/Lekensteyn/dmg2img.git "$CACHE_DIR/dmg2img"
        make -C "$CACHE_DIR/dmg2img" dmg2img >"$LOGS/dmg2img-build.log" 2>&1 || die "dmg2img build failed; see $LOGS/dmg2img-build.log" ;;
    esac
  fi
  local d2i; d2i="$(command -v dmg2img || echo "$CACHE_DIR/dmg2img/dmg2img")"
  "$d2i" -i "$dmg" "$out.part" >"$LOGS/convert.log" 2>&1 || die "dmg2img failed; see $LOGS/convert.log"
  mv "$out.part" "$out"
}

# ------------------------------------------------------------------ identity + secrets
secrets_gen() {
  step "Generating this box's identity and passwords"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would write passwords, ssh key and SMBIOS into $SECRETS"; return 0; }
  umask 077
  [[ -s "$SECRETS/vnc-password" ]] || boxctl randpw 8 > "$SECRETS/vnc-password"   # VNC auth max is 8
  [[ -s "$SECRETS/mac-user-password" ]] || boxctl randpw 20 > "$SECRETS/mac-user-password"
  [[ -s "$SECRETS/bluebubbles-password" ]] || boxctl randpw 32 > "$SECRETS/bluebubbles-password"
  [[ -s "$SECRETS/prov-token" ]] || boxctl randpw 16 > "$SECRETS/prov-token"
  [[ -s "$SECRETS/guest-guid" ]] || python3 -c 'import uuid; print(str(uuid.uuid4()).upper())' > "$SECRETS/guest-guid"
  [[ -f "$SECRETS/guest_ssh_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C "$VM_NAME-host" -f "$SECRETS/guest_ssh_ed25519"
  [[ -s "$SECRETS/kcpassword" ]] || boxctl kcpassword "$SECRETS/mac-user-password" "$SECRETS/kcpassword"
  # Unique Mac identity (serial/MLB/UUID/ROM). Generated once and kept: changing it later
  # looks like a new Mac to Apple and de-registers iMessage.
  [[ -s "$SECRETS/smbios-serial" ]] || boxctl smbios "$CACHE_DIR/macserial" "$SMBIOS_MODEL" "$SECRETS"
  chmod 600 "$SECRETS"/*
  ok "identity ready (values stay in $SECRETS, mode 600)"
}

# ------------------------------------------------------------------ OpenCore + disks
build_vm() {
  step "Preparing OpenCore and the VM disk"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would build OpenCore images (install/recovery/run) and a ${DISK_GB}G disk in $VMD"; return 0; }
  # nodatacow on btrfs before any image exists, or the qcow2 fragments badly
  if [[ "$(stat -f -c %T "$VMD")" == btrfs ]]; then chattr +C "$VMD" 2>/dev/null || true; fi
  cp -n "$OSXKVM/OVMF_CODE_4M.fd" "$VMD/OVMF_CODE_4M.fd"
  [[ -f "$VMD/OVMF_VARS.fd" ]] || cp "$OSXKVM/OVMF_VARS-1920x1080.fd" "$VMD/OVMF_VARS.fd"
  # Apple's SMC key is read from OSX-KVM's launcher, not shipped here.
  grep -o 'osk="[^"]*"' "$OSXKVM/OpenCore-Boot.sh" | head -1 | cut -d'"' -f2 > "$VMD/osk"
  [[ -s "$VMD/osk" ]] || die "could not read the applesmc key from OSX-KVM/OpenCore-Boot.sh"
  local raw m plist
  raw="$(mktemp -p "$VMD" oc.XXXXXX.raw)"
  qemu-img convert -O raw "$OSXKVM/OpenCore/OpenCore.qcow2" "$raw"
  export MTOOLS_SKIP_CHECK=1
  mdir -i "$raw@@1M" ::/EFI/OC/Kexts/MCEReporterDisabler.kext >/dev/null 2>&1 || warn "OpenCore image layout changed (no MCEReporterDisabler.kext)"
  for m in install recovery run; do
    plist="$VMD/config-$m.plist"
    boxctl opencore "$OSXKVM/OpenCore/config.plist" "$plist" "$m" "$SECRETS" "$SIP"
    mcopy -o -i "$raw@@1M" "$plist" ::/EFI/OC/config.plist
    mcopy -n -i "$raw@@1M" ::/EFI/OC/config.plist - | cmp -s - "$plist" || die "OpenCore config did not land in the image"
    qemu-img convert -c -O qcow2 "$raw" "$VMD/opencore-$m.qcow2"
  done
  rm -f "$raw"
  chmod 600 "$VMD"/opencore-*.qcow2 "$VMD"/config-*.plist
  ok "OpenCore images: install, recovery, run (SIP $SIP)"
}

new_disk() {
  log "creating a blank ${DISK_GB}G disk"
  rm -f "$VMD/disk.qcow2" "$VMD/base.qcow2"
  qemu-img create -q -f qcow2 "$VMD/disk.qcow2" "${DISK_GB}G"
  cp "$OSXKVM/OVMF_VARS-1920x1080.fd" "$VMD/OVMF_VARS.fd"
}

# ------------------------------------------------------------------ install-time server
GURL=""
write_serve() { # STAGE1_DRYRUN
  local token; token="$(cat "$SECRETS/prov-token")"
  GURL="http://10.0.2.2:$PROV_PORT/$token"
  umask 077
  cp "$BOX_DIR"/guest/stage1.sh "$BOX_DIR"/guest/stage2.sh "$BOX_DIR"/guest/firstboot.sh "$SERVE/"
  cp "$SECRETS/guest_ssh_ed25519.pub" "$SERVE/authorized_keys"
  cp "$SECRETS/kcpassword" "$SERVE/kcpassword"
  ln -sf "$BB_ZIP" "$SERVE/bluebubbles.zip"
  cat > "$SERVE/box.env" <<EOF
DISK_BYTES=$DISK_BYTES
STAGE1_DRYRUN=${1:-0}
VM_NAME='$VM_NAME'
GUEST_USER='$GUEST_USER'
GUEST_FULLNAME='$GUEST_FULLNAME'
GUEST_UID=501
GUEST_GUID='$(cat "$SECRETS/guest-guid")'
GUEST_PASSWORD='$(cat "$SECRETS/mac-user-password")'
GUEST_TZ='$GUEST_TZ'
BB_PASSWORD='$(cat "$SECRETS/bluebubbles-password")'
SERVER_URL='$(server_url)'
REPORT_URL='$GURL'
EOF
}

SERVER_PID=""
start_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then return 0; fi
  python3 "$LIB/boxctl.py" serve "$SERVE" "$PROV_PORT" "$(cat "$SECRETS/prov-token")" "$EVENTS" > >(tee -a "$LOGS/provision-server.log") 2>&1 &
  SERVER_PID=$!
  sleep 1
  kill -0 "$SERVER_PID" 2>/dev/null || die "install server could not start on 127.0.0.1:$PROV_PORT; see $LOGS/provision-server.log"
}
stop_server() { if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; }
trap stop_server EXIT

vm_start() { echo "$1" > "$VMD/boot-mode"; BOOT_MODE="$1" "$BOX_DIR/vm.sh" start; }
vm_kill() { # stop without guest cooperation (installer phases have no ssh)
  local pid i
  pid="$(vm_pid)" || return 0
  boxctl powerdown "$QMP_SOCK" 2>/dev/null || true
  for ((i = 0; i < ${1:-60}; i++)); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  boxctl quit "$QMP_SOCK" 2>/dev/null || true
  sleep 3; kill "$pid" 2>/dev/null || true
}
shot() { boxctl shot "$QMP_TOOL" "$SHOTS/$1.png" >/dev/null 2>&1 || true; }
vnc_hint() { echo "Watch it over VNC at $BIND_ADDR:$VNC_PORT (password in $SECRETS/vnc-password; ./vm.sh vnc)"; }

# Wait for macOS Recovery, open its Terminal (Shift-Cmd-T) and type a one-line bootstrap.
recovery_run() { # SCRIPT START_EVENT
  local script="$1" event="$2" attempt from
  log "waiting for macOS Recovery to come up (about 3-5 min)"
  for attempt in 1 2 3 4 5; do
    boxctl wait-screen "$QMP_TOOL" --min 12 --max 70 --max-sat 40 --stable 15 --timeout $(( attempt == 1 ? 1200 : 120 )) \
      || { shot "recovery-timeout"; die "macOS Recovery did not appear. Screenshot: $SHOTS/recovery-timeout.png. $(vnc_hint)"; }
    shot "recovery-$attempt"
    from="$(event_lines)"
    boxctl key "$QMP_TOOL" esc
    sleep 1
    boxctl key "$QMP_TOOL" shift-meta-t
    sleep 8
    boxctl type "$QMP_TOOL" "B=$GURL; curl -fsSo /tmp/s \$B/f/$script && bash /tmp/s \$B"
    boxctl key "$QMP_TOOL" ret
    if wait_event "$event" 90 "$from"; then ok "Recovery Terminal is running $script"; return 0; fi
    shot "recovery-$attempt-after"
    warn "no answer from $script yet (attempt $attempt); retrying"
  done
  die "could not drive Recovery Terminal. Screenshots: $SHOTS/recovery-*.png. $(vnc_hint)"
}

# ------------------------------------------------------------------ install phases
phase_macos() {
  is_done macos-installed && return 0
  step "Installing macOS (unattended; downloads ~12 GB from Apple, about 30 min)"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would boot Recovery, run stage1.sh (erase + startosinstall) and wait for Setup Assistant"; return 0; }
  write_serve 0
  start_server
  local from; from="$(cat "$PROGRESS/stage1-from" 2>/dev/null || echo 0)"
  if is_done stage1-started && ! vm_running && ! wait_event installing 0 "$from"; then
    warn "the last install stopped before startosinstall ran; starting over"
    unmark stage1-started
  fi
  if ! is_done stage1-started; then
    vm_kill 5
    new_disk
    from="$(event_lines)"; echo "$from" > "$PROGRESS/stage1-from"
    vm_start install
    recovery_run stage1.sh stage1-start
    mark stage1-started
  elif ! vm_running; then
    log "resuming: booting the staged installer"
    vm_start install
  else
    log "resuming: the install is already running"
    boxctl key "$QMP_TOOL" shift   # wakes a blanked Setup Assistant if the install already finished
  fi
  wait_event erased 600 "$from" "stage1-error" || die "stage1 did not erase the disk; see $EVENTS. $(vnc_hint)"
  wait_event installing 120 "$from" "stage1-error" || die "startosinstall did not start; see $EVENTS"
  log "startosinstall is running; the VM reboots a few times. $(vnc_hint)"
  # Done = Setup Assistant's colourful screen (the installer screens are black).
  # Setup Assistant animates (so no stillness check) and blanks itself when idle (so --wake).
  if ! boxctl wait-screen "$QMP_TOOL" --min 70 --max 255 --min-sat 30 --stable 20 --changing --wake 60 --timeout $((INSTALL_TIMEOUT_MIN * 60)); then
    shot install-timeout
    die "macOS install did not finish in $INSTALL_TIMEOUT_MIN min. Screenshot: $SHOTS/install-timeout.png; guest log: $EVENTS. Re-run ./install.sh to keep waiting. $(vnc_hint)"
  fi
  shot install-done
  ok "macOS is installed (Setup Assistant reached)"
  vm_kill 60
  mark macos-installed
}

phase_provision() {
  is_done provisioned && return 0
  step "Creating the user and first-boot setup from Recovery (about 3 min)"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would boot Recovery and run stage2.sh"; return 0; }
  write_serve 0
  start_server
  vm_kill 30
  vm_start recovery
  local from; from="$(event_lines)"
  recovery_run stage2.sh stage2-start
  wait_event stage2-done 900 "$from" "stage2-error" || die "stage2 failed; see $EVENTS. $(vnc_hint)"
  local i
  for ((i = 0; i < 120; i++)); do vm_running || break; sleep 2; done
  vm_kill 10
  mark provisioned
}

phase_firstboot() {
  is_done firstboot && return 0
  step "First boot: BlueBubbles install and configuration (about 5-8 min)"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would boot macOS and wait for firstboot.sh + BlueBubbles"; return 0; }
  write_serve 0
  start_server
  local from; from="$(event_lines)"
  vm_running || vm_start run
  wait_event firstboot-done 2400 "$from" "firstboot-error" || die "first boot did not finish; see $EVENTS and, in the guest, /Library/imessage-box/firstboot.log (./vm.sh ssh). $(vnc_hint)"
  tail -n +"$((from + 1))" "$EVENTS" | grep -qE '^[^ ]+ permissions-manual' && warn "BlueBubbles still needs Full Disk Access: grant it over VNC (README, 'Manual permissions')"
  local i
  for ((i = 0; i < 60; i++)); do bb_api ping 2>/dev/null | grep -q pong && break; sleep 10; done
  bb_api ping 2>/dev/null | grep -q pong || die "BlueBubbles does not answer on $(local_addr):$BB_PORT. $(vnc_hint)"
  timeout 30 "${GSSH[@]}" true || die "guest ssh is not answering on 127.0.0.1:$SSH_PORT. $(vnc_hint)"
  ok "BlueBubbles answers on $(local_addr):$BB_PORT"
  mark firstboot
}

phase_snapshot() {
  [[ "$SNAPSHOT" == 1 ]] || return 0
  is_done snapshot && return 0
  step "Saving the clean install as the base image"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would stop the VM and turn disk.qcow2 into base.qcow2 + overlay"; return 0; }
  "$BOX_DIR/vm.sh" stop
  (cd "$VMD" && mv disk.qcow2 base.qcow2 && chmod 444 base.qcow2 \
    && qemu-img create -q -f qcow2 -b base.qcow2 -F qcow2 disk.qcow2)
  cp "$VMD/OVMF_VARS.fd" "$VMD/OVMF_VARS.base.fd"
  ok "base image saved ($(du -h "$VMD/base.qcow2" | cut -f1)); ./vm.sh reset returns here"
  mark snapshot
}

phase_service() {
  [[ "$DRY_RUN" == 1 ]] || echo run > "$VMD/boot-mode"
  if [[ "$SERVICE" == 1 ]] && have systemctl && [[ -d /run/systemd/system ]]; then
    step "Installing systemd unit $VM_NAME.service"
    local unit="/etc/systemd/system/$VM_NAME.service" after="network-online.target"
    systemctl cat tailscaled.service >/dev/null 2>&1 && after+=" tailscaled.service"
    local body
    body="[Unit]
Description=imessage-box macOS VM ($VM_NAME)
Wants=$after
After=$after

[Service]
Type=forking
User=$(id -un)
Group=$(id -gn)
Environment=BOX_CONF=$BOX_CONF
ExecStart=$BOX_DIR/vm.sh start
ExecStop=$BOX_DIR/vm.sh stop 150
PIDFile=$PIDFILE
TimeoutStartSec=300
TimeoutStopSec=200
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target"
    if [[ "$DRY_RUN" == 1 ]]; then printf '  [dry-run] would write %s:\n%s\n' "$unit" "$body"; return 0; fi
    if [[ "$(cat "$unit" 2>/dev/null)" != "$body" ]]; then
      $SUDO tee "$unit" >/dev/null <<<"$body"
      $SUDO systemctl daemon-reload
    fi
    if ! systemctl is-active --quiet "$VM_NAME.service"; then
      "$BOX_DIR/vm.sh" stop >/dev/null 2>&1 || true   # a VM started outside systemd
      $SUDO systemctl enable --now "$VM_NAME.service"
    else
      $SUDO systemctl enable --quiet "$VM_NAME.service"
    fi
    ok "$VM_NAME.service enabled and running (starts with the host)"
  else
    run "$BOX_DIR/vm.sh" start
  fi
}

smoke_test() {
  step "Smoke test: boot macOS Recovery and run stage1 in dry-run mode"
  [[ "$DRY_RUN" == 1 ]] && { log "[dry-run] would boot Recovery and run stage1.sh with STAGE1_DRYRUN=1"; return 0; }
  is_done macos-installed && die "macOS is already installed here; the smoke test would wipe it"
  write_serve 1
  start_server
  vm_kill 5
  new_disk
  vm_start install
  local from; from="$(event_lines)"
  recovery_run stage1.sh stage1-start
  wait_event stage1-dryrun-ok 120 "$from" "stage1-error" || die "stage1 dry run failed; see $EVENTS"
  grep -E '^[^ ]+ (disk-found|installer|stage1-dryrun-ok) ' "$EVENTS" | tail -3
  shot smoke-done
  vm_kill 20
  rm -f "$VMD/disk.qcow2"
  unmark stage1-started
  ok "smoke test passed: KVM boots macOS Recovery, the Terminal automation works, the VM disk and installer are visible"
}

# ------------------------------------------------------------------ main
[[ -n "$GUEST_TZ" ]] || GUEST_TZ="$( (timedatectl show -p Timezone --value 2>/dev/null || readlink /etc/localtime | sed 's|.*/zoneinfo/||') | head -1)"
preflight
[[ "$MODE" == check ]] && exit 0
deps
kvm_tuning
downloads
secrets_gen
is_done vm-built || { build_vm; mark vm-built; }
if [[ "$MODE" == smoke ]]; then smoke_test; exit 0; fi
phase_macos
phase_provision
phase_firstboot
phase_snapshot
phase_service
[[ "$DRY_RUN" == 1 ]] && { ok "dry run finished; nothing was changed"; exit 0; }
step "Done"
if [[ "$SNAPSHOT" == 1 ]] || ! bb_api ping 2>/dev/null | grep -q pong; then
  log "waiting for the VM to boot and BlueBubbles to answer"
  for _ in $(seq 1 36); do bb_api ping 2>/dev/null | grep -q pong && break; sleep 5; done
fi
"$BOX_DIR/status.sh" || true
cat <<EOF

Next: sign in to iMessage (needs your Apple ID and the code Apple sends to your iPhone):
  ./signin.sh

BlueBubbles client settings: URL $(server_url), password in $SECRETS/bluebubbles-password
EOF
