/*
 * btn-watcher.c - Hardware Button Multiplexer & Chord Supervisor for BNRV700
 *
 * Intercepts /dev/input/event0 with exclusive EVIOCGRAB:
 *
 * 1. HARDWARE CHORD SHORTCUTS (Hold Home + Press Side Button):
 *    - Home + Top Left (191):     KOReader (if already in KOReader: Frontlight Dialog)
 *    - Home + Bottom Left (192):  Plato    (if already in Plato: Frontlight Toggle)
 *    - Home + Top Right (193):    NetSurf Web Browser (if in NetSurf: Return to Reader)
 *    - Home + Bottom Right (194): Toggle Media Player Mode (Foreground <-> Background)
 *
 * 2. MEDIA PLAYER MODE (When Active in Foreground):
 *    - Top Left (191):     Previous Track (|<<)
 *    - Bottom Left (192):  Shuffle Toggle
 *    - Top Right (193):    Next Track (>>|)
 *    - Bottom Right (194): Play / Pause
 *    - Single Home (102):  Play / Pause
 *    - Home + Bottom Right: Send Media Player to Background (returns buttons to reading)
 *    (Music continues playing seamlessly in the background while reading!)
 *
 * 3. NORMAL READING MODE:
 *    - Single Power Tap:   Emits virtual KEY_POWER (Sleep / Suspend)
 *    - Double Power Tap:   Instant Hardware Frontlight Toggle (<=400ms)
 *    - Single Home Tap:    Emits virtual KEY_HOME (Library / Top Menu)
 *    - Long Home Press:    Emits virtual KEY_HOME hold (>=500ms -> Frontlight dialog)
 *    - Side Page Keys:     Forwarded with zero latency to readers (191-194)
 *    - Lid Sensor (SW_LID): Forwarded with zero latency (Smart Cover Sleep/Wake)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <linux/fb.h>

#include "font8x16.h"

#define POWER_DOUBLE_CLICK_MS 400
#define HOME_LONG_PRESS_MS    500
#define HOME_SINGLE_CLICK_MS  250

#define FB_WIDTH        1404
#define FB_HEIGHT       1872
#define FB_STRIDE       1408
#define FB_SIZE_BYTES   (FB_STRIDE * FB_HEIGHT * 2)

#define TOAST_X 102
#define TOAST_Y 60
#define TOAST_W 1200
#define TOAST_H 160

#define CARD_X 102
#define CARD_Y 536
#define CARD_W 1200
#define CARD_H 800

#define MXCFB_SEND_UPDATE_V1 0x4040462e

struct mxcfb_rect {
    uint32_t top;
    uint32_t left;
    uint32_t width;
    uint32_t height;
};

struct mxcfb_alt_buffer_data_v1 {
    uint32_t phys_addr;
    uint32_t width;
    uint32_t height;
    struct mxcfb_rect alt_update_region;
};

struct mxcfb_update_data_v1 {
    struct mxcfb_rect update_region;
    uint32_t waveform_mode;
    uint32_t update_mode;
    uint32_t update_marker;
    int temp;
    unsigned int flags;
    struct mxcfb_alt_buffer_data_v1 alt_buffer_data;
};

static int fb_fd = -1;
static uint16_t *fb_mem = NULL;
static uint16_t *toast_backup = NULL;
static uint16_t *card_backup = NULL;
static int toast_active = 0;
static int card_active = 0;
static uint64_t toast_expire_time = 0;
static int media_mode = 0;

static uint64_t get_mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void fb_init(void) {
    if (fb_mem) return;
    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) fb_fd = open("/dev/graphics/fb0", O_RDWR);
    if (fb_fd >= 0) {
        fb_mem = (uint16_t *)mmap(NULL, FB_SIZE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
        if (fb_mem == MAP_FAILED) {
            fb_mem = NULL;
            close(fb_fd);
            fb_fd = -1;
        } else {
            toast_backup = malloc(TOAST_W * TOAST_H * sizeof(uint16_t));
            card_backup = malloc(CARD_W * CARD_H * sizeof(uint16_t));
        }
    }
}

static void epdc_refresh(int left, int top, int width, int height, int mode) {
    if (fb_fd < 0) return;
    struct mxcfb_update_data_v1 upd;
    memset(&upd, 0, sizeof(upd));
    upd.update_region.left = (left < 0) ? 0 : left;
    upd.update_region.top = (top < 0) ? 0 : top;
    upd.update_region.width = (width > FB_WIDTH) ? FB_WIDTH : width;
    upd.update_region.height = (height > FB_HEIGHT) ? FB_HEIGHT : height;
    upd.waveform_mode = mode; /* 1 = AUTO, 2 = GC16 */
    upd.update_mode = (mode == 2) ? 0 : 1; /* 0 = FULL, 1 = PARTIAL */
    upd.temp = 0x1001; /* TEMP_USE_AMBIENT */
    ioctl(fb_fd, MXCFB_SEND_UPDATE_V1, &upd);
}

