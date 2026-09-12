# BNRV700 Standalone Linux User Guide

Welcome to your standalone Alpine Linux operating system on the **Barnes & Noble NOOK GlowLight Plus 7.8" (BNRV700)**. This guide covers day-to-day operation, navigation, reading, frontlight adjustments, audio playback, and synchronization.

---

## 1. Physical Hardware Controls & Quick Reference

The BNRV700 hardware buttons are unified across all reading, browsing, and media environments by the `/opt/bin/btn-watcher` supervisor daemon.

### 1.1 Quick Reference Cheat Sheet

| Gesture / Shortcut | Mode / App | Action | Description |
| :--- | :--- | :--- | :--- |
| **Power (Single Tap)** | Any | Sleep / Wake | Immediately suspends the device with current book cover. Resumes instantaneously. |
| **Power (Double Tap)** | Any | Frontlight Toggle | Toggles frontlight ON or OFF instantly without opening menus or redrawing the page. |
| **Home "n" (Single Tap)** | Reading | Library / Menu | Opens reader library view, file browser, or top navigation bar. |
| **Home "n" (Single Tap)** | NetSurf | Focus URL Bar & OSK | Focuses address bar and opens on-screen keyboard with URL preview. |
| **Home "n" (Single Tap)** | Media Mode | Play / Pause | Toggles music playback. |
| **Home "n" (Double Tap)** | Any | Audio Play / Pause | Toggles background music/playback from any app (shows the media card). |
| **Home "n" (Hold >=500ms)** | Reading | Frontlight Sliders | Pops up dual Brightness and Warmth (Amber color) slider dialog. |
| **Home + Top Left (191)** | Any | Switch to KOReader | Switches to KOReader. (If already in KOReader: triggers native Frontlight Dialog). |
| **Home + Bottom Left (192)**| Any | Switch to Plato | Switches to Plato. (If already in Plato: toggles Frontlight LEDs). |
| **Home + Top Right (193)** | Any | NetSurf Web Browser | Launches NetSurf. (If already in NetSurf: closes browser and returns to reading). |
| **Home + Bottom Right (194)**| Any | Media Player Mode | Toggles 5-button hardware media playback mode (foreground vs background). |
| **Magnetic Smart Cover** | Any | Cover Sleep / Wake | Closing folio cover sleeps device; opening wakes it up immediately. |

### 1.2 Side Bezel Buttons by Context

| Button | Reading Mode | NetSurf Browser Mode | Media Player Mode |
| :--- | :--- | :--- | :--- |
| **Top Left (191)** | Page Turn Back | **Page Up** (Scroll up) | **Previous Track** (`\|<<`) |
| **Bottom Left (192)** | Page Turn Forward | **Page Down** (Scroll down) | **Shuffle Toggle** (ON/OFF) |
| **Top Right (193)** | Page Turn Back | **Back / Dismiss OSK** | **Next Track** (`>>\|`) |
| **Bottom Right (194)** | Page Turn Forward | **Toggle OSK** | **Play / Pause** |


---

## 2. Reading Applications

You have two top-tier open-source reading engines installed side-by-side:

### 2.1 KOReader
- **Formats Supported**: EPUB, PDF, DJVU, MOBI, CBZ, FB2, TXT, HTML.
- **Key Features**: Reflowable PDF engine (K2pdfopt), dual-page mode, font fine-tuning, customizable tap zones, dictionary lookups, and rich plugin ecosystem.
- **Accessing Tools**: Tap the top bezel area to reveal the top navigation bar.

### 2.2 Plato
- **Formats Supported**: EPUB, PDF, CBZ.
- **Key Features**: Written in Rust for near-instant rendering and ultra-low latency page turns.
- **Frontlight Control**: Tapping the sun icon in the top system bar displays dual sliders for Intensity and Warmth.
- **Frontlight presets**: Pressing **Save** adds a preset named with the current time, such as `20:00`. Tap that time label later to restore the saved Intensity/Warmth values; remove unwanted presets from the same dialog.
- **Switching to Plato**:
  - Double-tap the physical **Home ("n")** button at any time.
  - OR inside KOReader: tap **Tools (Wrench/Cog icon) > Plato > Switch to Plato**.

### 2.3 Updating Plato from KOReader (Wi-Fi)

1. Turn Wi-Fi on in KOReader and wait until the device has connected.
2. Open **Tools > Plato > Update Plato (Latest Release)**.
3. Confirm the update and leave KOReader open while the download and installation finish. The updater downloads the current `plato-<version>.zip` asset from the official Plato GitHub release and installs it into `/opt/plato`.
4. When KOReader reports success, switch to Plato from **Tools > Plato > Switch to Plato**, or use the Plato hardware shortcut. Plato will start with your existing books, settings, and BNRV700 hardware support.

