# Troubleshooting & Emergency Recovery

This document provides diagnostic steps and recovery procedures for issues encountered when operating or developing on the **BNRV700 (NOOK GlowLight Plus 7.8")**.

---

## 1. Emergency Recovery & Fastboot Unbricking

If the operating system fails to boot or becomes unresponsive:

### 1.1 Entering Fastboot Mode
1. Ensure the device is powered down (hold Power button for 12 seconds).
2. Press and hold both the **Power** and **Home ("n")** buttons simultaneously for ~8 seconds until the display flashes.
3. Connect the Micro-USB cable to your host computer.
4. Verify fastboot detection:
   ```bash
   fastboot devices
   ```

### 1.2 Restoring Stock Android Boot Partition
To revert to stock Android:
```bash
fastboot flash boot boot_backup.img
fastboot reboot
```

### 1.3 Tethered Diagnostic Boot
To test the Linux boot image in RAM without writing to eMMC:
```bash
fastboot boot build/boot_linux.img
```

---

## 2. Touchscreen & Input Diagnostics

### 2.1 Touchscreen Not Responding
If touch is not registering in KOReader:
1. Verify whether the kernel driver is emitting raw single-touch events:
   ```bash
   ssh root@<DEVICE_IP>
   cat /proc/bus/input/devices
   ```
   Look for `elan-touch` on `event1`.
2. Inspect `/data/linux_init.log` to confirm that the hardware patch was applied:
   ```bash
   grep -i "BNRV700" /data/linux_init.log
   ```
   You should see:
   `INFO BNRV700: handleTouchEv is legacy: true`
3. Ensure that `/opt/koreader/patches/1-bnrv700-hardware.lua` exists and matches `components/koreader/overlay/1-bnrv700-hardware.lua`.

### 2.2 Buttons Not Responding
1. Check if the button supervisor daemon is active:
   ```bash
   ps aux | grep btn-watcher
   ```
2. Check the daemon log:
   ```bash
   cat /var/log/btn-watcher.log
   ```
3. Check virtual uinput device presence:
   ```bash
   ls -l /sys/class/input/event*/device/name
   ```
   You should see `nook-virtual-keys` registered as an input node.

---

## 3. Display & EPDC Diagnostics

### 3.1 EPDC Ghosting or Partial Refreshes
1. KOReader enforces Freescale EPDC V1 ioctls directly. If ghosting occurs after wake, press the Home button or tap the bottom-right corner to trigger a manual full refresh.
2. In Plato, verify that `libbnrv700_plato_shim.so` is loaded in `/opt/start_plato.sh` via `LD_PRELOAD`.

### 3.2 Display Artifacts or Skewed Lines
- The BNRV700 hardware framebuffer has a stride (line length) of 1408 pixels (2816 bytes) for a 1404x1872 image.
- Both KOReader and Plato accommodate this hardware alignment constraint automatically.

---

## 4. Frontlight Diagnostics

### 4.1 Frontlight Will Not Turn On
1. Test raw sysfs nodes manually via SSH:
   ```bash
   # Test white / cool LEDs:
   echo 50 > /sys/class/backlight/mxc_msp430_fl.0/brightness

   # Test amber / warm LEDs:
   echo 50 > /sys/class/backlight/lm3630a_ledb/brightness
   ```
2. Verify bind-mount shadow status:
   ```bash
   ls -l /sys/class/backlight/
   ```
   Ensure `lm3630a_led1a`, `lm3630a_led1b`, and `mxc_msp430.0` symlinks are present.

---

## 5. System Update Diagnostics

### 5.1 Payload Not Applied After Reboot

1. Check the boot log for the deploy lines:
   ```bash
   ssh root@<DEVICE_IP>
   grep -E "boot_linux|payload|rootfs version" /data/boot_linux.log | tail
   ```
   Look for `Found payload`, `Payload checksum OK`/`MISMATCH`, and the
   `rootfs version: old -> new` line.
2. On a checksum mismatch the payload is **kept** on the device for retry. Re-copy both
   files (MTP, or `make deploy`) and reboot again.
3. Confirm the installed version at any time:
   ```bash
   cat /etc/bnrv700-release
   ```
   or from the host: `make device-check` (reports `rootfs-version`).

### 5.2 Boot Loop After an Update

The deployed payload only replaces the chroot rootfs (`/data/linuxroot`); the boot
image in the eMMC `boot` partition is untouched. If a bad payload prevents boot:
1. Hold **Power** for 12 seconds, then **Power + Home** for ~8 seconds (fastboot).
2. Tether the known-good boot image: `fastboot boot build/boot_linux.img`.
3. Restore a good payload to `/data/deploy_payload.tar.gz` (or delete the staged files)
   and reboot, or re-run `make push-rootfs`.

---

## 6. Battery & Power Diagnostics

- Fuel gauge sysfs: `/sys/class/power_supply/mc13892_bat/{capacity,status,voltage_now}`;
  USB online state: `/sys/class/power_supply/mc13892_charger/online`.
- If the app-switcher header shows `BAT n/a`, verify `mc13892_bat` is present in
  `/sys/class/power_supply/` and that `capacity` is readable.
- If the lid does not suspend outside KOReader: confirm `btn-watcher` is running
  (Section 2.2) - it is the component that owns the lid event.

---

## 7. Display Health Probe (`make device-check`)

`make device-check` runs `/opt/bin/epdc_probe` inside the chroot: a full-frame
`MXCFB_SEND_UPDATE_V1` update followed by `MXCFB_WAIT_FOR_UPDATE_COMPLETE`, plus
geometry asserts (1404x1872, 16bpp, 2816-byte stride). One visible panel flash is
expected. The probe silences `/sys/class/graphics/fb0/epdc_auto_update` for the
round-trip (and restores the previous value), so it is not affected by another
framebuffer client's automatic refreshes. A failing EPDC check while KOReader still
renders correctly almost always points at a second client writing the framebuffer
without using the completion wait.

---

## 8. Audio Playback Hang (Stuck I2C Codec)

### 8.1 Symptom
Starting audio playback (the first `aplay`, e.g. via the Home double-tap audio
toggle) hangs the kernel: the device is unresponsive for ~60 s, then resets via
the hardware watchdog (WDT). It boots normally afterwards (chroot dropbear takes
1-5 min). The hang recurs on every playback start until the codec is fixed.
Double-tap detection, the `btn-watcher` log line, and the on-screen media card
still work; only the actual `aplay` stream hangs.

### 8.2 Root cause (high confidence)
- The only sound card is `alc5640-audio` (ALC5640 AIF1), bound to the
  **rt5640 codec at `i2c-0:0x1c`** and `imx-ssi.1`.
- At boot the codec I2C probe fails: `rt5640 0-001c: Failed to set private
  addr: -5` (EIO), and `i2c i2c-0: Failed to register i2c client rt5640 at
  0x1a (-16)`. This leaves the codec's I2C slave stuck (clock-stretching /
  mid-transaction).
