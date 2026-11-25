# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this
# Shared config, logging and helpers for imessage-box scripts. Sourced, never run.

BOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$BOX_DIR/lib"

# Config: box.conf in the repo (or $BOX_CONF) overrides these defaults.
BOX_CONF="${BOX_CONF:-$BOX_DIR/box.conf}"
# shellcheck source=/dev/null
[[ -f "$BOX_CONF" ]] && . "$BOX_CONF"

VM_NAME="${VM_NAME:-imessage-box}"
STATE_DIR="${STATE_DIR:-$BOX_DIR/state}"
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/imessage-box}"

MACOS="${MACOS:-ventura}"            # recovery shortname for fetch-macOS-v2.py; only ventura is tested
RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_GB="${DISK_GB:-64}"
NICE="${NICE:-10}"

BIND_ADDR="${BIND_ADDR:-127.0.0.1}"  # host address for BlueBubbles + VNC; a tailnet IP is a good choice
BB_PORT="${BB_PORT:-1234}"           # host port forwarded to BlueBubbles (guest 1234)
VNC_PORT="${VNC_PORT:-5910}"         # must be 5900-5999 (QEMU display = port - 5900)
SSH_PORT="${SSH_PORT:-2222}"         # guest ssh, always bound to 127.0.0.1
PROV_PORT="${PROV_PORT:-8767}"       # install-time file server, 127.0.0.1 only (guest sees it as 10.0.2.2)
SERVER_URL="${SERVER_URL:-}"         # URL BlueBubbles advertises to clients; default http://BIND_ADDR:BB_PORT

GUEST_USER="${GUEST_USER:-imsg}"
GUEST_FULLNAME="${GUEST_FULLNAME:-iMessage}"
GUEST_TZ="${GUEST_TZ:-}"             # default: the host's time zone
SMBIOS_MODEL="${SMBIOS_MODEL:-iMacPro1,1}"
SIP="${SIP:-off}"                    # off lets firstboot grant BlueBubbles its privacy permissions without clicks
SNAPSHOT="${SNAPSHOT:-1}"            # keep a clean post-install base image; `./vm.sh reset` returns to it
INSTALL_TIMEOUT_MIN="${INSTALL_TIMEOUT_MIN:-150}"

# Pinned downloads (bump together with a test run).
OSXKVM_REPO="${OSXKVM_REPO:-https://github.com/kholia/OSX-KVM.git}"
OSXKVM_COMMIT="${OSXKVM_COMMIT:-4c378a4b5e0b219783683012bec680325eb40719}"
OPENCORE_VERSION="${OPENCORE_VERSION:-1.0.8}"
OPENCORE_SHA256="${OPENCORE_SHA256:-2011e8b7216ecb2645d97ea710df965947edd406846e92050b9bc4190be6d27b}"
BB_VERSION="${BB_VERSION:-1.9.12}"
BB_SHA256="${BB_SHA256:-7078ea4302b4df6ab4b236bdaea84440aabf95b2a07b281919fd0ef8822e958c}"

VMD="$STATE_DIR/vm"
SECRETS="$STATE_DIR/secrets"
LOGS="$STATE_DIR/logs"
SHOTS="$STATE_DIR/shots"
PROGRESS="$STATE_DIR/progress"
SERVE="$STATE_DIR/serve"
EVENTS="$LOGS/guest-events.log"
QMP_SOCK="$VMD/qmp.sock"
QMP_TOOL="$VMD/qmp-tools.sock"
PIDFILE="$VMD/qemu.pid"
OSXKVM="$CACHE_DIR/OSX-KVM-${OSXKVM_COMMIT:0:12}"
MACOS_DIR="$CACHE_DIR/macos-$MACOS"
INSTALLER_IMG="$MACOS_DIR/BaseSystem.img"
BB_ZIP="$CACHE_DIR/BlueBubbles-$BB_VERSION-mac.zip"

DRY_RUN="${DRY_RUN:-0}"

