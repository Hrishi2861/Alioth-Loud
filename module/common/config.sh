#!/system/bin/sh
#
# alioth-loud :: user configuration
#
# Copied to /data/adb/alioth_loud/config.sh on first install and NOT
# overwritten on module update. Edit that copy, then reboot.
#
# ---------------------------------------------------------------------------
#  TUNED FOR THE MEASURED DEVICE
#    aliothin (Redmi K40 / Mi 11X / POCO F3, M2012K11AI), SM8250/kona
#    HyperOS OS1.0.10.0.TKHCNXM, Android 13 sdk 33, KernelSU 1.1.1, Enforcing
#    2x Cirrus Logic CS35L41 rev B2 on I2C 1-0040 (top/RCV) + 1-0041 (bottom)
#    ALSA card kona-mtp-snd-card  -> HAL reads mixer_paths.xml
# ---------------------------------------------------------------------------
#
#  ROUTING, WHICH DECIDES WHAT EACH LAYER CAN DO
#
#    speakers : MultiMedia1 -> TERT_MI2S_RX -> CS35L41 x2
#               ^ bypasses the WCD9385 codec completely
#    headset  : MultiMedia1 -> RX_MACRO RX0/RX1 -> HPHL/HPHR   (WCD9385)
#    earpiece : RX_RX2 -> EAR                                   (WCD9385)
#
#  So for SPEAKER loudness only layers 1, 2, 3 and 4b can help. Layer 4a
#  touches the WCD RX path, which the speakers never traverse.
#
#  ---------------------------------------------------------------------------
#  AND THE THING TO BE CLEAR ABOUT
#  Layer 3 flattens the attenuation curve. At volume index 100 the stock
#  attenuation is already 0 mB, so at MAX VOLUME layer 3 changes nothing at
#  all. It makes every step below max louder (about +12.7 dB at half volume on
#  this ROM's measured curve). If your complaint is "max is not loud enough",
#  layer 3 is not the layer that fixes it -- layers 1/2 (compression, in the
#  app) and 4b (amp gain) are.
#  ---------------------------------------------------------------------------

# ===========================================================================
# LAYER 3 -- volume curve flattening    (safe, reversible, big mid-range win)
# ===========================================================================

ENABLE_CURVE_PATCH=1

# How much to flatten the attenuation curve, 0.00 - 0.85.
#   0.00 = stock    0.55 = measured default    0.70 = aggressive
#
# Measured effect at 0.55 on this ROM's real MUSIC/SPEAKER curve, which Xiaomi
# customised to 15 points starting at -7100 mB (AOSP ships 4 points from -5800):
#
#     index   stock ->  patched     gain at that step
#        20   -5000     -2250        +27.5 dB
#        40   -3200     -1440        +17.6 dB
#        53   -2300     -1035        +12.7 dB
#        66   -1700      -765         +9.3 dB
#        80   -1000      -450         +5.5 dB
#       100       0         0         +0.0 dB   <-- max is unchanged, always
CURVE_FLATTEN=0.55

# Which curves to flatten. Matched against <reference name> / stream name.
# VOICE and SCO are excluded: the earpiece is easier to damage and wrecking
# call audio is worse than quiet music. ENFORCED_AUDIBLE is excluded because
# it is camera shutter / emergency tones that are meant to be fixed level.
CURVE_INCLUDE='MEDIA|MUSIC|RING|NOTIFICATION|SYSTEM|ALARM|ACCESSIBILITY'
CURVE_EXCLUDE='VOICE|CALL|SCO|HEARING|TTS|ENFORCED'

# Absolute floor in millibels; nothing is ever written below this.
CURVE_FLOOR_MB=-9600

# Verified against the real files: this touches exactly 6 stream/device blocks
# (MUSIC/SPEAKER, MUSIC/HEADSET, RING/SPEAKER, ALARM/SPEAKER,
# NOTIFICATION/SPEAKER, SYSTEM/HEADSET) plus 11 points in the shared
# reference curves, and leaves VOICE_CALL, BLUETOOTH_SCO, DTMF and
# ENFORCED_AUDIBLE bit-identical.

