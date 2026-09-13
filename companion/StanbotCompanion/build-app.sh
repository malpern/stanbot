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
echo "$app_dir"
