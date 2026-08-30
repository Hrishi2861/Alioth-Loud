#!/usr/bin/env bash
#
# alioth-loud :: layer 4b (Cirrus CS35L41) logic tests
#
# Layer 4b writes to a speaker amplifier. A misparsed range means writing a
# wrong value to hardware that cannot be un-damaged, so the parsing and
# clamping are tested here against every tinymix output format seen in the
# wild, using a stub tool. Nothing here touches real hardware.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; return 0; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1" "expected '$3' got '$2'"; }

# ---------------------------------------------------------------------------
# stub tinymix. FAKE_MODE selects which real-world output format to emulate.
# ---------------------------------------------------------------------------
make_stub() {
cat >"$TMP/tinymix" <<'STUB'
#!/usr/bin/env bash
# arg forms: "get <name>" | "<name>" | "set <name> <val>" | "<name> <val>"
if [ "${1:-}" = "set" ]; then shift; name="$1"; val="${2:-}"; mode=set
elif [ "${1:-}" = "get" ]; then shift; name="$1"; mode=get
elif [ $# -ge 2 ]; then name="$1"; val="$2"; mode=set
else name="${1:-}"; mode=get
fi
store="$FAKE_STORE/$(echo "$name" | tr ' /' '__')"
[ -f "$store" ] || echo "${FAKE_INIT:-1841}" > "$store"
cur=$(cat "$store")
if [ "$mode" = set ]; then
    [ "${FAKE_READONLY:-0}" = 1 ] && { echo "cannot set control" >&2; exit 1; }
    echo "$val" > "$store"; exit 0
fi
case "${FAKE_MODE:-modern}" in
  modern)   echo "$name: $cur (range 0->2144)" ;;
  bare)     echo "$cur" ;;
  norange)  echo "$name: $cur" ;;
  enum)     printf '%s:\t0dB\t>0dB, -1dB, -2dB\n' "$name" ;;
  spaced)   echo "$name:   $cur   (range 0 -> 2144)" ;;
  unknown)  echo "Invalid mixer control" >&2; exit 1 ;;
  # --- formats measured verbatim on aliothin / HyperOS 1.0.10 ---
  dsrange)  echo "$name: $cur (dsrange 0->${FAKE_MAX:-20})" ;;
  dsinvert) echo "$name: $cur (dsrange 0->-318)" ;;
  dsenum)   echo "$name: >0dB -18dB -24dB" ;;
  dsenum2)  echo "$name: >G_6_DB G_4P5_DB G_3_DB G_M18_DB" ;;
esac
STUB
chmod +x "$TMP/tinymix"
}
make_stub
export FAKE_STORE="$TMP/store"; mkdir -p "$FAKE_STORE"

# ---------------------------------------------------------------------------
# load the real module code with a stubbed environment
# ---------------------------------------------------------------------------
export MODDIR="$ROOT/module"
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
LOGFILE="$STATE_DIR/log"; VERBOSE_LOG=1; DRY_RUN=0
# shellcheck source=/dev/null
source "$ROOT/module/common/functions.sh"
STATE_DIR="$TMP/state"; LOGFILE="$STATE_DIR/log"
# shellcheck source=/dev/null
source "$ROOT/module/common/cirrus.sh"
CIRRUS_TM="$TMP/tinymix"

reset() { rm -rf "$FAKE_STORE" "$STATE_DIR"; mkdir -p "$FAKE_STORE" "$STATE_DIR"; : >"$LOGFILE"; }

echo ":: layer 4b parsing"
for mode in modern bare norange spaced; do
    reset; export FAKE_MODE=$mode FAKE_INIT=1841
    eq "cirrus_get [$mode]" "$(cirrus_get 'Digital PCM Volume')" "1841"
done

echo
echo ":: layer 4b range detection"
reset; export FAKE_MODE=modern
eq "range max [modern]" "$(cirrus_range 'Digital PCM Volume' | awk '{print $2}')" "2144"
reset; export FAKE_MODE=spaced
eq "range max [spaced]" "$(cirrus_range 'Digital PCM Volume' | awk '{print $2}')" "2144"
reset; export FAKE_MODE=norange
r=$(cirrus_range 'Digital PCM Volume' 2>/dev/null || true)
[ -z "$r" ] && ok "no range reported -> empty (caller must refuse)" \
            || bad "norange must yield empty" "got '$r'"

