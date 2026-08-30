#!/system/bin/sh
#
# alioth-loud :: patch drivers
#
# Every patch follows the same contract:
#   1. back up the pristine original
#   2. transform into a temp file
#   3. structurally validate the result
#   4. only then place it in the overlay
# A failed validation is a no-op, not a broken boot.

# apply_awk_patch <src> <awkfile> <roottag> [awk -v args...]
apply_awk_patch() {
    src="$1"; awkf="$2"; tag="$3"; shift 3

    dst=$(mod_target_path "$src")
    if [ -z "$dst" ]; then
        warn "no overlay mapping for $src (odm/my_product not supported) - skipped"
        return 1
    fi

    tmp="$STATE_DIR/.tmp.$$"
    tmperr="$STATE_DIR/.tmperr.$$"

    backup_once "$src"

    # Byte-exact passthrough regardless of the environment's locale.
    # mixer_paths.xml declares ISO-8859-1 and audio_policy_volumes.xml carries
    # UTF-8 curly quotes in its header comment. Under a mismatched locale awk
    # can re-encode or choke on those bytes; LC_ALL=C makes it byte-oriented.
    if ! LC_ALL=C awk "$@" -f "$awkf" "$src" >"$tmp" 2>"$tmperr"; then
        err "awk failed on $src"
        sed 's/^/    /' "$tmperr" >>"$LOGFILE" 2>/dev/null
        rm -f "$tmp" "$tmperr"
        return 1
    fi

    # awk reports its stats on stderr
    stats=$(grep '^changed=' "$tmperr" 2>/dev/null | tail -1)
    detail=$(grep -v '^changed=' "$tmperr" 2>/dev/null | head -20)
    [ -n "$detail" ] && echo "$detail" | sed 's/^/    /' >>"$LOGFILE"

    if ! xml_sane "$tmp" "$src" "$tag"; then
        err "REJECTED patch for $src - keeping stock file"
        rm -f "$tmp" "$tmperr"
        return 1
    fi

    nchanged=$(echo "$stats" | sed -n 's/.*changed=\([0-9]*\).*/\1/p')
    if [ "${nchanged:-0}" = "0" ]; then
        log "no changes needed for $src"
        rm -f "$tmp" "$tmperr"
        return 0
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "DRY: would install patched $src -> $dst ($stats)"
        cp -f "$tmp" "$STATE_DIR/dryrun-$(echo "${src#/}" | tr '/' '_')"
        rm -f "$tmp" "$tmperr"
        return 0
    fi

    mkdir -p "$(dirname "$dst")" 2>/dev/null
    cp -f "$tmp" "$dst" || { err "could not write $dst"; rm -f "$tmp" "$tmperr"; return 1; }

    # Mirror the original's ownership / mode / selinux label. Getting the
    # label wrong on a vendor config is its own way to break audio init.
    chown 0:0 "$dst" 2>/dev/null
    chmod 0644 "$dst" 2>/dev/null
    ctx=$(ls -Zd "$src" 2>/dev/null | awk '{print $1}')
    if [ -n "$ctx" ] && [ "$ctx" != "?" ]; then
        chcon "$ctx" "$dst" 2>/dev/null && log "  ctx $ctx"
    fi

    log "PATCHED $src -> overlay ($stats)"
    rm -f "$tmp" "$tmperr"
    return 0
}

# ------------------------------------------------------ layer 3: curves

patch_volume_curves() {
    [ "${ENABLE_CURVE_PATCH:-0}" = "1" ] || { log "layer3 curves: disabled"; return 0; }

    # 0.55 -> "0.55"; awk handles the float, shell never does math on it
    log "layer3 curves: flatten=$CURVE_FLATTEN include='$CURVE_INCLUDE'"

    n=0
    for f in $(find_audio_conf 'audio_policy_volumes*.xml') \
             $(find_audio_conf 'default_volume_tables*.xml'); do
        apply_awk_patch "$f" "$MODDIR/common/patch_volumes.awk" "volumes" \
            -v FLATTEN="$CURVE_FLATTEN" \
            -v INCLUDE="$CURVE_INCLUDE" \
            -v EXCLUDE="$CURVE_EXCLUDE" \
            -v FLOOR="$CURVE_FLOOR_MB" && n=$((n+1))
    done

    [ "$n" = "0" ] && warn "layer3: no volume curve files found at all"
    log "layer3 curves: $n file(s) processed"
}

# ------------------------------------------------------- layer 3b: props

apply_props() {
    [ "${ENABLE_PROP_PATCH:-0}" = "1" ] || { log "layer3b props: disabled"; return 0; }

    # ro.* props can only be overwritten by resetprop, not setprop.
    if ! command -v resetprop >/dev/null 2>&1; then
        warn "layer3b: resetprop unavailable - cannot override ro.* props"
        return 1
    fi

    steps=$(clamp "${MEDIA_VOL_STEPS:-15}" 5 100)
    setp ro.config.media_vol_steps "$steps"

    if [ "${DISABLE_SAFE_MEDIA_VOLUME:-0}" = "1" ]; then
        # Best-effort. The authoritative gate is the framework resource
        # config_safe_media_volume_index, which is baked into
        # framework-res.apk and needs an RRO overlay to change -- not a prop.
        # These props are honoured by some Qualcomm/MIUI audio paths, so they
        # are worth setting, but do not assume they are sufficient. If the
        # headset warning still caps you, the RRO route is the real fix.
        setp audio.safemedia.bypass true
        setp persist.vendor.audio.safex.bypass true
    fi
}

# -------------------------------------------------- layer 4a: mixer gain

patch_mixer_gain() {
    if [ "${ENABLE_MIXER_GAIN:-0}" != "1" ]; then
        log "layer4a mixer: disabled (enable only after probe review)"
        return 0
    fi

    gain=$(clamp "${MIXER_GAIN_DB:-0}" 0 6)
    if [ "$gain" != "${MIXER_GAIN_DB:-0}" ]; then
        warn "layer4a: MIXER_GAIN_DB=${MIXER_GAIN_DB} clamped to $gain"
    fi
    log "layer4a mixer: +${gain}dB, abs_max=$MIXER_CTL_ABS_MAX"

    n=0
    for f in $(find_audio_conf 'mixer_paths*.xml'); do
        # NOTE: the root element is <mixer>, NOT <mixer_paths>. Qualcomm names
        # the file mixer_paths but the document element is <mixer>. Passing the
        # wrong tag here makes xml_sane reject every patch silently, so layer 4a
        # appears enabled while doing nothing.
        apply_awk_patch "$f" "$MODDIR/common/patch_mixer.awk" "mixer" \
            -v GAIN_DB="$gain" \
            -v INCLUDE="$MIXER_CTL_INCLUDE" \
            -v ABS_MAX="$MIXER_CTL_ABS_MAX" \
            -v MIN_PLAUS="$MIXER_CTL_MIN_PLAUSIBLE" \
            -v MAX_PLAUS="$MIXER_CTL_MAX_PLAUSIBLE" && n=$((n+1))
    done

    [ "$n" = "0" ] && warn "layer4a: no mixer_paths files patched"
    log "layer4a mixer: $n file(s) processed"
}
