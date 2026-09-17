#!/bin/zsh
# Build (if needed) and run the desk camera coexistence probe. Needs a Studio Display.
# Run it from Terminal so macOS can ask for camera permission once.
set -euo pipefail
here=${0:A:h}
bin=${TMPDIR:-/tmp}/stanbot-desk-camera-probe
if [[ ! -x $bin || $here/DeskCameraProbe.swift -nt $bin ]]; then
  swiftc -O "$here/DeskCameraProbe.swift" -o "$bin"
fi
exec "$bin" "$@"
