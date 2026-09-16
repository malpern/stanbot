#!/usr/bin/env python3
"""Flash camera_stream over Wi-Fi, then prove the robot is running it.

    firmware/build.sh            # commit first; this refuses dirty builds
    python3 firmware/ota.py      # default host stanbot.local

1. Reads build_info.json from the last firmware/build.sh run and refuses a
   dirty build unless --allow-dirty.
2. Reads the OTA passphrase from STANBOT_OTA_PASSWORD, else decrypts it from
   ~/dotfiles/secrets.env with sops. It is never printed or put in argv.
3. Uploads with Espressif's espota and fails if the robot did not demand the
   passphrase: that means the firmware on it accepts unauthenticated updates,
   so anyone on the network could flash it. Firmware from 2026-09-16 on
   refuses OTA without a stored passphrase; --allow-unauthenticated exists only
   for the one upload that replaces an older image.
4. Waits for the reboot and asks V over TCP, passing only if the reported
   commit matches the build.

Quit Stanbot first: the robot serves one TCP viewer, so while the app holds
the link the V check cannot be answered. The robot connects back to this Mac
during the upload, so an inbound firewall must allow it.

From the mini, agent shells cannot reach LAN hosts (macOS Local Network
privacy); run this through `ssh malpern@openclaw.local`.
"""
import argparse
import glob
import importlib.util
import json
import os
import random
import socket
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(REPO, "firmware/camera_stream/build/esp32.esp32.m5stack_cores3")


def load_espota():
    candidates = sorted(glob.glob(os.path.expanduser(
        "~/Library/Arduino15/packages/esp32/hardware/esp32/*/tools/espota.py")))
    if not candidates:
        sys.exit("espota.py not found; is the arduino-cli esp32 core installed?")
    spec = importlib.util.spec_from_file_location("espota", candidates[-1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ota_password():
    if os.environ.get("STANBOT_OTA_PASSWORD"):
        return os.environ["STANBOT_OTA_PASSWORD"]
    env = dict(os.environ, SOPS_AGE_KEY_FILE=os.path.expanduser("~/.config/sops/age/keys.txt"),
               PATH="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", ""))
    out = subprocess.run(["sops", "-d", os.path.expanduser("~/dotfiles/secrets.env")],
                         capture_output=True, text=True, env=env)
    for line in out.stdout.splitlines():
        if line.startswith("STANBOT_OTA_PASSWORD="):
            return line.split("=", 1)[1]
    sys.exit("STANBOT_OTA_PASSWORD not found (sops exit %d)" % out.returncode)


def ask_version(ip, timeout):
    """Returns the SBVR JSON, or None if no viewer slot answered in time."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((ip, 3333), timeout=3) as sock:
                sock.settimeout(1)
                sock.sendall(b"X\nV\n")
                buffer = b""
                end = time.monotonic() + 4
                while time.monotonic() < end:
                    try:
                        chunk = sock.recv(4096)
                    except socket.timeout:
                        sock.sendall(b"V\n")
                        continue
                    if not chunk:
                        break
                    buffer += chunk
                    for line in buffer.split(b"\n"):
                        if line.startswith(b"SBVR {"):
                            return json.loads(line[5:])
        except OSError:
            pass
        time.sleep(2)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="stanbot.local")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--allow-unauthenticated", action="store_true",
                        help="accept a robot that did not ask for the passphrase (migration only)")
    args = parser.parse_args()

    with open(os.path.join(BUILD, "build_info.json")) as f:
        info = json.load(f)
    if info["dirty"] and not args.allow_dirty:
        sys.exit("refusing a dirty build (%s); commit and rerun firmware/build.sh" % info["commit"])
    image = os.path.join(BUILD, info["app_bin"])
    ip = socket.gethostbyname(args.host)

    before = ask_version(ip, 6)
    if before is None:
        sys.exit("no V reply from %s:3333 before flashing; is Stanbot still connected?" % ip)
    print(json.dumps({"before": before["commit"], "flashing": info["commit"], "ip": ip,
                      "app_bytes": info["app_bytes"]}), flush=True)

    espota = load_espota()
    espota.TIMEOUT = 10
    espota.PROGRESS = False
    demanded = {"auth": False}
    real_authenticate = espota.authenticate

    def authenticate(*a, **k):
        demanded["auth"] = True
        return real_authenticate(*a, **k)

    espota.authenticate = authenticate
    started = time.monotonic()
    code = espota.serve(ip, "0.0.0.0", 3232, random.randint(20000, 60000), ota_password(), False, image)
    upload_s = round(time.monotonic() - started, 1)
    print(json.dumps({"upload_exit": code, "upload_seconds": upload_s,
                      "passphrase_demanded": demanded["auth"]}), flush=True)
    if code != 0:
        sys.exit(1)

    after = ask_version(ip, 60)
    ok = after is not None and after["commit"] == info["commit"] and not after["follow_limits_measured"]
    print(json.dumps({"after": after, "reboot_to_answer_seconds": round(time.monotonic() - started - upload_s, 1),
                      "verified": ok}), flush=True)
    if not demanded["auth"]:
        print("WARNING: the robot accepted this upload without a passphrase", file=sys.stderr)
        if not args.allow_unauthenticated:
            sys.exit(1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
