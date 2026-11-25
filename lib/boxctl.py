#!/usr/bin/env python3
"""imessage-box helper: QMP control, screen/keyboard automation, install-time file server,
OpenCore config, SMBIOS and kcpassword generation. Python 3.8+ stdlib only.

Secrets are read from files or stdin and never printed.

  boxctl.py qmp SOCK JSON                      raw QMP command, prints the reply
  boxctl.py vnc-password SOCK FILE             set the VNC password from FILE
  boxctl.py powerdown SOCK                     ACPI power button
  boxctl.py quit SOCK                          stop qemu now
  boxctl.py shot SOCK OUT.png                  screenshot
  boxctl.py stats SOCK                         "mean saturation hash" of the screen
  boxctl.py wait-screen SOCK --min A --max B [--stable S] [--timeout T]
  boxctl.py key SOCK COMBO...                  e.g. ret, esc, shift-meta-t
  boxctl.py type SOCK TEXT                     type ASCII text
  boxctl.py type-stdin SOCK                    type one line read from stdin (no echo)
  boxctl.py click SOCK X Y
  boxctl.py serve DIR PORT TOKEN EVENTS        install-time HTTP server on 127.0.0.1
  boxctl.py opencore SRC DST MODE SECRETS SIP  write a patched config.plist
  boxctl.py smbios MACSERIAL MODEL SECRETS     generate serial/MLB/UUID/ROM into SECRETS
  boxctl.py kcpassword PWFILE OUT              macOS auto-login file
  boxctl.py fetch-macos SCRIPT SHORTNAME DIR   run OSX-KVM fetch-macOS-v2.py without a TTY
"""
import hashlib
import json
import os
import plistlib
import random
import re
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib


# ---------------------------------------------------------------- QMP
class QMP:
    def __init__(self, path, timeout=30):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self._read()  # greeting
        self.cmd({"execute": "qmp_capabilities"})

    def _read(self):
        line = self.f.readline()
        if not line:
            raise EOFError("qmp closed")
        return json.loads(line)

    def close(self):
        # makefile() keeps the fd open after socket.close(); QEMU serves one client per socket,
        # so a half-closed connection blocks every later one.
        for x in (self.f, self.s):
            try:
                x.close()
            except OSError:
                pass

    def cmd(self, obj):
        self.f.write((json.dumps(obj) + "\n").encode())
        self.f.flush()
        while True:
            r = self._read()
            if "return" in r or "error" in r:
                return r

    def run(self, name, **args):
        obj = {"execute": name}
        if args:
            obj["arguments"] = args
        r = self.cmd(obj)
        if "error" in r:
            raise RuntimeError("%s: %s" % (name, r["error"].get("desc")))
        return r["return"]


# ---------------------------------------------------------------- screen
def screendump(q):
    fd, ppm = tempfile.mkstemp(suffix=".ppm", dir=os.path.dirname(os.path.abspath(q.s.getpeername())))
    os.close(fd)
    try:
        os.chmod(ppm, 0o600)
        q.run("screendump", filename=ppm)
        data = open(ppm, "rb").read()
    finally:
        os.unlink(ppm)
    parts, idx = [], 0
    while len(parts) < 4:
        while data[idx:idx + 1].isspace():
            idx += 1
        st = idx
        while not data[idx:idx + 1].isspace():
            idx += 1
        parts.append(data[st:idx])
    idx += 1
    w, h = int(parts[1]), int(parts[2])
    return w, h, data[idx:idx + w * h * 3]


