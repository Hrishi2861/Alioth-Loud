# alioth-loud :: volume curve flattener
#
# Rewrites <point>index,millibel</point> entries inside selected volume
# curves, scaling the attenuation toward zero.
#
#   new_mB = mB * (1 - FLATTEN)
#
# Attenuation is negative, so scaling toward zero makes that step LOUDER.
# Unity (0 mB) is preserved exactly -- this layer cannot exceed 0 dBFS, and
# deliberately does not try to.
#
# vars: FLATTEN INCLUDE EXCLUDE FLOOR

function attr(line, key,    m, v) {
    if (match(line, key "=\"[^\"]*\"")) {
        v = substr(line, RSTART, RLENGTH)
        sub(key "=\"", "", v)
        sub(/"$/, "", v)
        return v
    }
    return ""
}

# Round half away from zero.
#
# int() truncates, and FLATTEN arrives as a decimal string, so 1.0-0.55 is
# 0.44999999999999996 and -5800*that is -2609.9999999999998 -- which int()
# turns into -2609 instead of -2610. One millibel is inaudible, but the error
# depends on the awk build's float handling, and a boot-time patcher must
# produce byte-identical output every time. Round explicitly.
function round(x) {
    return (x >= 0) ? int(x + 0.5) : -int(-x + 0.5)
}

function is_active(name) {
    if (name == "") return 0
    if (EXCLUDE != "" && name ~ EXCLUDE) return 0
    if (INCLUDE != "" && name !~ INCLUDE) return 0
    return 1
}

function rewrite_points(line,    out, rest, pre, m, inner, p, idx, mb, nmb) {
    out = ""; rest = line
    while (match(rest, /<point>[ ]*-?[0-9]+[ ]*,[ ]*-?[0-9]+[ ]*<\/point>/)) {
        pre  = substr(rest, 1, RSTART - 1)
        m    = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)

        inner = m
        sub(/^<point>[ ]*/, "", inner)
        sub(/[ ]*<\/point>$/, "", inner)
        split(inner, p, /[ ]*,[ ]*/)
        idx = p[1] + 0
        mb  = p[2] + 0

        nmb = round(mb * (1.0 - FLATTEN))
        if (nmb > 0)     nmb = 0          # never amplify here
        if (nmb < FLOOR) nmb = FLOOR

        if (nmb != mb) changed++
        out = out pre "<point>" idx "," nmb "</point>"
    }
    return out rest
}

BEGIN {
    ctx = ""; active = 0; changed = 0; incomment = 0
    if (FLATTEN == "")  FLATTEN = 0
    if (FLOOR == "")    FLOOR = -9600
}

{
    line = $0

    # --- comment passthrough
    #
    # Vendor files document themselves with commented-out example elements.
    # audio_policy_volumes.xml on HyperOS 1.0.10 contains a <volume> block with
    # <point> children inside its header comment (it survives today only because
    # that example uses curly quotes, which attr() refuses to match -- too
    # fragile to rely on). Rewriting points inside a comment is at minimum
    # cosmetic damage and can trip the size sanity check, so skip comments.
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

    # --- enter / leave a named reference curve
    if (line ~ /<reference[^>]*name=/) {
        ctx = attr(line, "name")
        active = is_active(ctx)
    }
    else if (line ~ /<\/reference>/) {
        ctx = ""; active = 0
    }

    # --- enter / leave an inline <volume stream=...> block
    else if (line ~ /<volume[^>]*stream=/) {
        ctx = attr(line, "stream")
        active = is_active(ctx)
        # self-closing volume element carries no points
        if (line ~ /\/>[ ]*$/) { print line; next }
    }
    else if (line ~ /<\/volume>/) {
        print line
        ctx = ""; active = 0
        next
    }

    if (active && line ~ /<point>/) {
        print rewrite_points(line)
    } else {
        print line
    }
}

END {
    # driver reads this off stderr
    printf("changed=%d\n", changed) > "/dev/stderr"
}
