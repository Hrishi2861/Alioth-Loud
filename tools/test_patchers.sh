#!/usr/bin/env bash
#
# alioth-loud :: patcher test suite
#
# The patchers run once, at boot, on a phone I cannot reach, and a bad result
# is a bootloop. So everything they do gets asserted here first, against
# fixtures that reproduce the real file structure and its edge cases.
#
# Run with:  ./tools/test_patchers.sh
# Set AWK=<path> to test against a specific awk (e.g. busybox awk).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tools/fixtures"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

AWK="${AWK:-awk}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; return 0; }
# must return 0: these are called as `cond && bad ... || ok ...`, so a
# non-zero return here would let the || branch fire too and print both.
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# assert_has <file> <literal> <label>
assert_has() {
    if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3" "expected to find: $2"; fi
}
assert_lacks() {
    if grep -qF -- "$2" "$1"; then bad "$3" "should not contain: $2"; else ok "$3"; fi
}

echo ":: awk = $AWK ($($AWK --version 2>&1 | head -1 || echo unknown))"
echo

# ===========================================================================
echo "-- layer 3: volume curve flattener"
# ===========================================================================
OUT="$TMP/vol.xml"
$AWK -v FLATTEN=0.55 \
     -v INCLUDE='MEDIA|MUSIC|RING|NOTIFICATION|SYSTEM|ALARM|ACCESSIBILITY' \
     -v EXCLUDE='VOICE|CALL|SCO|HEARING|TTS|ENFORCED' \
     -v FLOOR=-9600 \
     -f "$ROOT/module/common/patch_volumes.awk" \
     "$FIX/audio_policy_volumes.xml" >"$OUT" 2>"$TMP/vol.err"

# -5800 * (1 - 0.55) = -2610
assert_has   "$OUT" "<point>1,-2610</point>"  "media curve 1,-5800 -> -2610"
assert_has   "$OUT" "<point>20,-1800</point>" "media curve 20,-4000 -> -1800"
assert_has   "$OUT" "<point>60,-765</point>"  "media curve 60,-1700 -> -765"
assert_lacks "$OUT" "<point>1,-5800</point>"  "original media point is gone"

# unity must stay exactly unity, this layer never amplifies
assert_has   "$OUT" "<point>100,0</point>"    "unity preserved at 0 mB"

# SYSTEM curve is in INCLUDE: -2400 * 0.45 = -1080
assert_has   "$OUT" "<point>1,-1080</point>"  "system curve flattened"

# excluded curves must be byte-identical
assert_has   "$OUT" "<point>0,-4200</point>"  "VOICE curve untouched (excluded)"
assert_has   "$OUT" "<point>0,-9600</point>"  "SILENT curve untouched (no match)"
assert_has   "$OUT" "<point>0,-2700</point>"  "inline VOICE_CALL stream untouched"

# inline MUSIC/HEADSET block: -2900 * 0.45 = -1305
assert_has   "$OUT" "<point>1,-1305</point>"  "inline MUSIC stream flattened"

# structure must survive
lt=$(tr -cd '<' <"$OUT" | wc -c); gt=$(tr -cd '>' <"$OUT" | wc -c)
[ "$lt" = "$gt" ] && ok "bracket balance preserved ($lt)" || bad "bracket balance" "$lt vs $gt"
grep -q '</volumes>' "$OUT" && ok "root element intact" || bad "root element intact"

n_in=$(grep -c '<point>' "$FIX/audio_policy_volumes.xml")
n_out=$(grep -c '<point>' "$OUT")
[ "$n_in" = "$n_out" ] && ok "point count unchanged ($n_in)" || bad "point count" "$n_in -> $n_out"

# no positive gain may ever be emitted by this layer
if grep -oE '<point>[0-9]+,[0-9]+</point>' "$OUT" | grep -qvE ',0</point>'; then
    bad "no positive millibels emitted" "$(grep -oE '<point>[0-9]+,[0-9]+</point>' "$OUT" | grep -vE ',0</point>' | head -3)"
else
    ok "no positive millibels emitted"
fi

echo
echo "-- layer 3: floor clamp at extreme flatten"
OUT2="$TMP/vol2.xml"
$AWK -v FLATTEN=0.85 -v INCLUDE='MEDIA' -v EXCLUDE='VOICE' -v FLOOR=-500 \
     -f "$ROOT/module/common/patch_volumes.awk" \
     "$FIX/audio_policy_volumes.xml" >"$OUT2" 2>/dev/null
# -5800 * 0.15 = -870, clamped to floor -500
assert_has "$OUT2" "<point>1,-500</point>" "floor clamp applied"

