# BNRV700 / Quill Linux

Standalone Alpine Linux userspace for the Barnes & Noble NOOK GlowLight Plus
7.8-inch (BNRV700, Quill), using the stock Android Linux 3.0.35 kernel and
hardware drivers.

The port combines KOReader, Plato, and an E-Ink-optimized NetSurf browser.
The target is an i.MX6 SoloLite Cortex-A9 with VFPv3-D16 and no NEON, so all
native binaries must use the hard-float ARMv7 toolchain documented in
[`toolchains/README.md`](toolchains/README.md).

## Repository layout

| Directory | Responsibility |
| --- | --- |
| `components/common` | Headers shared by native components |
| `components/kernel` | Stock boot-image ramdisk patching and Alpine bootstrap |
| `components/koreader` | KOReader hardware userpatch, launcher, and plugins |
| `components/netsurf` | NetSurf framebuffer build, SDL shim, OSK, and browser overlay |
| `components/system` | Init, buttons, frontlight, audio, Plato shim, and system helpers |
| `mk` | Shared target compiler and ABI settings |
| `scripts` | Rootfs assembly, boot/deployment entrypoints, and device utilities |
| `tests` | Host-side layout, syntax, Makefile, and ARM ABI checks |
| `docs` | Architecture, build/deployment, hardware, user, and recovery guides |

Generated `build/`, `staging/`, `downloads/`, device images, and toolchain
caches are intentionally ignored. They are reconstructed by the documented
build process rather than committed to GitHub.

## Quick start

Install the host prerequisites and follow the complete [build and deployment
guide](docs/BUILD_AND_DEPLOY.md). In brief:

```sh
make all       # native helpers, NetSurf, patched boot image, rootfs payload
make test      # checks source layout, shell, Lua, and target ABI
make test-boot # safe RAM-only fastboot test
make push-rootfs  # upload/extract payload from TWRP ADB
```

Do not flash a boot image until the device-matched stock `boot_backup.img` has
been preserved and `fastboot boot build/boot_linux.img` has been tested.

## Deployment model

The rootfs payload is extracted into `/data/linuxroot` from a Ryogo/TWRP-style
recovery environment with `/data` mounted and writable. The patched boot image
starts `components/kernel/overlay/boot_linux.sh`, which enters the Alpine
userspace and launches the system supervisor. See [BUILD_AND_DEPLOY.md](docs/BUILD_AND_DEPLOY.md)
for the exact TWRP/ADB sequence and recovery procedure.

## Documentation

- [Build and deployment](docs/BUILD_AND_DEPLOY.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Hardware](docs/HARDWARE.md)
- [User guide](docs/USER_GUIDE.md)
- [Buttons](docs/BUTTONS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Developer guide](docs/DEVELOPMENT.md)

KOReader and Plato remain separate upstream projects and licenses. Their
release archives are fetched at build/update time; this repository contains
only the BNRV700 integration layer and packaging logic.
