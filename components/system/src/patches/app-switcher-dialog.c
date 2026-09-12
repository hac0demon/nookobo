/*
 * app-switcher.c - Standalone High-Performance E-Ink Application Switcher & Quick Launch
 * BNRV700 (NOOK GlowLight Plus 7.8" / Quill)
 *
 * Provides instant modal app switching between KOReader, Plato, NetSurf, and
 * background music playback controls on double-tap of the capacitive Home button.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <linux/input.h>
#include <linux/fb.h>

#include "font8x16.h"

#define FB_WIDTH        1404
#define FB_HEIGHT       1872
#define FB_STRIDE       1408
#define FB_SIZE_BYTES   (FB_STRIDE * FB_HEIGHT * 2)

#define COLOR_WHITE     0xFFFF
#define COLOR_BLACK     0x0000
#define COLOR_GRAY_LT   0xDEFB
#define COLOR_GRAY_MD   0x9CF3
#define COLOR_GRAY_DK   0x4208

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

/* Dialog bounding box (centered on 1404x1872) */
#define DLG_X 132
#define DLG_Y 200
#define DLG_W 1140
#define DLG_H 1470

static uint16_t *fb_mem = NULL;
static uint16_t *backup_mem = NULL;
static int fb_fd = -1;
static volatile sig_atomic_t g_running = 1;

static char active_app[32] = "koreader";

struct Button {
    int id;
    int x;
    int y;
    int w;
    int h;
    const char *text;
    const char *subtext;
    bool is_primary;
};

enum ButtonID {
    BTN_KOREADER = 1,
    BTN_PLATO,
    BTN_NETSURF,
    BTN_MUSIC_PREV,
    BTN_MUSIC_PLAY,
    BTN_MUSIC_NEXT,
    BTN_MUSIC_SHUFFLE,
    BTN_FRONTLIGHT,
    BTN_CLOSE,
    BTN_COUNT
};

static struct Button buttons[] = {
    { BTN_KOREADER,       202, 360,  1000, 120, "KOReader", "PDF, EPUB, MOBI Document Viewer", false },
    { BTN_PLATO,          202, 500,  1000, 120, "Plato Reader", "Fast Touch-Driven Rust Reader", false },
    { BTN_NETSURF,        202, 640,  1000, 120, "NetSurf Web Browser", "Lightweight Web Browsing", false },
    { BTN_MUSIC_PREV,     202, 980,  230,  100, "|<< Prev", "", false },
    { BTN_MUSIC_PLAY,     452, 980,  270,  100, "Play / Pause", "", true },
    { BTN_MUSIC_NEXT,     742, 980,  230,  100, "Next >>|", "", false },
    { BTN_MUSIC_SHUFFLE,  992, 980,  210,  100, "Shuffle", "", false },
    { BTN_FRONTLIGHT,     202, 1160, 1000, 110, "Toggle Frontlight (Cool/Warm)", "Switch Frontlight On / Off", false },
    { BTN_CLOSE,          202, 1290, 1000, 110, "Close / Keep Reading", "Resume current book or page", true },
};

#define NUM_BUTTONS (sizeof(buttons) / sizeof(buttons[0]))

static void handle_sigterm(int sig) {
    (void)sig;
    g_running = 0;
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
    if (x >= 0 && x < FB_WIDTH && y >= 0 && y < FB_HEIGHT) {
        fb_mem[y * FB_STRIDE + x] = color;
    }
}

static void draw_rect(int x, int y, int w, int h, uint16_t color) {
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

static void query_music_status(char *status, size_t status_len, char *track, size_t track_len, bool *shuffle) {
    memset(status, 0, status_len);
    memset(track, 0, track_len);
    strncpy(status, "STOPPED", status_len - 1);
    *shuffle = false;

    FILE *f = popen("/opt/audiocontrol.sh status 2>/dev/null", "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strncmp(line, "STATUS:", 7) == 0) {
            strncpy(status, line + 7, status_len - 1);
        } else if (strncmp(line, "TRACK:", 6) == 0) {
            const char *t = line + 6;
            const char *slash = strrchr(t, '/');
            if (slash) t = slash + 1;
            strncpy(track, t, track_len - 1);
        } else if (strncmp(line, "SHUFFLE:1", 9) == 0) {
            *shuffle = true;
        }
    }
    pclose(f);
}