echo
echo "-- layer 3: FLATTEN=0 is a no-op"
OUT3="$TMP/vol3.xml"
$AWK -v FLATTEN=0 -v INCLUDE='MEDIA|MUSIC|SYSTEM|ALARM' -v EXCLUDE='VOICE' -v FLOOR=-9600 \
     -f "$ROOT/module/common/patch_volumes.awk" \
     "$FIX/audio_policy_volumes.xml" >"$OUT3" 2>/dev/null
if diff -q <(tr -d ' ' <"$FIX/audio_policy_volumes.xml") <(tr -d ' ' <"$OUT3") >/dev/null; then
    ok "FLATTEN=0 produces identical content"
else
    bad "FLATTEN=0 no-op" "$(diff <(tr -d ' ' <"$FIX/audio_policy_volumes.xml") <(tr -d ' ' <"$OUT3") | head -5)"
fi

# ===========================================================================
echo
echo "-- layer 4a: mixer RX gain"
# ===========================================================================
MOUT="$TMP/mixer.xml"
$AWK -v GAIN_DB=4 \
     -v INCLUDE='RX[0-9]+ Digital Volume|RX_RX[0-9]+ Digital Volume' \
     -v ABS_MAX=90 -v MIN_PLAUS=60 -v MAX_PLAUS=88 \
     -f "$ROOT/module/common/patch_mixer.awk" \
     "$FIX/mixer_paths.xml" >"$MOUT" 2>"$TMP/mixer.err"

assert_has   "$MOUT" 'name="RX0 Digital Volume" value="88"'    "RX0 84 -> 88"
assert_has   "$MOUT" 'name="RX_RX0 Digital Volume" value="84"' "RX_RX0 80 -> 84"
assert_has   "$MOUT" 'name="RX2 Digital Volume" value="90"'    "RX2 88 -> 90 (clamped at ABS_MAX)"
assert_lacks "$MOUT" 'name="RX2 Digital Volume" value="92"'    "ABS_MAX not exceeded"

assert_has   "$MOUT" 'name="RX3 Digital Volume" value="20"'    "implausible stock value skipped"
assert_has   "$MOUT" 'name="RX4 Digital Volume" value="Two"'   "non-numeric value untouched"
assert_has   "$MOUT" 'name="ADC1 Volume" value="84"'           "capture ADC untouched"
assert_has   "$MOUT" 'name="TX_DEC0 Volume" value="84"'        "TX path untouched"
assert_has   "$MOUT" 'name="IIR1 INP0 Volume" value="84"'      "IIR volume untouched"
assert_has   "$MOUT" 'name="SLIM RX0 MUX" value="AIF1_PB"'     "mux routing untouched"
assert_has   "$MOUT" 'name="SpkrLeft BOOST Switch" value="1"'  "boost switch untouched"

grep -q '</mixer>' "$MOUT" && ok "root element intact" || bad "root element intact"
grep -q 'skip implausible: RX3' "$TMP/mixer.err" && ok "skip reported on stderr" || bad "skip reported"
# RX_RX0 appears twice in the fixture (top level and inside a <path>), so a
# correct run reports 5 changes across 4 distinct control names.
grep -q 'changed=5' "$TMP/mixer.err" && ok "reported changed=5" || bad "changed count" "$(cat "$TMP/mixer.err")"

echo
echo "-- layer 4a: GAIN_DB=0 is a no-op"
MOUT2="$TMP/mixer2.xml"
$AWK -v GAIN_DB=0 -v INCLUDE='RX[0-9]+ Digital Volume' \
     -v ABS_MAX=90 -v MIN_PLAUS=60 -v MAX_PLAUS=88 \
     -f "$ROOT/module/common/patch_mixer.awk" \
     "$FIX/mixer_paths.xml" >"$MOUT2" 2>/dev/null
diff -q "$FIX/mixer_paths.xml" "$MOUT2" >/dev/null \
    && ok "GAIN_DB=0 produces identical file" \
    || bad "GAIN_DB=0 no-op" "$(diff "$FIX/mixer_paths.xml" "$MOUT2" | head -5)"

# ===========================================================================
echo
echo "-- xml_sane() guard"
# ===========================================================================
export MODDIR="$ROOT/module"
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
LOGFILE="$TMP/state/test.log"
# shellcheck source=/dev/null
source "$ROOT/module/common/functions.sh" 2>/dev/null
STATE_DIR="$TMP/state"; LOGFILE="$TMP/state/test.log"

xml_sane "$OUT" "$FIX/audio_policy_volumes.xml" "volumes" \
    && ok "accepts a correctly patched file" \
    || bad "accepts valid patch"

: >"$TMP/empty.xml"
xml_sane "$TMP/empty.xml" "$FIX/audio_policy_volumes.xml" "volumes" 2>/dev/null \
    && bad "rejects empty file" || ok "rejects empty file"

