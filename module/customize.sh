#!/system/bin/sh
#
# alioth-loud :: install-time
#
# Runs inside the Magisk/KSU/APatch installer. MODPATH, API, ARCH, ui_print
# and abort are provided by the environment.

STATE_DIR=/data/adb/alioth_loud

ui_print " "
ui_print "  alioth-loud  $(grep '^version=' "$MODPATH/module.prop" | cut -d= -f2)"
ui_print "  volume ceiling removal for Poco F3"
ui_print " "

# ------------------------------------------------------------ environment
DEV=$(getprop ro.product.device)
ui_print "- device : $DEV"
ui_print "- android: $(getprop ro.build.version.release) (sdk $API)"
ui_print "- rom    : $(getprop ro.mi.os.version.incremental)"
ui_print "- arch   : $ARCH"

if [ "$API" -lt 31 ]; then
    abort "! needs Android 12+ (sdk 31); found sdk $API"
fi

case "$DEV" in
    alioth|aliothin)
        ui_print "- target device confirmed (probe-verified)"
        ;;
    *)
        ui_print " "
        ui_print "  ! this module was written for alioth (Poco F3)"
        ui_print "  ! '$DEV' is untested - layers 4a/4b stay disabled"
        ui_print "  ! layer 3 is generic and should still work"
        ui_print " "
        ;;
esac

# ---------------------------------------------------------------- config
if [ -f "$STATE_DIR/config.sh" ]; then
    ui_print "- keeping existing config at $STATE_DIR/config.sh"
else
    mkdir -p "$STATE_DIR"
    cp -f "$MODPATH/common/config.sh" "$STATE_DIR/config.sh"
    ui_print "- config installed to $STATE_DIR/config.sh"
fi

# Drop the probe script somewhere reachable without a PC.
for pb in probe.sh probe_cirrus.sh; do
    if [ -f "$MODPATH/tools/$pb" ]; then
        cp -f "$MODPATH/tools/$pb" "/sdcard/$pb" 2>/dev/null && \
            ui_print "- /sdcard/$pb"
    fi
done

# ----------------------------------------------------------- permissions
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh"      0 0 0755
set_perm "$MODPATH/uninstall.sh"    0 0 0755
find "$MODPATH/common" -name '*.sh' -exec chmod 0755 {} + 2>/dev/null
for pb in probe.sh probe_cirrus.sh; do
    [ -f "$MODPATH/tools/$pb" ] && set_perm "$MODPATH/tools/$pb" 0 0 0755
done

# ----------------------------------------------------- priv-app overlay base
# Materialize the system overlay at INSTALL time, not only at boot. If it only
# appears in post-fs-data.sh, whether PackageManager sees the app on the first
# boot depends on the module manager mounting after that script runs: Magisk
# does, but KernelSU (overlayfs/metamodule) can snapshot the module tree in a
# way that misses an overlay created later, leaving a priv-app that never gets
# scanned (no launcher icon, "install manually"). Shipping it here means the
# overlay is part of the installed module from the start, whatever the manager.
# post-fs-data.sh still rebuilds it afterwards, so it stays true to the live
# device configs without depending on boot timing.
if [ -d "$MODPATH/payload/priv-app" ]; then
    mkdir -p "$MODPATH/system/priv-app" "$MODPATH/system/etc/permissions"
    cp -a "$MODPATH/payload/priv-app/." "$MODPATH/system/priv-app/" 2>/dev/null
    [ -d "$MODPATH/payload/permissions" ] && \
        cp -a "$MODPATH/payload/permissions/." "$MODPATH/system/etc/permissions/" 2>/dev/null
    find "$MODPATH/system/priv-app" "$MODPATH/system/etc/permissions" \
        -type d -exec chmod 0755 {} + 2>/dev/null
    find "$MODPATH/system/priv-app" "$MODPATH/system/etc/permissions" \
        -type f -exec chmod 0644 {} + 2>/dev/null
    chown -R 0:0 "$MODPATH/system/priv-app" "$MODPATH/system/etc/permissions" 2>/dev/null
    ui_print "- priv-app overlay staged at install (system/priv-app)"
fi

# ------------------------------------------------------------- what's on
ui_print " "
ui_print "  enabled now:"
ui_print "   [x] layer 3   curve flatten 0.55  (+12.7 dB at half vol)"
ui_print "   [x] layer 3b  volume steps 30 -> 50"
ui_print "   [ ] layer 4a  WCD RX gain    headset/earpiece only"
ui_print "   [ ] layer 4b  CS35L41 amp    ~1-2 dB left in hardware"
if [ -d "$MODPATH/payload/priv-app" ]; then
ui_print "   [x] layers 1-2  Alioth Loud app (priv-app)"
else
ui_print "   [ ] layers 1-2  app not bundled in this zip"
fi
ui_print " "
ui_print "  MAX VOLUME: layer 3 does nothing at max -- stock"
ui_print "  attenuation there is already 0 dB. It makes every step"
ui_print "  BELOW max louder. To go beyond max, open the Alioth"
ui_print "  Loud app and turn it on; that is compression, which"
ui_print "  raises average level without clipping."
ui_print " "
ui_print "  next:"
ui_print "   1. reboot"
ui_print "   2. open Alioth Loud, check it says privileged: yes"
ui_print "   3. pick the Loud preset, then raise makeup gain"
ui_print " "
ui_print "  safety: 3 boots without boot_completed and the module"
ui_print "          disables itself automatically."
ui_print "  log:    $STATE_DIR/boot.log"
ui_print " "
