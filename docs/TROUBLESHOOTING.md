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
3. Ensure that `/opt/koreader/patches/1-bnrv700-hardware.lua` exists and matches `configs/1-bnrv700-hardware.lua`.

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
