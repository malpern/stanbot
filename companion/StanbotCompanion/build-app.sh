#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
cd "$script_dir"
swift build -c release

app_dir="$script_dir/build/Stanbot.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources" build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" App/StanbotIcon-v1.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" App/StanbotIcon-v1.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
cp App/Info.plist "$app_dir/Contents/Info.plist"
cp .build/release/StanbotCompanion "$app_dir/Contents/MacOS/Stanbot"
chmod 755 "$app_dir/Contents/MacOS/Stanbot"

# Sign the assembled bundle, not just the binary. swift build leaves a
# linker-signed ad-hoc signature whose identifier is the product name and which
# does not cover Info.plist. macOS then cannot attribute the app for TCC, so the
# Local Network prompt never appears, the app never shows up under Privacy &
# Security, and NSLocalNetworkUsageDescription is ignored: the connection simply
# never completes and looks exactly like an unreachable robot.
#
# Prefer a real Developer ID identity over ad-hoc. An ad-hoc signature's
# designated requirement is derived from the binary itself, so every rebuild
# looks like a different app and macOS asks for Local Network again. A stable
# team identity means the permission is granted once and survives rebuilds.
identity=${STANBOT_SIGN_IDENTITY:-"Developer ID Application: Micah Alpern (X2RKZ5TG99)"}
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
  echo "warning: '$identity' not available, falling back to ad-hoc;" >&2
  echo "         expect the Local Network permission to be asked again after each build." >&2
  identity="-"
fi
codesign --force --sign "$identity" \
  --identifier com.malpern.stanbot-companion \
  --options runtime \
  --timestamp=none \
  "$app_dir"
codesign --verify --strict "$app_dir"
codesign -dv "$app_dir" 2>&1 | grep -E "^Identifier|^Authority|^TeamIdentifier" >&2
echo "$app_dir"