static inline void set_pixel(int x, int y, uint16_t color) {
    if (fb_mem && x >= 0 && x < FB_WIDTH && y >= 0 && y < FB_HEIGHT) {
        fb_mem[y * FB_STRIDE + x] = color;
    }
}

static void draw_rect(int x, int y, int w, int h, uint16_t color) {
    if (!fb_mem) return;
    for (int cy = y; cy < y + h; cy++) {
        if (cy < 0 || cy >= FB_HEIGHT) continue;
        int row = cy * FB_STRIDE;
        for (int cx = x; cx < x + w; cx++) {
            if (cx >= 0 && cx < FB_WIDTH) {
                fb_mem[row + cx] = color;
            }
        }
    }
}

static void draw_rect_outline(int x, int y, int w, int h, int thickness, uint16_t color) {
    draw_rect(x, y, w, thickness, color);
    draw_rect(x, y + h - thickness, w, thickness, color);
    draw_rect(x, y, thickness, h, color);
    draw_rect(x + w - thickness, y, thickness, h, color);
}

static void draw_char(int x, int y, char ch, int scale, uint16_t fg, uint16_t bg) {
    if (ch < 32 || ch > 126) ch = ' ';
    const uint8_t *glyph = font8x16[ch - 32];
    for (int row = 0; row < 16; row++) {
        uint8_t line = glyph[row];
        for (int col = 0; col < 8; col++) {
            uint16_t color = (line & (1 << (7 - col))) ? fg : bg;
            if (scale == 1) {
                if (color != bg || bg != 0) set_pixel(x + col, y + row, color);
            } else {
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        set_pixel(x + col * scale + sx, y + row * scale + sy, color);
                    }
                }
            }
        }
    }
}

static void draw_string(int x, int y, const char *str, int scale, uint16_t fg, uint16_t bg) {
    int cx = x;
    while (*str) {
        draw_char(cx, y, *str, scale, fg, bg);
        cx += 8 * scale;
        str++;
    }
}

static void draw_string_centered(int box_x, int box_y, int box_w, int box_h, const char *str, int scale, uint16_t fg, uint16_t bg) {
    int len = strlen(str);
    int str_w = len * 8 * scale;
    int str_h = 16 * scale;
    int cx = box_x + (box_w - str_w) / 2;
    int cy = box_y + (box_h - str_h) / 2;
    draw_string(cx, cy, str, scale, fg, bg);
}

static void hide_toast(void) {
    if (!toast_active || !fb_mem || !toast_backup) return;
    for (int y = 0; y < TOAST_H; y++) {
        memcpy(&fb_mem[(TOAST_Y + y) * FB_STRIDE + TOAST_X],
               &toast_backup[y * TOAST_W], TOAST_W * sizeof(uint16_t));
    }
    epdc_refresh(TOAST_X, TOAST_Y, TOAST_W, TOAST_H, 1);
    toast_active = 0;
}

