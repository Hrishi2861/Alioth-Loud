#!/usr/bin/env bash
#
# alioth-loud :: build the flashable zip
#
#   ./build.sh              module only
#   ./build.sh --with-app   also build + bundle the companion APK
#   ./build.sh --test       run the awk patcher test suite only

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE="$ROOT/module"
DIST="$ROOT/dist"
STAGE="$ROOT/.stage"

WITH_APP=0
for a in "$@"; do
    case "$a" in
        --with-app) WITH_APP=1 ;;
        --test)     "$ROOT/tools/test_patchers.sh" && "$ROOT/tools/test_cirrus.sh"; exit $? ;;        -h|--help)  sed -n '3,8p' "$0"; exit 0 ;;
    esac
done

VER=$(grep '^version=' "$MODULE/module.prop" | cut -d= -f2)
ZIP="$DIST/alioth-loud-${VER}.zip"

echo ":: alioth-loud $VER"

# ---------------------------------------------------------------- verify
echo ":: running test suites"
for t in test_patchers test_cirrus; do
    if "$ROOT/tools/$t.sh" >/dev/null 2>&1; then
        n=$("$ROOT/tools/$t.sh" 2>/dev/null | sed -n 's/^:: \([0-9]*\) passed.*/\1/p')
        echo "   $t: $n passed"
    else
        echo "!! $t FAILED - refusing to build"
        echo "   run ./build.sh --test to see why"
        exit 1
    fi
done

# Module scripts run under Android's mksh/busybox ash, so they must be strict
# POSIX sh. Host-side tooling is allowed to be bash.
echo ":: checking shell syntax"
fail=0
while IFS= read -r f; do
    sh -n "$f" 2>/dev/null || { echo "   POSIX sh error: ${f#$ROOT/}"; fail=1; }
done < <(find "$MODULE" -name '*.sh')

# probe.sh also runs on device -> POSIX
for f in "$ROOT/tools/probe.sh" "$ROOT/tools/probe_cirrus.sh"; do
    sh -n "$f" 2>/dev/null || { echo "   POSIX sh error: ${f#$ROOT/}"; fail=1; }
done

for f in "$ROOT/build.sh" "$ROOT/tools/test_patchers.sh" "$ROOT/tools/test_cirrus.sh"; do
    bash -n "$f" 2>/dev/null || { echo "   bash error: ${f#$ROOT/}"; fail=1; }
done
[ "$fail" = 0 ] || exit 1
echo "   syntax ok (module=posix, tooling=bash)"

# ----------------------------------------------------------------- stage
rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST"
cp -a "$MODULE/." "$STAGE/"

# ship the probe script inside the zip so it lands on device
mkdir -p "$STAGE/tools"
cp -f "$ROOT/tools/probe.sh" "$ROOT/tools/probe_cirrus.sh" "$STAGE/tools/"

# ------------------------------------------------------------------- app
if [ "$WITH_APP" = 1 ]; then
    APK=$(find "$ROOT/app" -name '*-release*.apk' -o -name '*-debug*.apk' 2>/dev/null | head -1 || true)
    if [ -z "$APK" ]; then
        echo "!! --with-app given but no APK found under app/"
        echo "   build it first, then re-run"
        exit 1
    fi
    mkdir -p "$STAGE/payload/priv-app/AliothLoud"
    cp -f "$APK" "$STAGE/payload/priv-app/AliothLoud/AliothLoud.apk"
    echo ":: bundled app: $(basename "$APK")"
else
    # No APK yet: drop the permissions payload too, otherwise we mount an
    # allowlist for a package that isn't installed. Harmless, but noisy in
    # logcat and confusing when debugging.
    rm -rf "$STAGE/payload"
    echo ":: module only (no app bundled)"
fi

# --------------------------------------------------------------- package
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true
rm -f "$ZIP"
( cd "$STAGE" && zip -q -r9 "$ZIP" . -x '.*' )
rm -rf "$STAGE"

echo ":: $ZIP"
echo "   $(du -h "$ZIP" | cut -f1)"
unzip -l "$ZIP" | tail -n +4 | head -n -2 | awk '{printf "     %s\n", $4}' | sed '/^     $/d'