def write_png(path, w, h, px):
    raw = b"".join(b"\x00" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    out = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(out)


def screen_stats(q):
    """Mean brightness, mean saturation (0-255) and a coarse hash of the screen."""
    w, h, px = screendump(q)
    tot = sat = n = 0
    coarse = bytearray()
    for y in range(0, h, 8):
        row = y * w * 3
        for x in range(0, w, 8):
            i = row + x * 3
            r, g, b = px[i], px[i + 1], px[i + 2]
            tot += r + g + b
            sat += max(r, g, b) - min(r, g, b)
            n += 1
            if y % 32 == 0 and x % 32 == 0:
                coarse.append((r + g + b) // 48)
    return tot / (3 * n), sat / n, hashlib.sha1(bytes(coarse)).hexdigest()[:10]


def wait_screen(sock, lo, hi, stable, timeout, min_sat=None, max_sat=None, still=True, wake=0):
    """Wait until mean brightness is within [lo, hi] for `stable` s. With still=True the screen
    must also be unchanged (Recovery is static; Setup Assistant animates, so it uses still=False).
    wake=N taps Shift every N s while the screen is darker than `lo` after the wanted screen was
    seen once: macOS blanks an idle Setup Assistant after a few minutes. (Never before that, so a
    key press cannot stop OpenCore's auto-boot countdown.)"""
    t0 = time.time()
    since, last, lastprint, lastwake, seen = None, None, 0, 0, False
    while time.time() - t0 < timeout:
        q = None
        try:
            q = QMP(sock, timeout=20)
            m, s, hsh = screen_stats(q)
            if wake and seen and m < lo and time.time() - lastwake >= wake:
                press(q, ["shift"])
                lastwake = time.time()
        except (OSError, EOFError, RuntimeError) as e:
            print("screen: qmp unavailable (%s)" % e, flush=True)
            time.sleep(10)
            continue
        finally:
            if q:
                q.close()
        good = lo <= m <= hi and (min_sat is None or s >= min_sat) and (max_sat is None or s <= max_sat)
        seen = seen or good
        if good and (hsh == last or not still):
            if since and time.time() - since >= stable:
                print("screen ok: mean=%.0f sat=%.0f" % (m, s), flush=True)
                return 0
            since = since or time.time()
        else:
            since = time.time() if good else None
        last = hsh
        if time.time() - lastprint > 300:
            print("screen: mean=%.0f sat=%.0f (waiting for %s..%s)" % (m, s, lo, hi), flush=True)
            lastprint = time.time()
        time.sleep(5)
    return 1


# ---------------------------------------------------------------- input
KEYMAP = {" ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", ".": "dot",
          ",": "comma", "/": "slash", ";": "semicolon", "'": "apostrophe",
          "[": "bracket_left", "]": "bracket_right", "\\": "backslash", "`": "grave_accent"}
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
           "(": "9", ")": "0", "_": "minus", "+": "equal", ":": "semicolon", '"': "apostrophe",
           "<": "comma", ">": "dot", "?": "slash", "{": "bracket_left", "}": "bracket_right",
           "|": "backslash", "~": "grave_accent"}
MODS = {"ctrl": "ctrl", "shift": "shift", "alt": "alt", "meta": "meta_l", "cmd": "meta_l"}
HOLD = float(os.environ.get("BOX_KEY_HOLD", "0.06"))


def _keyev(code, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}


def press(q, codes):
    q.run("input-send-event", events=[_keyev(c, True) for c in codes])
    time.sleep(HOLD)
    q.run("input-send-event", events=[_keyev(c, False) for c in reversed(codes)])
    time.sleep(0.04)


def char_codes(ch):
    if ch.isalpha() and ch.isascii():
        return ["shift", ch.lower()] if ch.isupper() else [ch]
    if ch.isdigit():
        return [ch]
    if ch in KEYMAP:
        return [KEYMAP[ch]]
    if ch in SHIFTED:
        return ["shift", SHIFTED[ch]]
    raise ValueError("cannot type character %r" % ch)


def type_text(q, text):
    codes = [char_codes(c) for c in text]  # validate everything before typing anything
    for c in codes:
        press(q, c)


def click(q, x, y):
    w, h, _ = screendump(q)
    q.run("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (w - 1))}},
        {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (h - 1))}}])
    time.sleep(0.15)
    for down in (True, False):
        q.run("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])
        time.sleep(0.08)


# ---------------------------------------------------------------- install-time file server
def serve(root, port, token, events):
    import http.server
    import urllib.parse

    root = os.path.abspath(root)
    prefix = "/" + token + "/"

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def _report(self, qs):
            step = (qs.get("s") or ["?"])[0]
            msg = (qs.get("m") or [""])[0].replace("\n", " ").replace("\r", " ")[:500]
            line = "%s %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), re.sub(r"\s", "_", step), msg)
            with open(events, "a") as f:
                f.write(line.rstrip() + "\n")
            print("guest: " + line, flush=True)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")

        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            if not u.path.startswith(prefix):
                return self.send_error(404)
            rest = u.path[len(prefix):]
            if rest == "report":
                return self._report(urllib.parse.parse_qs(u.query))
            if rest.startswith("f/"):
                name = rest[2:]
                if "/" in name or name.startswith(".") or name not in os.listdir(root):
                    return self.send_error(404)
                path = os.path.join(root, name)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(os.path.getsize(path)))
                self.end_headers()
                with open(path, "rb") as f:
                    while True:
                        b = f.read(1 << 20)
                        if not b:
                            break
                        self.wfile.write(b)
                return None
            return self.send_error(404)

    class Server(http.server.ThreadingHTTPServer):
        def handle_error(self, request, client_address):
            pass  # stray non-HTTP probes from the guest network are not worth a traceback

    srv = Server(("127.0.0.1", port), H)
    print("provision server on 127.0.0.1:%d" % port, flush=True)
    srv.serve_forever()