head -c 200 "$FIX/audio_policy_volumes.xml" >"$TMP/trunc.xml"
xml_sane "$TMP/trunc.xml" "$FIX/audio_policy_volumes.xml" "volumes" 2>/dev/null \
    && bad "rejects truncated file" || ok "rejects truncated file"

sed 's/<\/volumes>//' "$OUT" >"$TMP/noroot.xml"
xml_sane "$TMP/noroot.xml" "$FIX/audio_policy_volumes.xml" "volumes" 2>/dev/null \
    && bad "rejects missing root close" || ok "rejects missing root close"

# Isolate the bracket check: append a stray '<' so balance breaks while size
# and root element stay valid. Matching on a specific millibel value here made
# the test silently vacuous when rounding changed by one.
{ cat "$OUT"; printf '<'; } >"$TMP/unbal.xml"
xml_sane "$TMP/unbal.xml" "$FIX/audio_policy_volumes.xml" "volumes" 2>/dev/null \
    && bad "rejects unbalanced brackets" || ok "rejects unbalanced brackets"

xml_sane "$MOUT" "$FIX/mixer_paths.xml" "mixer" \
    && ok "accepts patched mixer_paths" || bad "accepts patched mixer_paths"

# ===========================================================================
echo
echo "-- REAL DEVICE FILES (aliothin / HyperOS OS1.0.10.0.TKHCNXM)"
# ===========================================================================
# Synthetic fixtures test the logic; these test reality. Every assertion below
# is derived from the actual stock files pulled off the target device.
DEV="$FIX/device"

if [ ! -f "$DEV/audio_policy_volumes.xml" ]; then
    bad "device fixtures missing" "expected $DEV/*.xml"
else
DOUT="$TMP/dev_apv.xml"
$AWK -v FLATTEN=0.55 \
     -v INCLUDE='MEDIA|MUSIC|RING|NOTIFICATION|SYSTEM|ALARM|ACCESSIBILITY' \
     -v EXCLUDE='VOICE|CALL|SCO|HEARING|TTS|ENFORCED' \
     -v FLOOR=-9600 \
     -f "$ROOT/module/common/patch_volumes.awk" \
     "$DEV/audio_policy_volumes.xml" >"$DOUT" 2>"$TMP/dev_apv.err"

# Xiaomi's real 15-point music/speaker curve starts at -7100, not AOSP's -5800
assert_has   "$DOUT" "<point>1,-3195</point>"  "real MUSIC/SPEAKER -7100 -> -3195"
assert_has   "$DOUT" "<point>53,-1035</point>" "real MUSIC/SPEAKER mid -2300 -> -1035"
assert_has   "$DOUT" "<point>100,0</point>"    "real curve max stays at unity"
assert_lacks "$DOUT" "<point>1,-7100</point>"  "stock -7100 replaced"

# the header comment contains a <volume> example with <point> children;
# those must survive byte-identical
assert_has   "$DOUT" "<point>0,-9600</point>"  "points inside XML comment untouched"
assert_has   "$DOUT" "<point>100,0</point>"    "comment example second point untouched"

# That comment line also carries UTF-8 curly quotes while mixer_paths.xml
# declares ISO-8859-1. Assert byte-exact passthrough of the non-ASCII line so a
# locale-dependent awk re-encoding can never slip through unnoticed.
if diff -q <(LC_ALL=C grep -a '[^ -~	]' "$DEV/audio_policy_volumes.xml") \
           <(LC_ALL=C grep -a '[^ -~	]' "$DOUT") >/dev/null 2>&1; then
    ok "non-ASCII bytes preserved exactly"
else
    bad "non-ASCII bytes preserved" "awk re-encoded the UTF-8 comment line"
fi

# voice/SCO/enforced must be bit-identical on the real file
for blk in 'AUDIO_STREAM_VOICE_CALL" deviceCategory="DEVICE_CATEGORY_SPEAKER"' \
           'AUDIO_STREAM_VOICE_CALL" deviceCategory="DEVICE_CATEGORY_EARPIECE"' \
           'AUDIO_STREAM_BLUETOOTH_SCO" deviceCategory="DEVICE_CATEGORY_SPEAKER"'; do
    lbl=$(echo "$blk" | sed 's/AUDIO_STREAM_//;s/" deviceCategory="DEVICE_CATEGORY_/\//;s/"//')
    if diff -q <($AWK -v b="$blk" 'index($0,b){f=1} f{print} /<\/volume>/{if(f)exit}' "$DEV/audio_policy_volumes.xml") \
               <($AWK -v b="$blk" 'index($0,b){f=1} f{print} /<\/volume>/{if(f)exit}' "$DOUT") >/dev/null; then
        ok "real $lbl untouched"
    else
        bad "real $lbl untouched"
    fi
done