- A healthy second codec `rt5645` at `i2c-0:0x1a` answers `i2cget` instantly;
  the stuck `rt5640` at `0x1c` does not.
- The hang is **inside `snd_pcm_open`** — the ASoC DAPM `Off -> STANDBY`
  transition that powers the codec up (the first codec I2C burst). A staged ALSA
  probe prints `STAGE: start` and never reaches `open-ok`, then the connection
  drops at ~60 s.
- The i.MX I2C driver busy-waits on the stuck bus, starving the single
  Cortex-A9 core until the WDT (timeout = exactly 60 s) fires.

### 8.3 i.MX6SL register map facts (for debugging)
- `PAGE_OFFSET = 0xC0000000`; device VA = `0xC0000000 + phys`.
- `i2c-0` (codec bus) phys `0x021A0000` (VA `0xC21A0000`); `i2c-1` (touch)
  `0x021A4000`; `i2c-2` (frontlight/PMIC) `0x021A8000`. IOMUXC at `0x020E0000`
  (VA `0xC20E0000`).
- The I2C1 (i2c-0) pads on this SL board: dedicated `PAD_I2C1_SCL` (mux_reg
  `0x15C`, I2C mux 0, GPIO alt `GPIO3_IO12` = Linux 76, mux 5) and
  `PAD_I2C1_SDA` (mux_reg `0x160`, I2C mux 0, GPIO alt `GPIO3_IO13` = Linux 77,
  mux 5).
- **Caveat:** on this kernel `/dev/kmem` gives an **aliased/cached view** of the
  peripheral region — a write is reflected in kmem read-back but not always in
  the real register (a GPIO data register written via kmem did not change the
  sysfs value). `/dev/mem` returns "Bad address" for peripherals because they
  sit below the RAM base (`0x80000000`) and fall in the /dev/mem "hole". Direct
  userspace register pokes are best-effort; reliable access needs kernel
  (ioremap) context. Debug helpers `regpeek`/`kmemwrite`/`alsaprobe` are in
  `/data/bin/` on the device.

### 8.4 Fix attempts (bounded, 3.0.35)
1. **I2C 9-clock + STOP bus recovery** via GPIO bit-bang: mux
   `PAD_I2C1_SCL/SDA` to their GPIO alts, drive 9 SCL clocks + a STOP, restore
   the mux. Result: `aplay` still hung. Given the kmem-aliasing caveat above the
   mux write may not have reached the real IOMUXC, so this attempt is
   inconclusive rather than dispositive.
2. **Codec re-probe:** `echo 0-001c > /sys/bus/i2c/drivers/rt5640/unbind` then
   `.../bind`. The sound card survives and the driver re-binds, but `aplay`
   still hangs — the stuck state persists across a re-probe.

### 8.5 Definitive fix
The long-term plan is the **4.1.15 kernel migration**, which reworks the board
file / codec probe / clock (audmux + CCM MCLK) setup and is expected to clear
the stuck codec. A reliable userspace I2C recovery on 3.0.35 would need a small
kernel module to do the mux change + bit-bang in ioremap context (deferred).
