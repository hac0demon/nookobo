# Unified Button Multiplexer & Supervisor Architecture

This document specifies the technical design, timing rules, and event routing implemented by `/opt/bin/btn-watcher` on the **BNRV700 (NOOK GlowLight Plus 7.8")**.

---

## 1. Problem Statement & Motivation

On stock e-readers, physical buttons often trigger competing actions between the reading engine and the operating system. Furthermore, different reader applications (such as KOReader and Plato) have differing internal event mapping formats and keycode requirements.

To achieve:
1. **Zero-Latency Navigation**: Single-tap actions must feel instantaneous.
2. **Ergonomic Frontlight Toggle**: Instant double-tap power toggle without menu interaction.
3. **Seamless Engine Swapping**: Instant double-tap home switching between KOReader and Plato.
4. **Physical Isolation**: Preventing raw keypresses from leaking into inactive apps.

The system places a dedicated supervisor daemon between the physical Linux input subsystem and the userspace reader processes using Linux `uinput`.

---

## 2. Event Multiplexer Architecture

```
[ Physical Keys: /dev/input/event0 ]
               │
               ▼  (Exclusive EVIOCGRAB)
    [ /opt/bin/btn-watcher ]
     │                  │
     │ Intercepts:      │ Forwards to uinput:
     │ - 2x Power Tap   │ - 1x Home Click (KEY_HOME)
     │ - Home + TL/BL   │ - 1x Power Click (KEY_POWER)
     │ - Home + TR/BR   │ - Page Turn Keys (F9 - F12) [in reading mode]
     │ - Media Controls │ - Magnetic Cover (SW_LID)
     ▼                  ▼
[ OS & Reader Chords ] [ Virtual uinput Device: /dev/input/event2 ]
- Home+TL: KOReader     │
- Home+BL: Plato        ├──> KOReader (listens to event2)
- Home+TR: NetSurf      └──> Plato (listens to event2 via by-path symlink)
- Home+BR: Media Mode
```

---

## 3. Timing Rules & State Machine

### 3.1 Hardware Chord Shortcuts (Hold Home + Press Side Button)
- **Home + Top Left (191)**:
  - If current reader is NOT KOReader: Switches instantly to KOReader.
  - If current reader IS ALREADY KOReader: Triggers native Frontlight Dialog (Warmth & Brightness sliders).
- **Home + Bottom Left (192)**:
  - If current reader is NOT Plato: Switches instantly to Plato.
  - If current reader IS ALREADY Plato: Toggles Frontlight LEDs.
- **Home + Top Right (193)**:
  - If current app is NOT NetSurf: Launches NetSurf Web Browser.
  - If current app IS ALREADY NetSurf: Closes browser and returns to reading.
- **Home + Bottom Right (194)**:
  - Toggles **Media Player Mode** (Foreground controls <-> Background playback).

### 3.2 Media Player Mode (5-Button Hardware Control)
When Media Player Mode is toggled to active:
- **Top Left (191)**: Previous Track (`|<<`)
- **Bottom Left (192)**: Shuffle Toggle (`ON / OFF`)
- **Top Right (193)**: Next Track (`>>|`)
- **Bottom Right (194)**: Play / Pause
- **Single Home (102)**: Play / Pause
- **Home + Bottom Right (194)**: Sends Media Player to background! (Music continues playing seamlessly, and side buttons immediately revert to page turns).

### 3.3 Power Button (`KEY_POWER` / Code 116)
- **Down Event**:
  - Checks if `(now - last_down_timestamp) <= 400ms`.
  - **If true (Double-Tap)**:
    - Cancels pending single-tap sleep.
    - Executes `/opt/scripts/toggle_frontlight.sh &`.
    - Restores or zeros PWM brightness on `/sys/class/backlight/mxc_msp430_fl.0/brightness` and `lm3630a_leda`.
  - **If false (First Tap)**:
    - Marks single-tap pending with a deadline of `now + 400ms`.
- **Timer Expiry**:
  - If 400ms passes without a second press:
    - Emits `KEY_POWER` click (press + release) to the virtual `uinput` device.
    - Active reader renders sleep cover, saves reading position, and triggers Linux suspend (`mem > /sys/power/state`).

### 3.4 Normal Reading Mode Home Button (`KEY_HOME` / Code 102)
  - Records `home_down_time = now`.
  - If a single-tap was pending release (`now - last_up_timestamp <= 350ms`):
    - **Double-Tap Detected**:
      - Cancels pending single-tap menu and sets `home_double_consumed = 1`.
      - Launches `/opt/bin/app-switcher` modal dialog universally (works across KOReader, Plato, NetSurf).
      - Suspends active reading engine (`killall -STOP`).
      - Saves screen framebuffer in RAM.
      - Displays instant UI with buttons for **KOReader**, **Plato Reader**, **NetSurf Web Browser**, **Background Music Controls** (Prev, Play/Pause, Next, Shuffle), **Frontlight Toggle**, and **Close / Keep Reading**.
- **Hold Timer (500ms)**:
  - If the Home button remains depressed for >= 500ms:
    - Emits held `KEY_HOME` press to `uinput`.
    - Reader's long-press handler activates the native frontlight adjustment dialog.
- **Up Event**:
  - If held >= 500ms: emits `KEY_HOME` release.
  - If released after double-tap: consumes event without triggering single-tap.
  - If released < 500ms: marks single-tap pending with deadline `now + 350ms`.
- **Timer Expiry**:
  - If 350ms passes without a second tap:
    - If `app-switcher` is currently visible (`/tmp/switcher_active` exists): closes it cleanly with `killall -q app-switcher` and restores background reading page with zero latency.
    - If `netsurf-fb` is running: closes it cleanly with `killall -TERM netsurf-fb`.
    - Otherwise: emits clean `KEY_HOME` click to `uinput` (navigates to Library / Menu).

### 3.3 Page Turn Keys (`KEY_F9` - `KEY_F12`)
- Top Left (`KEY_F10` = 192), Bottom Left (`KEY_F9` = 191).
- Top Right (`KEY_F11` = 193), Bottom Right (`KEY_F12` = 194).
- Forwarded immediately to `uinput` with zero debounce delay.

---

## 4. Frontlight Toggle Script (`/opt/scripts/toggle_frontlight.sh`)

When double-tap power fires, this script checks current illumination:
```bash
if [ "$CURRENT_MSP" -gt 0 ] || [ "$CURRENT_LEDA" -gt 0 ]; then
    # Light is ON -> Save level and turn OFF
    echo "$CURRENT_MSP $CURRENT_LEDA" > /tmp/frontlight_saved_level
    echo 0 > /sys/class/backlight/mxc_msp430_fl.0/brightness
    echo 0 > /sys/class/backlight/lm3630a_leda/brightness
else
    # Light is OFF -> Restore saved level
    RESTORE_MSP=$(cat /tmp/frontlight_saved_level | awk '{print $1}')
    echo "$RESTORE_MSP" > /sys/class/backlight/mxc_msp430_fl.0/brightness
fi
```
