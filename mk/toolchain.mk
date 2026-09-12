# Shared target-toolchain definitions for the BNRV700 build.
#
# The i.MX6 SoloLite in the BNRV700 has ARMv7-A + VFPv3-D16 and no NEON.
# Keep these flags in one place so every native target uses the same ABI.

ROOT_DIR ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
TOOLCHAIN_DIR ?= $(ROOT_DIR)/downloads/toolchain_arm
CROSS_COMPILE ?= $(TOOLCHAIN_DIR)/bin/arm-linux-

TARGET_TRIPLE ?= arm-buildroot-linux-musleabihf
ifeq ($(origin CC), default)
CC := $(CROSS_COMPILE)gcc
endif
AR ?= $(CROSS_COMPILE)ar
RANLIB ?= $(CROSS_COMPILE)ranlib
STRIP ?= $(CROSS_COMPILE)strip

# Do not replace vfpv3-d16 with a distro default such as neon/vfpv3-d32.
ARCH_CFLAGS ?= -march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard
COMMON_CFLAGS ?= $(ARCH_CFLAGS) -O2 -Wall

export ARCH_CFLAGS COMMON_CFLAGS TARGET_TRIPLE
