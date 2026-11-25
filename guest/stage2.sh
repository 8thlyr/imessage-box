#!/bin/bash
# Stage 2, runs as root in macOS Recovery after macOS is installed, before its first boot.
# Creates the local admin user, skips Setup Assistant, turns on auto-login and ssh, and drops
# a one-shot LaunchDaemon (firstboot.sh) that sets up BlueBubbles on the first real boot.
# Usage: bash stage2.sh http://10.0.2.2:PORT/TOKEN
B="$1"
r() { curl -fsS -m 15 -G "$B/report" --data-urlencode "s=$1" --data-urlencode "m=${2:-}" >/dev/null 2>&1 || true; }
fail() { r stage2-error "$1"; echo "imessage-box stage2 failed: $1"; exit 1; }
get() { curl -fsS -m 600 "$B/f/$1" -o "$2" || fail "cannot fetch $1"; }

r stage2-start "recovery $(sw_vers -productVersion 2>/dev/null)"
get box.env /tmp/box.env
# shellcheck source=/dev/null
. /tmp/box.env

# Installed macOS = an APFS System volume (has User Template) + an APFS Data volume (has dslocal).
# Recovery also mounts HFS volumes of its own that look similar, hence the APFS check.
is_apfs() { diskutil info "$1" 2>/dev/null | grep -qiE 'Type \(Bundle\): +apfs'; }
find_vols() {
  DATA=""; SYS=""
  for v in /Volumes/*; do
    is_apfs "$v" || continue
    [ -d "$v/private/var/db/dslocal/nodes/Default" ] && DATA="$v"
    [ -f "$v/System/Library/CoreServices/SystemVersion.plist" ] && [ -d "$v/System/Library/User Template" ] && SYS="$v"
  done
}
find_vols
if [ -z "$DATA" ] || [ -z "$SYS" ]; then
  for name in "Macintosh HD - Data" "Macintosh HD"; do diskutil mount "$name" >/dev/null 2>&1; done
  find_vols
fi
[ -n "$DATA" ] || fail "installed Data volume not found: $(echo /Volumes/*)"
OSVER=$(defaults read "$SYS/System/Library/CoreServices/SystemVersion" ProductVersion 2>/dev/null)
OSBUILD=$(defaults read "$SYS/System/Library/CoreServices/SystemVersion" ProductBuildVersion 2>/dev/null)
r volumes "data=$DATA system=${SYS:-?} macOS=$OSVER ($OSBUILD)"

# --- local admin user, written straight into the offline directory node
N="$DATA/private/var/db/dslocal/nodes/Default"
D() { dscl -f "$N" localhost "$@"; }
P="/Local/Default/Users/$GUEST_USER"
if ! D -read "$P" >/dev/null 2>&1; then
  D -create "$P" || fail "dscl create user"
  D -create "$P" UserShell /bin/zsh
  D -create "$P" RealName "$GUEST_FULLNAME"
  D -create "$P" UniqueID "$GUEST_UID"
  D -create "$P" PrimaryGroupID 20
  D -create "$P" NFSHomeDirectory "/Users/$GUEST_USER"
  D -create "$P" GeneratedUID "$GUEST_GUID"
  D -passwd "$P" "$GUEST_PASSWORD" || fail "dscl passwd"
  D -append /Local/Default/Groups/admin GroupMembership "$GUEST_USER"
  D -append /Local/Default/Groups/admin GroupMembers "$GUEST_GUID"
fi
D -read "$P" UniqueID >/dev/null 2>&1 || fail "user record missing after create"

H="$DATA/Users/$GUEST_USER"
if [ ! -d "$H" ]; then
  T="$SYS/System/Library/User Template"
  if [ -d "$T/Non_localized" ]; then
    ditto "$T/Non_localized" "$H"
    ditto "$T/English.lproj" "$H"
  else
    mkdir -p "$H"
  fi
fi
mkdir -p "$H/.ssh" "$H/Library/Preferences" "$H/Library/LaunchAgents"
get authorized_keys "$H/.ssh/authorized_keys"
chmod 700 "$H/.ssh"; chmod 600 "$H/.ssh/authorized_keys"

# Per-user "mini" Setup Assistant (Apple ID, Siri, Screen Time ...) is already "seen".
SA="$H/Library/Preferences/com.apple.SetupAssistant"
for k in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeScreenTime DidSeeAppearanceSetup \
  DidSeeAccessibility DidSeeTrueTone DidSeeTouchIDSetup DidSeeActivationLock DidSeeApplePaySetup \
  DidSeeSyncSetup DidSeeSyncSetup2 DidSeeiCloudLoginForStorageServices DidSeeLockdownMode \
  DidSeeAvatarSetup DidSeeTermsOfAddress SkipFirstLoginOptimization; do
  defaults write "$SA" "$k" -bool true
done
defaults write "$SA" GestureMovieSeen none
if [ -n "$OSVER" ]; then
  defaults write "$SA" LastSeenCloudProductVersion "$OSVER"
  defaults write "$SA" LastPreLoginTasksPerformedVersion "$OSVER"
fi
if [ -n "$OSBUILD" ]; then
  defaults write "$SA" LastSeenBuddyBuildVersion "$OSBUILD"
  defaults write "$SA" LastPreLoginTasksPerformedBuild "$OSBUILD"
fi
chown -R "$GUEST_UID:20" "$H"
r user-created "$GUEST_USER"

# --- system: skip Setup Assistant, auto-login, ssh, quiet updates, no tunnels
touch "$DATA/private/var/db/.AppleSetupDone"
get kcpassword "$DATA/private/etc/kcpassword"
chown 0:0 "$DATA/private/etc/kcpassword"; chmod 600 "$DATA/private/etc/kcpassword"
defaults write "$DATA/Library/Preferences/com.apple.loginwindow" autoLoginUser "$GUEST_USER"
mkdir -p "$DATA/private/var/db/com.apple.xpc.launchd"
defaults write "$DATA/private/var/db/com.apple.xpc.launchd/disabled" com.openssh.sshd -bool false
mkdir -p "$DATA/private/etc/sudoers.d"
printf '%s ALL=(root) NOPASSWD: /sbin/shutdown\n' "$GUEST_USER" > "$DATA/private/etc/sudoers.d/imessage-box"
chown 0:0 "$DATA/private/etc/sudoers.d/imessage-box"; chmod 440 "$DATA/private/etc/sudoers.d/imessage-box"
# BlueBubbles' default proxy is a Cloudflare quick tunnel; it must never open one.
if ! grep -q imessage-box "$DATA/private/etc/hosts" 2>/dev/null; then
  cat >> "$DATA/private/etc/hosts" <<'EOF'
# imessage-box: no public tunnels from BlueBubbles
0.0.0.0 api.trycloudflare.com
0.0.0.0 trycloudflare.com
0.0.0.0 region1.v2.argotunnel.com
0.0.0.0 region2.v2.argotunnel.com
0.0.0.0 update.argotunnel.com
0.0.0.0 api.ngrok.com
0.0.0.0 connect.ngrok-agent.com
EOF
fi
SU="$DATA/Library/Preferences/com.apple.SoftwareUpdate"
for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates ConfigDataInstall CriticalUpdateInstall; do
  defaults write "$SU" "$k" -bool false
done
defaults write "$DATA/Library/Preferences/com.apple.commerce" AutoUpdate -bool false
defaults write "$DATA/Library/Preferences/com.apple.screensaver" loginWindowIdleTime -int 0
# QEMU's USB keyboard (vendor 0x0627, product 0x0001) as ANSI, so the Keyboard Setup Assistant stays away.
defaults write "$DATA/Library/Preferences/com.apple.keyboardtype" keyboardtype -dict-add "1-1575-0" -integer 40
r system-configured

# --- first-boot payload
L="$DATA/Library/imessage-box"
mkdir -p "$L" "$DATA/Library/LaunchDaemons"
get firstboot.sh "$L/firstboot.sh"
cp /tmp/box.env "$L/box.env"
get bluebubbles.zip "$L/bluebubbles.zip"
chown -R 0:0 "$L"; chmod 700 "$L"; chmod 755 "$L/firstboot.sh"; chmod 600 "$L/box.env"
cat > "$DATA/Library/LaunchDaemons/com.imessagebox.firstboot.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.imessagebox.firstboot</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/imessage-box/firstboot.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/Library/imessage-box/firstboot.log</string>
  <key>StandardErrorPath</key><string>/Library/imessage-box/firstboot.log</string>
</dict>
</plist>
EOF
chown 0:0 "$DATA/Library/LaunchDaemons/com.imessagebox.firstboot.plist"
chmod 644 "$DATA/Library/LaunchDaemons/com.imessagebox.firstboot.plist"
sync
r stage2-done "macOS $OSVER ready for first boot"
shutdown -h now
