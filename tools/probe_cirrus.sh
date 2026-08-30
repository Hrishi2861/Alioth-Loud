#!/system/bin/sh
#
# alioth-loud :: Cirrus CS35L41 control probe
#
# The first probe found the amplifier but not its limits. This one reads the
# ALSA mixer ranges and enum choices for the amp controls, which is what
# layer 4b needs before it is allowed to write anything.
#
# Why ALSA and not sysfs: alioth's amps are ASoC codec components on
# TERT_MI2S, so they expose no /sys gain nodes at all -- the first probe's
# pa-nodes.txt came back empty. Everything is a mixer control.
#
# Usage:  su -c 'sh /sdcard/probe_cirrus.sh'
# Result: /sdcard/alioth-cirrus-probe.txt
#
# Read-only. Sets nothing.

set -u
OUT=/sdcard/alioth-cirrus-probe.txt
: >"$OUT"

say() { echo "$@"; }
log() { echo "$@" >>"$OUT"; }

[ "$(id -u)" = "0" ] || { say "!! run as root: su -c 'sh $0'"; exit 1; }

TM=""
for t in tinymix /system/bin/tinymix /vendor/bin/tinymix; do
    command -v "$t" >/dev/null 2>&1 && { TM="$t"; break; }
done
[ -n "$TM" ] || { say "!! tinymix not found"; exit 1; }

log "tinymix   = $TM"
log "device    = $(getprop ro.product.device)"
log "rom       = $(getprop ro.mi.os.version.incremental)"
log "card      = $(sed -n '1p' /proc/asound/cards 2>/dev/null)"
log ""

# ---------------------------------------------------------------------------
# tinymix syntax differs by vendor build. Detect which form works so the
# module doesn't have to guess later.
# ---------------------------------------------------------------------------
log "=== TINYMIX SYNTAX DETECTION ==="
log "-- '\$TM --version':"
$TM --version 2>&1 | head -3 | sed 's/^/    /' >>"$OUT"
log "-- '\$TM help':"
$TM help 2>&1 | head -12 | sed 's/^/    /' >>"$OUT"

SYNTAX=""
if $TM get 'AMP PCM Gain' >/dev/null 2>&1; then
    SYNTAX="get/set"
elif $TM 'AMP PCM Gain' >/dev/null 2>&1; then
    SYNTAX="bare-name"
elif $TM 53 >/dev/null 2>&1; then
    SYNTAX="bare-id"
fi
log "detected syntax = ${SYNTAX:-UNKNOWN}"
log ""

# read a control every way we can, so the output is useful whichever
# tinymix this build ships
dump_ctl() {
    name="$1"; id="$2"
    log "---- [$id] $name"
    for form in "get $name" "get $id" "$name" "$id"; do
        # shellcheck disable=SC2086
        r=$($TM $form 2>&1)
        st=$?
        case "$r" in
            *"nvalid"*|*"sage:"*|*"annot"*|*"ailed"*) continue ;;
        esac
        [ -z "$r" ] && continue
        log "     (\$TM $form) rc=$st"
        echo "$r" | head -8 | sed 's/^/       /' >>"$OUT"
        break
    done
}

# ---------------------------------------------------------------------------
# The controls layer 4b could plausibly touch, with the ids seen in the first
# probe. ids can shift between boots/ROMs, so names are the primary key.
# ---------------------------------------------------------------------------
log "=== CS35L41 BOTTOM / MAIN AMP (i2c 1-0041) ==="
dump_ctl 'Digital PCM Volume'              52
dump_ctl 'AMP PCM Gain'                    53
dump_ctl 'Boost Class-H Tracking Enable'   60
dump_ctl 'Boost Target Voltage'            61
dump_ctl 'Class-H Head Room'               63
dump_ctl 'DSP1 Firmware'                   50

log ""
log "=== CS35L41 TOP / RCV AMP (i2c 1-0040) ==="
dump_ctl 'RCV Digital PCM Volume'           27
dump_ctl 'RCV AMP PCM Gain'                 28
dump_ctl 'RCV Boost Class-H Tracking Enable' 35
dump_ctl 'RCV Boost Target Voltage'         36
dump_ctl 'RCV Class-H Head Room'            38
dump_ctl 'RCV DSP1 Firmware'                25

log ""
log "=== CIRRUS SPEAKER PROTECTION (HAL level) ==="
dump_ctl 'Cirrus SP Volume Attenuation'    4161
dump_ctl 'Cirrus SP Protection'            4155
dump_ctl 'Cirrus SP'                       4154
dump_ctl 'Cirrus SP Usecase'               4156
dump_ctl 'Cirrus SP FBPort'                4153

log ""
log "=== WCD9385 CODEC (layer 4a targets -- headset/earpiece path) ==="
dump_ctl 'RX_RX0 Digital Volume'            194
dump_ctl 'RX_RX1 Digital Volume'            195
dump_ctl 'RX_RX2 Digital Volume'            196
dump_ctl 'HPHL Volume'                      4189
dump_ctl 'HPHR Volume'                      4190
dump_ctl 'EAR PA Gain'                      4169

log ""
log "=== CSPL DSP PARAMS (raw byte controls -- informational only) ==="
# 4-byte HALO DSP words. Format/scaling is undocumented publicly, so the
# module will not write these; captured only to understand the gain staging.
dump_ctl 'DSP1X Protection cd CSPL_OVERSIGHT_GAIN'     5390
dump_ctl 'RCV DSP1X Protection cd CSPL_OVERSIGHT_GAIN' 5347
dump_ctl 'DSP1X Protection cd CSPL_ENABLE'             5385
dump_ctl 'RCV DSP1X Protection cd CSPL_TEMPERATURE'    5346

log ""
log "=== FULL ENUM/RANGE DUMP ATTEMPT ==="
# Some builds support 'contents', which prints every control WITH its range
# and enum choices in one go. If it works it supersedes everything above.
if $TM contents >/dev/null 2>&1; then
    log "'tinymix contents' supported -- capturing amp-related entries"
    $TM contents 2>/dev/null | grep -iE -A3 \
        'cirrus|cspl|AMP PCM Gain|Digital PCM Volume|Boost|Class-H|EAR PA|HPH|RX_RX' \
        | head -200 | sed 's/^/    /' >>"$OUT"
else
    log "'tinymix contents' NOT supported on this build"
fi

log ""
log "=== CURRENT SPEAKER ROUTE (for reference) ==="
log "amps sit on TERT_MI2S per 'Cirrus SP FBPort'; confirm the mixer is on:"
for form in "get TERT_MI2S_RX Audio Mixer MultiMedia1" "TERT_MI2S_RX Audio Mixer MultiMedia1"; do
    # shellcheck disable=SC2086
    r=$($TM $form 2>&1); case "$r" in *"nvalid"*|*"sage:"*) continue ;; esac
    [ -n "$r" ] && { echo "$r" | sed 's/^/    /' >>"$OUT"; break; }
done

chmod 0644 "$OUT" 2>/dev/null

say ""
say ":: written to $OUT"
say ""
say "   send it back. layer 4b stays disabled until the ranges are known --"
say "   it clamps writes against the range tinymix reports, so it needs this."
say ""
say "--- preview ---"
sed -n '/=== CS35L41 BOTTOM/,/=== CIRRUS SPEAKER/p' "$OUT" | head -30