static void draw_button_widget(const struct Button *b, bool pressed) {
    uint16_t bg = pressed ? COLOR_BLACK : COLOR_WHITE;
    uint16_t fg = pressed ? COLOR_WHITE : COLOR_BLACK;
    uint16_t border = COLOR_BLACK;

    draw_rect(b->x, b->y, b->w, b->h, bg);
    draw_rect_outline(b->x, b->y, b->w, b->h, 4, border);

    char label[128];
    memset(label, 0, sizeof(label));
    strncpy(label, b->text, sizeof(label) - 1);

    /* Add [Running] tag to active app */
    if (b->id == BTN_KOREADER && strcmp(active_app, "koreader") == 0) {
        snprintf(label, sizeof(label), "%s  [Running]", b->text);
    } else if (b->id == BTN_PLATO && strcmp(active_app, "plato") == 0) {
        snprintf(label, sizeof(label), "%s  [Running]", b->text);
    } else if (b->id == BTN_NETSURF && strcmp(active_app, "netsurf") == 0) {
        snprintf(label, sizeof(label), "%s  [Running]", b->text);
    }

    if (b->subtext && b->subtext[0]) {
        draw_string_centered(b->x, b->y + 16, b->w, 36, label, 2, fg, bg);
        draw_string_centered(b->x, b->y + 60, b->w, 24, b->subtext, 1, fg, bg);
    } else {
        int scale = (b->h >= 90) ? 2 : 1;
        draw_string_centered(b->x, b->y, b->w, b->h, label, scale, fg, bg);
    }
}

static void draw_music_section(void) {
    char status[32], track[256];
    bool shuffle = false;
    query_music_status(status, sizeof(status), track, sizeof(track), &shuffle);

    int box_x = 202;
    int box_y = 800;
    int box_w = 1000;
    int box_h = 160;

    draw_rect(box_x, box_y, box_w, box_h, COLOR_WHITE);
    draw_rect_outline(box_x, box_y, box_w, box_h, 3, COLOR_GRAY_DK);

    /* Section Header */
    draw_rect(box_x, box_y, box_w, 36, COLOR_GRAY_LT);
    draw_string(box_x + 20, box_y + 8, "BACKGROUND MUSIC PLAYER (3.5mm & BLUETOOTH)", 1, COLOR_BLACK, COLOR_GRAY_LT);

    char info[256];
    if (track[0]) {
        snprintf(info, sizeof(info), "Track: %.45s", track);
    } else {
        snprintf(info, sizeof(info), "Track: (No track loaded)");
    }
    draw_string(box_x + 20, box_y + 50, info, 2, COLOR_BLACK, COLOR_WHITE);

    char state_str[128];
    snprintf(state_str, sizeof(state_str), "Status: %-8s  |  Shuffle: %-3s",
             status, shuffle ? "ON" : "OFF");
    draw_string(box_x + 20, box_y + 98, state_str, 2, COLOR_GRAY_DK, COLOR_WHITE);

    /* Update Play/Pause & Shuffle button text */
    for (size_t i = 0; i < NUM_BUTTONS; i++) {
        if (buttons[i].id == BTN_MUSIC_PLAY) {
            buttons[i].text = (strcmp(status, "PLAYING") == 0) ? "Pause [||]" : "Play [>]";
        }
        if (buttons[i].id == BTN_MUSIC_SHUFFLE) {
            buttons[i].text = shuffle ? "Shuf: ON" : "Shuf: OFF";
        }
    }

    draw_button_widget(&buttons[3], false);
    draw_button_widget(&buttons[4], false);
    draw_button_widget(&buttons[5], false);
    draw_button_widget(&buttons[6], false);
}