# ===========================================================================
# LAYER 3b -- properties
# ===========================================================================
#
# MEASURED: this ROM ALREADY ships everything this layer used to set.
#     ro.config.media_vol_steps        = 30    (already)
#     audio.safemedia.bypass           = true  (already)
#     persist.vendor.audio.safex.bypass= true  (already)
# So at the old defaults this layer was a complete no-op. It is left available
# because 30 -> 50 steps is still a real usability gain once the curve is
# flattened, but do not expect loudness from it.

ENABLE_PROP_PATCH=1

# Stock is 30. Raising to 50 gives finer control over the now-much-louder
# lower range. Hardware volume keys take longer to traverse. 0 = leave stock.
MEDIA_VOL_STEPS=50

# Already true on this ROM; harmless to re-assert, and matters if a future
# HyperOS update re-enables the cap.
DISABLE_SAFE_MEDIA_VOLUME=1

# ===========================================================================
# LAYER 4a -- WCD9385 RX digital gain     HEADSET + EARPIECE ONLY
# ===========================================================================
#
# MEASURED from the live mixer:
#     RX_RX0 Digital Volume = 84  (dsrange 0->124)   -> HPHL  headset left
#     RX_RX1 Digital Volume = 84  (dsrange 0->124)   -> HPHR  headset right
#     RX_RX2 Digital Volume = 84  (dsrange 0->124)   -> EAR   earpiece
#     HPHL/HPHR Volume      = 20  (dsrange 0->24)    -> headset analog PA
#     EAR PA Gain           = G_6_DB, ALREADY THE MAXIMUM of its enum
#     WSA_RX0/1             = 84                     -> unused macro on alioth
#   84 == 0 dB, 1 step == 1 dB, so hardware allows up to +40 dB. Do not.
#
# THIS DOES NOT AFFECT THE SPEAKERS. They leave via TERT_MI2S to the Cirrus
# amps and never pass through these controls. Enable it for louder wired
# headsets (USB-C analog accessory mode drives HPHL/HPHR) and earpiece.
#
# Risk: mixer_paths.xml is parsed by the audio HAL at init. An out-of-range
# value crash-loops audioserver. Mitigated by backup + structural validation
# before mount + the 3-strike boot counter.

ENABLE_MIXER_GAIN=0

# dB added to whitelisted controls. Keep <= 6; beyond that you pre-clip the DAC.
MIXER_GAIN_DB=4

MIXER_CTL_INCLUDE='RX_RX[0-9]+ Digital Volume'

# Hard ceiling regardless of the above. Hardware permits 124 (+40 dB); 90 is
# +6 dB over unity, which is already the sensible limit for a digital stage.
MIXER_CTL_ABS_MAX=90

# If a stock value falls outside this window the codec is not what we measured,
# so skip rather than guess.
MIXER_CTL_MIN_PLAUSIBLE=60
MIXER_CTL_MAX_PLAUSIBLE=88

