# Test report (2026-11-25)

`./install.sh` ran three times end to end on one host. Runs 1 and 2 found bugs, which are now
fixed. Run 3 used the fixed code and went from a bare host to a running BlueBubbles server in
**41 minutes with no human input**. Nothing was signed in to Apple: testing stopped at `signin.sh`.

## Test host

Intel i5-10400 (12 threads), Arch Linux, QEMU 11.1.3 with KVM. VM defaults: 2 vCPU, 4 GB RAM,
64 GB thin disk. The VM ran under a test name and test ports, at low CPU/IO priority, next to
production services. A disk watchdog would have aborted any run below 15 GB free; it never fired.

## Run 3: clean, unattended (the passing run)

| Phase | Clock | Duration |
|---|---|---|
| Host checks, cached downloads, identity, OpenCore images | 14:38:53 | 1.5 min |
| Recovery boots (no picker input), Terminal opened by keyboard, stage 1 starts | 14:40:22 | |
| `startosinstall` stages macOS (downloads ~12 GB from Apple), installer reboots | | ~10 min |
| macOS installer runs to Setup Assistant, detected on screen (mean 94, saturation 78) | 15:10:02 | ~20 min |
| Recovery again, stage 2: user, auto-login, ssh, first-boot payload | 15:12:46 | 2.5 min |
| First boot; auto-login missing, so one automatic reboot; logged in | 15:17:04 | 4 min |
| BlueBubbles installed, configured, permissions granted, API up | 15:17:57 | 1 min |
| Base snapshot (16 GB), systemd unit, VM booted, BlueBubbles answering | 15:20:19 | 2.5 min |
| **Total to ready** | | **41 min 26 s** |

Without a download cache, add about 1 minute (about 1 GB downloaded at ~100 MB/s).

What the finished box showed:
- `./status.sh`: "BlueBubbles up (server 1.9.12 on macOS 13.7.8, proxy dynamic-dns, private API off)",
  "iMessage not signed in", exit status 2.
- BlueBubbles' own log: "Full-disk access permissions are enabled", "Accessibility permissions
  are enabled", "Starting iMessage Database listeners", Ngrok/Cloudflare/Zrok proxies disabled.
  No tunnel process ran.
- Messages showed "Sign in to iMessage with your Apple ID", with the Apple ID field where
  `signin.sh` clicks.
- `systemctl restart`: clean guest shutdown over ssh in 6-8 s; BlueBubbles back in about 60-75 s.
- `./vm.sh reset`: a file written after install was gone; BlueBubbles back in 70 s; service still active.
- `./uninstall.sh --yes --purge-cache`: removed the unit, the VM, its state and the cache.

## Bugs found and fixed

| Run | Bug | Fix |
|---|---|---|
| 1 | The first boot after install showed the login window. Auto-login works from the second boot. | `firstboot.sh` waits 2 minutes for auto-login, otherwise reboots (at most twice) and continues. Run 3: one reboot, then logged in. |
| 1 | The final status printed before BlueBubbles was back up. | `install.sh` waits for the API first. |
| 1 | A stray non-HTTP connection printed a traceback from the install server. | Silenced. |
| 2 | Setup Assistant animates, so the "screen unchanged for 30 s" check never passed. macOS then blanked the display and the install sat waiting. | The install-done check no longer needs a still screen, and it taps Shift to wake a blanked display (only after Setup Assistant was seen, so it cannot interrupt OpenCore's boot countdown). Resuming taps Shift once. |
| 2 | Re-running `install.sh` mid-install failed the 45 GB free-space check, because the half-built disk already used that space. | The check subtracts what the VM disk already uses. |

Run 2 was resumed after these fixes and finished. Resuming a killed `install.sh` while the VM
kept installing worked as designed.

## Known gap: TRIM

The disk image does not shrink when macOS deletes files. `trimforce enable` works until the
next qemu power cycle, then reads "TRIM Support: No" again. Setting `EnableTRIM` through
OpenCore's NVRAM and OpenCore's `ThirdPartyDrives` quirk both left TRIM off, and a 2 GB
write-then-delete did not shrink the image after a reboot either. The install therefore no
longer tries. The image is about 16 GB after install and grows with use.

## Still untested

- `signin.sh` against Apple. The field position was checked on run 3's screen, but no Apple ID was used.
- Debian/Ubuntu, Fedora and openSUSE hosts, AMD CPUs, and cloud VMs with nested virtualization.
- The `dmg2img` fallback (`qemu-img` read Apple's dmg directly).
- `SIP=on` and its manual-permission path.
- Caching the ~12 GB macOS download made by `startosinstall`. A cached copy plus a full install
  did not fit the test host's disk budget. `./vm.sh reset` and the base snapshot cover re-runs
  on the same box.
