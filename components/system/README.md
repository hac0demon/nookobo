# System component

This component contains the Alpine init overlay, Plato launcher/frontlight
compatibility, audio/Bluetooth/Wi-Fi helpers, hardware-button supervisor, and
the Plato EPDC/input shim.

- `src/btn-watcher.c` owns raw GPIO-key multiplexing and virtual uinput keys.
- `src/app-switcher.c` owns the optional full-screen switcher.
- `src/plato_shim.c` translates Plato framebuffer ioctls and supplies target
  compatibility fallbacks.
- `overlay/` is installed below `/opt`, `/etc`, and `/opt/plato` by the rootfs
  assembler.
- Shared button/OSK font tables are in `components/common/include`.

All target binaries are built with the shared flags in `mk/toolchain.mk`.