echo
echo ":: layer 4b refuses to write blind"
reset; export FAKE_MODE=norange FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Digital PCM Volume' 5 'test' >/dev/null 2>&1 || true
v=$(cat "$FAKE_STORE/Digital_PCM_Volume" 2>/dev/null || echo MISSING)
eq "value untouched when range unknown" "$v" "1841"
grep -q 'refusing to write blind' "$LOGFILE" && ok "logged the refusal" || bad "refusal not logged"

echo
echo ":: layer 4b headroom clamp"
# cur=1841 max=2144 -> headroom 303; at 50% the most it may add is 151
reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 CIRRUS_MAX_HEADROOM_FRACTION_PCT=50 \
  cirrus_bump 'Digital PCM Volume' 9999 'test' >/dev/null 2>&1
eq "runaway request clamped to 50% headroom" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "1992"

reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 CIRRUS_MAX_HEADROOM_FRACTION_PCT=10 \
  cirrus_bump 'Digital PCM Volume' 9999 'test' >/dev/null 2>&1
eq "10% fraction honoured" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "1871"

reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 CIRRUS_MAX_HEADROOM_FRACTION_PCT=50 \
  cirrus_bump 'Digital PCM Volume' 3 'test' >/dev/null 2>&1
eq "small request applied verbatim" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "1844"

echo
echo ":: layer 4b never exceeds hardware max"
reset; export FAKE_MODE=modern FAKE_INIT=2144
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Digital PCM Volume' 50 'test' >/dev/null 2>&1
eq "already at max -> no write" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "2144"
grep -q 'already at hardware max' "$LOGFILE" && ok "logged already-at-max" || bad "already-at-max not logged"

echo
echo ":: layer 4b consent gates"
reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=0 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 cirrus_apply >/dev/null 2>&1
[ ! -f "$FAKE_STORE/Digital_PCM_Volume" ] && ok "disabled -> no hardware access" \
    || bad "disabled must not touch hardware"

reset
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=0 CIRRUS_DIGITAL_PCM_STEPS=5 \
  cirrus_apply >/dev/null 2>&1
[ ! -f "$FAKE_STORE/Digital_PCM_Volume" ] && ok "no risk ack -> no hardware access" \
    || bad "missing ack must not touch hardware"
grep -q 'risk not acknowledged' "$LOGFILE" && ok "logged missing ack" || bad "ack refusal not logged"

echo
echo ":: layer 4b top amp is opt-in separately"
reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  CIRRUS_DIGITAL_PCM_STEPS=3 CIRRUS_INCLUDE_TOP_AMP=0 cirrus_apply >/dev/null 2>&1
[ -f "$FAKE_STORE/Digital_PCM_Volume" ] && ok "bottom amp touched" || bad "bottom amp not touched"
[ ! -f "$FAKE_STORE/RCV_Digital_PCM_Volume" ] && ok "top/RCV amp left alone by default" \
    || bad "top amp must be opt-in"

reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  CIRRUS_DIGITAL_PCM_STEPS=3 CIRRUS_INCLUDE_TOP_AMP=1 cirrus_apply >/dev/null 2>&1
[ -f "$FAKE_STORE/RCV_Digital_PCM_Volume" ] && ok "top amp touched when opted in" \
    || bad "top amp not touched when opted in"

echo
echo ":: layer 4b DRY_RUN"
reset; export FAKE_MODE=modern FAKE_INIT=1841
DRY_RUN=1 ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Digital PCM Volume' 5 'test' >/dev/null 2>&1
v=$(cat "$FAKE_STORE/Digital_PCM_Volume" 2>/dev/null || echo ABSENT)
eq "DRY_RUN performs no write" "$v" "1841"
grep -q 'DRY: would set' "$LOGFILE" && ok "DRY_RUN logged intent" || bad "DRY_RUN intent not logged"
DRY_RUN=0

echo
echo ":: layer 4b revert"
reset; export FAKE_MODE=modern FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Digital PCM Volume' 20 'main digital' >/dev/null 2>&1
mid=$(cat "$FAKE_STORE/Digital_PCM_Volume")
cirrus_revert >/dev/null 2>&1
eq "revert restores stock (was $mid)" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "1841"