# exactly 6 stream/device blocks should change, no more
nch=$(python3 - "$DEV/audio_policy_volumes.xml" "$DOUT" <<'PY' 2>/dev/null || echo ERR
import re,sys
def blocks(p):
    ctx=None; out={}
    for ln in open(p):
        m=re.search(r'<volume[^>]*stream="([^"]*)"',ln)
        if m:
            ctx=m.group(1)
            d=re.search(r'deviceCategory="([^"]*)"',ln)
            if d: ctx+="/"+d.group(1)
        for pt in re.findall(r'<point>(-?\d+,-?\d+)</point>',ln):
            out.setdefault(ctx,[]).append(pt)
    return out
a,b=blocks(sys.argv[1]),blocks(sys.argv[2])
print(sum(1 for k in a if a[k]!=b.get(k)))
PY
)
[ "$nch" = "6" ] && ok "exactly 6 real stream blocks changed" \
                 || bad "real stream block count" "expected 6, got $nch"

xml_sane "$DOUT" "$DEV/audio_policy_volumes.xml" "volumes" \
    && ok "real patched audio_policy_volumes passes sanity" \
    || bad "real audio_policy_volumes sanity"

# --- default_volume_tables.xml (holds the shared reference curves)
DVT="$TMP/dev_dvt.xml"
$AWK -v FLATTEN=0.55 \
     -v INCLUDE='MEDIA|MUSIC|RING|NOTIFICATION|SYSTEM|ALARM|ACCESSIBILITY' \
     -v EXCLUDE='VOICE|CALL|SCO|HEARING|TTS|ENFORCED' \
     -v FLOOR=-9600 \
     -f "$ROOT/module/common/patch_volumes.awk" \
     "$DEV/default_volume_tables.xml" >"$DVT" 2>/dev/null
assert_has "$DVT" "<point>1,-2610</point>" "real DEFAULT_MEDIA curve -5800 -> -2610"
assert_has "$DVT" "<point>0,-9600</point>" "real SILENT curve untouched"
xml_sane "$DVT" "$DEV/default_volume_tables.xml" "volumes" \
    && ok "real patched default_volume_tables passes sanity" \
    || bad "real default_volume_tables sanity"

# --- mixer_paths.xml, the 150KB real one
MDEV="$TMP/dev_mixer.xml"
$AWK -v GAIN_DB=4 \
     -v INCLUDE='RX_RX[0-9]+ Digital Volume' \
     -v ABS_MAX=90 -v MIN_PLAUS=60 -v MAX_PLAUS=88 \
     -f "$ROOT/module/common/patch_mixer.awk" \
     "$DEV/mixer_paths.xml" >"$MDEV" 2>"$TMP/dev_mixer.err"

assert_has   "$MDEV" 'name="RX_RX0 Digital Volume" value="88"' "real RX_RX0 84 -> 88"
assert_has   "$MDEV" 'name="RX_RX1 Digital Volume" value="88"' "real RX_RX1 84 -> 88"
assert_has   "$MDEV" 'name="RX_RX2 Digital Volume" value="88"' "real RX_RX2 84 -> 88"
# WSA macro is unused on alioth (amps sit on TERT_MI2S) and is not whitelisted
assert_has   "$MDEV" 'name="WSA_RX0 Digital Volume" value="84"' "real WSA_RX0 untouched"
# capture path and headphone analog gain must not move
assert_has   "$MDEV" 'name="TX_DEC0 Volume" value="84"'         "real TX_DEC0 untouched"
assert_has   "$MDEV" 'name="HPHL Volume" value="18"'            "real HPHL untouched"
assert_has   "$MDEV" 'name="EAR SPKR PA Gain" value="G_DEFAULT"' "real EAR PA enum untouched"
grep -q 'changed=3' "$TMP/dev_mixer.err" && ok "real mixer: exactly 3 changes" \
    || bad "real mixer change count" "$(grep '^changed=' "$TMP/dev_mixer.err")"
xml_sane "$MDEV" "$DEV/mixer_paths.xml" "mixer" \
    && ok "real patched mixer_paths passes sanity" \
    || bad "real mixer_paths sanity"

# idempotency: patching an already-patched file must not double-apply past ABS_MAX
MDEV2="$TMP/dev_mixer2.xml"
$AWK -v GAIN_DB=4 -v INCLUDE='RX_RX[0-9]+ Digital Volume' \
     -v ABS_MAX=90 -v MIN_PLAUS=60 -v MAX_PLAUS=88 \
     -f "$ROOT/module/common/patch_mixer.awk" "$MDEV" >"$MDEV2" 2>/dev/null
assert_has "$MDEV2" 'name="RX_RX0 Digital Volume" value="90"' "re-patch clamps at ABS_MAX, no runaway"
fi

# ===========================================================================
echo
printf ':: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
