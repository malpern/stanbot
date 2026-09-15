#!/usr/bin/env python3
"""Provision the robot's Wi-Fi profiles from sops, over USB.

Credentials go straight from `sops -d ~/dotfiles/secrets.env` into the robot's
NVS. They are never written to this repository, never printed, and never passed
as command-line arguments where they would appear in a process list. The robot
does not echo them back either; `--status` reports only whether one is stored.

Close Stanbot first: only one process can hold the serial port.

  python3 companion/provision_wifi.py /dev/cu.usbmodem31201 --scan
  python3 companion/provision_wifi.py /dev/cu.usbmodem31201 --home --dojo
  python3 companion/provision_wifi.py /dev/cu.usbmodem31201 --status
"""
import argparse
import os
import select
import subprocess
import sys
import termios
import time

SECRETS = os.path.expanduser("~/dotfiles/secrets.env")


def secrets():
    """Decrypt once, in memory. Never logged, never written to disk."""
    result = subprocess.run(["sops", "-d", SECRETS], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("could not decrypt secrets.env; is the age key present?")
    values = {}
    for line in result.stdout.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


def profiles(chosen, store):
    """Ordered Wi-Fi profiles. Identity empty means a pre-shared key.

    Alpern-Home-5G is deliberately absent: the ESP32-S3 radio is 2.4 GHz only,
    so a 5 GHz SSID can never associate however correct its passphrase.
    """
    catalogue = {
        # SSID_1 is "Alpern-Home-5G". The name is misleading: a 2.4 GHz-only
        # scan from the robot on 2026-09-15 saw it on channels 6 and 11, so the
        # eeros broadcast that SSID on both bands. Neither "Alpern-Home" nor
        # "Alpern-Fiber" is on the air here, so this is the home network.
        "home": ("KEYPATH_WIFI_SSID_1", None, "KEYPATH_WIFI_PASSWORD_1"),
        # Hacker Dojo is WPA2-Enterprise (PEAP), not a pre-shared key: the
        # identity is the account, which is why it needs its own shape here.
        "dojo": (None, "KEYPATH_HACKER_DOJO_USERNAME", "KEYPATH_HACKER_DOJO_PASSWORD"),
        "beach": ("KEYPATH_WIFI_SSID_4", None, "KEYPATH_WIFI_PASSWORD_4"),
        "phone": ("KEYPATH_WIFI_SSID_3", None, "KEYPATH_WIFI_PASSWORD_3"),
    }
    out = []
    for name in chosen:
        ssid_key, user_key, pass_key = catalogue[name]
        ssid = "Hacker Dojo" if name == "dojo" else store.get(ssid_key, "")
        identity = store.get(user_key, "") if user_key else ""
        password = store.get(pass_key, "")
        if not ssid or not password:
            raise SystemExit(f"missing credentials for {name}; check secrets.env")
        out.append((name, ssid, identity, password))
    return out


class Link:
    def __init__(self, port):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.saved = termios.tcgetattr(self.fd)
        raw = termios.tcgetattr(self.fd)
        raw[0] = raw[1] = raw[3] = 0
        raw[2] |= termios.CLOCAL | termios.CREAD
        termios.tcsetattr(self.fd, termios.TCSANOW, raw)

    def close(self):
        termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
        os.close(self.fd)

    def send(self, line):
        os.write(self.fd, (line + "\n").encode())
        time.sleep(0.15)

    def collect(self, seconds):
        """Return SBWF lines only, so a stray frame cannot flood the terminal."""
        end = time.monotonic() + seconds
        buffer = bytearray()
        lines = []
        while time.monotonic() < end:
            if select.select([self.fd], [], [], 0.1)[0]:
                buffer.extend(os.read(self.fd, 65536))
            while b"\n" in buffer:
                line, _, rest = buffer.partition(b"\n")
                buffer = bytearray(rest)
                text = line.decode("utf-8", "replace").strip()
                if text.startswith("SBWF "):
                    lines.append(text[5:])
        return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port")
    parser.add_argument("--home", action="store_true", help="home 2.4 GHz network")
    parser.add_argument("--dojo", action="store_true", help="Hacker Dojo (WPA2-Enterprise)")
    parser.add_argument("--beach", action="store_true")
    parser.add_argument("--phone", action="store_true", help="phone hotspot, last resort")
    parser.add_argument("--ota-password", action="store_true",
                        help="also set an OTA passphrase, read from STANBOT_OTA_PASSWORD")
    parser.add_argument("--scan", action="store_true", help="report visible networks and exit")
    parser.add_argument("--status", action="store_true", help="report stored profiles and exit")
    parser.add_argument("--forget", action="store_true", help="erase every stored credential")
    parser.add_argument("--join", action="store_true", help="start joining after provisioning")
    args = parser.parse_args()

    link = Link(args.port)
    try:
        link.send("X")  # stop any stream so replies are not buried in frames
        link.collect(0.5)
        if args.scan:
            link.send("W,SCAN")
            for line in link.collect(8):
                print(line)
            return
        if args.status:
            link.send("W,?")
            for line in link.collect(3):
                print(line)
            return
        if args.forget:
            link.send("W,X")
            for line in link.collect(3):
                print(line)
            return

        chosen = [n for n, on in (("home", args.home), ("dojo", args.dojo),
                                  ("beach", args.beach), ("phone", args.phone)) if on]
        if not chosen:
            raise SystemExit("choose at least one of --home --dojo --beach --phone")
        store = secrets()
        selected = profiles(chosen, store)
        for index, (name, ssid, identity, password) in enumerate(selected):
            link.send(f"W,S,{index},{ssid}")
            link.send(f"W,U,{index},{identity}")
            link.send(f"W,P,{index},{password}")   # value never printed
            kind = "enterprise" if identity else "pre-shared key"
            print(f"profile {index}: {name} -> {ssid} ({kind})")
        link.send(f"W,N,{len(selected)}")
        if args.ota_password:
            ota = store.get("STANBOT_OTA_PASSWORD", "")
            if not ota:
                raise SystemExit("STANBOT_OTA_PASSWORD is not in secrets.env; "
                                 'add it with: open -W -n "/Applications/Add Secret.app" '
                                 "--args --key STANBOT_OTA_PASSWORD")
            link.send(f"W,O,{ota}")
            print("ota passphrase stored")
        for line in link.collect(2):
            print(line)
        if args.join:
            link.send("W,GO")
            print("joining; this can take a few seconds per profile")
            for line in link.collect(30):
                print(line)
    finally:
        link.close()


if __name__ == "__main__":
    main()
