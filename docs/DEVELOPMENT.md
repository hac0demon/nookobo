# Developer & Build Guide

This document is a development index for the **BNRV700 (NOOK GlowLight Plus 7.8")**. The complete reproducible host and TWRP procedure is in [BUILD_AND_DEPLOY.md](BUILD_AND_DEPLOY.md).

---

## 1. Toolchain & Prerequisites

### 1.1 Host Dependencies (x86_64 Linux)
```bash
sudo apt-get update
sudo apt-get install -y build-essential curl git unzip libarchive-tools \
    python3 python3-pip adb fastboot
```

### 1.2 Cross-Compiler Toolchain
The repository uses a Cortex-A9 optimized Buildroot musl cross-compiler (`arm-linux-gcc` / `arm-buildroot-linux-musleabihf-gcc` 13.3.0) located under `downloads/toolchain_arm/bin/`.

Verify the compiler:
```bash
./downloads/toolchain_arm/bin/arm-linux-gcc --version
```

---

## 2. Building Components

### 2.1 Full Build (Boot Image + Rootfs Payload)
```bash
make all
```
This target:
1. Runs `components/kernel/patch_boot.sh` using `magiskboot` to repack the boot image with the Linux bootstrap script (`build/boot_linux.img`).
2. Runs `scripts/build_rootfs.sh` to download Alpine Linux minirootfs, install packages via `apk.static`, deploy KOReader, compile helper daemons, configure shims, and package `build/deploy_payload.tar.gz`.

### 2.2 Compiling native components
```bash
make native
make netsurf
```

The shared `mk/toolchain.mk` supplies the mandatory VFPv3-D16 flags. Native
source is separated under `components/system/src` and `components/netsurf/src`.

---

## 3. Deploying to Hardware

### 3.1 Non-Destructive Tethered Boot Test
To test the Linux kernel and boot image without flashing the onboard eMMC:
1. Boot the device into fastboot mode (Hold Power + Home until Fastboot appears).
2. Execute:
   ```bash
   make test-boot
   ```
   (Invokes `fastboot boot build/boot_linux.img`).

### 3.2 Permanent Deployment via TWRP ADB
1. Boot into TWRP recovery.
2. Connect USB cable and execute:
   ```bash
   make push-rootfs
   ```
   This unpacks `deploy_payload.tar.gz` into `/data/linuxroot` on the device.

---

## 4. KOReader Plugin Development

KOReader plugins reside in `/opt/koreader/plugins/<plugin_name>.koplugin/`.
A minimal plugin requires two files:

### `_meta.lua`
```lua
local _ = require("gettext")
return {
    name = "myplugin",
    fullname = _("My Custom Plugin"),
    description = _("Description of functionality."),
}
```

### `main.lua`
```lua
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
}

function MyPlugin:addToMainMenu(menu_items)
    menu_items.my_plugin = {
        text = _("My Plugin Action"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Action triggered!"),
                timeout = 3,
            })
        end,
    }
end

return MyPlugin
```
