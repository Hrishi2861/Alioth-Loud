#!/system/bin/sh
#
# alioth-loud :: shared helpers
#
# Sourced by post-fs-data.sh and service.sh. Assumes busybox is in PATH
# (Magisk/KSU/APatch all guarantee this for module scripts).

STATE_DIR=/data/adb/alioth_loud
LOGFILE="$STATE_DIR/boot.log"
BOOTCOUNT="$STATE_DIR/.bootcount"
BACKUP_DIR="$STATE_DIR/backup"
MAX_BOOT_STRIKES=3

mkdir -p "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null

# ------------------------------------------------------------------ logging

log() {
    [ "${VERBOSE_LOG:-1}" = "1" ] || return 0
    echo "[$(date '+%H:%M:%S')] $*" >>"$LOGFILE"
}
warn() { echo "[$(date '+%H:%M:%S')] WARN  $*" >>"$LOGFILE"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR $*" >>"$LOGFILE"; }

log_rotate() {
    if [ -f "$LOGFILE" ] && [ "$(stat -c %s "$LOGFILE" 2>/dev/null || echo 0)" -gt 262144 ]; then
        mv -f "$LOGFILE" "$LOGFILE.old" 2>/dev/null
    fi
    echo "--- boot $(date '+%Y-%m-%d %H:%M:%S') ---" >>"$LOGFILE"
}

# --------------------------------------------------------- bootloop guard
#
# post-fs-data increments the counter. service.sh clears it once the system
# actually finishes booting. If we accumulate MAX_BOOT_STRIKES without ever
# reaching boot_completed, our patches are the likely cause -> disable self.

boot_strike_count() { cat "$BOOTCOUNT" 2>/dev/null || echo 0; }

boot_strike_inc() {
    n=$(( $(boot_strike_count) + 1 ))
    echo "$n" >"$BOOTCOUNT"
    log "boot strike $n/$MAX_BOOT_STRIKES"
    echo "$n"
}

boot_strike_clear() {
    echo 0 >"$BOOTCOUNT"
}

# Trip the module's own kill switch. Magisk/KSU/APatch all honour `disable`.
self_disable() {
    reason="$1"
    err "SELF-DISABLING: $reason"
    touch "$MODDIR/disable" 2>/dev/null
    # Strip the boot-generated patch overlay so even a manual re-enable boots
    # clean. The baked-in priv-app is left alone: it is only our own app, and
    # removing it would require a re-install to bring back.
    rm -rf "$MODDIR/system/vendor" "$MODDIR/system/product" "$MODDIR/system/system_ext" 2>/dev/null
    echo "$reason" >"$STATE_DIR/disabled-reason.txt"
}

# ------------------------------------------------------------------ backup

# Keep a pristine copy of every file we touch, once, keyed by flattened path.
backup_once() {
    src="$1"
    key=$(echo "${src#/}" | tr '/' '_')
    dst="$BACKUP_DIR/$key"
    if [ ! -f "$dst" ]; then
        cp -f "$src" "$dst" 2>/dev/null && log "backed up $src"
    fi
}

# ------------------------------------------------------- overlay path map
#
# Translate a live system path into the module overlay path that will shadow
# it. Magisk-style: everything hangs off $MODDIR/system/...

mod_target_path() {
    case "$1" in
        /vendor/*)     echo "$MODDIR/system/vendor/${1#/vendor/}" ;;
        /system_ext/*) echo "$MODDIR/system/system_ext/${1#/system_ext/}" ;;
        /product/*)    echo "$MODDIR/system/product/${1#/product/}" ;;
        /system/*)     echo "$MODDIR/system/${1#/system/}" ;;
        *)             echo "" ;;   # odm / my_product not overlayable this way
    esac
}

# ------------------------------------------------------------ xml sanity
#
# There is no xmllint on device, so this is a cheap structural check whose
# only job is to catch awk mangling before a broken file reaches the HAL.
# Returns 0 = looks sane, 1 = reject.

xml_sane() {
    f="$1"; orig="$2"; want_tag="$3"

    [ -s "$f" ] || { err "sanity: $f empty"; return 1; }

    # Angle brackets must balance.
    lt=$(tr -cd '<' <"$f" | wc -c)
    gt=$(tr -cd '>' <"$f" | wc -c)
    [ "$lt" = "$gt" ] || { err "sanity: $f bracket mismatch ($lt/$gt)"; return 1; }

    # Root element must survive.
    if [ -n "$want_tag" ]; then
        grep -q "</$want_tag>" "$f" || { err "sanity: $f missing </$want_tag>"; return 1; }
    fi

    # Size must stay within 25% of the original -- catches truncation.
    if [ -f "$orig" ]; then
        so=$(stat -c %s "$orig" 2>/dev/null || echo 0)
        sn=$(stat -c %s "$f"    2>/dev/null || echo 0)
        [ "$so" -gt 0 ] || return 0
        lo=$(( so * 75 / 100 )); hi=$(( so * 125 / 100 ))
        if [ "$sn" -lt "$lo" ] || [ "$sn" -gt "$hi" ]; then
            err "sanity: $f size $sn outside [$lo,$hi] of original $so"
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------------ misc

clamp() {   # clamp <val> <min> <max>
    v=$1; lo=$2; hi=$3
    [ "$v" -lt "$lo" ] && v=$lo
    [ "$v" -gt "$hi" ] && v=$hi
    echo "$v"
}

setp() {    # persistent-ish prop set, logged
    k="$1"; v="$2"
    if [ "${DRY_RUN:-0}" = "1" ]; then
        log "DRY: would set $k=$v (currently $(getprop "$k"))"
        return 0
    fi
    resetprop -n "$k" "$v" 2>/dev/null || resetprop "$k" "$v" 2>/dev/null
    log "prop $k = $(getprop "$k")"
}

# Find every live copy of a config file, most-specific first.
find_audio_conf() {
    pattern="$1"
    for d in /odm/etc /vendor/etc/audio /vendor/etc /system_ext/etc \
             /product/etc /system/etc; do
        [ -d "$d" ] || continue
        for f in "$d"/$pattern; do
            [ -f "$f" ] && echo "$f"
        done
    done
}
