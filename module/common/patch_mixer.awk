# alioth-loud :: mixer_paths RX digital gain bump   *** LAYER 4a, RISKY ***
#
# Adds GAIN_DB to whitelisted <ctl name="..." value="N"/> entries.
# On WCD93xx-class codecs these controls are 1 step == 1 dB with 84 == 0 dB.
#
# Guards, in order:
#   1. name must match INCLUDE
#   2. value must be a bare integer
#   3. stock value must sit inside [MIN_PLAUS, MAX_PLAUS] -- if it doesn't,
#      the codec isn't what we assumed, so skip rather than guess
#   4. result is hard-clamped to ABS_MAX
#
# vars: GAIN_DB INCLUDE ABS_MAX MIN_PLAUS MAX_PLAUS

function attr(line, key,    v) {
    if (match(line, key "=\"[^\"]*\"")) {
        v = substr(line, RSTART, RLENGTH)
        sub(key "=\"", "", v)
        sub(/"$/, "", v)
        return v
    }
    return ""
}

BEGIN { changed = 0; skipped = 0; incomment = 0 }

{
    line = $0

    # --- comment passthrough (see patch_volumes.awk for rationale)
    # A commented-out <ctl> would otherwise get its value bumped, which is how
    # a "harmless" cosmetic edit turns into a diff nobody can explain later.
    probe = line
    while (match(probe, /<!--.*-->/))
        probe = substr(probe, 1, RSTART - 1) substr(probe, RSTART + RLENGTH)

    if (incomment) {
        print line
        if (probe ~ /-->/) incomment = 0
        next
    }
    if (probe ~ /<!--/) { print line; incomment = 1; next }
    if (line ~ /^[ \t]*<!--.*-->[ \t]*$/) { print line; next }

    if (line !~ /<ctl[^>]*name=/) { print line; next }

    name = attr(line, "name")
    val  = attr(line, "value")

    if (name == "" || val == "")            { print line; next }
    if (INCLUDE != "" && name !~ INCLUDE)   { print line; next }
    if (val !~ /^-?[0-9]+$/)                { print line; next }

    n = val + 0
    if (n < MIN_PLAUS || n > MAX_PLAUS) {
        skipped++
        printf("skip implausible: %s = %s\n", name, val) > "/dev/stderr"
        print line; next
    }

    nn = n + GAIN_DB
    if (nn > ABS_MAX) nn = ABS_MAX
    if (nn == n) { print line; next }

    # replace only the value attribute, leave formatting intact
    sub("value=\"" val "\"", "value=\"" nn "\"", line)
    changed++
    printf("bump: %s %s -> %s\n", name, val, nn) > "/dev/stderr"
    print line
}

END {
    printf("changed=%d skipped=%d\n", changed, skipped) > "/dev/stderr"
}