echo
echo ":: layer 4b non-numeric / unreadable control"
reset; export FAKE_MODE=enum
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Cirrus SP Volume Attenuation' 3 'attn' >/dev/null 2>&1 || true
grep -qE 'not numeric|cannot read range' "$LOGFILE" && ok "enum control rejected safely" \
    || bad "enum control must be rejected" "$(tail -2 "$LOGFILE")"

reset; export FAKE_MODE=unknown
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'No Such Control' 3 'nope' >/dev/null 2>&1 || true
grep -q 'not readable' "$LOGFILE" && ok "missing control rejected safely" \
    || bad "missing control must be rejected" "$(tail -2 "$LOGFILE")"

# ===========================================================================
echo
echo ":: REAL tinymix output formats (aliothin / HyperOS 1.0.10)"
# ===========================================================================
# This build prints "dsrange", not "range", and one control reports an
# inverted range. Both strings below are verbatim from the device.

reset; export FAKE_MODE=dsrange FAKE_INIT=18 FAKE_MAX=20
eq "AMP PCM Gain value parsed"  "$(cirrus_get 'AMP PCM Gain')" "18"
eq "dsrange max parsed"         "$(cirrus_range 'AMP PCM Gain' | awk '{print $2}')" "20"

# 'Digital PCM Volume: 1841 (dsrange 0->-318)' -- hi < lo, not interpretable.
# The old parser returned -318 as the max, concluded 1841 >= -318, and logged
# "already at hardware max". Safe by accident, wrong by reasoning.
reset; export FAKE_MODE=dsinvert FAKE_INIT=1841
r=$(cirrus_range 'Digital PCM Volume' 2>/dev/null || true)
[ -z "$r" ] && ok "inverted dsrange rejected (0->-318)" \
            || bad "inverted dsrange must be rejected" "got '$r'"
grep -q 'uninterpretable range' "$LOGFILE" && ok "logged why it was rejected" \
    || bad "rejection reason not logged"

reset; export FAKE_MODE=dsinvert FAKE_INIT=1841
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
  cirrus_bump 'Digital PCM Volume' 20 'test' >/dev/null 2>&1 || true
eq "no write on inverted range" "$(cat "$FAKE_STORE/Digital_PCM_Volume")" "1841"
grep -q 'already at hardware max' "$LOGFILE" \
    && bad "must NOT claim already-at-max on an invalid range" \
    || ok "does not misreport invalid range as already-at-max"

# AMP PCM Gain 18 of 20: only 2 steps exist. At the default 50% fraction the
# most that may be added is 1. This is the real headroom on this hardware.
reset; export FAKE_MODE=dsrange FAKE_INIT=18 FAKE_MAX=20
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 CIRRUS_MAX_HEADROOM_FRACTION_PCT=50 \
  cirrus_bump 'AMP PCM Gain' 5 'ampgain' >/dev/null 2>&1
eq "AMP PCM Gain 18 -> 19 (50% of 2 steps)" "$(cat "$FAKE_STORE/AMP_PCM_Gain")" "19"

reset; export FAKE_MODE=dsrange FAKE_INIT=18 FAKE_MAX=20
ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 CIRRUS_MAX_HEADROOM_FRACTION_PCT=100 \
  cirrus_bump 'AMP PCM Gain' 5 'ampgain' >/dev/null 2>&1
eq "AMP PCM Gain 18 -> 20 at 100% fraction" "$(cat "$FAKE_STORE/AMP_PCM_Gain")" "20"

# enum controls: '>' marks the current choice. Both of these are already at
# their maximum on this device (Cirrus SP attenuation 0dB, EAR PA G_6_DB).
for m in dsenum dsenum2; do
    reset; export FAKE_MODE=$m
    ENABLE_CIRRUS_GAIN=1 I_ACCEPT_SPEAKER_DAMAGE_RISK=1 \
      cirrus_bump 'Some Enum' 3 'enum' >/dev/null 2>&1 || true
    grep -qE 'not numeric|no usable range' "$LOGFILE" \
        && ok "enum format [$m] rejected safely" \
        || bad "enum [$m] must be rejected" "$(tail -2 "$LOGFILE")"
done

echo
printf ':: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