# ---------------------------------------------------------------- OpenCore
# ScanPolicy: FS/device locks + SATA/SASEX/SCSI/NVMe/PCI, plus the file systems below.
SCAN_DEVICES = 0x00000001 | 0x00000002 | 0x00010000 | 0x00020000 | 0x00040000 | 0x00080000 | 0x01000000
SCAN_APFS, SCAN_HFS = 0x100, 0x200
SCAN = {
    "install": SCAN_DEVICES | SCAN_APFS | SCAN_HFS,  # installer + staged macOS Installer on the new disk
    "recovery": SCAN_DEVICES | SCAN_HFS,             # only the installer (Recovery), whatever NVRAM says
    "run": SCAN_DEVICES | SCAN_APFS,                 # only the installed macOS (0x10F0103)
}
NV_APPLE = "7C436110-AB2A-4BBB-A880-FE41995C9F82"


def opencore(src, dst, mode, secdir, sip):
    d = plistlib.load(open(src, "rb"))

    def sec(name):
        return open(os.path.join(secdir, name)).read().strip()

    g = d["PlatformInfo"]["Generic"]
    g["SystemProductName"] = sec("smbios-model")
    g["SystemSerialNumber"] = sec("smbios-serial")
    g["MLB"] = sec("smbios-mlb")
    g["SystemUUID"] = sec("smbios-uuid")
    g["ROM"] = bytes.fromhex(sec("smbios-rom-mac").replace(":", ""))
    # iMacPro1,1 panics in AppleIntelMCEReporter unless the disabler kext loads; OSX-KVM's
    # config points at AppleMCEReporterDisabler.kext but its image ships MCEReporterDisabler.kext.
    for k in d["Kernel"]["Add"]:
        if k.get("BundlePath") == "AppleMCEReporterDisabler.kext":
            k["BundlePath"] = "MCEReporterDisabler.kext"
            k["Enabled"] = True
    nv = d["NVRAM"]
    nv["Add"][NV_APPLE]["boot-args"] = "keepsyms=1"
    # 0x0FEF = SIP fully off; 0 = on. In Delete so OpenCore rewrites it every boot.
    nv["Add"][NV_APPLE]["csr-active-config"] = bytes.fromhex("EF0F0000" if sip == "off" else "00000000")
    dl = nv["Delete"].setdefault(NV_APPLE, [])
    if "csr-active-config" not in dl:
        dl.append("csr-active-config")
    d["Misc"]["Boot"]["ShowPicker"] = True
    d["Misc"]["Boot"]["Timeout"] = 3
    d["Misc"]["Boot"]["HideAuxiliary"] = True
    d["Misc"]["Security"]["ScanPolicy"] = SCAN[mode]
    old = os.umask(0o077)
    try:
        with open(dst, "wb") as f:
            plistlib.dump(d, f)
    finally:
        os.umask(old)


