#!/system/bin/sh
#
# alioth-loud :: device audio probe
#
# Dumps everything needed to write a volume-boost module that will not
# bootloop you. Collects NOTHING except audio config + hardware IDs.
#
# Usage (on device, in Termux/adb shell):
#     su -c 'sh /sdcard/probe.sh'
#
# Result: /sdcard/alioth-audio-probe.tar.gz  -- send that file back.
#
set -u

OUT=/data/local/tmp/audio-probe
TARBALL=/sdcard/alioth-audio-probe.tar.gz
LOG="$OUT/00-summary.txt"

rm -rf "$OUT"; mkdir -p "$OUT/files" "$OUT/sys"
exec 3>&1

say()  { echo "$@" >&3; }
log()  { echo "$@" >>"$LOG"; }
hdr()  { log ""; log "=== $* ==="; }

if [ "$(id -u)" != "0" ]; then
    say "!! Not root. Run with: su -c 'sh $0'"
    exit 1
fi

say ":: probing audio subsystem ..."

# ---------------------------------------------------------------- identity
hdr "DEVICE"
for p in ro.product.device ro.product.name ro.product.model ro.board.platform \
         ro.build.version.release ro.build.version.sdk ro.build.version.incremental \
         ro.mi.os.version.incremental ro.vendor.build.fingerprint \
         ro.hardware ro.soc.model; do
    log "$p = $(getprop $p)"
done

hdr "ROOT / SELINUX"
log "selinux    = $(getenforce 2>/dev/null)"
log "magisk     = $(magisk -V 2>/dev/null || echo n/a)"
log "ksu        = $(ksud -V 2>/dev/null || echo n/a)"
log "apd        = $(apd -V 2>/dev/null || echo n/a)"

# ------------------------------------------------------------ volume props
hdr "VOLUME-RELATED PROPS (current values, so we know what to override)"
getprop | grep -Ei 'vol_steps|audio|media\.|af\.|sound|dolby|misound|speaker|dirac' \
        | sed 's/^/  /' >>"$LOG" 2>/dev/null

# ------------------------------------------------- audio config file hunt
hdr "AUDIO CONFIG FILES FOUND"
# Order matters: later dirs win at runtime, we want to know all copies.
for d in /vendor/etc /vendor/etc/audio /system/etc /system/vendor/etc \
         /odm/etc /product/etc /system_ext/etc /my_product/etc; do
    [ -d "$d" ] || continue
    for f in "$d"/mixer_paths*.xml \
             "$d"/audio_policy_volumes*.xml \
             "$d"/default_volume_tables*.xml \
             "$d"/audio_policy_configuration*.xml \
             "$d"/audio_effects*.xml \
             "$d"/audio_platform_info*.xml; do
        [ -f "$f" ] || continue
        sz=$(stat -c %s "$f" 2>/dev/null)
        log "  $f  (${sz} bytes)"
        # flatten path into filename so nothing collides
        dest=$(echo "${f#/}" | tr '/' '_')
        cp -f "$f" "$OUT/files/$dest" 2>/dev/null
    done
done

# --------------------------------------------------------- effects / DSP
hdr "SOUNDFX LIBRARIES (existing post-processing effects)"
for d in /vendor/lib/soundfx /vendor/lib64/soundfx /system/lib/soundfx \
         /system/lib64/soundfx /odm/lib64/soundfx; do
    [ -d "$d" ] || continue
    log "  [$d]"
    ls -1 "$d" 2>/dev/null | sed 's/^/    /' >>"$LOG"
done

# ------------------------------------------------------------- smart PA
hdr "SMART PA / AMPLIFIER DETECTION"
# Known micro-speaker smart amps used by Xiaomi/Qualcomm devices.
PA_PATTERNS='aw882|aw88|awinic|cs35l|cirrus|tfa9|tfa98|nxp|tas25|tas27|ti_smartpa|max98|sia81|fs16|fourier'
log "-- /sys/class matches:"
ls -1 /sys/class 2>/dev/null | grep -Ei "$PA_PATTERNS" | sed 's/^/    /' >>"$LOG"
log "-- /sys/bus/i2c/devices matches:"
ls -1 /sys/bus/i2c/devices 2>/dev/null | sed 's/^/    /' >>"$LOG"
log "-- deep scan for PA sysfs nodes (bounded depth):"
find /sys/devices -maxdepth 7 -iregex ".*\($PA_PATTERNS\).*" 2>/dev/null \
    | head -n 200 | sed 's/^/    /' >>"$LOG"

