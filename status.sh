#!/usr/bin/env bash
# Is the box working? VM, BlueBubbles API and the iMessage account it detects.
# Exit status: 0 all good, 1 VM or BlueBubbles down, 2 up but not signed in to iMessage.
set -uo pipefail
. "$(dirname "$0")/lib/common.sh"

rc=0
if pid="$(vm_pid)"; then
  printf 'VM           running (%s, pid %s, up %s)\n' "$VM_NAME" "$pid" "$(ps -o etime= -p "$pid" | tr -d ' ')"
else
  printf 'VM           not running\n'; rc=1
fi
if systemctl cat "$VM_NAME.service" >/dev/null 2>&1; then
  printf 'service      %s.service %s, %s\n' "$VM_NAME" "$(systemctl is-enabled "$VM_NAME.service" 2>/dev/null)" "$(systemctl is-active "$VM_NAME.service" 2>/dev/null)"
fi

if [[ ! -f "$SECRETS/bluebubbles-password" ]]; then
  printf 'BlueBubbles  not installed yet (run ./install.sh)\n'; exit 1
fi
if bb_api ping 2>/dev/null | grep -q pong; then
  info="$(bb_api server/info 2>/dev/null)"
  python3 - "$info" <<'EOF'
import json, sys
d = json.loads(sys.argv[1]).get("data", {})
print("BlueBubbles  up (server %s on macOS %s, proxy %s, private API %s)" % (
    d.get("server_version"), d.get("os_version"), d.get("proxy_service"), "on" if d.get("private_api") else "off"))
acct = d.get("detected_imessage")
print("iMessage     " + ("signed in as %s" % acct if acct else "not signed in (run ./signin.sh)"))
sys.exit(0 if acct else 2)
EOF
  r=$?; (( rc == 0 )) && rc=$r
else
  printf 'BlueBubbles  not answering on %s:%s\n' "$(local_addr)" "$BB_PORT"; rc=1
fi

printf 'client URL   %s (password: %s)\n' "$(server_url)" "$SECRETS/bluebubbles-password"
printf 'VNC          %s:%s (password: %s)\n' "$BIND_ADDR" "$VNC_PORT" "$SECRETS/vnc-password"
exit "$rc"
