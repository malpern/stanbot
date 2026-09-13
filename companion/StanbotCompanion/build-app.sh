#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
cd "$script_dir"
swift build -c release

app_dir="$script_dir/build/Stanbot.app"
mkdir -p "$app_dir/Contents/MacOS"
cp App/Info.plist "$app_dir/Contents/Info.plist"
cp .build/release/StanbotCompanion "$app_dir/Contents/MacOS/Stanbot"
chmod 755 "$app_dir/Contents/MacOS/Stanbot"
echo "$app_dir"
