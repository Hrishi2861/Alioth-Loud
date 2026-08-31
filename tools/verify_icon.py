#!/usr/bin/env python3
"""
Verify the app's icon assets.

Run from the repo root:  python3 tools/verify_icon.py

This replaces an earlier version that checked hand-written vector path geometry.
The icons are now PNG artwork exported from IconKitchen, so the useful checks
changed: instead of "is the geometry inside the safe zone", the questions are
about the alpha channel, because that is what silently breaks.

The three failure modes this catches, all of which produce a wrong-looking icon
rather than a build error:

  1. Monochrome layer with an opaque background. Android's themed icons tint
     every non-transparent pixel, so an opaque background renders the themed
     icon as a solid filled blob instead of a speaker.

  2. Background layer that is NOT opaque. The launcher composites the background
     under the foreground and applies its own mask; a transparent background
     shows through to whatever is behind it.

  3. A notification icon whose glyph is too small. Small icons are treated as an
     alpha mask on a 24dp canvas; reusing the adaptive monochrome layer directly
     gives ~40% fill, which looks like a tiny speaker in a big empty box. The
     generated asset targets ~83%.

Exit status is non-zero if any check fails, so this can gate a build.
"""

import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow:  pip install Pillow")

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "app", "app", "src", "main", "res")

DENSITIES = ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]

# A notification glyph is generated at 83% fill. Allow a little slack for
# rounding at 24px, but flag anything that has drifted far from the target.
NOTIF_FILL_MIN = 0.70
NOTIF_FILL_MAX = 0.95

failures = []


def check(cond, msg):
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        failures.append(msg)


def alpha_stats(path):
    im = Image.open(path).convert("RGBA")
    a = im.split()[3]
    w, h = im.size
    bbox = a.getbbox()
    corners = [a.getpixel(p) for p in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1))]
    return im.size, bbox, corners, a


def rel(p):
    return os.path.relpath(p, os.path.join(os.path.dirname(RES), "..", "..", "..", ".."))


print("adaptive launcher icon")
for d in DENSITIES:
    for layer in ("background", "foreground", "monochrome"):
        p = os.path.join(RES, f"mipmap-{d}", f"ic_launcher_{layer}.png")
        if not os.path.isfile(p):
            check(False, f"mipmap-{d}/ic_launcher_{layer}.png missing")
            continue
        (w, h), bbox, corners, _ = alpha_stats(p)
        if layer == "background":
            # must be fully opaque, or the launcher shows through
            check(all(c == 255 for c in corners),
                  f"mipmap-{d}/ic_launcher_background.png opaque")
        else:
            # must have a transparent surround, or it composites/tints as a box
            check(all(c == 0 for c in corners),
                  f"mipmap-{d}/ic_launcher_{layer}.png transparent surround")
        check(w == h, f"mipmap-{d}/ic_launcher_{layer}.png square ({w}x{h})")

for f in ("ic_launcher.xml", "ic_launcher_round.xml"):
    p = os.path.join(RES, "mipmap-anydpi-v26", f)
    ok = os.path.isfile(p)
    check(ok, f"mipmap-anydpi-v26/{f} present")
    if ok:
        body = open(p).read()
        for layer in ("background", "foreground", "monochrome"):
            check(f"@mipmap/ic_launcher_{layer}" in body,
                  f"mipmap-anydpi-v26/{f} declares <{layer}>")

# minSdk is 31 and 'anydpi' outranks every density qualifier, so a per-density
# ic_launcher.png can never be selected. Its presence is dead weight (~64 KB).
legacy = [d for d in DENSITIES
          if os.path.isfile(os.path.join(RES, f"mipmap-{d}", "ic_launcher.png"))]
check(not legacy,
      "no unreachable legacy ic_launcher.png rasters"
      + (f" (found in {', '.join(legacy)})" if legacy else ""))

print("\nnotification icon")
for d in DENSITIES:
    p = os.path.join(RES, f"drawable-{d}", "ic_notification.png")
    if not os.path.isfile(p):
        check(False, f"drawable-{d}/ic_notification.png missing")
        continue
    (w, h), bbox, corners, a = alpha_stats(p)
    check(all(c == 0 for c in corners),
          f"drawable-{d}/ic_notification.png transparent surround")
    if bbox:
        fill = max(bbox[2] - bbox[0], bbox[3] - bbox[1]) / max(w, h)
        check(NOTIF_FILL_MIN <= fill <= NOTIF_FILL_MAX,
              f"drawable-{d}/ic_notification.png glyph fill {fill:.0%} "
              f"(want {NOTIF_FILL_MIN:.0%}-{NOTIF_FILL_MAX:.0%})")
    else:
        check(False, f"drawable-{d}/ic_notification.png is empty")

print()
if failures:
    print(f":: {len(failures)} check(s) FAILED")
    sys.exit(1)
print(":: all icon checks passed")