static void draw_dialog(void) {
    /* White dialog background */
    draw_rect(DLG_X, DLG_Y, DLG_W, DLG_H, COLOR_WHITE);
    /* 6px solid black border */
    draw_rect_outline(DLG_X, DLG_Y, DLG_W, DLG_H, 6, COLOR_BLACK);

    /* Header bar */
    draw_rect(DLG_X, DLG_Y, DLG_W, 90, COLOR_BLACK);
    draw_string_centered(DLG_X, DLG_Y, DLG_W, 90, "NOOK APPLICATION SWITCHER", 2, COLOR_WHITE, COLOR_BLACK);

    /* Section Subtitle */
    draw_string(202, 315, "SELECT APPLICATION TO RUN:", 2, COLOR_GRAY_DK, COLOR_WHITE);

    /* Draw application buttons */
    draw_button_widget(&buttons[0], false); /* KOReader */
    draw_button_widget(&buttons[1], false); /* Plato */
    draw_button_widget(&buttons[2], false); /* NetSurf */

    /* Draw Music Player Section */
    draw_music_section();

    /* Draw Bottom Action buttons */
    draw_button_widget(&buttons[7], false); /* Frontlight */
    draw_button_widget(&buttons[8], false); /* Close */
}

static void find_active_app(void) {
    memset(active_app, 0, sizeof(active_app));
    FILE *f = fopen("/tmp/current_app", "r");
    if (!f) f = fopen("/tmp/active_reader", "r");
    if (f) {
        if (fgets(active_app, sizeof(active_app), f)) {
            active_app[strcspn(active_app, "\r\n")] = 0;
        }
        fclose(f);
    }
    if (active_app[0] == '\0') {
        strncpy(active_app, "koreader", sizeof(active_app) - 1);
    }
}

static void suspend_active_app(void) {
    if (strcmp(active_app, "koreader") == 0) {
        system("killall -STOP luajit 2>/dev/null || true");
    } else if (strcmp(active_app, "plato") == 0) {
        system("killall -STOP ld-2.19.so 2>/dev/null; killall -STOP plato 2>/dev/null || true");
    } else if (strcmp(active_app, "netsurf") == 0) {
        system("killall -STOP netsurf-fb 2>/dev/null || true");
    }
}