def smbios(macserial, model, secdir):
    out = subprocess.run([macserial, "-m", model, "-g", "-n", "1"], capture_output=True, text=True, check=True).stdout
    m = re.search(r"^\s*([A-Z0-9]{12})\s*\|\s*([A-Z0-9]{17})\s*$", out, re.M)
    if not m:
        sys.exit("macserial gave no serial for %s" % model)
    rng = random.SystemRandom()
    mac = "52:54:00:%02x:%02x:%02x" % (rng.randrange(256), rng.randrange(256), rng.randrange(256))
    vals = {"smbios-model": model, "smbios-serial": m.group(1), "smbios-mlb": m.group(2),
            "smbios-uuid": str(uuid.uuid4()).upper(), "smbios-rom-mac": mac}
    old = os.umask(0o077)
    try:
        for k, v in vals.items():
            with open(os.path.join(secdir, k), "w") as f:
                f.write(v + "\n")
    finally:
        os.umask(old)
    print("SMBIOS generated for %s (values in %s)" % (model, secdir))


def kcpassword(pwfile, out):
    key = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]
    pw = open(pwfile).read().strip().encode()
    pad = len(pw) + (12 - len(pw) % 12 if len(pw) % 12 else 12)
    b = (pw + b"\0" * (pad - len(pw)))
    enc = bytes(c ^ key[i % len(key)] for i, c in enumerate(b))
    old = os.umask(0o077)
    try:
        with open(out, "wb") as f:
            f.write(enc)
    finally:
        os.umask(old)


def fetch_macos(script, shortname, outdir):
    import runpy
    os.get_terminal_size = lambda *a: os.terminal_size((100, 24))  # the script assumes a TTY
    os.chdir(outdir)
    sys.argv = [script, "-s", shortname]
    runpy.run_path(script, run_name="__main__")


def randpw(n):
    a = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    return "".join(secrets.choice(a) for _ in range(n))


# ---------------------------------------------------------------- main
def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    a = argv[1]
    if a == "qmp":
        print(json.dumps(QMP(argv[2]).cmd(json.loads(argv[3]))))
    elif a == "vnc-password":
        pw = open(argv[3]).read().strip()
        QMP(argv[2]).run("set_password", protocol="vnc", password=pw)
    elif a == "powerdown":
        QMP(argv[2], timeout=10).run("system_powerdown")
    elif a == "quit":
        try:
            QMP(argv[2], timeout=10).run("quit")
        except (EOFError, OSError):
            pass
    elif a == "shot":
        w, h, px = screendump(QMP(argv[2]))
        write_png(argv[3], w, h, px)
        print(argv[3])
    elif a == "stats":
        print("%.0f %.0f %s" % screen_stats(QMP(argv[2])))
    elif a == "wait-screen":
        import argparse
        p = argparse.ArgumentParser()
        p.add_argument("sock")
        p.add_argument("--min", type=float, required=True)
        p.add_argument("--max", type=float, required=True)
        p.add_argument("--min-sat", type=float)
        p.add_argument("--max-sat", type=float)
        p.add_argument("--stable", type=float, default=15)
        p.add_argument("--timeout", type=float, default=600)
        p.add_argument("--changing", action="store_true", help="screen may animate (no stillness check)")
        p.add_argument("--wake", type=float, default=0, help="tap Shift every N s while the screen is dark")
        o = p.parse_args(argv[2:])
        return wait_screen(o.sock, o.min, o.max, o.stable, o.timeout, o.min_sat, o.max_sat,
                           still=not o.changing, wake=o.wake)
    elif a == "key":
        q = QMP(argv[2])
        for combo in argv[3:]:
            parts = combo.split("-")
            press(q, [MODS.get(p, p) for p in parts[:-1]] + [parts[-1]])
    elif a == "type":
        type_text(QMP(argv[2]), argv[3])
    elif a == "type-stdin":
        line = sys.stdin.readline().rstrip("\n")
        type_text(QMP(argv[2]), line)
    elif a == "click":
        click(QMP(argv[2]), int(argv[3]), int(argv[4]))
    elif a == "serve":
        serve(argv[2], int(argv[3]), argv[4], argv[5])
    elif a == "opencore":
        opencore(argv[2], argv[3], argv[4], argv[5], argv[6])
    elif a == "smbios":
        smbios(argv[2], argv[3], argv[4])
    elif a == "kcpassword":
        kcpassword(argv[2], argv[3])
    elif a == "fetch-macos":
        fetch_macos(argv[2], argv[3], argv[4])
    elif a == "randpw":
        print(randpw(int(argv[2])))
    else:
        sys.exit("unknown command: " + a)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
