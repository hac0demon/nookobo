# Packaging and deployment boundary

`scripts/build_rootfs.sh` is the rootfs assembler and `scripts/deploy.sh` is
the guarded operator/deployment entrypoint. They intentionally remain thin
top-level commands so a release can be operated with:

```sh
make rootfs
make push-rootfs
```

The assembler merges the four component overlays into one Alpine filesystem:

```text
components/kernel/overlay   -> boot ramdisk input
components/koreader/overlay -> /opt/koreader and userpatches
components/netsurf/overlay  -> /root/.netsurf, /etc/netsurf, browser launcher
components/system/overlay   -> /opt, /etc, Plato settings and system helpers
```

Native outputs from `make native` and `make netsurf` are copied into the
payload only after they pass the ARM ABI checks. The payload is a tar archive,
not a filesystem image, so TWRP/ADB can extract it into `/data/linuxroot`
without repartitioning the device.

`INSTALL.md` is the release-install template used by
`scripts/package_release.sh`. The generated release contains a checksummed
rootfs archive, an optional device-matched boot image, and a convenience ZIP.