The update does not replace `Settings.toml` or the BNRV700 display/frontlight shim. Do not launch Plato while an update is in progress. If the update fails, check Wi-Fi and review `/tmp/plato_update.log`; the existing Plato installation remains in place until a complete archive has been downloaded and verified.

---

## 3. Audio & Text-to-Speech (TTS)

The BNRV700 features a **3.5mm Headphone Jack** powered by an internal Realtek ALC5640 hardware DAC:

### 3.1 Text-to-Speech (Read Aloud)
- KOReader includes the native **Read Aloud** plugin backed by **eSpeak-NG**.
- Highlight any paragraph in an EPUB/MOBI/FB2 book and select **Read Aloud**, or select continuous reading.
- Speech is synthesized on-the-fly with negligible CPU impact (~3-5% usage).

### 3.2 Integrated MP3 Audio Player
- Place your audiobooks and music files in `/sdcard/Music` or `/data/books`.
- Inside KOReader, navigate to **Tools > Audio Player** to start background playback while reading.

### 3.3 Bluetooth Audio & Keyboards
- The internal Realtek RTL8723DS Bluetooth 4.2 controller supports both **A2DP wireless headphones/speakers** and **Bluetooth HID keyboards**.
- Use the built-in terminal or `/opt/bt-manager.sh` to scan and pair devices:
  ```bash
  /opt/bt-manager.sh scan
  /opt/bt-manager.sh pair <MAC_ADDRESS>
  ```

---

## 4. File Transfer & Synchronization

### 4.1 USB MTP Connection (Plug-and-Play)
1. Connect the NOOK to your computer (Windows, macOS, or Linux) using a standard Micro-USB cable.
2. The device automatically enumerates as an MTP media device ("NOOK GlowLight Plus").
3. Drag and drop books directly into the `Books` folder or music into the `Music` folder.

### 4.2 Syncthing Background Note & Document Sync
- Syncthing runs silently in the background, keeping `/data/syncthing/notes/` in continuous sync with your computer or phone.
- Markdown notes created with the **Minfolio** plugin are immediately synced across all your devices over local Wi-Fi.
- To configure Syncthing from a computer on the same Wi-Fi network, open a web browser to:
  `http://<NOOK_IP_ADDRESS>:8384`

### 4.3 SSH Sideloading & Debugging
- Dropbear SSH runs on port 22 on all network interfaces:
  ```bash
  ssh root@<NOOK_IP_ADDRESS>
  ```
- No password is required by default.

---

## 5. Web Browsing (NetSurf)

The BNRV700 includes an optimized, standalone build of the **NetSurf Web Browser** with high-DPI scaling, full hardware button navigation, a direct framebuffer on-screen keyboard (OSK), and smartphone remote typing.

### 5.1 Launching NetSurf & E-Ink Optimizations
- **Hardware Shortcut**: Hold **Home ("n")** and press the **Top Right side button (193)**.
- **Within KOReader**: Tap **Tools (Cog icon) > NetSurf Browser > Launch NetSurf**.
- **Exit Browser**: Press the **Top Right side button (193)** (or Home+TR chord) to return to your book.
- **Zero-Ghosting Display Engine**: NetSurf automatically performs a full-screen hardware white wipe and a 16-level grayscale (GC16) E-ink flashing refresh upon launch and on page renders, completely eliminating afterimages and ghosting from the previous reader application.
- **High-Legibility URL Toolbar**: The top toolbar features a crisp, double-scaled (16x32 bold) address bar formatted specifically for the 300 DPI Carta panel so full URLs and search queries remain sharp and instantly readable.
- **Power Conservation**: Wi-Fi is automatically enabled upon launching NetSurf and restored to its previous state when closing the browser.

### 5.2 Physical Button Navigation
While browsing, the 4 side bezel buttons provide ergonomic one-handed navigation:

| Button | Function | Description |
| :--- | :--- | :--- |
| **Top Left (191)** | **Page Up** | Scrolls up one screen. |
| **Bottom Left (192)** | **Page Down** | Scrolls down one screen. |
| **Top Right (193)** | **Back / Dismiss OSK** | Goes back in history, or hides the keyboard if open. |
| **Bottom Right (194)** | **Toggle OSK** | Shows / hides the on-screen keyboard. |
| **Home Button (102)** | **Focus URL Bar & OSK** | Positions the cursor directly in the address bar and displays the keyboard. |

