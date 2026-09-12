# GitHub releases and workflow artifacts

The repository keeps generated binaries out of Git history. The supported
publication path is:

1. GitHub Actions checks the source and builds the rootfs from a pinned input
   bundle.
2. The workflow creates `build/release/bnrv700-<version>/` with a rootfs
   archive, optional patched boot image, `INSTALL.md`, and `SHA256SUMS`.
3. The workflow uploads those files as a run artifact and, when requested,
   creates a GitHub Release containing the same files.

Run the local packaging step with:

```sh
make rootfs
make release VERSION=v2026.09.0
```

The install ZIP is convenient for users, while the separate rootfs and boot
assets are useful for scripting and inspection.

## Why a build-input bundle is required

The current rootfs builder uses more than source checked into this repository:

- the Buildroot ARMHF musl toolchain;
- the pinned NetSurf source tree;
- a merged Alpine/device sysroot and matching development APKs;
- optional device firmware, Plato, and plugins; and
- `magiskboot` plus a stock boot image for boot-image generation.

A GitHub runner starts with none of those ignored files. Create an immutable
input archive using the exact files from a known-good local build, publish it
where the workflow can download it, and record its SHA-256. The repository
provides a helper that preserves the required relative paths:

```sh
./scripts/package_ci_inputs.sh build/bnrv700-ci-inputs.tar.gz
```

Set `INCLUDE_BOOT=0` when making a rootfs-only input bundle. The helper stores
the pristine `netsurf-all-3.11.tar.gz`, not the locally configured NetSurf
directory; the workflow extracts and rebuilds it on the runner so local
absolute paths cannot leak into CI. Archive creation does not require network
access; the runner fetches missing public NetSurf APKs during the build.

Do not publish stock firmware or proprietary third-party files publicly unless
their redistribution terms permit it. A private object store or a private
release asset plus a read-only Actions secret is safer. The workflow accepts a
URL and verifies the supplied digest before extraction.

The boot image is deliberately not treated as universal: it is derived from
the supplied BNRV700 stock image. If no boot input is supplied, the workflow
still produces a rootfs release but does not pretend that it can produce a
safe boot image.

## First workflow setup

The manual `Build release artifacts` workflow takes:

- `release_tag`, for example `v2026.09.0`;
- `build_inputs_url`, the immutable input archive URL; and
- `build_inputs_sha256`, its SHA-256 digest.

Set the repository variables `BNRV700_BUILD_INPUTS_URL` and
`BNRV700_BUILD_INPUTS_SHA256` if the same bundle will be reused. For a private
URL, configure `BNRV700_BUILD_INPUTS_TOKEN` as an Actions secret; it is only
used as a bearer token for the download.

Run the workflow once with release publication disabled, inspect the uploaded
artifact, and perform the normal `fastboot boot` test. Then run it with
publication enabled. Workflow artifacts are for CI hand-off and have a
retention period; GitHub Release assets are the durable user-download path.

## User-facing install model

Users should download the release ZIP, verify `SHA256SUMS`, boot Ryogo/TWRP,
extract the rootfs payload into `/data/linuxroot`, and use `fastboot boot` for
the first image test. Permanent `fastboot flash boot` is intentionally a
separate, documented step after validation.