static void show_toast(const char *title, const char *subtitle, uint64_t now) {
    fb_init();
    if (!fb_mem) return;

    if (!toast_active) {
        if (toast_backup) {
            for (int y = 0; y < TOAST_H; y++) {
                memcpy(&toast_backup[y * TOAST_W],
                       &fb_mem[(TOAST_Y + y) * FB_STRIDE + TOAST_X], TOAST_W * sizeof(uint16_t));
            }
        }
        toast_active = 1;
    }

    draw_rect(TOAST_X, TOAST_Y, TOAST_W, TOAST_H, 0x0000); /* solid black */
    draw_rect_outline(TOAST_X, TOAST_Y, TOAST_W, TOAST_H, 4, 0xFFFF); /* white border */

    if (subtitle && subtitle[0]) {
        draw_string_centered(TOAST_X, TOAST_Y + 25, TOAST_W, 55, title, 3, 0xFFFF, 0x0000);
        draw_string_centered(TOAST_X, TOAST_Y + 95, TOAST_W, 40, subtitle, 2, 0xDEFB, 0x0000);
    } else {
        draw_string_centered(TOAST_X, TOAST_Y, TOAST_W, TOAST_H, title, 3, 0xFFFF, 0x0000);
    }

    epdc_refresh(TOAST_X, TOAST_Y, TOAST_W, TOAST_H, 1);
    toast_expire_time = now + 2200;
}

static void hide_media_card(void) {
    if (!card_active || !fb_mem || !card_backup) return;
    for (int y = 0; y < CARD_H; y++) {
        memcpy(&fb_mem[(CARD_Y + y) * FB_STRIDE + CARD_X],
               &card_backup[y * CARD_W], CARD_W * sizeof(uint16_t));
    }
    epdc_refresh(CARD_X, CARD_Y, CARD_W, CARD_H, 2); /* GC16 refresh */
    card_active = 0;
}

static void show_media_card(const char *status) {
    fb_init();
    if (!fb_mem) return;

    if (!card_active) {
        if (card_backup) {
            for (int y = 0; y < CARD_H; y++) {
                memcpy(&card_backup[y * CARD_W],
                       &fb_mem[(CARD_Y + y) * FB_STRIDE + CARD_X], CARD_W * sizeof(uint16_t));
            }
        }
        card_active = 1;
    }

    /* 1. Base card: crisp solid white with double high-contrast black border */
    draw_rect(CARD_X, CARD_Y, CARD_W, CARD_H, 0xFFFF);
    draw_rect_outline(CARD_X, CARD_Y, CARD_W, CARD_H, 6, 0x0000);
    draw_rect_outline(CARD_X + 10, CARD_Y + 10, CARD_W - 20, CARD_H - 20, 2, 0x0000);

    /* 2. Top Header banner */
    draw_rect(CARD_X + 14, CARD_Y + 14, CARD_W - 28, 125, 0x0000);
    draw_string_centered(CARD_X + 14, CARD_Y + 26, CARD_W - 28, 50, "MEDIA PLAYER CONTROLS", 3, 0xFFFF, 0x0000);
    draw_string_centered(CARD_X + 14, CARD_Y + 84, CARD_W - 28, 36, status ? status : "PLAYBACK ACTIVE", 2, 0xFFFF, 0x0000);

    /* 3. 4 Physical Button Quadrants */
    int col_w = 560;
    int row_h = 195;
    int col1_x = CARD_X + 25;
    int col2_x = CARD_X + 615;
    int row1_y = CARD_Y + 160;
    int row2_y = CARD_Y + 375;

    /* Top Left: F9 */
    draw_rect(col1_x, row1_y, col_w, row_h, 0xFFFF);
    draw_rect_outline(col1_x, row1_y, col_w, row_h, 3, 0x0000);
    draw_string_centered(col1_x, row1_y + 35, col_w, 35, "[ TOP-LEFT BUTTON (F9) ]", 2, 0x0000, 0xFFFF);
    draw_string_centered(col1_x, row1_y + 95, col_w, 55, "|<< PREV TRACK", 3, 0x0000, 0xFFFF);

    /* Top Right: F11 */
    draw_rect(col2_x, row1_y, col_w, row_h, 0xFFFF);
    draw_rect_outline(col2_x, row1_y, col_w, row_h, 3, 0x0000);
    draw_string_centered(col2_x, row1_y + 35, col_w, 35, "[ TOP-RIGHT BUTTON (F11) ]", 2, 0x0000, 0xFFFF);
    draw_string_centered(col2_x, row1_y + 95, col_w, 55, "NEXT TRACK >>|", 3, 0x0000, 0xFFFF);

    /* Bottom Left: F10 */
    draw_rect(col1_x, row2_y, col_w, row_h, 0xFFFF);
    draw_rect_outline(col1_x, row2_y, col_w, row_h, 3, 0x0000);
    draw_string_centered(col1_x, row2_y + 35, col_w, 35, "[ BOTTOM-LEFT BUTTON (F10) ]", 2, 0x0000, 0xFFFF);
    draw_string_centered(col1_x, row2_y + 95, col_w, 55, "SHUFFLE ON / OFF", 3, 0x0000, 0xFFFF);

    /* Bottom Right: F12 */
    draw_rect(col2_x, row2_y, col_w, row_h, 0xFFFF);
    draw_rect_outline(col2_x, row2_y, col_w, row_h, 3, 0x0000);
    draw_string_centered(col2_x, row2_y + 35, col_w, 35, "[ BOTTOM-RIGHT BUTTON (F12) ]", 2, 0x0000, 0xFFFF);
    draw_string_centered(col2_x, row2_y + 95, col_w, 55, ">|| PLAY / PAUSE", 3, 0x0000, 0xFFFF);

    /* 4. Footer Instructions */
    draw_rect(CARD_X + 25, CARD_Y + 585, CARD_W - 50, 3, 0x0000);
    draw_string_centered(CARD_X, CARD_Y + 605, CARD_W, 35, "HOME BUTTON:  >|| PLAY / PAUSE", 2, 0x0000, 0xFFFF);
    draw_string_centered(CARD_X, CARD_Y + 655, CARD_W, 35, "HOLD HOME + BOTTOM-RIGHT:  RETURN TO READING", 2, 0x0000, 0xFFFF);
    draw_string_centered(CARD_X, CARD_Y + 705, CARD_W, 35, "(Music continues playing seamlessly in background)", 2, 0x0000, 0xFFFF);

    epdc_refresh(CARD_X, CARD_Y, CARD_W, CARD_H, 1);
}

