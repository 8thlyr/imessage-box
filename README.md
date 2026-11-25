# imessage-box

Turn a Linux server with KVM into an iMessage box: a headless macOS Ventura VM running the
[BlueBubbles](https://bluebubbles.app) server, with its REST API on a port of the host.

> **Unofficial.** This project is not affiliated with, endorsed by, or supported by Apple Inc.
> or BlueBubbles. macOS and iMessage are Apple's. You must comply with Apple's macOS licence
> (which only permits macOS on Apple-branded hardware) and Apple's terms for iMessage; see
> [Licensing and terms](#licensing-and-terms).

```sh
git clone https://github.com/8thlyr/imessage-box.git && cd imessage-box
./install.sh      # ~45 min, unattended (41 min in testing)
./signin.sh       # Apple ID + the 6-digit code from your iPhone
./status.sh       # VM, BlueBubbles API, iMessage account
```

`install.sh` is the only setup step. You type nothing into the VM: it installs macOS from
Recovery with `startosinstall`, creates the user offline, skips Setup Assistant, and a first-boot
script installs and configures BlueBubbles. `signin.sh` is the one human step, because Apple
sends the 2FA code to your phone.

## Requirements

| | |
|---|---|
| CPU | x86_64 with VT-x or AMD-V, and AVX2 (Ventura needs it). Intel is tested; OSX-KVM reports modern Ryzen works. |
| Virtualization | `/dev/kvm`. On a cloud VM that means nested virtualization must be on (GCP `--enable-nested-virtualization`, Azure Dv3/Ev3 and newer, Proxmox `cpu: host`, or a bare-metal instance). `install.sh` detects a VM without it and says so. |
| RAM | 4 GB for the VM plus ~0.5 GB (set `RAM_MB`). |
| Disk | ~45 GB free during install; the image is ~16 GB afterwards. It grows with use and does not shrink when macOS deletes files (TRIM does not work in this VM yet). Plus ~4 GB download cache. |
| Distro | Arch, Debian/Ubuntu, Fedora (openSUSE best effort). Packages are installed with your package manager; `sudo` is used for that, the kvm module setting and the systemd unit. RHEL/CentOS `qemu-kvm` lacks the `isa-applesmc` device and will not work. |
| Network | Outbound HTTPS to Apple (macOS download, iMessage) and GitHub (OSX-KVM, OpenCore, BlueBubbles). |

Run `./install.sh --check` first to see whether a host qualifies. It changes nothing.

## What install.sh does

Every step is idempotent and the run is resumable: if it stops (network, reboot, Ctrl-C),
run `./install.sh` again and it continues. The VM runs as a daemonized qemu, so it keeps
installing even if the terminal closes. Logs go to `state/logs/install-*.log`; guest progress
to `state/logs/guest-events.log`; screenshots of each phase to `state/shots/`.

1. **Host checks**: KVM, nested virt, AVX2, RAM, disk, free ports.
2. **Packages**: qemu, mtools, python3, curl, git, openssh; sets `kvm ignore_msrs=1`
   (`/etc/modprobe.d/imessage-box-kvm.conf`), without which macOS crashes at boot.
3. **Downloads**, cached in `~/.cache/imessage-box` and checksummed: OSX-KVM at a pinned commit,
   OpenCore 1.0.8 (for `macserial`), BlueBubbles 1.9.12, and the macOS Ventura recovery image
   straight from Apple (verified against Apple's chunklist). A second box on the same host
   reuses the cache.
4. **Identity**: a unique iMacPro1,1 serial, MLB, system UUID and ROM (the NIC MAC), generated
   with `macserial` and kept in `state/secrets/`. Passwords for the macOS user, BlueBubbles and
   VNC are random and live there too (mode 600). Nothing secret is printed or logged.
5. **OpenCore**: three images from OSX-KVM's, differing only in what the boot picker may boot
   (`install`: installer + new disk, `recovery`: only the installer, `run`: only macOS), so
   no keypress in the picker is ever needed. Also fixes the MCE reporter kext path that
   otherwise panics iMacPro1,1 under KVM, and sets SIP (see below).
6. **macOS install** (45-75 min): boots Recovery, opens its Terminal with Shift-Cmd-T, types a
   one-line `curl ... | bash` that fetches `guest/stage1.sh` from a token-protected server on
   the host's loopback. Stage 1 erases the disk and runs `startosinstall`, which downloads
   macOS from Apple. The host waits for Setup Assistant to appear on screen.
7. **Provisioning from Recovery**: `guest/stage2.sh` creates the admin user with `dscl`
   directly on the installed disk, marks Setup Assistant done, writes auto-login, enables ssh,
   turns off updates and blocks BlueBubbles' Cloudflare/ngrok tunnel hosts.
8. **First boot**: `guest/firstboot.sh` (a one-shot LaunchDaemon) installs BlueBubbles, sets
   its config (password, port 1234, manual/dynamic-DNS URL, no tunnel, no update checks),
   grants its privacy permissions and adds a login agent.
9. **Snapshot**: the clean disk becomes a read-only `base.qcow2` with a thin overlay on top.
   `./vm.sh reset` goes back to it in seconds instead of reinstalling.
10. **Service**: a systemd unit `imessage-box.service` starts the VM at boot and shuts it down
    cleanly. `--no-service` skips it.

`./install.sh --smoke-test` stops after step 5 plus a Recovery boot: it proves the host can
boot macOS and that the Terminal automation works, and erases nothing. It took 2 minutes on
the test host once the ~1 GB of downloads were cached.

## Using it

| Command | |
|---|---|
| `./status.sh` | VM, service, BlueBubbles, iMessage account. Exit 0 = all good, 2 = not signed in. |
| `./signin.sh` | Apple ID sign-in. `--force` to redo it. |
| `./vm.sh start\|stop\|restart` | Start/stop (use `sudo systemctl ... imessage-box` when the unit is installed). |
| `./vm.sh ssh [cmd]` | Shell in the guest (key auth, 127.0.0.1 only). |
| `./vm.sh vnc` | VNC address and password file, for anything you want to see or click. |
| `./vm.sh shot [name]` | Screenshot to `state/shots/`. |
| `./vm.sh reset` | Back to the clean post-install disk. Signs iMessage out. |
| `./uninstall.sh` | Stop and delete everything except the download cache (`--purge-cache` too). |

BlueBubbles clients (Android, web, desktop) connect to `http://BIND_ADDR:BB_PORT` with the
password in `state/secrets/bluebubbles-password`. The REST API is documented at
<https://docs.bluebubbles.app/server/developer-guides/rest-api-and-webhooks>.

## Configuration

Copy `box.conf.example` to `box.conf`. The settings you are most likely to change:

- `BIND_ADDR` (default `127.0.0.1`): where BlueBubbles and VNC listen on the host. For a phone
  to reach the box, use a private address such as the host's Tailscale IP. Do not expose these
  ports to the internet: the API is guarded by one password and VNC by an 8-character one.
- `BB_PORT`, `VNC_PORT`, `SSH_PORT`, `PROV_PORT`, `VM_NAME`: to run more than one box per host.
- `SERVER_URL`: the URL BlueBubbles hands its clients, if it differs from `http://BIND_ADDR:BB_PORT`.
- `SIP` (default `off`; set `SIP=on` in `box.conf` to keep it on): see below.

### SIP and permissions

**Trade-off:** `SIP=off` (default) lets the first boot grant BlueBubbles its permissions itself, so setup needs no clicks.
`SIP=on` keeps macOS's System Integrity Protection, at the cost of two toggles in System Settings over VNC.

BlueBubbles needs Full Disk Access (to read the Messages database), Accessibility, Contacts and
Automation of Messages. macOS only lets a user grant those in System Settings, unless SIP is off,
in which case `firstboot.sh` writes them into the TCC databases itself.

With `SIP=on`, after install open VNC (`./vm.sh vnc`) and in System Settings > Privacy &
Security turn on BlueBubbles under Full Disk Access and Accessibility; the first message sent
asks to let BlueBubbles control Messages (click OK). `install.sh` warns when this is needed.

Private API features (typing indicators, tapbacks, edits) are not set up.

## Things to know

- **Do not update macOS.** Updates are off. A major upgrade (Ventura is offered Tahoe) can stop
  OpenCore booting or break BlueBubbles. Take a copy of `state/` before any manual update.
- **Keep `state/secrets/smbios-*`.** They are the Mac's identity. Changing them after sign-in
  looks like a new Mac to Apple and de-registers iMessage. `vm.sh reset` keeps them.
- **Apple may refuse a VM.** iMessage activation from a generated serial normally works (it did
  on the box this was built from), but Apple can block it or flag the account ("customer code"
  error). Try a spare Apple ID first.
- **Push notifications** to the BlueBubbles mobile app need a Firebase project you attach in the
  BlueBubbles server UI. Without it, clients receive messages while connected.
- After sign-in Messages may show an "Add an Email Address" sheet. If `./status.sh` shows the
  account, iMessage is registered; close the sheet over VNC and check Messages > Settings >
  iMessage for the addresses you can be reached at.

## Licensing and terms

- **This repository**: MIT (see `LICENSE`). It covers these scripts only.
- **Apple**: macOS's licence (EULA) only permits running it on Apple-branded hardware. Running
  it in a VM on other hardware breaks those terms. You are responsible for whether you do. This
  repository contains no Apple software: the recovery image and macOS are downloaded from
  Apple's servers on your machine at install time, and the Apple SMC key qemu needs is read
  from the OSX-KVM checkout, not shipped here.
- **OSX-KVM** (<https://github.com/kholia/OSX-KVM>) is downloaded at install time, not
  vendored. Its repository declares no licence; see its README and CREDITS.
- **OpenCore** (BSD-3-Clause) and **BlueBubbles** (Apache-2.0) are downloaded from their
  GitHub releases.
- iMessage is Apple's service; using it through an unofficial client can get an Apple ID
  restricted.

## Layout

```
install.sh signin.sh status.sh uninstall.sh vm.sh   entry points
lib/common.sh    config defaults, logging, helpers
lib/boxctl.py    QMP, screen/keyboard automation, install server, OpenCore/SMBIOS/kcpassword
guest/stage1.sh  Recovery: erase + startosinstall
guest/stage2.sh  Recovery: user, auto-login, ssh, first-boot payload
guest/firstboot.sh  first boot: BlueBubbles, permissions
state/           per-box disks, secrets, logs (gitignored)
```
