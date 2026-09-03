# alioth-loud

**Volume ceiling removal for the Redmi K40 / POCO F3 / Mi 11X (alioth / aliothin, HyperOS).**

A Magisk/KernelSU/APatch module + companion priv-app that makes the Redmi K40 / POCO F3 / Mi 11X actually loud — not by shipping static files that an OTA wipes, but by **patching the live vendor audio configs at every boot** and layering a global compressor on top.

> ⚠️ **Alioth only.** This module is built for and properly tested on `alioth`/`aliothin` (Redmi K40 / POCO F3 / Mi 11X) hardware. Do not flash it on any other device — every probe-verified value and gain limit assumes this exact audio chain.

> Probe-verified for `aliothin` (M2012K11AI) on HyperOS 1.0.10 CN, Android 13, KernelSU 1.1.1, SELinux Enforcing.

---

## Tech stack

[![Kotlin](https://img.shields.io/badge/Kotlin-2.0-7F52FF?logo=kotlin&logoColor=white)](https://kotlinlang.org)
[![Android](https://img.shields.io/badge/Android-12%2B-3DDC84?logo=android&logoColor=white)](https://developer.android.com)
[![Material](https://img.shields.io/badge/Material_Components-1.12-7570D3?logo=materialdesign&logoColor=white)](https://m3.material.io)
[![Gradle](https://img.shields.io/badge/Gradle-8-02303A?logo=gradle&logoColor=white)](https://gradle.org)
[![Shell](https://img.shields.io/badge/POSIX_sh-mksh%20%2F%20busybox-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![AWK](https://img.shields.io/badge/AWK-XML_patchers-SR0120)](https://en.wikipedia.org/wiki/AWK)
[![Python](https://img.shields.io/badge/Python-3-3776AB?logo=python&logoColor=white)](https://www.python.org)
[![Magisk](https://img.shields.io/badge/Root-Magisk%20%2F%20KernelSU%20%2F%20APatch-00AF9C)](https://topjohnwu.github.io/Magisk/)

---

## Why this exists

Two facts from the probe data shaped everything:

1. **Stock attenuation at volume index 100 is already 0 mB.** No amount of XML editing raises the max — the win is at every step *below* max, where Xiaomi's curve is steep. Flattening it (`CURVE_FLATTEN=0.55`) gives **+12.7 dB at half volume**, measured on the real MUSIC/SPEAKER curve.
2. **There is almost no hardware headroom left.** The earpiece PA and Cirrus SP attenuator are already at their enum maxima; the CS35L41 class-D stage sits at 18 of 20 (~1–2 dB remains). The only way past max volume is **dynamic range compression** — pull quiet parts up, hold peaks with a limiter — which raises average level 10–15 dB without ever exceeding 0 dBFS.

## The layers

| Layer | What it does | Where | Default |
|---|---|---|---|
| **1–2** | Global 4-band multiband compressor + limiter + optional LoudnessEnhancer on session 0 | Companion app (priv-app) | on, via app |
| **3** | Flattens the volume-attenuation curve in `audio_policy_volumes*.xml` | Module, awk patcher | **on** |
| **3b** | 30 → 50 volume steps, safe-media bypass props | Module, `resetprop` | **on** |
| **4a** | WCD9385 RX digital gain (**headset/earpiece only** — speakers bypass this codec) | Module, awk patcher | off |
| **4b** | Cirrus CS35L41 amp gain (**only layer that raises speaker SPL**, ~1–2 dB, permanent-damage risk) | Module, `tinymix` | off, double opt-in |

**Max volume is unchanged by design** — layer 3 only makes steps below max louder. To go beyond max, that's compression in the app (layers 1–2).

## How it survives HyperOS updates

`post-fs-data.sh` runs **before** the module overlay is mounted. It reads the live, unmodified vendor configs from disk, patches them with awk, validates the result structurally (bracket balance, root tag, ±25% size), and only then writes the patched copy into `$MODDIR/system` — which the root implementation mounts over the originals. The overlay is rebuilt from scratch every boot, so a HyperOS update that changes `mixer_paths.xml` never leaves a stale file mounted.

Every patch follows the same contract: **backup → transform → validate → mount**. A failed validation is a no-op, not a broken boot.

## Safety model

- **Bootloop guard** — 3 boots without `boot_completed` and the module disables itself (`disable` flag + overlay stripped) and writes the reason to `/data/adb/alioth_loud/disabled-reason.txt`.
- **Layer 4b** refuses to write any value it hasn't validated against the range `tinymix` itself reports, clamps to a fraction of remaining headroom, and requires both `ENABLE_CIRRUS_GAIN=1` **and** `I_ACCEPT_SPEAKER_DAMAGE_RISK=1`.
- **Dry-run mode** (`DRY_RUN=1` in config) logs what would happen and changes nothing — recommended for the first boot after enabling a risky layer.
- **Clean uninstall** — XML patches live only in the overlay (removing the module restores stock), the amp is reverted to stock values, and backups of every touched file are kept.

## The companion app

Installed by the module into `/system/priv-app` with a `privapp-permissions` allowlist — required because attaching an effect to the global output mix (session 0) is gated behind `MODIFY_DEFAULT_AUDIO_EFFECTS`, which is `signature|privileged`. Without it, the app could only process its own audio.

It uses the framework **DynamicsProcessing** effect rather than shipping a `.so` — no vendor library, no `audio_effects.xml` patching, no SELinux label to get right, nothing for an OTA to revert, and it survives the Android 15 AIDL effect-HAL transition that is currently breaking ViPER4Android.

Features: master switch, Loud preset, input gain / threshold / ratio / attack / release / makeup gain / limiter ceiling sliders, boot-persistent foreground service, and a clear "privileged: yes/no" status so a failed priv-app install never looks like a silent no-op.

## Build

```sh
./build.sh              # module only
./build.sh --with-app   # also build + bundle the companion APK
./build.sh --test       # run the awk patcher + cirrus test suites only
```

The build refuses to package if the test suites fail, shell syntax is off (module scripts must be strict POSIX sh — they run under Android's mksh/busybox ash), the APK signature is invalid, the icon assets are malformed, or the manifest's privileged permissions have drifted from the privapp-permissions allowlist (on some builds a mismatch is a boot failure, not a warning).

## Install

1. Download the module zip from [**GitHub Releases**](../../releases) and flash it in Magisk / KernelSU / APatch (Android 12+).
2. Reboot.
3. Open **Alioth Loud**, confirm it says `privileged: yes`.
4. Pick the **Loud** preset, then raise makeup gain to taste.

Configuration lives at `/data/adb/alioth_loud/config.sh` and survives module updates; a probe script is copied to `/sdcard/probe.sh` so you can inspect your own device without a PC. Boot log: `/data/adb/alioth_loud/boot.log`.

## Repo layout

```
module/           flashable Magisk module (POSIX sh + awk patchers)
  common/         config, patch engine, bootloop guard, cirrus layer
  payload/        priv-app APK + privapp-permissions allowlist
app/              companion Android app (Kotlin, Views + Material)
tools/            probe scripts, awk test suite, icon verification
```

## License

[MIT License](./LICENSE) — Copyright (c) 2026 Hrishikesh Thombare.

## ⚠️ Use at your own risk — hardware layer 4b can genuinely destroy speakers, and everything here assumes the measured Redmi K40 / POCO F3 / Mi 11X (alioth) hardware.