static void inject_plato_frontlight(void) {
    int tfd = open("/dev/input/event1", O_WRONLY);
    if (tfd < 0) return;

    struct input_event evs[6];
    memset(evs, 0, sizeof(evs));

    /* First tap: unhides bars in reader mode or opens frontlight dialog directly */
    evs[0].type = EV_ABS; evs[0].code = 57;  evs[0].value = 1;   /* TRACKING_ID */
    evs[1].type = EV_ABS; evs[1].code = 53;  evs[1].value = 35;  /* X */
    evs[2].type = EV_ABS; evs[2].code = 54;  evs[2].value = 180; /* Y */
    evs[3].type = EV_KEY; evs[3].code = 330; evs[3].value = 1;   /* BTN_TOUCH down */
    evs[4].type = EV_SYN; evs[4].code = 0;   evs[4].value = 0;   /* SYN_REPORT */
    write(tfd, evs, 5 * sizeof(struct input_event));
    usleep(40000);

    evs[0].type = EV_ABS; evs[0].code = 57;  evs[0].value = -1;  /* TRACKING_ID lift */
    evs[1].type = EV_KEY; evs[1].code = 330; evs[1].value = 0;   /* BTN_TOUCH up */
    evs[2].type = EV_SYN; evs[2].code = 0;   evs[2].value = 0;
    write(tfd, evs, 3 * sizeof(struct input_event));

    /* Second tap after 180ms: taps the sun icon if bars were previously hidden */
    usleep(180000);
    evs[0].type = EV_ABS; evs[0].code = 57;  evs[0].value = 1;
    evs[1].type = EV_ABS; evs[1].code = 53;  evs[1].value = 35;
    evs[2].type = EV_ABS; evs[2].code = 54;  evs[2].value = 180;
    evs[3].type = EV_KEY; evs[3].code = 330; evs[3].value = 1;
    evs[4].type = EV_SYN; evs[4].code = 0;   evs[4].value = 0;
    write(tfd, evs, 5 * sizeof(struct input_event));
    usleep(40000);

    evs[0].type = EV_ABS; evs[0].code = 57;  evs[0].value = -1;
    evs[1].type = EV_KEY; evs[1].code = 330; evs[1].value = 0;
    evs[2].type = EV_SYN; evs[2].code = 0;   evs[2].value = 0;
    write(tfd, evs, 3 * sizeof(struct input_event));

    close(tfd);
}

