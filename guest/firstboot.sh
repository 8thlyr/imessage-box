#!/bin/bash
# First boot of the installed macOS, as root from a one-shot LaunchDaemon (written by stage2.sh).
# Applies system settings, installs and configures BlueBubbles and grants its privacy
# permissions. Reports progress to the host install server when it is up.
L=/Library/imessage-box
[ -f "$L/.done" ] && exit 0
# shellcheck source=/dev/null
. "$L/box.env"
B="$REPORT_URL"
r() { curl -fsS -m 10 -G "$B/report" --data-urlencode "s=$1" --data-urlencode "m=${2:-}" >/dev/null 2>&1 || true; }
log() { echo "$(date '+%F %T') $*"; }
step() { log "$1 ${2:-}"; r "$1" "${2:-}"; }

for _ in $(seq 1 60); do curl -fsS -m 5 -o /dev/null "$B/report?s=net-up" && break; sleep 5; done
step firstboot-start "macOS $(sw_vers -productVersion) $(csrutil status 2>/dev/null | head -1)"

# --- system settings
scutil --set ComputerName "$VM_NAME"; scutil --set LocalHostName "$VM_NAME"; scutil --set HostName "$VM_NAME"
[ -n "$GUEST_TZ" ] && systemsetup -settimezone "$GUEST_TZ" >/dev/null 2>&1
pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 womp 1 autorestart 1
systemsetup -setcomputersleep Never >/dev/null 2>&1
systemsetup -setdisplaysleep Never >/dev/null 2>&1
softwareupdate --schedule off >/dev/null 2>&1
for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do
  defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool false
done
launchctl enable system/com.openssh.sshd
launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null
step system-settings "sleep off, updates off, ssh on"

# --- BlueBubbles app
APP=/Applications/BlueBubbles.app
if [ ! -d "$APP" ]; then
  rm -rf /tmp/bbx; mkdir -p /tmp/bbx
  if ! { ditto -x -k "$L/bluebubbles.zip" /tmp/bbx && ditto /tmp/bbx/BlueBubbles.app "$APP"; }; then
    step firstboot-error "BlueBubbles unzip failed"; exit 1
  fi
  rm -rf /tmp/bbx
  xattr -dr com.apple.quarantine "$APP"
fi
chown -R "$GUEST_USER:staff" "$APP"
step bluebubbles-installed "$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"

# --- wait for auto-login. The very first boot of a freshly installed macOS shows the login
# window even with kcpassword + autoLoginUser set (seen in testing); the next boot logs in.
for _ in $(seq 1 24); do [ "$(stat -f %Su /dev/console)" = "$GUEST_USER" ] && break; sleep 5; done
if [ "$(stat -f %Su /dev/console)" != "$GUEST_USER" ]; then
  n=$(cat "$L/.loginreboots" 2>/dev/null || echo 0)
  if [ "$n" -lt 2 ]; then
    echo $((n + 1)) > "$L/.loginreboots"
    step login-reboot "no auto-login yet (console: $(stat -f %Su /dev/console)); rebooting once"
    shutdown -r now
    exit 0
  fi
  step firstboot-error "auto-login did not happen after $n reboots (console: $(stat -f %Su /dev/console))"
  exit 1
fi
UID_N=$(id -u "$GUEST_USER")
HOME_D="/Users/$GUEST_USER"
au() { launchctl asuser "$UID_N" sudo -u "$GUEST_USER" "$@"; }
step logged-in "$GUEST_USER"
sleep 20
pkill -f KeyboardSetupAssistant 2>/dev/null
au defaults -currentHost write com.apple.screensaver idleTime -int 0
au defaults write com.apple.screensaver askForPassword -int 0

