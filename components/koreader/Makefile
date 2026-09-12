ROOT_DIR := $(abspath ../..)
.PHONY: all check
all: check
	@echo "KOReader overlays are ready for rootfs assembly."
check:
	@test -f overlay/1-bnrv700-hardware.lua
	@test -d overlay/plugins/platomanager.koplugin
