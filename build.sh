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
    APK=$(find "$ROOT/app" -path '*/outputs/apk/release/*.apk' 2>/dev/null | head -1 || true)
    [ -n "$APK" ] || APK=$(find "$ROOT/app" -name '*-release*.apk' 2>/dev/null | head -1 || true)
    if [ -z "$APK" ]; then
        echo "!! --with-app given but no release APK found under app/"
        echo "   cd app && ANDROID_HOME=/opt/android-sdk gradle :app:assembleRelease"
        exit 1
    fi

    BT=$(ls -d /opt/android-sdk/build-tools/* 2>/dev/null | sort -V | tail -1)
    AAPT2="$BT/aapt2"; APKSIGNER="$BT/apksigner"
    XML="$MODULE/system/etc/permissions/privapp-permissions-aliothloud.xml"

    # --- icon assets. These fail silently at runtime rather than at build time:
    # a monochrome layer with an opaque background gives a solid blob for the
    # themed icon, and a notification glyph at the adaptive layer's 40% fill
    # looks like a speck in the status bar. Checked here so neither ships.
    if python3 -c 'import PIL' 2>/dev/null; then
        if python3 "$ROOT/tools/verify_icon.py" >/dev/null 2>&1; then
            echo ":: icon assets ok"
        else
            echo "!! icon checks FAILED - refusing to build"
            python3 "$ROOT/tools/verify_icon.py" | grep -E 'FAIL|failed' | sed 's/^/   /'
            exit 1
        fi
    else
        echo ":: icon checks skipped (no Pillow)"
    fi

    # --- signature must be valid, or the priv-app simply will not install
    if [ -x "$APKSIGNER" ]; then
        "$APKSIGNER" verify "$APK" >/dev/null 2>&1 \
            && echo ":: apk signature ok" \
            || { echo "!! APK signature invalid"; exit 1; }
    fi

    # --- allowlist must cover every signature|privileged permission requested.
    #
    # This is not cosmetic. PermissionManagerService throws when a priv-app
    # requests a signature|privileged permission that is not allowlisted, and on
    # some builds that is a boot failure rather than a logged warning. The
    # manifest and the XML are two files that must agree, which is exactly the
    # kind of thing that silently drifts, so it is checked on every build.
    if [ -x "$AAPT2" ] && [ -f "$XML" ]; then
        want=$("$AAPT2" dump permissions "$APK" 2>/dev/null \
               | sed -n "s/^uses-permission: name='\(android\.permission\.[A-Z_]*\)'/\1/p" \
               | grep -E 'MODIFY_DEFAULT_AUDIO_EFFECTS|MODIFY_AUDIO_ROUTING|MODIFY_AUDIO_SETTINGS_PRIVILEGED' \
               | sort -u)
        have=$(grep -o 'android\.permission\.[A-Z_]*' "$XML" | sort -u)
        missing=$(comm -23 <(echo "$want") <(echo "$have") || true)
        if [ -n "$missing" ]; then
            echo "!! privileged permissions requested by the APK but NOT allowlisted:"
            echo "$missing" | sed 's/^/     /'
            echo "   add them to $(basename "$XML") or the device may fail to boot"
            exit 1
        fi
        echo ":: privapp allowlist consistent ($(echo "$want" | wc -w) privileged perms)"

        # And the reverse: an allowlist entry for a permission the app no longer
        # requests is harmless but means the files have drifted.
        extra=$(comm -13 <(echo "$want") <(echo "$have") || true)
        [ -n "$extra" ] && echo "   note: allowlisted but unused: $(echo "$extra" | tr '\n' ' ')"
    fi

    # BCR-style: the APK is baked into the module's own system/ overlay, so the
    # module manager (Magisk magic-mount / KernelSU overlayfs) mounts it and
    # PackageManager scans it on every boot, no runtime copy needed.
    mkdir -p "$STAGE/system/priv-app/AliothLoud"
    cp -f "$APK" "$STAGE/system/priv-app/AliothLoud/AliothLoud.apk"
    echo ":: bundled app: $(basename "$APK") ($(du -h "$APK" | cut -f1))"
else
    # No APK: drop the baked priv-app + allowlist, otherwise we mount an
    # allowlist for a package that is not installed. Harmless, but noisy in
    # logcat and confusing when debugging.
    rm -rf "$STAGE/system/priv-app"
    rm -f "$STAGE/system/etc/permissions/privapp-permissions-aliothloud.xml"
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