static void resume_active_app(void) {
    if (strcmp(active_app, "koreader") == 0) {
        system("killall -CONT luajit 2>/dev/null || true");
    } else if (strcmp(active_app, "plato") == 0) {
        system("killall -CONT ld-2.19.so 2>/dev/null; killall -CONT plato 2>/dev/null || true");
    } else if (strcmp(active_app, "netsurf") == 0) {
        system("killall -CONT netsurf-fb 2>/dev/null || true");
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    setlinebuf(stdout);
    setlinebuf(stderr);

    /* Register signal handlers for clean dismissal */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_sigterm;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    /* Mark switcher active */
    int act_fd = open("/tmp/switcher_active", O_CREAT | O_WRONLY | O_TRUNC, 0666);
    if (act_fd >= 0) close(act_fd);

    find_active_app();
    printf("[app-switcher] Active app is '%s'\n", active_app);

    /* Suspend active app so it does not compete for touch or redraw */
    suspend_active_app();

    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) {
        fb_fd = open("/dev/graphics/fb0", O_RDWR);
    }
    if (fb_fd < 0) {
        fprintf(stderr, "Failed to open framebuffer: %s\n", strerror(errno));
        resume_active_app();
        unlink("/tmp/switcher_active");
        return 1;
    }

    fb_mem = (uint16_t *)mmap(NULL, FB_SIZE_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_mem == MAP_FAILED) {
        fprintf(stderr, "mmap failed: %s\n", strerror(errno));
        close(fb_fd);
        resume_active_app();
        unlink("/tmp/switcher_active");
        return 1;
    }

    /* Allocate backup buffer and save area behind dialog */
    backup_mem = malloc(DLG_W * DLG_H * sizeof(uint16_t));
    if (backup_mem) {
        for (int y = 0; y < DLG_H; y++) {
            memcpy(&backup_mem[y * DLG_W], &fb_mem[(DLG_Y + y) * FB_STRIDE + DLG_X], DLG_W * sizeof(uint16_t));
        }
    }

    /* Render dialog */
    draw_dialog();
    epdc_refresh(DLG_X, DLG_Y, DLG_W, DLG_H, 1);

    /* Open touch digitizer and claim exclusive access while switcher is active */
    int touch_fd = open("/dev/input/event1", O_RDONLY | O_NONBLOCK);
    if (touch_fd < 0) {
        fprintf(stderr, "[app-switcher] ERROR: Failed to open /dev/input/event1: %s\n", strerror(errno));
    } else {
        printf("[app-switcher] Opened /dev/input/event1 successfully (fd=%d)\n", touch_fd);
        if (ioctl(touch_fd, EVIOCGRAB, 1) < 0) {
            fprintf(stderr, "[app-switcher] Warning: EVIOCGRAB(1) failed: %s\n", strerror(errno));
        } else {
            printf("[app-switcher] Successfully grabbed /dev/input/event1 exclusively\n");
        }
        /* Drain any pending/stale events from before the dialog opened */
        struct input_event dummy;
        while (read(touch_fd, &dummy, sizeof(dummy)) == sizeof(dummy)) {}
    }
    fflush(stdout);
    fflush(stderr);

    int last_raw_x = -1;
    int last_raw_y = -1;
    bool is_contact_down = false;
    bool was_contact_down = false;
    struct Button *active_pressed_btn = NULL;
    int chosen_action = 0;

    while (g_running) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int max_fd = -1;
        if (touch_fd >= 0) {
            FD_SET(touch_fd, &rfds);
            max_fd = touch_fd;
        }

        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        int ret = select(max_fd + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* Check touch input */
        if (touch_fd >= 0 && FD_ISSET(touch_fd, &rfds)) {
            struct input_event ev;
            bool syn_received = false;

            while (read(touch_fd, &ev, sizeof(ev)) == sizeof(ev)) {
                if (ev.type == EV_ABS) {
                    if (ev.code == 53 || ev.code == 0) {       /* ABS_MT_POSITION_X or ABS_X */
                        last_raw_x = ev.value;
                    } else if (ev.code == 54 || ev.code == 1) { /* ABS_MT_POSITION_Y or ABS_Y */
                        last_raw_y = ev.value;
                    } else if (ev.code == 57) {                 /* ABS_MT_TRACKING_ID */
                        if (ev.value == -1) {
                            is_contact_down = false;
                        } else if (ev.value >= 0) {
                            is_contact_down = true;
                        }
                    }
                } else if (ev.type == EV_KEY && ev.code == 330) { /* BTN_TOUCH */
                    is_contact_down = (ev.value != 0);
                } else if (ev.type == EV_SYN && ev.code == 0) {   /* SYN_REPORT */
                    syn_received = true;
                }

                if (syn_received) {
                    syn_received = false;

                    /* State transition: Touch Press (Lift -> Down) */
                    if (!was_contact_down && is_contact_down) {
                        was_contact_down = true;
                        if (last_raw_x >= 0 && last_raw_y >= 0) {
                            int screen_x = 1403 - last_raw_y;
                            int screen_y = last_raw_x;
                            if (screen_x < 0) screen_x = 0;
                            if (screen_x >= FB_WIDTH) screen_x = FB_WIDTH - 1;
                            if (screen_y < 0) screen_y = 0;
                            if (screen_y >= FB_HEIGHT) screen_y = FB_HEIGHT - 1;

                            printf("[app-switcher] TOUCH DOWN: raw=(%d, %d) -> screen=(%d, %d)\n",
                                   last_raw_x, last_raw_y, screen_x, screen_y);
                            fflush(stdout);

                            /* Immediate 12x12 touch indicator feedback */
                            draw_rect(screen_x - 6, screen_y - 6, 12, 12, COLOR_BLACK);
                            epdc_refresh(screen_x - 8, screen_y - 8, 16, 16, 1);

                            /* Find if a button was pressed */
                            active_pressed_btn = NULL;
                            const int PAD_X = 35;
                            const int PAD_Y = 15;
                            for (size_t i = 0; i < NUM_BUTTONS; i++) {
                                struct Button *b = &buttons[i];
                                if (screen_x >= (b->x - PAD_X) && screen_x <= (b->x + b->w + PAD_X) &&
                                    screen_y >= (b->y - PAD_Y) && screen_y <= (b->y + b->h + PAD_Y)) {
                                    active_pressed_btn = b;
                                    break;
                                }
                            }

                            if (active_pressed_btn) {
                                printf("[app-switcher] Button pressed: #%d ('%s')\n",
                                       active_pressed_btn->id, active_pressed_btn->text);
                                fflush(stdout);
                                draw_button_widget(active_pressed_btn, true);
                                epdc_refresh(active_pressed_btn->x, active_pressed_btn->y,
                                             active_pressed_btn->w, active_pressed_btn->h, 1);
                            }
                        }
                    }
                    /* State transition: Touch Release (Down -> Lift) */
                    else if (was_contact_down && !is_contact_down) {
                        was_contact_down = false;
                        if (last_raw_x >= 0 && last_raw_y >= 0) {
                            int screen_x = 1403 - last_raw_y;
                            int screen_y = last_raw_x;
                            if (screen_x < 0) screen_x = 0;
                            if (screen_x >= FB_WIDTH) screen_x = FB_WIDTH - 1;
                            if (screen_y < 0) screen_y = 0;
                            if (screen_y >= FB_HEIGHT) screen_y = FB_HEIGHT - 1;

                            printf("[app-switcher] TOUCH UP: raw=(%d, %d) -> screen=(%d, %d)\n",
                                   last_raw_x, last_raw_y, screen_x, screen_y);
                            fflush(stdout);

                            /* Un-highlight active pressed button */
                            if (active_pressed_btn) {
                                draw_button_widget(active_pressed_btn, false);
                                epdc_refresh(active_pressed_btn->x, active_pressed_btn->y,
                                             active_pressed_btn->w, active_pressed_btn->h, 1);
                            }

                            /* Tapped outside dialog? Dismiss cleanly */
                            if (screen_x < DLG_X - 20 || screen_x > DLG_X + DLG_W + 20 ||
                                screen_y < DLG_Y - 20 || screen_y > DLG_Y + DLG_H + 20) {
                                printf("[app-switcher] Tapped outside dialog -> closing\n");
                                fflush(stdout);
                                chosen_action = BTN_CLOSE;
                                g_running = 0;
                                break;
                            }

                            /* Determine target action (use pressed button or match release pos) */
                            struct Button *target = active_pressed_btn;
                            if (!target) {
                                const int PAD_X = 35;
                                const int PAD_Y = 15;
                                for (size_t i = 0; i < NUM_BUTTONS; i++) {
                                    struct Button *b = &buttons[i];
                                    if (screen_x >= (b->x - PAD_X) && screen_x <= (b->x + b->w + PAD_X) &&
                                        screen_y >= (b->y - PAD_Y) && screen_y <= (b->y + b->h + PAD_Y)) {
                                        target = b;
                                        break;
                                    }
                                }
                            }

                            if (target) {
                                printf("[app-switcher] Executing action for button #%d ('%s')\n",
                                       target->id, target->text);
                                fflush(stdout);

                                switch (target->id) {
                                    case BTN_MUSIC_PREV:
                                        system("/opt/audiocontrol.sh prev 2>/dev/null");
                                        draw_music_section();
                                        epdc_refresh(202, 800, 1000, 300, 1);
                                        break;

                                    case BTN_MUSIC_PLAY:
                                        system("/opt/audiocontrol.sh pause 2>/dev/null");
                                        draw_music_section();
                                        epdc_refresh(202, 800, 1000, 300, 1);
                                        break;

                                    case BTN_MUSIC_NEXT:
                                        system("/opt/audiocontrol.sh next 2>/dev/null");
                                        draw_music_section();
                                        epdc_refresh(202, 800, 1000, 300, 1);
                                        break;

                                    case BTN_MUSIC_SHUFFLE:
                                        system("/opt/audiocontrol.sh shuffle 2>/dev/null");
                                        draw_music_section();
                                        epdc_refresh(202, 800, 1000, 300, 1);
                                        break;

                                    case BTN_FRONTLIGHT:
                                        system("/opt/scripts/toggle_frontlight.sh &");
                                        break;

                                    default:
                                        chosen_action = target->id;
                                        g_running = 0;
                                        break;
                                }
                            }
                            active_pressed_btn = NULL;
                            if (!g_running) break;
                        }
                    }
                }
            }
        }
    }

    if (touch_fd >= 0) {
        ioctl(touch_fd, EVIOCGRAB, 0);
        close(touch_fd);
    }

    printf("[app-switcher] Selected action: %d\n", chosen_action);

    if (chosen_action == BTN_KOREADER) {
        if (strcmp(active_app, "koreader") == 0) {
            printf("[app-switcher] KOReader already active, resuming...\n");
            if (backup_mem) {
                for (int y = 0; y < DLG_H; y++) {
                    memcpy(&fb_mem[(DLG_Y + y) * FB_STRIDE + DLG_X], &backup_mem[y * DLG_W], DLG_W * sizeof(uint16_t));
                }
            }
            epdc_refresh(DLG_X, DLG_Y, DLG_W, DLG_H, 1);
            resume_active_app();
        } else {
            printf("[app-switcher] Switching to KOReader...\n");
            FILE *f = fopen("/tmp/current_app", "w");
            if (f) { fprintf(f, "koreader\n"); fclose(f); }
            f = fopen("/tmp/active_reader", "w");
            if (f) { fprintf(f, "koreader\n"); fclose(f); }
            system("killall -9 ld-2.19.so 2>/dev/null; killall -9 plato 2>/dev/null; killall -9 netsurf-fb 2>/dev/null || true");
        }
    } else if (chosen_action == BTN_PLATO) {
        if (strcmp(active_app, "plato") == 0) {
            printf("[app-switcher] Plato already active, resuming...\n");
            if (backup_mem) {
                for (int y = 0; y < DLG_H; y++) {
                    memcpy(&fb_mem[(DLG_Y + y) * FB_STRIDE + DLG_X], &backup_mem[y * DLG_W], DLG_W * sizeof(uint16_t));
                }
            }
            epdc_refresh(DLG_X, DLG_Y, DLG_W, DLG_H, 1);
            resume_active_app();
        } else {
            printf("[app-switcher] Switching to Plato...\n");
            FILE *f = fopen("/tmp/current_app", "w");
            if (f) { fprintf(f, "plato\n"); fclose(f); }
            f = fopen("/tmp/active_reader", "w");
            if (f) { fprintf(f, "plato\n"); fclose(f); }
            system("killall -9 luajit 2>/dev/null; killall -9 netsurf-fb 2>/dev/null || true");
        }
    } else if (chosen_action == BTN_NETSURF) {
        printf("[app-switcher] Launching NetSurf...\n");
        FILE *f = fopen("/tmp/current_app", "w");
        if (f) { fprintf(f, "netsurf\n"); fclose(f); }
        system("killall -9 ld-2.19.so 2>/dev/null; killall -9 plato 2>/dev/null; killall -9 luajit 2>/dev/null || true");
        system("/opt/start_browser.sh &");
    } else {
        /* Close / Cancel */
        printf("[app-switcher] Restoring screen and resuming active app...\n");
        if (backup_mem) {
            for (int y = 0; y < DLG_H; y++) {
                memcpy(&fb_mem[(DLG_Y + y) * FB_STRIDE + DLG_X], &backup_mem[y * DLG_W], DLG_W * sizeof(uint16_t));
            }
        }
        epdc_refresh(DLG_X, DLG_Y, DLG_W, DLG_H, 1);
        resume_active_app();
    }

    if (backup_mem) free(backup_mem);
    munmap(fb_mem, FB_SIZE_BYTES);
    close(fb_fd);
    unlink("/tmp/switcher_active");
    return 0;
}