### 5.3 On-Screen Framebuffer Keyboard (OSK)
- **Direct Tap-to-Type**: Simply tap anywhere along the top **URL Bar** to automatically focus the address field and open the on-screen keyboard.
- **Hardware Trigger**: You can also press the **Bottom Right side button (194)** or the physical **Home ("n")** button at any time to toggle the OSK.
- **Interactive Input Preview**: The keyboard features a dedicated live input preview strip displaying the current address or search text, complete with **Clear** (erase entire line) and **Hide Kbd** shortcuts.
- **Multilingual Support**: Tap **EN / RU** to instantly toggle between English QWERTY and Russian ЙЦУКЕН layouts.
- **Symbol Mode**: Tap **?123** for numbers, punctuation, and web symbols (`/`, `.`, `:`, `-`, `@`, `_`, `?`).
- **Dismissing the Keyboard**: Tap anywhere on the page above the keyboard, press the **Top Right side button (193)**, or tap **Hide Kbd**. The keyboard restores the underlying web page bitmap cleanly with zero visual artifacts.
- **Tactile E-Ink Feedback**: Pressed keys invert in real-time with an instant localized E-ink regional refresh.

### 5.4 Remote Smartphone Keyboard & Controller (`nook-webkey`)
For typing long URLs, complex passwords, search queries, or form inputs, you can control the browser from your smartphone or computer over local Wi-Fi:

1. Ensure your phone and the NOOK are connected to the same Wi-Fi network.
2. Open a web browser on your phone and navigate to:
   ```text
   http://<NOOK_IP_ADDRESS>:8080
   ```
3. **Features**:
   - **Quick Navigation**: Instant buttons for URL Bar, History Back, Page Up, Page Down, and Toggle OSK.
   - **Open URL**: Type or paste any address on your phone and tap **Go to URL**.
   - **Instant Search**: Type search terms and tap **Search DuckDuckGo**.
   - **Live Phone Keyboard**: Tap the live input field to type into any focused text box on the NOOK screen using your phone's native keyboard, autocorrect, clipboard paste, and voice dictation.

---

## 6. System Updates & Diagnostics

### 6.1 Updating the Linux System (Self-Update)

The boot script (`/data/boot_linux.sh`) installs a new rootfs payload automatically
when one is staged on the device:

1. Copy `deploy_payload.tar.gz` **and** its checksum file `deploy_payload.tar.gz.sha256`
   to the device:
   - **MTP (easiest)**: connect via USB and drag both files to the NOOK's storage root
     (the same area that shows `Books`/`Music`).
   - **adb** (from this repository, while Android is running): `make deploy` and choose
     "Stage payload via Android /sdcard".
2. Reboot the device.
3. On the next Linux boot the boot script:
   - verifies the payload against the `.sha256` checksum (on a mismatch the payload is
     kept and the boot log records the mismatch - re-copy the files and reboot),
   - extracts it over `/data/linuxroot`,
   - records the version transition (`old -> new`) in `/data/boot_linux.log`,
   - removes the staged payload so it is applied exactly once.

Every payload carries a version marker at `/etc/bnrv700-release` (git description +
build time). `make device-check` and the boot log report it, so you can always confirm
which build is installed.

### 6.2 Battery Indicators

- **Boot splash**: a battery gauge (outline with proportional fill) is drawn under the
  title card while the panel wakes.
- **App switcher**: the dialog header shows the live fuel gauge, e.g.
  `BAT 87% DIS`, `BAT 100% FULL`, `BAT 54% CHG`.
- Inside KOReader, the reader's own status bar reports the battery as usual.

### 6.3 Smart Cover (Lid) Behavior

- **In KOReader**: the cover is handled by KOReader's native smart-cover support
  (sleep screen, wake on open).
- **In any other app (Plato, NetSurf, app switcher)**: closing the cover suspends the
  SoC to RAM. The e-ink panel keeps the last frame while the cover is closed, and the
  running app resumes in place when you open the cover.

### 6.4 Device Health Check (`make device-check`)

From this repository, with the device connected via USB (adb) and the Linux chroot
running:

```bash
make device-check
bash scripts/device_check.sh --glyph   # additionally verify rendered text on the panel
```

The suite verifies: the EPDC V1 full-frame update + completion wait (one visible panel
flash), framebuffer geometry (1404x1872 / 16bpp / 2816-byte stride), the touch and
virtual-key input nodes, the `btn-watcher` / `dropbear` / `syncthing` daemons,
frontlight write/read-back, battery sysfs, NetSurf dynamic linking, disk usage,
supervisor state files, and the installed rootfs version. Failing checks are printed
as `FAIL <name>`.
