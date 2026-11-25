#!/usr/bin/env bash
# Sign the box in to iMessage. Asks for your Apple ID, password and the 2FA code Apple sends to
# your iPhone, and types them into Messages inside the VM. Nothing is stored or logged.
#   ./signin.sh           sign in
#   ./signin.sh --force   try again even if BlueBubbles already sees an iMessage account
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

FORCE=0
[[ "${1:-}" == --force ]] && FORCE=1

imessage_account() {
  bb_api server/info 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("detected_imessage") or "")' 2>/dev/null || true
}

vm_running || die "the VM is not running (sudo systemctl start $VM_NAME, or ./vm.sh start)"
bb_api ping 2>/dev/null | grep -q pong || die "BlueBubbles is not answering yet; give the VM a minute after boot and retry (./status.sh)"
acct="$(imessage_account)"
if [[ -n "$acct" && "$FORCE" != 1 ]]; then ok "already signed in to iMessage as $acct"; exit 0; fi

cat <<'EOF'
This types your Apple ID into Messages in the VM. Tips:
 - A spare Apple ID is safest the first time: Apple can refuse or flag accounts used on VMs.
 - Only ASCII characters can be typed; a password with other characters has to go in over VNC.
EOF
read -r -p "Apple ID (email or phone): " APPLE_ID
[[ -n "$APPLE_ID" ]] || die "no Apple ID given"
read -r -s -p "Apple ID password: " APPLE_PW; echo
[[ -n "$APPLE_PW" ]] || die "no password given"

log "opening Messages"
guest_ssh 'killall Messages 2>/dev/null; sleep 2; open -a Messages' || true
sleep 8
mkdir -p "$SHOTS"
boxctl click "$QMP_TOOL" 640 354   # the Apple ID field of the sign-in sheet (1280x800 screen)
sleep 0.5
printf '%s\n' "$APPLE_ID" | boxctl type-stdin "$QMP_TOOL" || die "cannot type that Apple ID; sign in over VNC instead ($BOX_DIR/vm.sh vnc)"
boxctl key "$QMP_TOOL" ret
sleep 4
printf '%s\n' "$APPLE_PW" | boxctl type-stdin "$QMP_TOOL" || die "cannot type that password; sign in over VNC instead ($BOX_DIR/vm.sh vnc)"
unset APPLE_PW
boxctl key "$QMP_TOOL" ret

echo "Apple is sending a 6-digit code to your iPhone (or other trusted device)."
read -r -p "Code (press Enter if no code was asked for): " CODE
CODE="${CODE//[^0-9]/}"
if [[ -n "$CODE" ]]; then
  [[ ${#CODE} -eq 6 ]] || die "the code must be 6 digits; run ./signin.sh --force to try again"
  boxctl type "$QMP_TOOL" "$CODE"
fi

log "waiting for iMessage to activate (up to 3 min)"
for _ in $(seq 1 36); do
  acct="$(imessage_account)"
  [[ -n "$acct" ]] && break
  sleep 5
done
boxctl shot "$QMP_TOOL" "$SHOTS/signin.png" >/dev/null 2>&1 || true
if [[ -n "$acct" ]]; then
  ok "iMessage is signed in as $acct. BlueBubbles can send and receive now."
  echo "Client settings: URL $(server_url), password in $SECRETS/bluebubbles-password"
else
  warn "BlueBubbles does not see an iMessage account yet. Screenshot: $SHOTS/signin.png"
  echo "Apple sometimes needs a few minutes, or shows an extra prompt. Check the screen over VNC:"
  "$BOX_DIR/vm.sh" vnc
  exit 1
fi
