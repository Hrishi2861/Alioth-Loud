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

# ------------------------------------------------------------- what's on
ui_print " "
ui_print "  enabled now:"
ui_print "   [x] layer 3   curve flatten 0.55  (+12.7 dB at half vol)"
ui_print "   [x] layer 3b  volume steps 30 -> 50"
ui_print "   [ ] layer 4a  WCD RX gain    headset/earpiece only"
ui_print "   [ ] layer 4b  CS35L41 amp    needs probe_cirrus.sh"
ui_print " "
ui_print "  NOTE: at MAX volume layer 3 changes nothing -- stock"
ui_print "        attenuation there is already 0 dB. It makes every"
ui_print "        step BELOW max louder. For beyond-max you need the"
ui_print "        app (compression) or layer 4b (amp gain)."
ui_print " "
ui_print "  next:"
ui_print "   1. reboot"
ui_print "   2. su -c 'sh /sdcard/probe_cirrus.sh'"
ui_print "   3. send /sdcard/alioth-cirrus-probe.txt back"
ui_print " "
ui_print "  safety: 3 boots without boot_completed and the module"
ui_print "          disables itself automatically."
ui_print "  log:    $STATE_DIR/boot.log"
ui_print " "
