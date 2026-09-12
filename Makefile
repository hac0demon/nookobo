SHELL := /bin/bash

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(ROOT_DIR)/mk/toolchain.mk

BUILD_DIR ?= $(ROOT_DIR)/build
BOOT_ORIG ?= $(ROOT_DIR)/boot_backup.img
BOOT_OUT ?= $(BUILD_DIR)/boot_linux.img
PAYLOAD_TAR ?= $(BUILD_DIR)/deploy_payload.tar.gz
MAGISKBOOT ?= $(ROOT_DIR)/scripts/magiskboot

SYSTEM_SRC := $(ROOT_DIR)/components/system/src
NETSURF_SRC := $(ROOT_DIR)/components/netsurf/src
COMMON_INC := $(ROOT_DIR)/components/common/include
NETSURF_BUILD_INPUTS := $(shell find $(ROOT_DIR)/components/netsurf -type f -print 2>/dev/null)
COMPONENT_FILES := $(shell find $(ROOT_DIR)/components -type f -print 2>/dev/null)

NATIVE_BINARIES := \
	$(BUILD_DIR)/btn-watcher \
	$(BUILD_DIR)/app-switcher \
	$(BUILD_DIR)/libbnrv700_plato_shim.so \
	$(BUILD_DIR)/libSDL-1.2.so.0 \
	$(BUILD_DIR)/nook-webkey \
	$(BUILD_DIR)/send_key \
	$(BUILD_DIR)/umtprd \
	$(BUILD_DIR)/epdc_probe

.PHONY: all native system netsurf koreader boot patch-boot rootfs payload release ci-inputs deploy \
	test test-boot push-rootfs clean distclean help device-check

# Full host-side build. Downloads and device images are intentionally not
# checked into Git; see docs/BUILD_AND_DEPLOY.md for prerequisites.
all: native netsurf boot rootfs

native system: $(NATIVE_BINARIES)

netsurf: $(BUILD_DIR)/libSDL-1.2.so.0 $(BUILD_DIR)/nook-webkey $(BUILD_DIR)/netsurf-fb

koreader:
	@echo "KOReader component is overlay-only; Lua syntax is checked by 'make test'."

$(BUILD_DIR):
	@mkdir -p "$@"

$(BUILD_DIR)/btn-watcher: $(SYSTEM_SRC)/btn-watcher.c | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) -I"$(COMMON_INC)" "$<" -o "$@"

$(BUILD_DIR)/app-switcher: $(SYSTEM_SRC)/app-switcher.c $(COMMON_INC)/font8x16.h | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) -I"$(COMMON_INC)" "$<" -o "$@"

$(BUILD_DIR)/libbnrv700_plato_shim.so: $(SYSTEM_SRC)/plato_shim.c | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) -fPIC -shared "$<" -o "$@" -Lstaging/lib -nodefaultlibs -ldl -lc -lgcc

$(BUILD_DIR)/libSDL-1.2.so.0: $(NETSURF_SRC)/sdl_fb0_shim.c $(COMMON_INC)/font8x16.h $(COMMON_INC)/font8x16_cyrillic.h | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) -I"$(COMMON_INC)" -fPIC -shared "$<" -o "$@" -lpthread

$(BUILD_DIR)/nook-webkey: $(NETSURF_SRC)/nook-webkey.c | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) "$<" -o "$@"

$(BUILD_DIR)/send_key: $(SYSTEM_SRC)/send_key.c | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) "$<" -o "$@"
$(BUILD_DIR)/epdc_probe: $(SYSTEM_SRC)/epdc_probe.c | $(BUILD_DIR)
	$(CC) $(COMMON_CFLAGS) "$<" -o "$@"

$(BUILD_DIR)/umtprd: $(SYSTEM_SRC)/umtprd/Makefile $(shell find $(SYSTEM_SRC)/umtprd/inc $(SYSTEM_SRC)/umtprd/src -type f)
	$(MAKE) -C "$(SYSTEM_SRC)/umtprd" OBJDIR="$(BUILD_DIR)/umtprd-obj" OUTPUT="$@" CC="$(CC)" CFLAGS="-I./inc $(COMMON_CFLAGS)" LDFLAGS="-lpthread -lrt $(ARCH_CFLAGS) -s"

$(BUILD_DIR)/netsurf-fb: $(NETSURF_BUILD_INPUTS)
	@bash "$(ROOT_DIR)/components/netsurf/build.sh"
	@test -x "$@"

boot patch-boot: $(BOOT_OUT)

$(BOOT_OUT): $(BOOT_ORIG) $(MAGISKBOOT) $(ROOT_DIR)/components/kernel/patch_boot.sh $(ROOT_DIR)/components/kernel/overlay/boot_linux.sh
	bash "$(ROOT_DIR)/components/kernel/patch_boot.sh" "$(BOOT_ORIG)" "$(BOOT_OUT)"

rootfs payload: $(PAYLOAD_TAR)

$(PAYLOAD_TAR): $(ROOT_DIR)/scripts/build_rootfs.sh $(COMPONENT_FILES) $(NATIVE_BINARIES) $(BUILD_DIR)/netsurf-fb
	bash "$(ROOT_DIR)/scripts/build_rootfs.sh"

deploy:
	bash "$(ROOT_DIR)/scripts/deploy.sh"

release: $(PAYLOAD_TAR)
	bash "$(ROOT_DIR)/scripts/package_release.sh"

ci-inputs:
	bash "$(ROOT_DIR)/scripts/package_ci_inputs.sh"

test:
	bash "$(ROOT_DIR)/tests/run.sh"

device-check: $(BUILD_DIR)/epdc_probe
	bash "$(ROOT_DIR)/scripts/device_check.sh"

test-boot: $(BOOT_OUT)
	bash "$(ROOT_DIR)/scripts/deploy.sh" --test-boot

push-rootfs: $(PAYLOAD_TAR)
	bash "$(ROOT_DIR)/scripts/deploy.sh" --push-rootfs

clean:
	rm -rf "$(BUILD_DIR)" "$(ROOT_DIR)/staging"

distclean: clean
	@echo "distclean removes only generated/download caches; source is untouched."
	rm -rf "$(ROOT_DIR)/downloads"

help:
	@echo "BNRV700 / Quill build targets"
	@echo "  make all          Build native helpers, NetSurf, boot image, and rootfs payload"
	@echo "  make native       Build system/button/Plato helpers for ARMv7 VFPv3-D16"
	@echo "  make netsurf      Build NetSurf and its framebuffer/input shims"
	@echo "  make boot         Patch a stock boot image into build/boot_linux.img"
	@echo "  make rootfs       Assemble build/deploy_payload.tar.gz"
	@echo "  make test         Run shell, Lua, layout, and ARM ABI checks"
	@echo "  make device-check  Run the on-device health check (needs adb + running chroot)"
	@echo "  make test-boot    Non-destructive fastboot boot test"
	@echo "  make push-rootfs  Deploy payload through TWRP ADB"
	@echo "  make deploy       Open the guided deployment assistant"
	@echo "  make release      Package checksummed GitHub release assets"
	@echo "  make ci-inputs    Package ignored CI build inputs with a digest"
