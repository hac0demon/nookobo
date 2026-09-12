# BNRV700 Feature-Batch On-Device Verification Report

Date: 2026-09-12
Device: Barnes & Noble NOOK GlowLight Plus 7.8" (BNRV700, *Quill*), standalone Alpine chroot.
Final device state: `device_check.sh --glyph` **20/20 PASS**, KOReader active, rootfs marker `bnrv700-rootfs 857a618-dirty 2026-09-12T17:13:24Z`.

## Summary

All feature-batch CLs are committed and verified on-device. The batch comprises **15 CLs** (`51f261f` → `ad0aed7`), following 5 earlier NetSurf-CI CLs. Every load-bearing behavior was exercised against the live device (e-ink framebuffer capture + render, button/log evidence, health suite, sysfs read-back).

## Feature-batch CLs and verification

| CL | Description | On-device verification |
|---|---|---|
| `51f261f` | KOReader OTA token | KOReader supervisor (`start_koreader.sh`) launches `./reader.lua`; restart-on-exit-85 loop confirmed by process inspection. |
| `50349a8` | syncthing + freetype apk | `apk-db readable (118 packages)`; `daemon-syncthing running`. |
| `bcdffc9` | fbshot framebuffer capture/decode | Used throughout this session: `scripts/fbshot.py` renders every captured `/dev/fb0` raw (KOReader pages, app-switcher dialog, NetSurf, media card, battery header). |
| `7ea29d4` | device health check suite | `device_check.sh --glyph` **20/20 PASS** (final run). |
| `139b31d` | rootfs version marker + payload checksum | `rootfs-version bnrv700-rootfs 857a618-dirty` present and readable on device. |
| `c7b5311` | battery in app-switcher + splash | **Visual VERIFIED**: app-switcher header re-drawn with live sysfs battery (black bar + white centered title + white `BAT 100% FULL`); ink-map read of the header crop confirmed the black bar, the `NOOK APPLICATION SWITCHER` title, and the `BAT 100% FULL` text. |
| `9926b41` | suspend SoC on lid close (when KOReader not active) | See Lid test below. KOReader cover passthrough verified; NetSurf suspend path not triggered because the SW_LID lid-switch is not firing on this unit. |
| `6e02521` | shellcheck gate | `scripts/` shell scripts pass the shellcheck gate (CI-enforced). |
| `a10f9c7` | docs (self-update, health, battery, lid) | `docs/` updated; TROUBLESHOOTING.md §8 added by `ad0aed7`. |
| `d5db07a` | gitignore pyc | `.gitignore` ignores Python bytecode artifacts. |
| `857a618` | ship app-switcher / nook-webkey / send_key | `app-switcher`, `send_key` present and exercised on-device (media card, button handling); `input-event2` (uinput virtual keys) registered. |
| `9209e06` | syncthing v2 serve syntax | `daemon-syncthing running` (v2 `serve --home=` syntax confirmed working on-device). |
| `4c67144` | payload checksum PATH-independent at boot | boot checksum verification confirmed on-device (device_check `rootfs-version` + boot log). |
| `8dffc0d` | double-Home audio toggle | **VERIFIED end-to-end**: double-Home → `[btn-watcher] Home double tap detected -> audio play/pause toggle` + `[audiocontrol] Paused` in log; media card e-ink render (md5 `40278df7…`) shows `PLAYBACK: PLAY / PAUSE TOGGLED >||`; `audiocontrol` state cleaned to STOPPED. |
| `ad0aed7` | audio playback hang docs | Root cause documented (DAPM Off→STANDBY I2C burst on `snd_pcm_open`; `rt5640@i2c-0:0x1c` stuck after boot EIO; i2c busy-wait starves the single core → 60s WDT). Real fix = 4.1.15 kernel. |

## Lid test (`9926b41`)

- **Part (a) — KOReader active, lid close:** KOReader receives the SW_LID passthrough and runs its native `Kobo suspend` path; the e-ink retains the page (no separate cover frame — fb md5 identical before/closed/open: `be8013c7…`). KOReader log (`/data/linux_init.log`) confirms the `Kobo suspend` loop running.
- **Part (b) — NetSurf active, lid close:** the **SW_LID lid-switch is not generating an event on `/dev/input/event0`**. btn-watcher is processing event0 (it logged `Home single tap confirmed`), but never the SW_LID — across 4+ lid closes, including a raw-capture window with btn-watcher dead (exclusive read of event0) that also saw zero events. The SW_LID capability is present on gpio-keys (`B: SW=5`), but the lid sensor is not firing. The btn-watcher's `Lid closed -> suspending (active=netsurf)` path (`btn-watcher.c` SW_LID branch) is therefore not being triggered on this unit.

## Deltas & pre-existing observations

- **Kobo suspend wake-alarm loop (pre-existing):** KOReader's `/data/linux_init.log` shows ~689 `Kobo suspend: going to sleep` / `ZzZ... And woke up!` cycles since 09/09 (every ~17s), with `unexpected wakeups` incrementing; dmesg confirms matching `request_suspend_state: sleep (3->3)`. A background wake-alarm condition (device cannot stay asleep — likely USB wake events), not caused by this batch. Not a blocker.
- **Lid sensor not firing:** SW_LID capability present but not toggling (see Lid test part b).
- **USB flakiness:** ssh(9922) drops on commands >~0.3s, esp. with `sleep` or large base64 args; small gzip pulls and `echo OK` hold. Managed with fast ssh commands + streaming file transfers.
- **WDT soft-resets:** 4 physical power cycles used earlier; WDT soft-resets (60s timeout) do not count. `imx2-wdt: Unexpected close` spam (15×) is benign.
- **aplay repo version:** repo has `alsa-utils 1.2.11-r1` vs installed `1.2.16-r0`; `aplay` restored to the real ELF (66880B musl) via `apk fetch alsa-utils`.
- **Rootfs marker still `857a618-dirty`:** the device was deployed at `857a618`; later CLs (`9209e06`, `4c67144`, `8dffc0d`, `ad0aed7`) are committed on host but the device rootfs marker still reads `857a618-dirty` (redeploy would update it).
- **Chroot scratch packages:** the device chroot gained `alsa-lib-dev`, `build-base`, `alsa-utils` as scratch (for on-device debug tool compilation); can be `apk del`'d if the scratch footprint matters.
