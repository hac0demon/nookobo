# Target: BNRV700 (Netronix E70Q50 / Quill) Linux Deployment Pipeline

## Context
We are converting an Android 4.4.2 BNRV700 e-reader into a standalone Alpine Linux ARMHF terminal.
Stock kernel: Linux 3.0.35 (nook_ntx_6sl).
Partitions: /data is large ext4, /boot is standard Android boot.img format.

## Tasks Required
1. Generate an automated `Makefile` orchestrating all host tasks.
2. Unpack `boot_backup.img` using `magiskboot`, inject a hook into `ramdisk/init.rc` at `on post-fs-data` calling `/system/bin/sh /data/boot_linux.sh`, and repack into `boot_linux.img`.
3. Script downloading and unpacking `alpine-minirootfs-*-armhf.tar.gz` into `staging/`.
4. Generate `/data/boot_linux.sh` (device bootstrapper) to mount /proc, /sys, /dev, /dev/pts, configure EPDC sysfs nodes, and chroot into `/data/linuxroot`.
5. Pre-configure Alpine userland:
   - `resolv.conf`, package installation script (syncthing, netsurf-framebuffer, tslib, dejavu fonts, dropbear, curl).
   - NetSurf configuration (`~/.netsurf/Choices`) set to 140pt DejaVu Sans, direct linux fb surface.
   - KOReader launcher (`start_koreader.sh`) with `FRAMEBUFFER=/dev/fb0`, `KOR_INPUT_TOUCH=/dev/input/event1`, `KOR_INPUT_KEYS=/dev/input/event0`.
   - KOReader `event_map.lua` mapping keycodes 191-194 (F9-F12) to LPgBack / LPgFwd.
   - Background Syncthing systemd/openrc service or runscript targeting `/data/syncthing`.
6. Package payload into `deploy_quill.tar.gz` and generate a verified `deploy.sh` script using ADB and Fastboot.