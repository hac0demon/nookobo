# NetSurf component

This component builds the NetSurf framebuffer frontend and the BNRV700 direct
framebuffer/input integration.

- `src/sdl_fb0_shim.c` provides the EPDC V1 SDL 1.2 backend, touch dispatch,
  URL-bar OSK, and hardware-button integration.
- `src/nook-webkey.c` provides the optional phone keyboard/controller server.
- `src/netsurf_fb_osk.patch` adds the text-input callback used by the shim.
- `overlay/` contains the launcher, browser plugin, CSS, font settings, and
  NetSurf `Choices` file.
- `build.sh` builds the upstream NetSurf 3.11 source using the merged Alpine
  ARMHF sysroot.

The target compiler must use ARMv7-A, hard-float, and VFPv3-D16. NEON and
VFPv3-D32 binaries are rejected by the build check because the i.MX6SL has no
NEON unit and only registers `d0` through `d15`.
