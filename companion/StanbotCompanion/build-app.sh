#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
cd "$script_dir"
swift build -c release

# Assemble and sign in a staging bundle, then swap it into place. Never write
# into the live bundle: copying over Contents/MacOS/Stanbot rewrites the same
# inode a running copy is executing, and the next page macOS faults in fails
# its code-signature check, so the running app is SIGKILLed with "Code
# Signature Invalid" (seen 2026-09-16, surfacing in NetworkReader.receive).
# A rename leaves the running process on the old, now-unlinked files.
final_dir="$script_dir/build/Stanbot.app"
app_dir="$script_dir/build/Stanbot.app.staging"
rm -rf "$app_dir" build/AppIcon.iconset
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources" build/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" App/StanbotIcon-v1.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" App/StanbotIcon-v1.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app_dir/Contents/Resources/AppIcon.icns"
cp App/Info.plist "$app_dir/Contents/Info.plist"
# Stanbot's Metal shaders (Shaders/*.metal) into one library in Resources. The
# app turns the effects off when the library is missing, so a failed compile
# only costs the look, never the app.
air_dir=$(mktemp -d)
for shader in Shaders/*.metal; do
  xcrun -sdk macosx metal -c "$shader" -o "$air_dir/${shader:t:r}.air"
done
xcrun -sdk macosx metallib "$air_dir"/*.air -o "$app_dir/Contents/Resources/StanbotShaders.metallib"
rm -rf "$air_dir"
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

old_dir="$script_dir/build/Stanbot.app.old"
rm -rf "$old_dir"
[[ -e "$final_dir" ]] && mv "$final_dir" "$old_dir"
mv "$app_dir" "$final_dir"
rm -rf "$old_dir"
if pgrep -f "$final_dir/Contents/MacOS/Stanbot" >/dev/null; then
  echo "note: Stanbot is running the previous build; quit and reopen to use this one." >&2
fi
echo "$final_dir"
