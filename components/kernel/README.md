# Kernel and boot component

This component keeps the stock BNRV700 Android Linux 3.0.35 kernel and
patches only the boot image ramdisk. It does not build a replacement kernel.

`overlay/boot_linux.sh` is copied into the ramdisk and starts the Alpine
userspace from `/data/linuxroot`. `patch_boot.sh` uses the host `magiskboot`
binary to unpack, patch, and repack a stock `boot.img`.

Prerequisites:

- A device-matched stock `boot_backup.img` (never use a boot image from another
  BNRV700 revision).
- An executable `magiskboot` under `scripts/magiskboot` or `MAGISKBOOT=...`.
- `cpio`, `python3`, and standard host shell utilities.

Build with `make boot`. Test with `fastboot boot build/boot_linux.img` before
using the permanent `fastboot flash boot` operation.