static void emit_event(int ufd, uint16_t type, uint16_t code, int32_t val) {
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    struct timeval tv;
    gettimeofday(&tv, NULL);
    ev.input_event_sec = tv.tv_sec;
    ev.input_event_usec = tv.tv_usec;
    ev.type = type;
    ev.code = code;
    ev.value = val;
    write(ufd, &ev, sizeof(ev));
}

static void emit_syn(int ufd) {
    emit_event(ufd, EV_SYN, SYN_REPORT, 0);
}

static void emit_key_click(int ufd, uint16_t code) {
    emit_event(ufd, EV_KEY, code, 1);
    emit_syn(ufd);
    usleep(20000);
    emit_event(ufd, EV_KEY, code, 0);
    emit_syn(ufd);
}

static void get_active_app(char *buf, size_t len) {
    memset(buf, 0, len);
    FILE *f = fopen("/tmp/current_app", "r");
    if (!f) f = fopen("/tmp/active_reader", "r");
    if (f) {
        if (fgets(buf, len, f)) {
            buf[strcspn(buf, "\r\n")] = 0;
        }
        fclose(f);
    }
    if (buf[0] == '\0') {
        strncpy(buf, "koreader", len - 1);
    }
}

static void set_active_app(const char *name) {
    FILE *f = fopen("/tmp/current_app", "w");
    if (f) { fprintf(f, "%s\n", name); fclose(f); }
    f = fopen("/tmp/active_reader", "w");
    if (f) { fprintf(f, "%s\n", name); fclose(f); }
}

