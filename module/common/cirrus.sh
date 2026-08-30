#!/system/bin/sh
#
# alioth-loud :: layer 4b -- Cirrus CS35L41 amplifier gain
#
#                    *** THIS LAYER CAN DESTROY YOUR SPEAKERS ***
#
# alioth drives two Cirrus Logic CS35L41 amps (rev B2) over I2C:
#   1-0040  "RCV" prefix   top speaker / earpiece-tweeter
#   1-0041  no prefix      bottom main speaker
# Both run Cirrus speaker-protection firmware in their on-chip HALO DSP
# (CSPL_ENABLE=1), which limits excursion and coil temperature using per-unit
# factory calibration.
#
# IMPORTANT ARCHITECTURE NOTE
# These amps are ASoC codec components, not platform devices with sysfs gain
# nodes. The first probe's /sys scan came back completely empty. Every knob is
# an ALSA mixer control, so this layer drives tinymix, not file writes. An
# earlier version of this file targeted /sys paths and could never have worked
# on this device.
#
# WHY THIS IS THE ONLY LAYER THAT RAISES SPEAKER SPL
# The speaker route is  MultiMedia1 -> TERT_MI2S_RX -> CS35L41, which bypasses
# the WCD9385 codec entirely. That means layer 4a (RX_RX* Digital Volume) does
# nothing for the speakers -- it only affects the headset/earpiece path. Real
# acoustic gain on speaker has to come from the amps themselves, or from
# compression upstream in the framework (layers 1-2).
#
# SAFETY MODEL
#   - requires ENABLE_CIRRUS_GAIN=1 AND I_ACCEPT_SPEAKER_DAMAGE_RISK=1
#   - never writes a value it has not first validated against the range that
#     tinymix itself reports for that control
#   - refuses to exceed CIRRUS_MAX_HEADROOM_FRACTION of available headroom
#   - records stock values on first touch so revert is always possible
#   - a phone micro-speaker has roughly 3-6 dB of abuse headroom. The failure
#     mode is a burnt voice coil: permanent, and not a software problem.

CIRRUS_TM=""

cirrus_tool() {
    [ -n "$CIRRUS_TM" ] && return 0
    for t in tinymix /system/bin/tinymix /vendor/bin/tinymix; do
        if command -v "$t" >/dev/null 2>&1; then CIRRUS_TM="$t"; return 0; fi
    done
    warn "layer4b: tinymix not found - cannot reach the amps"
    return 1
}

cirrus_guard() {
    [ "${ENABLE_CIRRUS_GAIN:-0}" = "1" ] || { log "layer4b: disabled"; return 1; }

    if [ "${I_ACCEPT_SPEAKER_DAMAGE_RISK:-0}" != "1" ]; then
        warn "layer4b: enabled but risk not acknowledged - refusing"
        return 1
    fi
    cirrus_tool || return 1
    return 0
}

# ---------------------------------------------------------------------------
# read a control's current value; echoes bare value or empty
# ---------------------------------------------------------------------------
cirrus_get() {
    name="$1"
    for form in "get" ""; do
        # shellcheck disable=SC2086
        r=$($CIRRUS_TM $form "$name" 2>/dev/null) || continue
        case "$r" in ""|*nvalid*|*sage:*|*annot*) continue ;; esac
        # tinymix prints either a bare "1841" or "Name: 1841 (dsrange 0->20)".
        # Strip from the first '(' rather than matching "(range", because this
        # build says "dsrange" -- anchoring on "range" left the whole suffix
        # attached and produced "18(dsrange0->20)", which then failed the
        # numeric check and silently disabled the layer.
        echo "$r" | sed -n '1s/.*: *//;1s/ *(.*//;1p' | tr -d ' \r'
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Parse the control's range from tinymix's own output and VALIDATE it.
#
# Echoes "lo hi" on success, nothing on failure. Callers must refuse to write
# when this yields nothing.
#
# This build of tinymix prints "dsrange", not "range":
#     AMP PCM Gain: 18 (dsrange 0->20)                 <- sane
#     Digital PCM Volume: 1841 (dsrange 0->-318)       <- NOT interpretable
#
# That second form is real, measured output. A naive ".*range ...->\(...\)"
# capture returns -318 as the maximum, and since the current value is 1841 the
# caller then concludes the control is already maxed and skips it -- safe by
# luck, wrong by reasoning, and it hides the fact that we do not understand the
# control. The CS35L41's AMP_VOL_PCM is a signed field with a TLV dB scale, so
# what the kernel reports as a "max" here is not a raw ceiling we can add to.
#
# Rule: hi must be numeric and strictly greater than lo, or we do not know the
# range and must not write.
# ---------------------------------------------------------------------------
cirrus_range() {
    name="$1"
    for form in "get" ""; do
        # shellcheck disable=SC2086
        r=$($CIRRUS_TM $form "$name" 2>/dev/null) || continue
        case "$r" in *range*) ;; *) continue ;; esac

        lo=$(echo "$r" | sed -n 's/.*range *\(-\{0,1\}[0-9]\{1,\}\)[ ]*->.*/\1/p'          | head -1)
        hi=$(echo "$r" | sed -n 's/.*range *-\{0,1\}[0-9]\{1,\}[ ]*->[ ]*\(-\{0,1\}[0-9]\{1,\}\).*/\1/p' | head -1)

        [ -n "$lo" ] && [ -n "$hi" ] || continue
        case "$lo$hi" in *[!0-9-]*) continue ;; esac

        if [ "$hi" -le "$lo" ] 2>/dev/null; then
            warn "layer4b: '$name' reports uninterpretable range ${lo}->${hi}"
            warn "         (signed/TLV-scaled control, not a raw ceiling) - refusing"
            return 1
        fi
        echo "$lo $hi"
        return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# cirrus_bump <control-name> <steps> <label>