log "-- kernel log references:"
dmesg 2>/dev/null | grep -Ei "$PA_PATTERNS" | head -n 40 | sed 's/^/    /' >>"$LOG"

# Snapshot writable PA control nodes + their current values.
find /sys -maxdepth 8 -iregex ".*\($PA_PATTERNS\).*" -type f 2>/dev/null \
    | grep -Ei 'gain|volume|prof|cali|range|re25|f0|temp|status|monitor|spk|switch' \
    | head -n 120 > "$OUT/sys/pa-nodes.txt"
while IFS= read -r n; do
    [ -r "$n" ] || continue
    printf '%s :: %s\n' "$n" "$(timeout 1 cat "$n" 2>/dev/null | head -c 200 | tr '\n' ' ')"
done < "$OUT/sys/pa-nodes.txt" > "$OUT/sys/pa-values.txt" 2>/dev/null

# ------------------------------------------------------------ mixer ctls
hdr "MIXER CONTROLS (gain/volume candidates for layer 4a)"
MIXER_TOOL=""
for t in tinymix /system/bin/tinymix /vendor/bin/tinymix; do
    command -v "$t" >/dev/null 2>&1 && { MIXER_TOOL="$t"; break; }
done
if [ -n "$MIXER_TOOL" ]; then
    log "  tool = $MIXER_TOOL"
    "$MIXER_TOOL" 2>/dev/null > "$OUT/files/tinymix-all.txt"
    grep -Ei 'volume|gain|boost|limit' "$OUT/files/tinymix-all.txt" \
        | head -n 120 | sed 's/^/    /' >>"$LOG"
else
    log "  tinymix NOT PRESENT -- will read controls from mixer_paths xml instead"
fi

# ALSA card/codec identity
hdr "ALSA"
log "cards:";      cat /proc/asound/cards 2>/dev/null | sed 's/^/    /' >>"$LOG"
ls -1 /proc/asound 2>/dev/null | sed 's/^/    /' >>"$LOG"

# ------------------------------------------------------- current effects
hdr "ACTIVE AUDIO EFFECTS / SESSIONS"
dumpsys media.audio_flinger 2>/dev/null | sed -n '1,160p' > "$OUT/files/audioflinger.txt"
dumpsys media.audio_policy 2>/dev/null | sed -n '1,200p' > "$OUT/files/audiopolicy.txt"
log "  (see files/audioflinger.txt, files/audiopolicy.txt)"

# Does the ROM expose DynamicsProcessing? Critical for layer 1.
hdr "DYNAMICSPROCESSING AVAILABILITY (layer 1 depends on this)"
if grep -qi 'dynamics' "$OUT"/files/*audio_effects*.xml 2>/dev/null; then
    log "  FOUND dynamics processing in audio_effects xml -- good"
    grep -i -A2 -B2 'dynamics' "$OUT"/files/*audio_effects*.xml 2>/dev/null \
        | head -n 30 | sed 's/^/    /' >>"$LOG"
else
    log "  not declared in vendor audio_effects.xml"
    log "  (framework effect may still exist via libaudiopreprocessing / libdynproc)"
fi
ls -1 /system/lib64/libdynproc* /system/lib64/soundfx/libdynproc* 2>/dev/null \
    | sed 's/^/    /' >>"$LOG"

# -------------------------------------------------------------- package
hdr "DONE"
log "collected $(find "$OUT" -type f | wc -l) files"

tar -czf "$TARBALL" -C "$OUT" . 2>/dev/null
chmod 0644 "$TARBALL" 2>/dev/null

say ""
say ":: summary written to $OUT/00-summary.txt"
say ":: archive -> $TARBALL"
say ""
say "   send that .tar.gz back, then we build layer 4 for your exact hardware"
say ""
# Show the parts that decide the risky layers
say "--- quick look: smart PA ---"
sed -n '/=== SMART PA/,/=== MIXER/p' "$LOG" | head -n 40
