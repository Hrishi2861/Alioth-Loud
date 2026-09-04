#!/system/bin/sh
#
# alioth-loud :: post-fs-data stage
#
# Runs BEFORE the module overlay is mounted (guaranteed by Magisk, KernelSU
# and APatch). That ordering is the whole design: we read the live, unmodified
# vendor configs here, write patched copies into $MODDIR/system, and the root
# implementation then mounts them over the originals.
#
# Because the patch is generated from whatever is on the device right now, a
# HyperOS update that changes mixer_paths won't leave a stale file mounted.

MODDIR=${0%/*}
STATE_DIR=/data/adb/alioth_loud

mkdir -p "$STATE_DIR" 2>/dev/null

# ---- config: user copy is authoritative and survives module updates
CFG="$STATE_DIR/config.sh"
[ -f "$CFG" ] || cp -f "$MODDIR/common/config.sh" "$CFG" 2>/dev/null
# shellcheck source=/dev/null
. "$CFG" 2>/dev/null

. "$MODDIR/common/functions.sh"
. "$MODDIR/common/patch.sh"
. "$MODDIR/common/cirrus.sh"

log_rotate
log "post-fs-data start (module $(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2))"
log "device=$(getprop ro.product.device) rom=$(getprop ro.mi.os.version.incremental) sdk=$(getprop ro.build.version.sdk)"

# ===========================================================================
# bootloop guard -- must come first
# ===========================================================================
strikes=$(boot_strike_inc)
if [ "$strikes" -ge "$MAX_BOOT_STRIKES" ]; then
    self_disable "reached $strikes boots without ever seeing boot_completed"
    exit 0
fi

# ===========================================================================
# companion app: clear stale PackageManager cache
# ===========================================================================
# PackageManager keeps a parsed copy of each apk in /data/system/package_cache.
# On a device where the priv-app previously shipped an older APK, that cached
# entry can have an mtime NEWER than the freshly-mounted apk, so PM serves the
# STALE cached package instead of the mounted one: wrong version, no launcher
# icon, and the app refuses to open (theme/app not found). The mounted apk on
# disk is correct, but PM never re-reads it.
#
# This is exactly what BCR's ClearPackageManagerCaches does. Deleting the cache
# entry here (post-fs-data runs before zygote/system_server parses priv-apps)
# forces PM to re-parse the mounted apk on the next scan. It is a no-op on the
# first clean install and harmless every time after.
APP_ID="com.f3.aliothloud"
if [ -d /data/system/package_cache ]; then
    n=$(find /data/system/package_cache -maxdepth 1 -name "${APP_ID}-*" 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        find /data/system/package_cache -maxdepth 1 -name "${APP_ID}-*" -delete 2>/dev/null
        log "priv-app: cleared $n stale PackageManager cache entry/ies for $APP_ID"
    fi
fi

# ===========================================================================
# boot-generated overlay, rebuilt every boot
# ===========================================================================
# The priv-app and its allowlist are baked into the module archive at
# $MODDIR/system/priv-app and $MODDIR/system/etc/permissions (BCR-style), so
# the module manager mounts them on every boot and PackageManager always scans
# them. They are NOT rebuilt here and must not be wiped.
#
# The device-dependent config patches live under system/vendor, system/product
# and system/system_ext and ARE rebuilt each boot: stale overlay files are how
# config changes appear not to work and how a ROM update ends up with a
# mismatched mixer_paths mounted over it. Wipe only those roots, never the
# statically-baked priv-app/allowlist.
rm -rf "$MODDIR/system/vendor" \
       "$MODDIR/system/product" \
       "$MODDIR/system/system_ext" 2>/dev/null
mkdir -p "$MODDIR/system/vendor/etc" \
         "$MODDIR/system/product/etc" \
         "$MODDIR/system/system_ext/etc" 2>/dev/null

# ===========================================================================
# patches
# ===========================================================================
[ "${DRY_RUN:-0}" = "1" ] && log "*** DRY_RUN active - nothing will be mounted ***"

patch_volume_curves     # layer 3   safe
patch_mixer_gain        # layer 4a  risky, off by default
apply_props             # layer 3b  safe

log "post-fs-data done"
exit 0
