# BNRV700 Standalone Linux User Guide

Welcome to your standalone Alpine Linux operating system on the **Barnes & Noble NOOK GlowLight Plus 7.8" (BNRV700)**. This guide covers day-to-day operation, navigation, reading, frontlight adjustments, audio playback, and synchronization.

---

## 1. Physical Hardware Controls

The BNRV700 hardware buttons have been unified across both reading environments (KOReader and Plato):

| Button Gesture | Action | Description |
| :--- | :--- | :--- |
| **Power Button (Single Tap)** | Sleep / Wake | Immediately suspends the device. The screen displays the cover of the book currently being read. Tapping again resumes instantaneously. |
| **Power Button (Double Tap)** | Frontlight Toggle | Toggles the frontlight completely ON or OFF instantly without opening any menus or redrawing the page. |
| **Home "n" (Single Tap)** | Library / Top Menu | Opens the reader's file browser, library view, or top navigation bar. |
| **Home "n" (Double Tap)** | Switch Reader | Instantly switches between **KOReader** and **Plato** in ~1.5 seconds, restoring the last opened book. |
| **Home "n" (Hold >=500ms)** | Frontlight Slider Dialog | Opens the full dual-slider dialog for overall Brightness and Warmth (Amber color temperature). |
| **Side Bezel Buttons (F9 - F12)**| Page Turn Forward/Back | The top buttons turn one page backward; the bottom buttons turn one page forward. |
| **Magnetic Smart Cover** | Cover Sleep / Wake | Closing a magnetic folio cover automatically puts the reader to sleep; opening it wakes the device. |

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
- **Switching to Plato**:
  - Double-tap the physical **Home ("n")** button at any time.
  - OR inside KOReader: tap **Tools (Wrench/Cog icon) > Plato > Switch to Plato**.

### 2.3 Updating Plato via Wi-Fi (OTA)
1. Turn on Wi-Fi inside KOReader or via the top menu.
2. Tap **Tools > Plato > Update Plato (Latest Release)**.
3. Confirm the dialog. KOReader will download the latest binary from GitHub, unpack it into `/opt/plato`, and notify you upon completion.

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
