#!/system/bin/sh
#
# alioth-loud :: uninstall
#
# The XML patches live only in the module overlay, so removing the module
# already restores stock audio config. What needs active cleanup is anything
# we wrote outside the overlay: PA sysfs values and the watchdog process.

MODDIR=${0%/*}
STATE_DIR=/data/adb/alioth_loud

CFG="$STATE_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$CFG" ] && . "$CFG" 2>/dev/null
[ -f "$MODDIR/common/functions.sh" ] && . "$MODDIR/common/functions.sh"
[ -f "$MODDIR/common/cirrus.sh" ]   && . "$MODDIR/common/cirrus.sh"

# stop the PA watchdog
if [ -f "$STATE_DIR/.watchdog.pid" ]; then
    kill "$(cat "$STATE_DIR/.watchdog.pid")" 2>/dev/null
    rm -f "$STATE_DIR/.watchdog.pid"
fi

# put the amplifier back where the vendor left it
command -v cirrus_revert >/dev/null 2>&1 && cirrus_revert

# Props were set with resetprop on ro.* keys, which do not persist across a
# reboot, so there is nothing to undo there.

# Keep backups and logs -- they are small and useful if something is still off.
# Remove the rest.
rm -f "$STATE_DIR"/dryrun-* 2>/dev/null
rm -f "$STATE_DIR"/.tmp.* "$STATE_DIR"/.tmperr.* 2>/dev/null
rm -f "$STATE_DIR/.bootcount" "$STATE_DIR/disabled-reason.txt" 2>/dev/null

echo "alioth-loud uninstalled; stock config restored on next boot" \
    >>"$STATE_DIR/boot.log" 2>/dev/null

exit 0
