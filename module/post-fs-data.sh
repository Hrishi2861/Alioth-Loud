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
# rebuild the overlay from scratch every boot
# ===========================================================================
# Stale overlay files are how config changes appear not to work and how a
# ROM update ends up with a mismatched mixer_paths mounted over it.
rm -rf "$MODDIR/system" 2>/dev/null
mkdir -p "$MODDIR/system" 2>/dev/null

# ===========================================================================
# companion app as privileged system app
# ===========================================================================
# A normal APK cannot attach an effect to global session 0; it can only
# process its own output. MODIFY_AUDIO_ROUTING is signature|privileged, so
# the app has to live in priv-app with an explicit allowlist entry.
install_priv_app() {
    [ "${INSTALL_PRIV_APP:-0}" = "1" ] || { log "priv-app: disabled"; return 0; }
    [ -d "$MODDIR/payload/priv-app" ] || { log "priv-app: no payload in this build"; return 0; }

    cp -a "$MODDIR/payload/priv-app" "$MODDIR/system/priv-app" 2>/dev/null || {
        warn "priv-app: copy failed"; return 1; }

    mkdir -p "$MODDIR/system/etc/permissions" 2>/dev/null
    [ -d "$MODDIR/payload/permissions" ] && \
        cp -a "$MODDIR/payload/permissions/." "$MODDIR/system/etc/permissions/" 2>/dev/null

    find "$MODDIR/system/priv-app" "$MODDIR/system/etc/permissions" \
        -type d -exec chmod 0755 {} + 2>/dev/null
    find "$MODDIR/system/priv-app" "$MODDIR/system/etc/permissions" \
        -type f -exec chmod 0644 {} + 2>/dev/null
    chown -R 0:0 "$MODDIR/system/priv-app" "$MODDIR/system/etc/permissions" 2>/dev/null

    log "priv-app: installed"
}
install_priv_app

# ===========================================================================
# patches
# ===========================================================================
[ "${DRY_RUN:-0}" = "1" ] && log "*** DRY_RUN active - nothing will be mounted ***"

patch_volume_curves     # layer 3   safe
patch_mixer_gain        # layer 4a  risky, off by default
apply_props             # layer 3b  safe

log "post-fs-data done"
exit 0
