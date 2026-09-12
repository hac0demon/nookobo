# KOReader component

This component contains only BNRV700 overlays for the upstream KOReader
bundle. KOReader itself is downloaded as a release archive by the rootfs
builder and is not vendored in this repository.

- `overlay/1-bnrv700-hardware.lua` is the early userpatch for EPDC V1,
  touchscreen geometry, frontlight paths, buttons, and the OTA mirror.
- `overlay/plugins/` contains the browser, Plato manager, audio, battery,
  read-aloud, and reader-switch plugins.
- `overlay/start_koreader.sh` is the device launcher/watchdog.

Do not edit `/opt/koreader/frontend` on a device. Update this overlay, rebuild
the payload, and let the userpatch survive KOReader updates.

## OTA Update and the `/tmp/koreader.sh` Token

KOReader's `Kobo:isStartupScriptUpToDate()` (v2024.07, `frontend/device/kobo/device.lua`)
compares `md5(/tmp/koreader.sh)` against `md5($KOREADER_DIR/koreader.sh)`. When they
differ, the UI offers the "startup script is outdated" re-localization dialog. The
check exists to make users re-localize the bundled `koreader.sh` after an OTA update.

Two BNRV700 specifics made the check unreliable:

1. `/tmp` is tmpfs, so the token file vanishes on every reboot.
2. The supervisor (`overlay/start_koreader.sh`) runs `./reader.lua` directly; the
   stock `koreader.sh` wrapper (which performs the re-localization) is bypassed, so
   the token was never refreshed by KOReader itself.

Fix: `overlay/start_koreader.sh` re-copies `/opt/koreader/koreader.sh` to
`/tmp/koreader.sh` (mode 777) before every launch, immediately after the OTA-unpack
block (exit code 85 triggers the OTA unpack, then the re-copy). The md5 comparison
therefore passes after every OTA update and after every restart, preserving the
stock check's semantics instead of overriding it.
