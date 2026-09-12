# BNRV700 / Quill release @VERSION@

This package is for the Barnes & Noble NOOK GlowLight Plus 7.8-inch BNRV700
(Quill). Verify the model before continuing.

## Verify the download

```sh
sha256sum -c SHA256SUMS
```

## Install the rootfs

The first installation requires a Ryogo/TWRP-style recovery with **Data**
mounted and decrypted:

```sh
adb devices
adb push bnrv700-@VERSION@-rootfs.tar.gz /data/deploy_payload.tar.gz
adb shell "mkdir -p /data/linuxroot && tar -xzf /data/deploy_payload.tar.gz -C /data/linuxroot && rm /data/deploy_payload.tar.gz"
```

## Test the boot image without flashing

If this release includes `bnrv700-@VERSION@-boot.img`, put the reader into
fastboot mode and run:

```sh
fastboot devices
fastboot boot bnrv700-@VERSION@-boot.img
```

Validate display, touch, Wi-Fi, KOReader, Plato, NetSurf, and sleep before
considering a permanent flash. `fastboot boot` is RAM-only and does not replace
the boot partition.

Only after a successful test should an experienced operator consider:

```sh
fastboot flash boot bnrv700-@VERSION@-boot.img
fastboot reboot
```

Keep the original device-matched boot image for recovery. Do not use a boot
image built for another hardware revision.