int main(int argc, char **argv) {
    setlinebuf(stdout);
    setlinebuf(stderr);

    const char *evdev_path = "/dev/input/event0";
    if (argc > 1) {
        evdev_path = argv[1];
    }

    int ev_fd = open(evdev_path, O_RDONLY);
    if (ev_fd < 0) {
        fprintf(stderr, "Failed to open %s: %s\n", evdev_path, strerror(errno));
        return 1;
    }

    /* Grab physical hardware event node */
    if (ioctl(ev_fd, EVIOCGRAB, 1) < 0) {
        fprintf(stderr, "Warning: EVIOCGRAB failed: %s\n", strerror(errno));
    }

    /* Create virtual uinput device */
    int ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) {
        ufd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK);
    }
    if (ufd < 0) {
        fprintf(stderr, "Failed to open uinput: %s\n", strerror(errno));
        close(ev_fd);
        return 1;
    }

    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    ioctl(ufd, UI_SET_EVBIT, EV_SW);
    ioctl(ufd, UI_SET_EVBIT, EV_SYN);

    ioctl(ufd, UI_SET_KEYBIT, KEY_POWER);
    ioctl(ufd, UI_SET_KEYBIT, KEY_HOME);
    ioctl(ufd, UI_SET_KEYBIT, 191); /* KEY_F9 */
    ioctl(ufd, UI_SET_KEYBIT, 192); /* KEY_F10 */
    ioctl(ufd, UI_SET_KEYBIT, 193); /* KEY_F11 */
    ioctl(ufd, UI_SET_KEYBIT, 194); /* KEY_F12 */
    ioctl(ufd, UI_SET_SWBIT, 0);    /* SW_LID */

    struct uinput_user_dev uidev;
    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "nook-virtual-keys");
    uidev.id.bustype = BUS_VIRTUAL;
    uidev.id.vendor  = 0x0001;
    uidev.id.product = 0x0001;
    uidev.id.version = 1;

    if (write(ufd, &uidev, sizeof(uidev)) < 0 || ioctl(ufd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "Failed to create uinput device: %s\n", strerror(errno));
        close(ufd);
        close(ev_fd);
        return 1;
    }

    printf("[btn-watcher] Initialized: grabbed %s, uinput created.\n", evdev_path);
    printf("[btn-watcher] Chords: Home+TL: KOReader, Home+BL: Plato, Home+TR: NetSurf, Home+BR: Media Mode\n");
    fflush(stdout);

    /* Update symlinks and permissions so readers find virtual keys immediately */
    system("for f in /sys/class/input/event*/device/name; do "
           "  if [ \"$(cat $f 2>/dev/null)\" = \"nook-virtual-keys\" ]; then "
           "    EV=$(basename $(dirname $(dirname $f))); "
           "    mkdir -p /dev/input/by-path; "
           "    ln -sfn /dev/input/$EV /dev/input/by-path/platform-gpio-keys-event; "
           "    if [ \"$EV\" != \"event2\" ] && [ ! -c /dev/input/event2 ]; then "
           "      ln -sfn /dev/input/$EV /dev/input/event2 2>/dev/null || true; "
           "    fi; "
           "    chmod 666 /dev/input/$EV; "
           "    break; "
           "  fi; "
           "done");


    /* State variables */
    int power_pending = 0;
    uint64_t power_down_time = 0;

    int home_down = 0;
    int home_combo_consumed = 0;
    int home_pending_single = 0;
    int home_long_sent = 0;
    uint64_t home_down_time = 0;
    uint64_t home_single_time = 0;
    int home_double_consumed = 0;

    while (1) {
        uint64_t now = get_mono_ms();
        int timeout_ms = 1000;

        /* Toast expiration check */
        if (toast_active) {
            int rem = (int)(toast_expire_time - now);
            if (rem <= 0) {
                hide_toast();
            } else if (rem < timeout_ms) {
                timeout_ms = rem;
            }
        }

        /* Power button single tap timeout */
        if (power_pending) {
            int rem = (int)(power_down_time + POWER_DOUBLE_CLICK_MS - now);
            if (rem <= 0) {
                printf("[btn-watcher] Power single tap confirmed -> sleeping/suspending\n");
                emit_key_click(ufd, KEY_POWER);
                power_pending = 0;
            } else if (rem < timeout_ms) {
                timeout_ms = rem;
            }
        }

        /* Home button long press check (only if not in a chord) */
        if (home_down && !home_combo_consumed && !home_long_sent) {
            int rem = (int)(home_down_time + HOME_LONG_PRESS_MS - now);
            if (rem <= 0) {
                printf("[btn-watcher] Home long press detected -> emitting KEY_HOME down\n");
                emit_event(ufd, EV_KEY, KEY_HOME, 1);
                emit_syn(ufd);
                home_long_sent = 1;
                home_pending_single = 0;
            } else if (rem < timeout_ms) {
                timeout_ms = rem;
            }
        }

        /* Home button single tap emission, confirmed after the double-tap window */
        if (home_pending_single) {
            int rem = (int)(home_single_time + POWER_DOUBLE_CLICK_MS - now);
            if (rem <= 0) {
                printf("[btn-watcher] Home single tap confirmed -> Library/Menu\n");
                emit_key_click(ufd, KEY_HOME);
                home_pending_single = 0;
            } else if (rem < timeout_ms) {
                timeout_ms = rem;
            }
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(ev_fd, &rfds);

        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;

        int ret = select(ev_fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (ret == 0) {
            continue;
        }

        struct input_event ev;
        ssize_t n = read(ev_fd, &ev, sizeof(ev));
        if (n != (ssize_t)sizeof(ev)) {
            continue;
        }

        now = get_mono_ms();

        if (ev.type == EV_KEY && ev.code == KEY_POWER) {
            if (ev.value == 1) { /* Down */
                if (power_pending && (now - power_down_time <= POWER_DOUBLE_CLICK_MS)) {
                    printf("[btn-watcher] Double Power tap detected -> Toggling frontlight\n");
                    power_pending = 0;
                    system("/opt/scripts/toggle_frontlight.sh &");
                } else {
                    power_pending = 1;
                    power_down_time = now;
                }
            }
        } else if (ev.type == EV_KEY && ev.code == KEY_HOME) {
            if (ev.value == 1) { /* Down */
                /* Home double tap: second press inside the double-click window
                 * toggles background audio playback in any app */
                if (home_pending_single && !home_double_consumed &&
                    (now - home_single_time <= POWER_DOUBLE_CLICK_MS)) {
                    printf("[btn-watcher] Home double tap detected -> audio play/pause toggle\n");
                    home_pending_single = 0;
                    home_double_consumed = 1;
                    system("/opt/audiocontrol.sh pause 2>/dev/null &");
                    show_media_card("PLAYBACK: PLAY / PAUSE TOGGLED  >||");
                }
                home_down = 1;
                home_down_time = now;
                home_combo_consumed = 0;
                home_long_sent = 0;
                home_pending_single = 0;
            } else if (ev.value == 0) { /* Up */
                home_down = 0;
                if (home_combo_consumed) {
                    /* Combo was triggered while Home was held -> ignore release */
                    home_combo_consumed = 0;
                } else if (home_long_sent) {
                    /* Release virtual long press */
                    printf("[btn-watcher] Home long press released\n");
                    emit_event(ufd, EV_KEY, KEY_HOME, 0);
                    emit_syn(ufd);
                    home_long_sent = 0;
                } else if (home_double_consumed) {
                    /* Release of the second press of a double tap: do not
                     * re-arm the pending single tap */
                    home_double_consumed = 0;
                } else {
                    /* If in media mode, single Home tap toggles Play/Pause */
                    if (media_mode) {
                        printf("[btn-watcher] Home tap in Media Mode -> Play/Pause\n");
                        system("/opt/audiocontrol.sh pause 2>/dev/null &");
                        show_media_card("PLAYBACK: PLAY / PAUSE TOGGLED  >||");
                    } else {
                        /* Normal reading: confirmed single Home tap */
                        home_pending_single = 1;
                        home_single_time = now;
                    }
                }
            }
        } else if (ev.type == EV_KEY && (ev.code >= 191 && ev.code <= 194)) {
            /* Page Buttons: F9(191)=TopLeft, F10(192)=BotLeft, F11(193)=TopRight, F12(194)=BotRight */
            if (ev.value == 1) { /* Down */
                if (home_down) {
                    /* === HARDWARE CHORD SHORTCUT TRIGGERED === */
                    home_combo_consumed = 1;
                    home_pending_single = 0;

                    if (ev.code == 191) {
                        /* Home + Top Left -> KOReader */
                        if (media_mode) { hide_media_card(); media_mode = 0; }
                        char curr[32];
                        get_active_app(curr, sizeof(curr));
                        if (strcmp(curr, "koreader") == 0) {
                            printf("[btn-watcher] Chord Home+Top-Left in KOReader -> Frontlight Dialog\n");
                            show_toast("FRONTLIGHT DIALOG", "KOReader Warmth & Brightness", now);
                            /* Emit 550ms KEY_HOME hold to trigger KOReader light dialog */
                            emit_event(ufd, EV_KEY, KEY_HOME, 1);
                            emit_syn(ufd);
                            usleep(550000);
                            emit_event(ufd, EV_KEY, KEY_HOME, 0);
                            emit_syn(ufd);
                            home_combo_consumed = 0;
                        } else {
                            printf("[btn-watcher] Chord Home+Top-Left -> Switching to KOReader\n");
                            show_toast("SWITCHING TO KOREADER...", "Document & Book Reader", now);
                            set_active_app("koreader");
                            system("killall -9 ld-2.19.so plato netsurf-fb 2>/dev/null || true");
                        }

                    } else if (ev.code == 192) {
                        /* Home + Bottom Left -> Plato */
                        if (media_mode) { hide_media_card(); media_mode = 0; }
                        char curr[32];
                        get_active_app(curr, sizeof(curr));
                        if (strcmp(curr, "plato") == 0) {
                            printf("[btn-watcher] Chord Home+Bottom-Left in Plato -> Frontlight Dialog\n");
                            show_toast("FRONTLIGHT DIALOG", "Opening Plato Warmth & Brightness", now);
                            inject_plato_frontlight();
                        } else {
                            printf("[btn-watcher] Chord Home+Bottom-Left -> Switching to Plato\n");
                            show_toast("SWITCHING TO PLATO...", "Fast Touch-Driven Rust Reader", now);
                            set_active_app("plato");
                            system("killall -9 luajit netsurf-fb 2>/dev/null || true");
                        }

                    } else if (ev.code == 193) {
                        /* Home + Top Right -> NetSurf */
                        if (media_mode) { hide_media_card(); media_mode = 0; }
                        char curr[32];
                        get_active_app(curr, sizeof(curr));
                        if (strcmp(curr, "netsurf") == 0) {
                            printf("[btn-watcher] Chord Home+Top-Right in NetSurf -> Returning to Reader\n");
                            show_toast("CLOSING NETSURF...", "Returning to Document Reader", now);
                            set_active_app("koreader");
                            system("killall -9 netsurf-fb 2>/dev/null || true");
                        } else {
                            printf("[btn-watcher] Chord Home+Top-Right -> Launching NetSurf\n");
                            show_toast("LAUNCHING NETSURF...", "E-Ink Optimized Web Browser", now);
                            set_active_app("netsurf");
                            system("killall -9 luajit ld-2.19.so plato 2>/dev/null || true");
                        }

                    } else if (ev.code == 194) {
                        /* Home + Bottom Right -> Toggle Media Player Mode */
                        media_mode = !media_mode;
                        if (media_mode) {
                            printf("[btn-watcher] Chord Home+Bottom-Right -> Media Mode ACTIVE\n");
                            show_media_card("PLAYBACK ACTIVE: CONTROLS READY");
                        } else {
                            printf("[btn-watcher] Chord Home+Bottom-Right -> Media Mode BACKGROUND\n");
                            hide_media_card();
                            show_toast("READING MODE RESTORED",
                                       "Audio running in background (Side buttons = Page turns)", now);
                        }
                    }
                } else if (media_mode) {
                    /* === 5-BUTTON MEDIA PLAYER CONTROLS === */
                    if (ev.code == 191) {
                        /* Top Left: Prev Track */
                        printf("[btn-watcher] Media Mode: Prev Track\n");
                        system("/opt/audiocontrol.sh prev 2>/dev/null &");
                        show_media_card("TRACK SKIPPED: PREVIOUS  |<<");
                    } else if (ev.code == 192) {
                        /* Bottom Left: Shuffle Toggle */
                        printf("[btn-watcher] Media Mode: Shuffle Toggle\n");
                        system("/opt/audiocontrol.sh shuffle 2>/dev/null &");
                        show_media_card("PLAYLIST: SHUFFLE TOGGLED");
                    } else if (ev.code == 193) {
                        /* Top Right: Next Track */
                        printf("[btn-watcher] Media Mode: Next Track\n");
                        system("/opt/audiocontrol.sh next 2>/dev/null &");
                        show_media_card("TRACK SKIPPED: NEXT  >>|");
                    } else if (ev.code == 194) {
                        /* Bottom Right: Play / Pause */
                        printf("[btn-watcher] Media Mode: Play/Pause\n");
                        system("/opt/audiocontrol.sh pause 2>/dev/null &");
                        show_media_card("PLAYBACK: PLAY / PAUSE TOGGLED  >||");
                    }
                } else {
                    /* Normal Reading: Forward page key press to active reader */
                    emit_event(ufd, ev.type, ev.code, ev.value);
                }
            } else if (ev.value == 0) { /* Up */
                if (home_combo_consumed || media_mode) {
                    /* Consume key release during combo or media mode */
                } else {
                    emit_event(ufd, ev.type, ev.code, ev.value);
                }
            }
        } else if (ev.type == EV_SW && ev.code == 0) { /* SW_LID */
            if (ev.value == 1) {
                /* Cover closed. KOReader consumes the passthrough event and
                 * draws its own sleep cover; for any other active app,
                 * suspend the SoC directly - the e-ink panel retains the
                 * last frame until the cover opens. */
                char app[32];
                get_active_app(app, sizeof(app));
                if (strcmp(app, "koreader") != 0) {
                    printf("[btn-watcher] Lid closed -> suspending (active=%s)\n", app);
                    fflush(stdout);
                    system("echo mem > /sys/power/state 2>/dev/null");
                    printf("[btn-watcher] Lid open -> resumed\n");
                }
            }
            /* Pass through so KOReader's smart cover still sees the event. */
            emit_event(ufd, ev.type, ev.code, ev.value);
        } else if (ev.type == EV_SW || ev.type == EV_SYN) {
            /* Pass through other switch events and EV_SYN */
            emit_event(ufd, ev.type, ev.code, ev.value);
        }
    }

    ioctl(ev_fd, EVIOCGRAB, 0);
    ioctl(ufd, UI_DEV_DESTROY);
    close(ufd);
    close(ev_fd);
    if (fb_mem) munmap(fb_mem, FB_SIZE_BYTES);
    if (fb_fd >= 0) close(fb_fd);
    if (toast_backup) free(toast_backup);
    if (card_backup) free(card_backup);
    return 0;
}