if [[ -t 2 ]]; then C_B=$'\e[1m' C_R=$'\e[31m' C_Y=$'\e[33m' C_G=$'\e[32m' C_0=$'\e[0m'; else C_B='' C_R='' C_Y='' C_G='' C_0=''; fi
log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_0" >&2; }
ok()   { printf '%s %s%s%s\n' "$(date '+%H:%M:%S')" "$C_G" "$*" "$C_0" >&2; }
warn() { printf '%s %sWARN:%s %s\n' "$(date '+%H:%M:%S')" "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s %sERROR:%s %s\n' "$(date '+%H:%M:%S')" "$C_R" "$C_0" "$*" >&2; exit 1; }

# run CMD...: execute, or print it under --dry-run.
run() { if [[ "$DRY_RUN" == 1 ]]; then printf '  [dry-run] %s\n' "$*" >&2; else "$@"; fi; }

have() { command -v "$1" >/dev/null 2>&1; }

boxctl() { python3 "$LIB/boxctl.py" "$@"; }

ensure_state_dirs() {
  umask 077
  mkdir -p "$STATE_DIR" "$VMD" "$SECRETS" "$LOGS" "$SHOTS" "$PROGRESS" "$SERVE" "$CACHE_DIR"
  chmod 700 "$STATE_DIR" "$SECRETS" "$SERVE"
}

# Progress markers make install.sh resumable.
is_done() { [[ -f "$PROGRESS/$1" ]]; }
mark()    { [[ "$DRY_RUN" == 1 ]] || date -Is > "$PROGRESS/$1"; }
unmark()  { rm -f "$PROGRESS/$1"; }

# Address the host uses to reach the forwarded ports itself.
local_addr() { if [[ "$BIND_ADDR" == 0.0.0.0 ]]; then echo 127.0.0.1; else echo "$BIND_ADDR"; fi; }
server_url() { echo "${SERVER_URL:-http://$(local_addr):$BB_PORT}"; }

vm_pid() {
  local pid
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
  # Only ever treat our own qemu as "the VM".
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "-name $VM_NAME " || return 1
  echo "$pid"
}
vm_running() { vm_pid >/dev/null; }

# bb_api PATH: call the BlueBubbles REST API with the stored password (never on the command line).
bb_api() {
  curl -fsS -m 10 -G "http://$(local_addr):$BB_PORT/api/v1/${1:-ping}" \
    --data-urlencode "password@$SECRETS/bluebubbles-password"
}

GSSH=(ssh -i "$SECRETS/guest_ssh_ed25519" -p "$SSH_PORT" -o IdentitiesOnly=yes
  -o UserKnownHostsFile="$SECRETS/guest_known_hosts" -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR "$GUEST_USER@127.0.0.1")
guest_ssh() { "${GSSH[@]}" "$@"; }

# wait_event STEP TIMEOUT_S [FROM_LINE] [FAIL_REGEX]: wait for a guest report line after FROM_LINE.
# Returns 0 found, 1 timeout, 2 FAIL_REGEX seen. (The install server prints reports as they arrive.)
wait_event() {
  local stepname="$1" timeout="$2" from="${3:-0}" fail="${4:-}" t=0 tailtxt
  while :; do
    if [[ -f "$EVENTS" ]]; then
      tailtxt="$(tail -n +"$((from + 1))" "$EVENTS")"
      if grep -qE "^[^ ]+ $stepname( |$)" <<<"$tailtxt"; then return 0; fi
      if [[ -n "$fail" ]] && grep -qE "^[^ ]+ ($fail)( |$)" <<<"$tailtxt"; then
        warn "guest reported: $(grep -E "^[^ ]+ ($fail)( |$)" <<<"$tailtxt" | tail -1)"
        return 2
      fi
    fi
    (( t >= timeout )) && return 1
    sleep 5; t=$((t + 5))
  done
}
event_lines() { if [[ -f "$EVENTS" ]]; then wc -l < "$EVENTS"; else echo 0; fi; }
