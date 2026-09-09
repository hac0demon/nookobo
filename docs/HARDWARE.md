# Hardware Inventory & Pinout Specifications

This document catalogs the physical hardware components, bus assignments, and device nodes for the **Barnes & Noble NOOK GlowLight Plus 7.8" (BNRV700 / Quill)**.

---

## 1. System-on-Chip (SoC) & Memory

- **Processor**: NXP / Freescale i.MX6 SoloLite (MCIMX6L8DVN10AB).
- **Core Architecture**: Single-core ARM Cortex-A9 up to 1.0 GHz with 32 KB L1 caches and 256 KB L2 cache.
- **System Memory**: 1 GB LPDDR2 RAM.
- **Onboard Storage**: 8 GB eMMC 4.5 flash memory (`/dev/block/mmcblk0`).
- **Power Management (PMIC)**: Ricoh RN5T618 / RC5T619 multi-channel PMIC with integrated battery fuel gauge.

---

## 2. Display Subsystem (E-Ink Carta HD)

- **Panel Technology**: 7.8-inch E Ink Carta HD flexible display.
- **Native Resolution**: 1404 x 1872 pixels (300 DPI, 16 levels of grayscale).
- **Display Controller**: Integrated i.MX6 EPDC (Electrophoretic Display Controller).
- **Device Node**: `/dev/graphics/fb0`.
- **EPDC Waveform Modes**:
  - `WAVEFORM_MODE_INIT` (0): Panel initialization.
  - `WAVEFORM_MODE_DU` (1): Direct update, 1-bit monochrome fast refresh (typing, menus).
  - `WAVEFORM_MODE_GC16` (2): Full 16-level grayscale refresh (illustrations, book covers).
  - `WAVEFORM_MODE_GL16` (3): Low-ghosting 16-level refresh (e-book text pages).
  - `WAVEFORM_MODE_A2` (4): Fast 2-level dithered animation mode.
- **Hardware Stride / Line Length**: 1408 pixels (2816 bytes in 16bpp RGB565).

---

## 3. Input & Sensors

### 3.1 Physical Buttons (`/dev/input/event0` - `gpio-keys`)
All physical switches are wired to i.MX6 GPIO pins and reported via the standard Linux `gpio-keys` driver:

| Physical Key | Position | Linux Keycode | Evdev Name | Primary Function |
| :--- | :--- | :--- | :--- | :--- |
| **Power Button** | Top bezel | 116 | `KEY_POWER` | Sleep / Wake / Suspend |
| **Home Button** | Bottom bezel ("n") | 102 | `KEY_HOME` | Menu / Library / App Switcher |
| **Page Turn Up** | Left bezel (Top) | 192 | `KEY_F10` | Page Backward |
| **Page Turn Down** | Left bezel (Bottom) | 191 | `KEY_F9` | Page Forward |
| **Page Turn Up** | Right bezel (Top) | 193 | `KEY_F11` | Page Backward |
| **Page Turn Down** | Right bezel (Bottom) | 194 | `KEY_F12` | Page Forward |

### 3.2 Magnetic Folio Hall Effect Sensor
- **Driver**: `gpio-keys` on `/dev/input/event0`.
- **Event Type**: `EV_SW` (type 5), code 0 (`SW_LID`).
- **Values**:
  - `value = 1`: Magnetic cover closed -> triggers deep sleep / cover display.
  - `value = 0`: Magnetic cover opened -> triggers instant panel wake.

### 3.3 Touchscreen Digitizer (`/dev/input/event1` - `elan-touch`)
- **Controller**: Elan I2C Capacitive Touch Digitizer.
- **I2C Bus**: I2C-1 at 400 kHz.
- **Firmware Revision**: `7993220230` (Field 124 = 3).
- **Reporting Protocol**: Single-Touch protocol (`ABS_X`, `ABS_Y`, `ABS_TOOL_WIDTH`, `BTN_TOUCH`).

---

## 4. Frontlight & Illumination

Dual-channel ComfortLight system with warm (amber) and cool (white) LEDs:
- **White LED Controller**: TI LM3630A Channel A / MSP430 PWM (`/sys/class/backlight/mxc_msp430_fl.0/brightness`).
- **Amber LED Controller**: TI LM3630A Channel B (`/sys/class/backlight/lm3630a_ledb/brightness`).
- **Color Mixer**: `/sys/class/backlight/lm3630a_led/color` (0 = cool white, 10 = maximum warm amber).

---

## 5. Audio & Connectivity

### 5.1 3.5mm Headphone Audio Jack
- **Audio Codec**: Realtek ALC5640 / ALC5645 High-Definition I2S DAC.
- **I2C Control Bus**: I2C-0 at address `0x1a` or `0x1c`.
- **ALSA Sound Card**: `card 0` (`hw:0,0` / `/dev/snd/pcmC0D0p`).
- **CPU Footprint**: ~3-5% CPU during full eSpeak-NG text-to-speech synthesis or MP3 decoding.

### 5.2 Wi-Fi & Bluetooth (Realtek RTL8723DS)
- **Wi-Fi Interface**: SDIO interface running `8723ds.ko` (`wlan0`).
- **Bluetooth Controller**: High-speed UART interface (`/dev/ttymxc1`) running Realtek H5 protocol (`rtk_h5`) at 1,500,000 baud.
- **Firmware Files**: `/lib/firmware/rtlbt/rtl8723d_fw` and `rtl8723d_config`.

### 5.3 USB OTG & MTP Interface
- **Connector**: Micro-USB 2.0 High Speed.
- **USB Controller**: Freescale Chipidea USB OTG controller.
- **MTP Gadget Node**: `/dev/mtp_usb` served via `uMTP-Responder`.
