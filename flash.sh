#!/usr/bin/env bash
# Put the working tree on the robot, and say honestly whether it landed.
#
# This was six manual steps with two traps, both of which have been walked into
# more than once and are in the handoff notes because of it:
#
#   * `swift build` does NOT produce the app. Shipping a stale bundle next to
#     new firmware makes a working feature look broken (2026-09-17).
#   * a flash can fail with "no V reply" and still LOOK like it worked if the
#     result is not read. A flash reported as done without reading the result
#     is how the robot ran old firmware for an afternoon.
#
# So this refuses to lie: it reads the verification, compares the commit the
# robot reports against the one that was built, and exits non-zero otherwise.
#
#   ./flash.sh                # test, build, flash, verify
#   ./flash.sh --skip-tests   # when they were just run
#   ./flash.sh --app-only     # rebuild and restart the Mac app, no firmware
set -uo pipefail
cd "$(dirname "$0")"

MINI="${STANBOT_MINI:-malpern@openclaw.local}"
APP="companion/StanbotCompanion/build/Stanbot.app"

skip_tests=0
app_only=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) skip_tests=1 ;;
    --app-only) app_only=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$1"; }
die() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

if [[ $skip_tests -eq 0 ]]; then
  say "tests"
  ./test.sh || die "tests failed; nothing was flashed"
fi

# Uncommitted firmware makes the robot report dirty:true, which makes it
# impossible to say later what it is actually running.
if [[ $app_only -eq 0 ]] && ! git diff --quiet -- firmware/; then
  die "uncommitted changes under firmware/ -- commit them first, or the robot reports dirty:true"
fi

say "building the Mac app"
(cd companion/StanbotCompanion && ./build-app.sh) >/tmp/stanbot-app-build.log 2>&1 \
  || { tail -20 /tmp/stanbot-app-build.log; die "the app did not build"; }
echo "built $APP"

if [[ $app_only -eq 1 ]]; then
  say "restarting the app"
  osascript -e 'quit app "Stanbot"' 2>/dev/null
  sleep 2
  open "$APP"
  echo "app restarted; firmware untouched"
  exit 0
fi

say "building the firmware"
built=$(STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1 STANBOT_FOLLOW_YAW_RANGE=288 \
        firmware/build.sh 2>/tmp/stanbot-build.log | grep -E '^\{' | tail -1)
[[ -n "$built" ]] || { tail -20 /tmp/stanbot-build.log; die "the firmware did not build"; }
echo "$built"
commit=$(printf '%s' "$built" | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"])')
dirty=$(printf '%s' "$built" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dirty"])')
[[ "$dirty" == "False" ]] || die "built from uncommitted changes; the robot would report dirty:true"

say "pushing, so the mini can pull it"
git push -q origin HEAD || die "could not push; the mini flashes what it can pull"

# The app holds the robot's one Wi-Fi viewer slot, and OTA needs it.
say "quitting the app"
osascript -e 'quit app "Stanbot"' 2>/dev/null
sleep 3

say "flashing over the air (agent shells cannot reach the LAN; the mini can)"
result=$(ssh "$MINI" 'cd ~/local-code/stanbot && git pull -q; python3 firmware/ota.py' 2>&1 | grep -E '^\{' | tail -1)
echo "$result"

verified=$(printf '%s' "$result" | python3 -c '
import json, sys
try:
    got = json.load(sys.stdin)
except ValueError:
    print("unreadable"); raise SystemExit
after = got.get("after") or {}
print("yes" if got.get("verified") and after.get("commit", "").startswith(sys.argv[1]) else "no")
' "$commit" 2>/dev/null)

say "reopening the app"
open "$APP"
sleep 6

if [[ "$verified" != "yes" ]]; then
  die "the robot is NOT running $commit -- read the result above. A common cause is
       'no V reply', where the app had not released the viewer slot; wait a few
       seconds and run this again."
fi

say "what the robot says it is running"
python3 tools/stanbot status || true
printf '\nflashed and verified: %s\n' "$commit"