# --- BlueBubbles config: first launch creates config.db, then we set it before it is ever used.
DB="$HOME_D/Library/Application Support/bluebubbles-server/config.db"
q() { sqlite3 "$DB" "$1"; }
if [ ! -f "$L/.bbconfig" ]; then
  au open -g -a "$APP"
  for _ in $(seq 1 60); do
    [ -f "$DB" ] && [ "$(q "select count(*) from config where name='proxy_service'" 2>/dev/null)" = 1 ] && break
    sleep 3
  done
  sleep 5
  osascript -e 'quit app "BlueBubbles"' >/dev/null 2>&1; sleep 3; pkill -f BlueBubbles.app; sleep 2; pkill -9 -f BlueBubbles.app
  pkill -f cloudflared; pkill -f ngrok; pkill -f zrok
  [ -f "$DB" ] || { step firstboot-error "BlueBubbles did not create config.db"; exit 1; }
  set_cfg() { q "update config set value='$2' where name='$1'"; [ "$(q "select count(*) from config where name='$1'")" = 1 ] || q "insert into config (name, value) values ('$1', '$2')"; }
  set_cfg proxy_service dynamic-dns
  set_cfg server_address "$SERVER_URL"
  set_cfg socket_port 1234
  set_cfg password "$BB_PASSWORD"
  set_cfg auto_caffeinate 1
  set_cfg check_for_updates 0
  set_cfg auto_install_updates 0
  set_cfg open_findmy_on_startup 0
  set_cfg enable_private_api 0
  set_cfg start_minimized 1
  set_cfg tutorial_is_done 1
  set_cfg auto_start 0
  set_cfg auto_start_method none
  touch "$L/.bbconfig"
  step bluebubbles-configured "proxy=dynamic-dns url=$SERVER_URL"
fi

# --- start BlueBubbles at every login
LA="$HOME_D/Library/LaunchAgents/local.imessagebox.bluebubbles.plist"
cat > "$LA" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.imessagebox.bluebubbles</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>/Applications/BlueBubbles.app</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
chown "$GUEST_USER:staff" "$LA"; chmod 644 "$LA"

# --- privacy permissions (TCC). Needs SIP off; otherwise they are a VNC step (see README).
csreq_hex() {
  local req
  req=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p')
  [ -n "$req" ] || return 1
  echo "$req" | csreq -r- -b /tmp/csreq.bin >/dev/null 2>&1 || return 1
  xxd -p /tmp/csreq.bin | tr -d '\n'
  rm -f /tmp/csreq.bin
}
tcc() { # DB SERVICE CLIENT CSREQ_HEX [TARGET_ID TARGET_CSREQ_HEX]
  local itype=NULL iid=UNUSED ireq=NULL
  if [ -n "${5:-}" ]; then itype=0; iid="$5"; ireq="X'$6'"; fi
  sqlite3 "$1" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('$2', '$3', 0, 2, 3, 1, X'$4', NULL, $itype, '$iid', $ireq, 0, CAST(strftime('%s','now') AS INTEGER));"
}
BBID=$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)
BBREQ=$(csreq_hex "$APP")
MSGREQ=$(csreq_hex /System/Applications/Messages.app)
SEREQ=$(csreq_hex /System/Library/CoreServices/System\ Events.app)
SYSDB="/Library/Application Support/com.apple.TCC/TCC.db"
USRDB="$HOME_D/Library/Application Support/com.apple.TCC/TCC.db"
for _ in $(seq 1 24); do [ -f "$USRDB" ] && break; sleep 5; done
tccok=1
if [ -n "$BBREQ" ] && csrutil status | grep -q disabled; then
  tcc "$SYSDB" kTCCServiceSystemPolicyAllFiles "$BBID" "$BBREQ" || tccok=0
  tcc "$SYSDB" kTCCServiceAccessibility "$BBID" "$BBREQ" || tccok=0
  tcc "$USRDB" kTCCServiceAddressBook "$BBID" "$BBREQ" || tccok=0
  [ -n "$MSGREQ" ] && { tcc "$USRDB" kTCCServiceAppleEvents "$BBID" "$BBREQ" com.apple.MobileSMS "$MSGREQ" || tccok=0; }
  [ -n "$SEREQ" ] && { tcc "$USRDB" kTCCServiceAppleEvents "$BBID" "$BBREQ" com.apple.systemevents "$SEREQ" || tccok=0; }
  killall tccd 2>/dev/null
else
  tccok=0
fi
if [ "$tccok" = 1 ]; then
  step permissions "Full Disk Access, Accessibility, Contacts, Automation granted"
else
  step permissions-manual "grant BlueBubbles Full Disk Access over VNC (SIP: $(csrutil status | head -1))"
fi

# --- start BlueBubbles and check it answers
au open -g -a "$APP"
bb=down
for _ in $(seq 1 60); do
  curl -fsS -m 5 -G http://127.0.0.1:1234/api/v1/ping --data-urlencode "password=$BB_PASSWORD" 2>/dev/null | grep -q pong && { bb=up; break; }
  sleep 5
done
pgrep -lf 'cloudflared|ngrok|zrok' >/dev/null && step firstboot-error "a tunnel process is running"
step bluebubbles "$bb"

touch "$L/.done"
rm -f /Library/LaunchDaemons/com.imessagebox.firstboot.plist "$L/bluebubbles.zip"
step firstboot-done "bluebubbles=$bb"
