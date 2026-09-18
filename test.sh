#!/usr/bin/env bash
# Every test in the repo, in one command.
#
# There are four kinds and they run four different ways: native C++ for the
# firmware's pure logic, Python for the companion scripts and the tools, and
# Swift for the app. Running them by hand means four loops and remembering all
# four, which is how one gets skipped before a commit.
#
#   ./test.sh            # everything
#   ./test.sh --quick    # skip the Swift suite (~26 s of the total)
#
# Exits non-zero if anything failed, and prints one summary line naming what.
set -uo pipefail
cd "$(dirname "$0")"

quick=0
[[ "${1:-}" == "--quick" ]] && quick=1

failed=()
passed=0

run() {   # run <name> <command...>
  local name="$1"; shift
  if "$@" >/tmp/stanbot-test.$$ 2>&1; then
    passed=$((passed + 1))
  else
    failed+=("$name")
    echo "--- FAILED: $name"
    tail -25 /tmp/stanbot-test.$$
  fi
  rm -f /tmp/stanbot-test.$$
}

echo "native firmware tests"
for source in companion/test_*.cpp; do
  name="$(basename "$source")"
  binary="/tmp/stanbot-$(basename "$source" .cpp)"
  if c++ -std=c++17 -include initializer_list -I companion/stubs "$source" -o "$binary" 2>/tmp/stanbot-build.$$; then
    run "$name" "$binary"
  else
    failed+=("$name (does not compile)")
    echo "--- FAILED to compile: $name"
    head -25 /tmp/stanbot-build.$$
  fi
  rm -f "$binary" /tmp/stanbot-build.$$
done

echo "python tests"
for source in companion/test_*.py tools/test_*.py; do
  run "$(basename "$source")" python3 "$source"
done

if [[ $quick -eq 0 ]]; then
  # Compile the Metal shaders so the tests that need them actually RUN. They
  # skip themselves without a library, and a skipped test is not a passing one:
  # the eye veil shipped an opaque-black frame that covered the face during the
  # opening sequence, and the check for it would have sat skipped forever.
  shader_lib=""
  if command -v xcrun >/dev/null && [[ -d companion/StanbotCompanion/Shaders ]]; then
    air=$(mktemp -d)
    ok=1
    for shader in companion/StanbotCompanion/Shaders/*.metal; do
      name=$(basename "$shader" .metal)
      xcrun -sdk macosx metal -c "$shader" -o "$air/$name.air" 2>/dev/null || ok=0
    done
    if [[ $ok -eq 1 ]] && xcrun -sdk macosx metallib "$air"/*.air -o "$air/StanbotShaders.metallib" 2>/dev/null; then
      shader_lib="$air/StanbotShaders.metallib"
      echo "swift tests (with shaders)"
    else
      echo "swift tests (shaders did not build; those tests will skip)"
    fi
  else
    echo "swift tests"
  fi
  run "swift test" env -C companion/StanbotCompanion STANBOT_SHADER_LIBRARY="$shader_lib" swift test
else
  echo "swift tests skipped (--quick)"
fi

echo
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "all $passed test suites passed"
  exit 0
fi
echo "$passed passed, ${#failed[@]} FAILED: ${failed[*]}"
exit 1
