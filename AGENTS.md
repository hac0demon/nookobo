# AGENTS.md - Developer & AI Agent Guide for BNRV700 Linux

This document defines the architecture, design patterns, operational constraints, and development guidelines for AI agents and human contributors working within the **BNRV700 (NOOK GlowLight Plus 7.8" / Quill)** standalone Linux codebase.

---

## 1. System Overview & Context

- **Device**: Barnes & Noble NOOK GlowLight Plus 7.8" (Model BNRV700, Netronix E70Q50 board, codename *Quill*).
- **SoC**: NXP/Freescale i.MX6 SoloLite (MCIMX6L8DVN10AB, single-core ARM Cortex-A9 r2p10 @ 1.0 GHz, ARMv7-A hard-float).
  - **FPU Implementation**: **VFPv3-D16 ONLY (16 double-precision registers `d0-d15`)**.
  - **SIMD / NEON**: **NO NEON hardware unit**.
  - **Mandatory Target Compiler Baseline**: `-march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard`. Emitting any NEON vector instruction or referencing registers `d16-d31` will trigger an undefined instruction trap (`SIGILL`) and crash immediately.
- **Memory & Storage**: 1 GB LPDDR2 RAM, 8 GB eMMC 4.5 (`/dev/block/mmcblk0`).
- **Kernel**: Stock Android Linux 3.0.35 (`nook_ntx_6sl` PREEMPT).
- **Base Userspace**: Alpine Linux 3.20 (ARMHF, musl libc) located in `/data/linuxroot` (ext4).
- **Secondary Runtime**: Debian Jessie glibc 2.19 layer (`/lib/ld-2.19.so`, `libc.so.6`, `libstdc++.so.6`) for glibc binaries (KOReader native plugins and Plato reader).
- **Primary Applications**: KOReader (v2024.07) and Plato (0.9.45).

---

## 2. Critical Hardware & Subsystem Constraints

### 2.1 Display Subsystem (Freescale EPDC V1)
- **Controller**: Integrated i.MX6 EPDC.
- **Physical vs Logical Orientation**:
  - Hardware physical panel is landscape (1872 width x 1404 height) with `rotate = 1` (90 degrees clockwise), rotated 180° from default so the header is at the physical top and Nook logo/Home button are at the bottom.
  - Operating system logical orientation is portrait (1404 width x 1872 height, 300 DPI).
  - Framebuffer stride is **1408 pixels** (2816 bytes in 16bpp RGB565) due to 16-byte memory alignment.
- **Ioctl ABI**:
  - The 3.0.35 kernel supports **EPDC V1 ioctls ONLY**:
    - `MXCFB_SEND_UPDATE_V1 = 0x4040462e` (64-byte payload `struct mxcfb_update_data_v1`).
    - `MXCFB_WAIT_FOR_UPDATE_COMPLETE = 0xc008462f` (3221767727 with `struct mxcfb_update_marker_data`).
  - EPDC V2 ioctls (`0x4048462e` / `0x4004462f`) fail with `ENOTTY: Not a typewriter`.
- **KOReader Mapping**:
  - `components/koreader/overlay/1-bnrv700-hardware.lua` overrides `self.mech_refresh` and `self.mech_wait_update_complete` in `ffi/framebuffer_mxcfb.lua`.
  - Coordinates MUST be converted from logical portrait to physical landscape using `bb:getBoundedRect(x, y, w, h, ...)` and `bb:getPhysicalRect(x, y, w, h)`.
- **Plato Mapping**:
  - Plato Aura ONE (`PRODUCT="daylight"`, `MODEL_NUMBER="381"`) issues `0x4044462e` (68-byte V1 struct with `virt_addr`) while Clara HD issues `0x4048462e` (72-byte V2).
  - Both fail on the 3.0.35 kernel with `ENOTTY: Not a typewriter` unless translated.
  - Plato MUST be launched with `LD_PRELOAD=/opt/plato/libs/libbnrv700_plato_shim.so` (source: `components/system/src/plato_shim.c`), which:
    1. Intercepts `0x4048462e` and `0x4044462e` and translates them to kernel V1 (`0x4040462e`, 64 bytes).
    2. Intercepts `FBIOPUT_VSCREENINFO` (0x4601) and `FBIOGET_VSCREENINFO` (0x4600) to transparently remap rotation by 180° (`(rotate + 2) % 4`), keeping Plato upright with the Home button at the bottom.
    3. Intercepts `open` and `open64` to provide virtual fallback for missing hardware like `/sys/devices/virtual/input/input3/als_vis_data` (ambient light sensor) and `/dev/rtc0`.
    4. Intercepts `read` on `/dev/input/event1` to synthesize `ABS_MT_TOUCH_MAJOR = 100` when `BTN_TOUCH == 1` so Plato's `TouchProto::MultiA` registers finger contacts.

### 2.2 Touchscreen Digitizer (Elan Protocol & Snow Protocol Handling)
- **Device Node**: `/dev/input/event1` (`elan-touch`, I2C-1 @ 0x10).
- **Firmware ID**: `7993220230` (field 124 == 3).
- **Protocol Details**:
  - The driver emits Linux Multi-Touch Type A with single/multi-contact slots:
    - `EV_ABS (3), ABS_MT_TRACKING_ID (57)`: 0..2
    - `EV_ABS (3), ABS_MT_POSITION_X (53)`: 0..1872
    - `EV_ABS (3), ABS_MT_POSITION_Y (54)`: 0..1404
    - `EV_ABS (3), ABS_MT_TOUCH_MAJOR (48)`: always 0
    - `EV_ABS (3), ABS_MT_WIDTH_MAJOR (50)`: always 0
    - `EV_KEY (1), BTN_TOUCH (330)`: contact state (1 down, 0 up)
    - `EV_ABS (3), ABS_TOOL_WIDTH (24)`: 1024 down, 0 up
    - `EV_SYN (0), SYN_REPORT (0)`
- **KOReader Requirements**:
  - `KoboDevice.touch_snow_protocol` MUST be `true` (`Input.snow_protocol = true`).
  - `KoboDevice.touch_phoenix_protocol` MUST be `false` (Phoenix cancels touches when `TOUCH_MAJOR == 0`).
  - `KoboDevice.hasMultitouch` MUST be `true`.
  - `KoboDevice.touch_switch_xy` MUST be `true`, `touch_mirrored_x` MUST be `true`, `touch_mirrored_y` MUST be `false` (matches 180° upright orientation).
  - `BTN_TOUCH (330)` MUST NOT be mutated or intercepted as `EV_ABS` in hooks; KOReader's `handleKeyBoardEv` requires `EV_KEY: BTN_TOUCH: 0` to detect contact lift under `snow_protocol`.
  - Standard `Input:handleTouchEv` is used (do NOT override with `handleTouchEvLegacy`).

### 2.3 Hardware Buttons & Multiplexing (`btn-watcher` & `app-switcher`)
- **Raw Event Node**: `/dev/input/event0` (`gpio-keys`).
  - Keycodes: `KEY_POWER` (116), `KEY_HOME` (102), `KEY_F9` (191), `KEY_F10` (192), `KEY_F11` (193), `KEY_F12` (194), `SW_LID` (0).
- **Supervisor Daemon**: `/opt/bin/btn-watcher` (source: `components/system/src/btn-watcher.c`).
- **App Switcher & Quick Launch**: `/opt/bin/app-switcher` (source: `components/system/src/app-switcher.c`, font: `components/system/src/font8x16.h`).
  - **Operation**:
  - Opens `/dev/input/event0` with `EVIOCGRAB` to prevent double-event reception by readers.
  - Emits filtered events onto a virtual `uinput` node (`/dev/input/event2` labeled `nook-virtual-keys`).
  - **Single Power Tap**: Emits virtual `KEY_POWER` click -> readers render sleep cover and call `mem > /sys/power/state`.
  - **Double Power Tap (<=400ms)**: Intercepts event and executes `/opt/scripts/toggle_frontlight.sh &` to toggle LEDs without redrawing.
  - **Hardware Chord Shortcuts (Hold Home + Press Side Button)**:
    - **Home + Top Left (191)**: Switch to KOReader (if already in KOReader: triggers native Frontlight Dialog).
    - **Home + Bottom Left (192)**: Switch to Plato (if already in Plato: toggles Frontlight LEDs).
    - **Home + Top Right (193)**: Launch NetSurf Web Browser (if in NetSurf: returns to reading).
    - **Home + Bottom Right (194)**: Toggle Media Player Mode (foreground controls <-> background playback).
  - **Media Player Mode (5-Button Hardware Control)**:
    - Top Left (191): Previous Track (`|<<`)
    - Bottom Left (192): Shuffle Toggle (`ON / OFF`)
    - Top Right (193): Next Track (`>>|`)
    - Bottom Right (194): Play / Pause
    - Single Home (102): Play / Pause
    - Home + Bottom Right (194): Send Media Player to background (music keeps playing seamlessly, side buttons revert to page turns).
  - **Normal Reading Mode**:
    - Single Home Tap: Emits virtual `KEY_HOME` click -> Library / Top Menu.
    - Long Home Hold (>=500ms): Emits held `KEY_HOME` -> reader displays Frontlight & Warmth slider dialog.
    - Page Keys (F9-F12) & Lid (SW_LID): Forwarded with zero latency directly to `uinput`.

### 2.4 Dual-Channel Frontlight (ComfortLight)
- **Hardware**:
  - Cool White LEDs: `/sys/class/backlight/mxc_msp430_fl.0/brightness` (0..100) and `lm3630a_leda` (0..255).
  - Warm Amber LEDs: `/sys/class/backlight/lm3630a_ledb/brightness` (0..255).
  - Color Mixer: `/sys/class/backlight/lm3630a_led/color` (0..10).
- **Plato Emulation**:
  - Plato Aura ONE hardcodes `/sys/class/backlight/lm3630a_led1a` and `/sys/class/backlight/lm3630a_led1b`.
  - A bind mount over `/sys/class/backlight` using `/tmp/fake_backlight` symlinks MUST be active before Plato starts. This is configured in `components/system/overlay/init_system.sh` and `components/system/overlay/start_plato.sh`.

---

## 3. Repository Structure & Key Files

```
.
├── Makefile                     # Top-level build automation
├── README.md                    # User-facing repository landing page
├── AGENTS.md                    # This developer & agent guide
├── docs/                        # In-depth architectural & hardware documentation
│   ├── ARCHITECTURE.md          # Full system architecture
│   ├── HARDWARE.md              # Pinout, buses, and sensor inventory
│   ├── USER_GUIDE.md            # Comprehensive user manual
│   ├── DEVELOPMENT.md           # Developer & build guide
│   ├── BUTTONS.md               # Button supervisor daemon specification
│   └── TROUBLESHOOTING.md       # Emergency recovery & diagnostics
├── components/                  # Separated, publishable source components
│   ├── common/                  # Headers shared by native components
│   ├── kernel/                  # Boot-image patch and Alpine bootstrap
│   ├── koreader/                # KOReader userpatches and plugins
│   ├── netsurf/                 # NetSurf source, shim, OSK, and overlay
│   └── system/                  # Init, buttons, Plato shim, and utilities
├── mk/toolchain.mk              # Shared VFPv3-D16 target ABI settings
├── packaging/                   # Rootfs merge and release packaging notes
├── scripts/                     # Build, deployment, and target update scripts
├── tests/                       # Host-side reproducibility and ABI checks
└── toolchains/                  # Host and target toolchain compatibility notes
```

---

## 4. Development Workflow & Commands

### 4.1 Cross-Compilation
The host repository contains an ARMv7 Cortex-A9 cross-compiler at `downloads/toolchain_arm/bin/arm-linux-gcc`.

- **Compile `btn-watcher`**:
  ```bash
  make native
  ```
- **Compile `app-switcher`**:
  ```bash
  make native
  ```
- **Compile `libbnrv700_plato_shim.so`**:
  ```bash
  make native
  ```

### 4.2 Building & Packaging
- **Build Full System** (boot image + rootfs payload):
  ```bash
  make all
  ```
- **Repack Boot Image Only**:
  ```bash
  make patch-boot
  ```
- **Reconstruct Rootfs Payload Only**:
  ```bash
  make rootfs
  ```

### 4.3 Testing on Target Hardware
- **Tethered Boot Test (RAM-only, non-destructive)**:
  ```bash
  fastboot boot build/boot_linux.img
  ```
- **Deploy Rootfs via TWRP ADB**:
  ```bash
  make push-rootfs
  ```
- **Interactive SSH Access**:
  ```bash
  ssh -p 2222 root@127.0.0.1
  # (or direct on local network: ssh root@<DEVICE_IP>)
  ```

---

## 5. Guidelines for AI Agents

1. **Source Synchronization Rule**:
   - Never modify files directly on the live device via SSH without also updating the corresponding canonical files in `components/` or `scripts/`.
   - The rootfs assembler is the only supported path from component overlays to `staging/`; do not hand-edit generated staging files.
2. **Preserve Userpatch Structure**:
   - All KOReader modifications MUST remain inside `components/koreader/overlay/1-bnrv700-hardware.lua` as an early userpatch (`package.loaders[2]` interceptor).
   - Do NOT edit stock KOReader core files in `/opt/koreader/frontend/` directly. This ensures that KOReader internal OTA updates do not break hardware compatibility.
3. **EPDC Geometry Safety**:
   - Always retain bounding box calculations (`bb:getBoundedRect` and `bb:getPhysicalRect`) in the framebuffer userpatch. Passing raw unaligned logical coordinates to `MXCFB_SEND_UPDATE_V1` will cause kernel framebuffer corruption.
4. **Binary Compatibility**:
   - When compiling helper C binaries for Alpine rootfs, use standard musl headers or static linking.
   - When compiling shims or libraries for Plato (`libbnrv700_plato_shim.so`), link against the target's glibc runtime (`libc.so.6`) and declare functions directly to avoid musl 64-bit time symbol collisions (`__dlsym_time64`).
5. **Supervisor State Files**:
   - The active reader state is tracked via `/tmp/current_app` and `/tmp/active_reader` ("koreader" or "plato").
   - When initiating a reader swap, update both state files before issuing `SIGTERM` or `pkill`.
6. **Mandatory CPU / FPU Architecture Baseline**:
   - Standard Linux distributions define `armhf` as ARMv7-A with VFPv3-D32 + NEON.
   - The i.MX6SL Cortex-A9 r2p10 **lacks NEON** and has **VFPv3-D16 only** (16 registers `d0-d15`).
   - All compilers (C/C++, Rust, Go) MUST be passed:
     `-march=armv7-a -mcpu=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard`
   - Never allow auto-vectorization or compilers to target `vfpv3-d32` or touch `d16-d31`, or the SoC will throw an undefined instruction trap (`SIGILL`).
