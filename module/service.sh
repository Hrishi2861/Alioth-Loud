#!/system/bin/sh
#
# alioth-loud :: late_start service stage
#
# Two jobs:
#   1. clear the bootloop counter once the system genuinely finished booting
#      -- this is the signal that whatever we patched did not break audio init
#   2. apply the smart PA override, which can only be done after the audio HAL
#      has brought the amplifier up

MODDIR=${0%/*}
STATE_DIR=/data/adb/alioth_loud

CFG="$STATE_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$CFG" ] && . "$CFG" 2>/dev/null

. "$MODDIR/common/functions.sh"
. "$MODDIR/common/cirrus.sh"

# --------------------------------------------------- wait for a real boot
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
done

if [ "$(getprop sys.boot_completed)" = "1" ]; then
    boot_strike_clear
    log "boot_completed after ${i}s - strike counter cleared"
else
    warn "boot_completed never seen after ${i}s - leaving strike counter set"
fi

# Give the audio HAL a moment to finish enumerating the amp before we poke it.
sleep 3

cirrus_apply
cirrus_watchdog

# ------------------------------------------------------------- diagnostics
log "--- effective state ---"
log "media_vol_steps = $(getprop ro.config.media_vol_steps)"
for f in $(find_audio_conf 'audio_policy_volumes*.xml'); do
    log "mounted $f -> $(stat -c %s "$f" 2>/dev/null) bytes"
done
log "service done"
exit 0
