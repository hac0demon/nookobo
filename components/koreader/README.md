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
