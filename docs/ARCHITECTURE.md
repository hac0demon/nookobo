# System Architecture & Technical Design

This document details the software and hardware adaptation architecture of the standalone Alpine Linux operating system port for the **Barnes & Noble NOOK GlowLight Plus 7.8" (BNRV700 / Quill)**.

---

## 1. High-Level Architecture Overview

The BNRV700 Linux port operates as a clean, low-overhead embedded Linux distribution replacing Android while retaining the vendor-optimized stock Linux 3.0.35 kernel and hardware drivers.

```
+-----------------------------------------------------------------------+
|                             USERSPACE                                 |
|                                                                       |
|   +-----------------------+               +-----------------------+   |
|   |        KOReader       |               |         Plato         |   |
|   |  - Native E-Ink UI    | <--- App ---> |  - Rust Fast Reader   |   |
|   |  - Minfolio / RSS     |    Switcher   |  - Dual Frontlight    |   |
|   |  - Read Aloud (TTS)   |  (Double-Tap) |  - EPDC V1 Shim       |   |
|   +-----------------------+               +-----------------------+   |
|               |                                       |               |
|               +-------------------+-------------------+               |
|                                   |                                   |
|                      +--------------------------+                     |
|                      |  Virtual uinput Device   |                     |
|                      |  (/dev/input/event2)     |                     |
|                      +--------------------------+                     |
|                                   ^                                   |
|                                   | (Filtered & Remapped)             |
|                      +--------------------------+                     |
|                      | Button Supervisor Daemon |                     |
|                      |   (/opt/bin/btn-watcher) |                     |
|                      +--------------------------+                     |
|                                   ^                                   |
|                                   | (EVIOCGRAB)                       |
+-----------------------------------|-----------------------------------+
| KERNEL & HARDWARE                 |                                   |
|                                   |                                   |
|  [gpio-keys: /dev/input/event0] --+                                   |
|  [elan-touch: /dev/input/event1]  (Single-Touch ABS_X/Y/WIDTH -> ABS_PRESSURE)
|  [imx_epdc_fb: /dev/graphics/fb0] (EPDC V1 ioctls 0x4040462e / wait 0xc008462f)
|  [LM3630A + MSP430: sysfs]        (Cool/Warm PWM Frontlight Mixer)    |
|  [ALC5640 I2C DAC: /dev/snd]      (3.5mm Headphone Jack Audio Output) |
|  [RTL8723DS: wlan0 / /dev/ttymxc1](Wi-Fi 802.11n + Bluetooth 4.2 A2DP)|
+-----------------------------------------------------------------------+
```

---

## 2. Boot & Execution Flow

### 2.1 Boot Sequence
1. **Bootloader (u-boot)** loads `boot.img` (kernel + ramdisk) into RAM at `0x70800000`.
2. **Linux 3.0.35 Kernel** initializes SoC peripherals, clocks, memory controllers, EPDC display engine, and mounts `initramfs` (Android ramdisk).
3. **Android `/init` Hijack**:
   - The stock `/init` binary is replaced or chained with `/data/boot_linux.sh`.
   - The script mounts physical partitions:
     - `/dev/block/mmcblk0p7` (`/data`) as primary storage.
     - Optional `/dev/block/mmcblk0p5` (`/system`, ~360 MB) as rootfs or swap.
   - The script establishes a chroot or `pivot_root` environment into `/data/linuxroot` (Alpine Linux ARMHF).
4. **Userspace Initialization (`/opt/init_system.sh`)**:
   - Sets up dynamic sysfs compatibility shims for ComfortLight dual-channel LEDs (`/sys/class/backlight/lm3630a_led1a` and `lm3630a_led1b`).
   - Probes and un-mutes the Realtek ALC5640 audio codec for the 3.5mm headphone jack.
   - Initializes Realtek RTL8723DS Bluetooth UART (`rtk_h5` at 1.5 Mbps) and powers on `hci0`.
   - Starts Dropbear SSH daemon for tethered or wireless debugging.
   - Launches `uMTP-Responder` on `/dev/mtp_usb` for USB mass file transfer.
   - Launches background `Syncthing` for markdown note and document sync.
   - Launches `btn-watcher` hardware button supervisor with exclusive grab on `/dev/input/event0`.
   - Enters the persistent reader supervisor loop.

---

## 3. Hardware Adaptation Layer (HAL)

### 3.1 Display Subsystem (Freescale EPDC V1)
- **Controller**: Built-in i.MX6 SoloLite EPDC (Electrophoretic Display Controller).
- **Physical Geometry**: 1872 x 1404 landscape physical native matrix with 270-degree hardware scan (`rotate = 3`).
- **Logical Geometry**: 1404 x 1872 portrait resolution (300 DPI, 7.8-inch display).
- **Ioctl Command Set (V1 ABI)**:
  - `MXCFB_SEND_UPDATE_V1 = 0x4040462e` (64-byte payload `struct mxcfb_update_data_v1`).
  - `MXCFB_WAIT_FOR_UPDATE_COMPLETE = 0xc008462f` (3221767727 with `struct mxcfb_update_marker_data`).
