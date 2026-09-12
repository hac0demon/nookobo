# Build and deployment guide

This repository produces two artifacts:

- `build/boot_linux.img`: a patched copy of the device-matched stock boot
  image.
- `build/deploy_payload.tar.gz`: an Alpine ARMHF rootfs overlay payload.

The build never commits downloaded operating-system bundles, device images,
generated binaries, or staging trees. They are placed in ignored directories.

## Host prerequisites

Use a Linux x86_64 host. Install the host tools once:

```sh
sudo apt-get update
sudo apt-get install -y build-essential curl git unzip cpio python3 \
    pkg-config dpkg-dev adb fastboot
```

NetSurf additionally needs `flex`, `bison`, `m4`, `gperf`, and the matching
development packages. Its builder stages these into `downloads/hosttools`
when they are unavailable in the host environment.

The repository expects the Buildroot ARMHF musl toolchain at
`downloads/toolchain_arm`. The target ABI is mandatory:

```text
-march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard
```

The target is an i.MX6 SoloLite Cortex-A9 with VFPv3-D16 and no NEON. Do not
use a normal Debian armhf compiler configured for NEON/VFPv3-D32. See
`toolchains/README.md` for the expected compiler identity and checks.

## Fetching inputs

`make rootfs` downloads and caches Alpine 3.20 ARMHF, KOReader, Debian Jessie
glibc compatibility libraries, Alpine packages, and Plato under `downloads/`.
NetSurf also needs its pinned `netsurf-all-3.11` source tree and the merged
device sysroot described by `components/netsurf/build.sh`.

Supply a stock boot image obtained from the same BNRV700 device as
`boot_backup.img`. The boot patcher does not validate that an image belongs to
the correct hardware revision.

## Build targets

```sh
make native       # button supervisor, Plato shim, SDL/input helpers, uMTP
make netsurf      # NetSurf framebuffer binary and shims
make boot         # patched build/boot_linux.img
make rootfs       # build/deploy_payload.tar.gz
make all          # all of the above
make test         # host-side shell/layout/Lua/ARM ABI checks
```

The top-level Makefile delegates to the component Makefiles. Component source
is under `components/`; `build/`, `staging/`, and `downloads/` are generated.

## Safe deployment sequence

### 1. Non-destructive boot test

Put the reader into fastboot mode and verify the host sees it:

```sh
fastboot devices
make test-boot
```

`fastboot boot` loads the image into RAM and does not overwrite the boot
partition. Validate display, touch, Wi-Fi, KOReader, Plato, NetSurf, and sleep
before flashing anything.

### 2. TWRP rootfs deployment

Ryogo/TWRP-style recovery is required for the first payload installation:

1. Boot the device into TWRP recovery.
2. In TWRP, mount **Data**. The `/data` partition must be writable and
   decrypted if encryption is enabled.
3. Connect USB and verify `adb devices` shows the recovery device.
4. Run:

   ```sh
   make push-rootfs
   ```

   This creates `/data/linuxroot`, pushes `components/kernel/overlay/boot_linux.sh`
   to `/data/boot_linux.sh`, uploads the payload, extracts it, and removes the
   temporary archive.

If recovery ADB cannot see `/data`, stop and fix the TWRP mount/decryption
state first. Do not use a normal Android shell for the initial extraction if
it cannot write the Linux rootfs.

### 3. Tethered validation, then permanent flash

After the payload is present, run the tethered boot test again. Only after it
passes should the boot partition be modified:

```sh
fastboot flash boot build/boot_linux.img
fastboot reboot
```

Keep the original device-matched boot image in a safe location. Recovery is:

```sh
fastboot flash boot boot_backup.img
fastboot reboot
```

The interactive `scripts/deploy.sh` assistant exposes the same actions with
confirmation gates. It is the recommended entry point for operators who have
not used fastboot/TWRP on this device before.