#
# Adds <steps> to a control, but only after confirming the control exists, its
# value is numeric, and the result sits inside both the hardware range and the
# configured headroom fraction.
# ---------------------------------------------------------------------------
cirrus_bump() {
    name="$1"; steps="$2"; label="$3"

    [ -n "$steps" ] && [ "$steps" -gt 0 ] 2>/dev/null || return 0

    cur=$(cirrus_get "$name")
    if [ -z "$cur" ]; then
        warn "layer4b: control not readable, skipping: '$name'"
        return 1
    fi
    case "$cur" in
        ''|*[!0-9-]*) warn "layer4b: '$name' is not numeric ('$cur') - skipped"; return 1 ;;
    esac

    max=$(cirrus_range "$name" | awk '{print $2}')
    if [ -z "$max" ]; then
        warn "layer4b: no usable range for '$name' - refusing to write blind"
        warn "         (run tools/probe_cirrus.sh and report the output)"
        return 1
    fi

    if [ "$cur" -ge "$max" ] 2>/dev/null; then
        log "layer4b: '$name' already at hardware max ($cur of $max) - nothing to gain"
        return 0
    fi

    # Cap the write to a fraction of the remaining headroom. Going straight to
    # the hardware maximum is how speakers die.
    head=$(( max - cur ))
    frac="${CIRRUS_MAX_HEADROOM_FRACTION_PCT:-50}"
    allow=$(( head * frac / 100 ))
    [ "$allow" -lt 1 ] && allow=1

    want="$steps"
    if [ "$want" -gt "$allow" ]; then
        warn "layer4b: '$name' +$want capped to +$allow (${frac}% of ${head} headroom)"
        want="$allow"
    fi

    new=$(( cur + want ))
    [ "$new" -gt "$max" ] && new="$max"

    # remember stock once, for revert
    key=$(echo "$label" | tr ' /' '__')
    stock="$STATE_DIR/cirrus-stock-$key.txt"
    [ -f "$stock" ] || printf '%s\t%s\n' "$name" "$cur" >"$stock"

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "DRY: would set '$name' $cur -> $new (max $max)"
        return 0
    fi

    if $CIRRUS_TM set "$name" "$new" >/dev/null 2>&1 || \
       $CIRRUS_TM "$name" "$new" >/dev/null 2>&1; then
        after=$(cirrus_get "$name")
        if [ "$after" = "$new" ]; then
            log "layer4b: '$name' $cur -> $after  (max $max)"
        else
            warn "layer4b: '$name' write did not stick (wanted $new, read $after)"
        fi
    else
        warn "layer4b: '$name' write failed (selinux? control read-only?)"
        return 1
    fi
}

cirrus_apply() {
    cirrus_guard || return 0

    log "layer4b: applying to CS35L41 pair"

    # Bottom / main speaker amp.
    cirrus_bump 'Digital PCM Volume' "${CIRRUS_DIGITAL_PCM_STEPS:-0}" 'main digital'
    cirrus_bump 'AMP PCM Gain'       "${CIRRUS_AMP_GAIN_STEPS:-0}"    'main ampgain'

    # Top / RCV amp. Separate flag: it doubles as the earpiece, so overdriving
    # it degrades call audio too, and it is the smaller of the two drivers.
    if [ "${CIRRUS_INCLUDE_TOP_AMP:-0}" = "1" ]; then
        cirrus_bump 'RCV Digital PCM Volume' "${CIRRUS_DIGITAL_PCM_STEPS:-0}" 'rcv digital'
        cirrus_bump 'RCV AMP PCM Gain'       "${CIRRUS_AMP_GAIN_STEPS:-0}"    'rcv ampgain'
    else
        log "layer4b: top/RCV amp left alone (CIRRUS_INCLUDE_TOP_AMP=0)"
    fi

    # 'Cirrus SP Volume Attenuation' reads 0dB on stock, i.e. already no
    # attenuation, so there is nothing to win there. It is left untouched
    # unless a future probe shows positive entries in its enum.
}

# The HAL re-applies mixer_paths and the Cirrus HAL re-initialises the amps on
# every route change (speaker <-> headset, screen off, call start). Without
# re-asserting, the boost silently disappears after the first route change.
cirrus_watchdog() {
    cirrus_guard || return 0
    iv="${CIRRUS_WATCHDOG_SEC:-0}"
    [ "$iv" -gt 0 ] 2>/dev/null || { log "layer4b: watchdog off"; return 0; }

    log "layer4b: watchdog every ${iv}s"
    (
        while true; do
            sleep "$iv"
            # Only act while something is actually playing, so we are not
            # fighting the HAL's idle teardown or burning wakeups.
            case "$(getprop init.svc.audioserver)" in running) ;; *) continue ;; esac
            cirrus_apply >/dev/null 2>&1
        done
    ) &
    echo $! >"$STATE_DIR/.watchdog.pid"
}

cirrus_revert() {
    cirrus_tool || return 0
    for f in "$STATE_DIR"/cirrus-stock-*.txt; do
        [ -f "$f" ] || continue
        name=$(cut -f1 "$f"); val=$(cut -f2 "$f")
        [ -n "$name" ] && [ -n "$val" ] || continue
        if $CIRRUS_TM set "$name" "$val" >/dev/null 2>&1 || \
           $CIRRUS_TM "$name" "$val" >/dev/null 2>&1; then
            log "layer4b: reverted '$name' -> $val"
        fi
    done
}