- **KOReader Integration**:
  - `configs/1-bnrv700-hardware.lua` patches `ffi/framebuffer_mxcfb.lua`.
  - Maps portrait bounding box coordinates to physical landscape hardware EPDC regions via `bb:getBoundedRect` and `bb:getPhysicalRect`.
  - Completely eliminates EPDC update corruption and `ENOTTY` errors.
- **Plato Integration**:
  - Plato Aura ONE / Clara HD targets EPDC V2 ioctls (`0x4048462e`).
  - `libbnrv700_plato_shim.so` translates V2 ioctls to V1 in real time, enabling native, hardware-accelerated E-ink refreshes without recompiling Plato.

### 3.2 Touchscreen Digitizer (Elan I2C Single-Touch)
- **Hardware**: Elan I2C Capacitive Touch Digitizer on `/dev/input/event1`.
- **Protocol**: Firmware ID `7993220230` implements the Linux **Single-Touch Protocol**:
  - `EV_ABS: ABS_X (0)`: 0..1872
  - `EV_ABS: ABS_Y (1)`: 0..1404
  - `EV_ABS: ABS_TOOL_WIDTH (24)`: contact width (>0 down, 0 up)
  - `EV_KEY: BTN_TOUCH (330)`: contact state (1 down, 0 up)
- **Event Translation**:
  - KOReader's `1-bnrv700-hardware.lua` activates `handleTouchEvLegacy` and maps:
    - `ABS_TOOL_WIDTH (24) -> ABS_PRESSURE (16)`.
    - `BTN_TOUCH (330) -> ABS_PRESSURE (16)` down/up transition.
    - Swaps axes and mirrors X to match 1404x1872 logical portrait coordinates.

### 3.3 Unified Button Architecture (`btn-watcher`)
- **Daemon**: `/opt/bin/btn-watcher` running in background.
- **Isolation**: Grabs `/dev/input/event0` with `EVIOCGRAB` to prevent double-event triggers.
- **Virtual Device**: Creates `/dev/input/event2` (labeled `nook-virtual-keys`) via Linux `uinput`.
- **Event Dispatch Rules**:
  | Input Trigger | Action | Target / Result |
  | :--- | :--- | :--- |
  | **Power Button (Single Tap)** | Sleep / Suspend | Passes `KEY_POWER` to active reader; renders cover; calls `sysfs suspend` |
  | **Power Button (Double Tap)** | Instant Frontlight Toggle | Runs `/opt/scripts/toggle_frontlight.sh` (saves/restores brightness) |
  | **Home Button (Single Tap)** | Menu / Library Navigation | Emits `KEY_HOME` click to virtual uinput |
  | **Home Button (Double Tap)** | Instant Reader Switch | Toggles `/tmp/current_app` and swaps between KOReader and Plato |
  | **Home Button (Long Press >=500ms)** | Frontlight Dialog | Emits held `KEY_HOME` to uinput (triggers native brightness sliders) |
  | **Page Keys (F9 - F12)** | Turn Page Forward / Back | Emits keys immediately to uinput |
  | **Magnetic Cover (SW_LID)** | Smart Cover Sleep / Wake | Emits switch event immediately to uinput |

### 3.4 Dual-Channel Frontlight (ComfortLight)
- **Hardware Architecture**:
  - White / Cool LEDs driven via TI LM3630A I2C controller / MSP430 PWM (`/sys/class/backlight/mxc_msp430_fl.0/brightness` or `lm3630a_leda`).
  - Warm / Amber LEDs driven via TI LM3630A (`/sys/class/backlight/lm3630a_ledb` or mixer `/sys/class/backlight/lm3630a_led/color`).
- **Sysfs Emulation**:
  - `start_plato.sh` and `init_system.sh` mount a bind-mount shadow over `/sys/class/backlight` exposing `lm3630a_led1a`, `lm3630a_led1b`, and `mxc_msp430.0` symlinks.
  - Allows both KOReader and Plato to independently control dual-channel intensity and warmth.

### 3.5 Audio Subsystem
- **3.5mm Headphone Jack**: Realtek ALC5640/5645 DAC wired to I2C-0 and Linux ALSA `card 0`. Direct PCM playback via `mpg123` or `espeak-ng`.
- **Bluetooth A2DP**: RTL8723DS UART Bluetooth controller managed via `bluez` and `bluez-alsa` (`aplay -D bluealsa`).