# ===========================================================================
# LAYER 4b -- Cirrus CS35L41 amp gain    *** PERMANENT SPEAKER DAMAGE ***
# ===========================================================================
#
# The only layer that raises actual speaker SPL.
#
# MEASURED per amp (both 1-0040 "RCV"/top and 1-0041 bottom read identically):
#
#   AMP PCM Gain            18   (dsrange 0->20)   <- USABLE: 2 steps left
#   Digital PCM Volume    1841   (dsrange 0->-318) <- NOT INTERPRETABLE, refused
#   Boost Target Voltage     0   (dsrange 0->170)  <- not touched, see below
#   Class-H Head Room       11   (dsrange 0->127)  <- not touched
#   Boost Class-H Tracking  On
#   DSP1 Firmware      Protection                  <- in-amp protection running
#
#   Cirrus SP Protection      Disable  (of: Disable, Enable)
#   Cirrus SP                 Config SP Disable
#   Cirrus SP Volume Attenuation  0dB  (of: 0dB, -18dB, -24dB)
#                                       ^ already the maximum, nothing to gain
#   EAR PA Gain               G_6_DB    ^ already the maximum, nothing to gain
#
# ---------------------------------------------------------------------------
# THE HONEST CONCLUSION FROM THOSE NUMBERS
#
# There is almost no untapped hardware headroom on this device. Xiaomi already
# ships the earpiece PA at its maximum, the Cirrus attenuator at 0 dB, and the
# class-D gain at 18 of 20. The entire remaining hardware budget is TWO STEPS
# of AMP PCM Gain, worth roughly 1-2 dB, and spending it removes the margin the
# amp firmware uses to protect the voice coil.
#
# 'Digital PCM Volume' reports 0->-318, which is not a raw ceiling -- it is a
# signed, TLV-dB-scaled field. The module refuses to write it rather than guess
# a format, because guessing the scale of an amplifier gain register is how
# speakers die. Do not "fix" this by hardcoding a number.
#
# So: if you want a large loudness increase on speaker, it comes from layer 1
# (compression in the app), not from here. Layer 4b is a 1-2 dB garnish with
# real downside.
# ---------------------------------------------------------------------------
#
# HOW THIS LAYER PROTECTS YOU
#   - refuses to run without both flags below
#   - reads each control's range from tinymix and refuses to write when that
#     range is missing or inverted -- it never writes blind
#   - clamps any change to CIRRUS_MAX_HEADROOM_FRACTION_PCT of remaining
#     headroom, so it cannot jump straight to the hardware maximum
#   - saves stock values for revert on uninstall

ENABLE_CIRRUS_GAIN=0
I_ACCEPT_SPEAKER_DAMAGE_RISK=0

# Raw mixer steps to add, NOT dB.
# 'AMP PCM Gain' has exactly 2 steps of headroom (18 -> 20). At the default 50%
# fraction below, the most that will actually be applied is +1. Set the
# fraction to 100 if you want both steps.
CIRRUS_AMP_GAIN_STEPS=0

# Left at 0 and refused by the range check anyway; see the note above.
CIRRUS_DIGITAL_PCM_STEPS=0

# Never consume more than this percentage of a control's remaining headroom.
CIRRUS_MAX_HEADROOM_FRACTION_PCT=50

# The top amp doubles as the earpiece and is the smaller driver, so it is
# opt-in separately from the bottom main speaker.
CIRRUS_INCLUDE_TOP_AMP=0

# The HAL re-initialises the amps on every route change, so without a
# re-assert the boost vanishes the first time you plug in a headset or the
# screen turns off. 0 disables. 30 is a reasonable interval.
CIRRUS_WATCHDOG_SEC=0

# ===========================================================================
# COMPANION APP
# ===========================================================================
#
# MEASURED: layers 1-2 are viable on this ROM.
#     /vendor/lib64/soundfx/libdynproc.so present
#     <effect name="dynamics_processing" uuid="e0e6539b-1781-7261-676f-6d7573696340">
#     <effect name="loudness_enhancer"   uuid="fa415329-2034-4bea-b5dc-5b381c8d1e2c">
# and the vendor <postprocess> chain holds only volume-listener helpers, so a
# global session-0 effect has a clean path with no vendor effect to fight.
#
# The companion app is baked directly into the module overlay at build time as
# a priv-app (system/priv-app) with an allowlist entry (system/etc/permissions)
# granting MODIFY_DEFAULT_AUDIO_EFFECTS, which AudioFlinger requires to attach
# an effect to session 0. Without it the app can only process its own audio,
# which boosts nothing. Whether the app ships is decided at build time
# (./build.sh --with-app), so this flag is informational only.
INSTALL_PRIV_APP=1

# ===========================================================================
# DEBUG
# ===========================================================================

VERBOSE_LOG=1

# Log what would happen, change nothing. Use this for the first boot after
# enabling a risky layer.
DRY_RUN=0
