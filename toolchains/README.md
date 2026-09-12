# Toolchains and binary compatibility

## Native Alpine helpers and NetSurf

Use the repository's Buildroot musl ARMHF compiler:

```sh
downloads/toolchain_arm/bin/arm-linux-gcc --version
make native netsurf
```

Required target flags:

```text
-march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard
```

These produce ARM EABI5 hard-float binaries for Alpine Linux ARMHF. The
device's Cortex-A9 r2p10 has VFPv3-D16 only and no NEON. A binary containing
NEON instructions or registers `d16`–`d31` will fail with `SIGILL`.

## Plato shim

`components/system/src/plato_shim.c` is a glibc-linked preload library because
it is loaded into the Debian Jessie glibc Plato process. The rootfs builder
links it against the staged target libraries with `-nodefaultlibs -ldl -lc
-lgcc`. Do not link this library against the host libc or the Alpine musl
runtime.

## Rust/Plato source builds

The repository consumes the official prebuilt Plato release by default. If
Plato is built from source, its target configuration must be changed from
NEON-enabled defaults to an ARMv7 hard-float VFPv3-D16 target and linked with
the Debian Jessie-compatible runtime. Run the ABI scanner in `make test`
before putting a custom Plato binary on the device.
