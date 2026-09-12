/*
 * sdl_fb0_shim.c - Minimal direct Linux /dev/fb0 SDL 1.2 drop-in shim for NetSurf
 * Targets BNRV700 (1404x1872 @ 16bpp RGB565 with 1408 stride & Elan touch)
 * Includes:
 *   - Direct Framebuffer On-Screen Keyboard (OSK) with EN/RU multilingual layouts
 *   - External FIFO input listener (/tmp/netsurf_input.fifo) for phone typing
 *   - 4-Button Hardware Navigation (PageUp, PageDown, History Back, Toggle OSK)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <ctype.h>

#include "font8x16.h"
#include "font8x16_cyrillic.h"

#define FB_PATH "/dev/fb0"
#define TOUCH_PATH "/dev/input/event1"
#define KEYS_PATH "/dev/input/event2"
#define FIFO_PATH "/tmp/netsurf_input.fifo"

#define PANEL_WIDTH  1404
#define PANEL_HEIGHT 1872
#define PANEL_STRIDE 1408
#define PANEL_BPP    16

#define OSK_Y 1272
#define OSK_H 600
#define OSK_W 1404

#define COLOR_WHITE      0xFFFF
#define COLOR_BLACK      0x0000
#define COLOR_BG         0xEF7D  /* Very light gray */
#define COLOR_KEY_BG     0xFFFF  /* White */
#define COLOR_SPECIAL_BG 0xDEFB  /* Light gray */
#define COLOR_BORDER     0x0000
#define COLOR_PRESSED_BG 0x0000
#define COLOR_PRESSED_FG 0xFFFF

#define MXCFB_SEND_UPDATE_V1 0x4040462e

/* Freescale i.MX6 EPDC V1 Waveform and Update Modes */
#define WAVEFORM_MODE_INIT   0
#define WAVEFORM_MODE_DU     1    /* Direct Update: 1-bit monochrome, fast */
#define WAVEFORM_MODE_GC16   2    /* Grayscale Clear 16-levels */
#define WAVEFORM_MODE_GC4    3
#define WAVEFORM_MODE_A2     4
#define WAVEFORM_MODE_GL16   5
#define WAVEFORM_MODE_AUTO   257  /* Hardware automatic selection */

#define UPDATE_MODE_PARTIAL  0    /* Non-flashing partial update */
#define UPDATE_MODE_FULL     1    /* Full flashing clear */

#define TEMP_USE_AMBIENT     4096 /* Use ambient temperature sensor */
#define EPDC_FLAG_FORCE_MONOCHROME 2


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

/* SDL 1.2 Structure Definitions */
typedef struct SDL_Rect {
    int16_t x, y;
    uint16_t w, h;
} SDL_Rect;

typedef struct SDL_Color {
    uint8_t r, g, b, unused;
} SDL_Color;

typedef struct SDL_Palette {
    int ncolors;
    SDL_Color *colors;
} SDL_Palette;

typedef struct SDL_PixelFormat {
    SDL_Palette *palette;
    uint8_t  BitsPerPixel;
    uint8_t  BytesPerPixel;
    uint8_t  Rloss, Gloss, Bloss, Aloss;
    uint8_t  Rshift, Gshift, Bshift, Ashift;
    uint32_t Rmask, Gmask, Bmask, Amask;
    uint32_t colorkey;
    uint8_t  alpha;
} SDL_PixelFormat;

typedef struct SDL_Surface {
    uint32_t flags;
    SDL_PixelFormat *format;
    int w, h;
    uint16_t pitch;
    void *pixels;
    int offset;
    void *hwdata;
    SDL_Rect clip_rect;
    uint32_t unused1;
    uint32_t locked;
    void *map;
    unsigned int format_version;
    int refcount;
} SDL_Surface;

typedef struct SDL_keysym {
    uint8_t scancode;
    int sym;
    int mod;
    uint16_t unicode;
} SDL_keysym;

typedef struct SDL_KeyboardEvent {
    uint8_t type;
    uint8_t which;
    uint8_t state;
    SDL_keysym keysym;
} SDL_KeyboardEvent;

typedef struct SDL_MouseMotionEvent {
    uint8_t type;
    uint8_t which;
    uint8_t state;
    uint16_t x, y;
    int16_t xrel, yrel;
} SDL_MouseMotionEvent;

typedef struct SDL_MouseButtonEvent {
    uint8_t type;
    uint8_t which;
    uint8_t button;
    uint8_t state;
    uint16_t x, y;
} SDL_MouseButtonEvent;

typedef struct SDL_UserEvent {
    uint8_t type;
    int code;
    void *data1;
    void *data2;
} SDL_UserEvent;

typedef struct SDL_ActiveEvent {
    uint8_t type;
    uint8_t gain;
    uint8_t state;
} SDL_ActiveEvent;

typedef struct SDL_ResizeEvent {
    uint8_t type;
    int w;
    int h;
} SDL_ResizeEvent;

typedef struct SDL_QuitEvent {
    uint8_t type;
} SDL_QuitEvent;

typedef union SDL_Event {
    uint8_t type;
    SDL_ActiveEvent active;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_ResizeEvent resize;
    SDL_QuitEvent quit;
    SDL_UserEvent user;
} SDL_Event;

#define SDL_NOEVENT          0
#define SDL_ACTIVEEVENT      1
#define SDL_KEYDOWN          2
#define SDL_KEYUP            3
#define SDL_MOUSEMOTION      4
#define SDL_MOUSEBUTTONDOWN  5
#define SDL_MOUSEBUTTONUP    6
#define SDL_QUIT             12
#define SDL_USEREVENT        24

#define SDL_PRESSED          1
#define SDL_RELEASED         0
#define SDL_BUTTON_LEFT      1

#define SDLK_BACKSPACE 8
#define SDLK_TAB       9
#define SDLK_RETURN    13
#define SDLK_ESCAPE    27
#define SDLK_SPACE     32
#define SDLK_DELETE    127
#define SDLK_u         117
#define SDLK_LEFT      276
#define SDLK_RIGHT     275
#define SDLK_UP        273
#define SDLK_DOWN      274
#define SDLK_HOME      278
#define SDLK_END       279
#define SDLK_PAGEUP    280
#define SDLK_PAGEDOWN  281
#define SDLK_LCTRL     306


#define MAX_TIMERS 16
typedef uint32_t (*SDL_NewTimerCallback)(uint32_t interval, void *param);
typedef struct SDL_TimerID_t {
    volatile bool active;
    uint32_t interval_ms;
    uint64_t next_expire_ms;
    SDL_NewTimerCallback cb;
    void *param;
} *SDL_TimerID;

static struct SDL_TimerID_t g_timers[MAX_TIMERS];
static pthread_mutex_t g_timer_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_t g_timer_thread;
static volatile bool g_timer_thread_running = false;
static void *timer_worker(void *arg);

static int fb_fd = -1;
static int touch_fd = -1;
static int keys_fd = -1;
static int fifo_fd = -1;
static uint8_t *fb_mem = NULL;
static size_t fb_size = 0;
static SDL_Surface main_surface;
static SDL_PixelFormat main_format;

static int last_touch_x = 0;
static int last_touch_y = 0;
static bool touch_down = false;

/* OSK state */
static bool osk_active = false;
static int osk_lang = 0; /* 0 = English, 1 = Russian */
static bool osk_shift = false;
static bool osk_symbols = false;
static uint16_t *osk_backup = NULL;

/* Event queue */
#define MAX_EVENTS 2048
static SDL_Event event_queue[MAX_EVENTS];
static int eq_head = 0;
static int eq_tail = 0;
static pthread_mutex_t eq_mutex = PTHREAD_MUTEX_INITIALIZER;

static void queue_event(const SDL_Event *ev) {
    pthread_mutex_lock(&eq_mutex);
    int next = (eq_tail + 1) % MAX_EVENTS;
    if (next != eq_head) {
        event_queue[eq_tail] = *ev;
        eq_tail = next;
    }
    pthread_mutex_unlock(&eq_mutex);
}

static bool dequeue_event(SDL_Event *ev) {
    pthread_mutex_lock(&eq_mutex);
    if (eq_head == eq_tail) {
        pthread_mutex_unlock(&eq_mutex);
        return false;
    }
    memcpy(ev, &event_queue[eq_head], sizeof(SDL_Event));
    eq_head = (eq_head + 1) % MAX_EVENTS;
    pthread_mutex_unlock(&eq_mutex);
    return true;
}

static void osk_inject_key(int sym, uint32_t unicode) {
    SDL_Event ev_down, ev_up;
    memset(&ev_down, 0, sizeof(ev_down));
    ev_down.type = SDL_KEYDOWN;
    ev_down.key.state = SDL_PRESSED;
    ev_down.key.keysym.sym = sym;
    ev_down.key.keysym.scancode = sym;
    ev_down.key.keysym.unicode = (uint16_t)unicode;
    queue_event(&ev_down);

    memset(&ev_up, 0, sizeof(ev_up));
    ev_up.type = SDL_KEYUP;
    ev_up.key.state = SDL_RELEASED;
    ev_up.key.keysym.sym = sym;
    ev_up.key.keysym.scancode = sym;
    ev_up.key.keysym.unicode = (uint16_t)unicode;
    queue_event(&ev_up);
}

static void send_ctrl_key(int sym, uint32_t unicode) {
    SDL_Event ctrl_down, key_down, key_up, ctrl_up;

    memset(&ctrl_down, 0, sizeof(ctrl_down));
    ctrl_down.type = SDL_KEYDOWN;
    ctrl_down.key.state = SDL_PRESSED;
    ctrl_down.key.keysym.sym = SDLK_LCTRL;
    ctrl_down.key.keysym.scancode = 0;
    queue_event(&ctrl_down);

    memset(&key_down, 0, sizeof(key_down));
    key_down.type = SDL_KEYDOWN;
    key_down.key.state = SDL_PRESSED;
    key_down.key.keysym.sym = sym;
    key_down.key.keysym.scancode = (sym < 256) ? sym : 0;
    key_down.key.keysym.unicode = (uint16_t)unicode;
    queue_event(&key_down);

    memset(&key_up, 0, sizeof(key_up));
    key_up.type = SDL_KEYUP;
    key_up.key.state = SDL_RELEASED;
    key_up.key.keysym.sym = sym;
    key_up.key.keysym.scancode = (sym < 256) ? sym : 0;
    key_up.key.keysym.unicode = (uint16_t)unicode;
    queue_event(&key_up);

    memset(&ctrl_up, 0, sizeof(ctrl_up));
    ctrl_up.type = SDL_KEYUP;
    ctrl_up.key.state = SDL_RELEASED;
    ctrl_up.key.keysym.sym = SDLK_LCTRL;
    ctrl_up.key.keysym.scancode = 0;
    queue_event(&ctrl_up);
}

static void simulate_click(int x, int y) {
    SDL_Event motion_ev, down_ev, up_ev;

    memset(&motion_ev, 0, sizeof(motion_ev));
    motion_ev.type = SDL_MOUSEMOTION;
    motion_ev.motion.state = 0;
    motion_ev.motion.x = x;
    motion_ev.motion.y = y;
    queue_event(&motion_ev);

    usleep(10000);

    memset(&down_ev, 0, sizeof(down_ev));
    down_ev.type = SDL_MOUSEBUTTONDOWN;
    down_ev.button.button = SDL_BUTTON_LEFT;
    down_ev.button.state = SDL_PRESSED;
    down_ev.button.x = x;
    down_ev.button.y = y;
    queue_event(&down_ev);

    usleep(25000);

    memset(&up_ev, 0, sizeof(up_ev));
    up_ev.type = SDL_MOUSEBUTTONUP;
    up_ev.button.button = SDL_BUTTON_LEFT;
    up_ev.button.state = SDL_RELEASED;
    up_ev.button.x = x;
    up_ev.button.y = y;
    queue_event(&up_ev);
}

/*
 * NetSurf's framebuffer frontend uses libnsfb's cursor position for hit
 * testing.  The x/y fields on SDL_MOUSEBUTTON events are not consulted by
 * fbtk_click(), so every real touch must move the cursor before pressing.
 */
static void queue_touch_motion(int x, int y) {
    SDL_Event motion_ev;

    memset(&motion_ev, 0, sizeof(motion_ev));
    motion_ev.type = SDL_MOUSEMOTION;
    motion_ev.motion.state = 0;
    motion_ev.motion.x = x;
    motion_ev.motion.y = y;
    motion_ev.motion.xrel = x - last_touch_x;
    motion_ev.motion.yrel = y - last_touch_y;
    queue_event(&motion_ev);
}

static void clear_browser_url_bar(void) {
    /* 1. Ensure caret is at the end of NetSurf's text widget */
    osk_inject_key(SDLK_END, 0);
    for (int i = 0; i < 15; i++) {
        osk_inject_key(SDLK_RIGHT, 0);
    }

    /* 2. Send Ctrl+U (fbtk wipe text line) */
    send_ctrl_key(SDLK_u, 'u');

    /* 3. Send Backspaces backwards from the end */
    for (int i = 0; i < 50; i++) {
        osk_inject_key(SDLK_BACKSPACE, 8);
    }

    /* 4. Send Ctrl+U again */
    send_ctrl_key(SDLK_u, 'u');
}


/* Framebuffer Drawing & EPDC Helpers */

static void epdc_refresh_area(int left, int top, int width, int height, int waveform_mode, int update_mode, int flags) {
    if (fb_fd < 0) return;
    int aligned_left = left & ~7;
    int aligned_top = top & ~7;
    int aligned_right = (left + width + 7) & ~7;
    int aligned_bottom = (top + height + 7) & ~7;
    if (aligned_right > PANEL_WIDTH) aligned_right = PANEL_WIDTH;
    if (aligned_bottom > PANEL_HEIGHT) aligned_bottom = PANEL_HEIGHT;
    if (aligned_right <= aligned_left || aligned_bottom <= aligned_top) return;

    struct mxcfb_update_data_v1 upd;
    memset(&upd, 0, sizeof(upd));
    upd.update_region.left = aligned_left;
    upd.update_region.top = aligned_top;
    upd.update_region.width = aligned_right - aligned_left;
    upd.update_region.height = aligned_bottom - aligned_top;
    upd.waveform_mode = waveform_mode;
    upd.update_mode = update_mode;
    upd.temp = TEMP_USE_AMBIENT;
    upd.flags = flags;
    ioctl(fb_fd, MXCFB_SEND_UPDATE_V1, &upd);
}

/* Fast 1-bit monochrome partial update for rapid typing feedback */
static void epdc_refresh_fast(int left, int top, int width, int height) {
    epdc_refresh_area(left, top, width, height, WAVEFORM_MODE_DU, UPDATE_MODE_PARTIAL, EPDC_FLAG_FORCE_MONOCHROME);
}

/* 16-level grayscale partial update for web page contents and keyboard redraws */
static void epdc_refresh_gray(int left, int top, int width, int height) {
    epdc_refresh_area(left, top, width, height, WAVEFORM_MODE_GC16, UPDATE_MODE_PARTIAL, 0);
}

/* Full flashing GC16 update to purge ghosting */
static void epdc_refresh_full(int left, int top, int width, int height) {
    epdc_refresh_area(left, top, width, height, WAVEFORM_MODE_GC16, UPDATE_MODE_FULL, 0);
}

static inline void fb_set_pixel(int x, int y, uint16_t color) {
    if (fb_mem && x >= 0 && x < PANEL_WIDTH && y >= 0 && y < PANEL_HEIGHT) {
        ((uint16_t *)fb_mem)[y * PANEL_STRIDE + x] = color;
    }
}

static void fb_draw_rect(int x, int y, int w, int h, uint16_t color) {
    if (!fb_mem) return;
    for (int cy = y; cy < y + h; cy++) {
        if (cy < 0 || cy >= PANEL_HEIGHT) continue;
        int row = cy * PANEL_STRIDE;
        for (int cx = x; cx < x + w; cx++) {
            if (cx >= 0 && cx < PANEL_WIDTH) {
                ((uint16_t *)fb_mem)[row + cx] = color;
            }
        }
    }
}

static void fb_draw_rect_outline(int x, int y, int w, int h, int thickness, uint16_t color) {
    fb_draw_rect(x, y, w, thickness, color);
    fb_draw_rect(x, y + h - thickness, w, thickness, color);
    fb_draw_rect(x, y, thickness, h, color);
    fb_draw_rect(x + w - thickness, y, thickness, h, color);
}

static const char *utf8_next(const char *s, uint32_t *cp) {
    if (!s || !*s) return NULL;
    uint8_t c = (uint8_t)*s;
    if (c < 0x80) {
        *cp = c;
        return s + 1;
    } else if ((c & 0xE0) == 0xC0) {
        *cp = ((c & 0x1F) << 6) | ((uint8_t)s[1] & 0x3F);
        return s + 2;
    } else if ((c & 0xF0) == 0xE0) {
        *cp = ((c & 0x0F) << 12) | (((uint8_t)s[1] & 0x3F) << 6) | ((uint8_t)s[2] & 0x3F);
        return s + 3;
    } else {
        *cp = c;
        return s + 1;
    }
}

static void fb_draw_utf8_char(int x, int y, uint32_t cp, int scale, uint16_t fg, uint16_t bg) {
    const uint8_t *glyph = NULL;
    if (cp >= 32 && cp <= 126) {
        glyph = font8x16[cp - 32];
    } else {
        int c_idx = get_cyrillic_font_index(cp);
        if (c_idx >= 0) {
            glyph = font8x16_cyrillic[c_idx];
        }
    }
    if (!glyph) glyph = font8x16['?' - 32];

    for (int row = 0; row < 16; row++) {
        uint8_t line = glyph[row];
        for (int col = 0; col < 8; col++) {
            uint16_t color = (line & (1 << (7 - col))) ? fg : bg;
            if (scale == 1) {
                if (color != bg || bg != 0) fb_set_pixel(x + col, y + row, color);
            } else {
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        fb_set_pixel(x + col * scale + sx, y + row * scale + sy, color);
                    }
                }
            }
        }
    }
}

static void fb_draw_utf8_string(int x, int y, const char *str, int scale, uint16_t fg, uint16_t bg) {
    uint32_t cp;
    int cx = x;
    const char *p = str;
    while ((p = utf8_next(p, &cp))) {
        fb_draw_utf8_char(cx, y, cp, scale, fg, bg);
        cx += 8 * scale;
    }
}

static int utf8_string_len(const char *str) {
    int len = 0;
    uint32_t cp;
    const char *p = str;
    while ((p = utf8_next(p, &cp))) {
        len++;
    }
    return len;
}

static void fb_draw_utf8_string_centered(int box_x, int box_y, int box_w, int box_h, const char *str, int scale, uint16_t fg, uint16_t bg) {
    int len = utf8_string_len(str);
    int str_w = len * 8 * scale;
    int str_h = 16 * scale;
    int cx = box_x + (box_w - str_w) / 2;
    int cy = box_y + (box_h - str_h) / 2;
    fb_draw_utf8_string(cx, cy, str, scale, fg, bg);
}

/* URL Tracking & High-DPI URL Bar Rendering */
static char g_current_url[1024] = "https://lite.duckduckgo.com";
static bool g_url_bar_focused = true;

static void init_current_url(void) {
    FILE *f = fopen("/proc/self/cmdline", "r");
    if (f) {
        char buf[2048];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        if (n > 0) {
            buf[n] = '\0';
            char *p = buf;
            while (p < buf + n) {
                if (strncmp(p, "http://", 7) == 0 || strncmp(p, "https://", 8) == 0) {
                    strncpy(g_current_url, p, sizeof(g_current_url) - 1);
                    break;
                }
                p += strlen(p) + 1;
            }
        }
    }
}

static void draw_url_bar_overlay(void) {
    if (!fb_mem) return;
    /* Draw crisp white URL bar box inside toolbar: X=145..1320, Y=6..64 (height 58) */
    fb_draw_rect(145, 6, 1175, 58, COLOR_WHITE);
    fb_draw_rect_outline(145, 6, 1175, 58, 2, COLOR_BLACK);

    /* Draw URL text in scale 2 (16x32 bold font) */
    char display_buf[80];
    snprintf(display_buf, sizeof(display_buf), "URL: %s", g_current_url);
    int max_chars = 64;
    if ((int)strlen(display_buf) > max_chars) {
        display_buf[max_chars - 3] = '.';
        display_buf[max_chars - 2] = '.';
        display_buf[max_chars - 1] = '.';
        display_buf[max_chars] = '\0';
    }
    fb_draw_utf8_string(160, 19, display_buf, 2, COLOR_BLACK, COLOR_WHITE);
}

static void draw_osk_input_preview(void) {
    if (!fb_mem) return;
    /* Large high-contrast white input box between Hide and Clear: X=202..1202, Y=1275..1321 */
    fb_draw_rect(202, 1275, 1000, 46, COLOR_WHITE);
    fb_draw_rect_outline(202, 1275, 1000, 46, 2, COLOR_BLACK);

    char osk_buf[128];
    if (!g_url_bar_focused || strlen(g_current_url) == 0) {
        const char *hint;
        if (!g_url_bar_focused)
            hint = (osk_lang == 0) ? "Tap keys to type in the page field..." : "Введите текст в поле страницы...";
        else
            hint = (osk_lang == 0) ? "Tap keys to type URL / Search query..." : "Введите адрес или поисковый запрос...";
        fb_draw_utf8_string(216, 1282, hint, 2, COLOR_SPECIAL_BG, COLOR_WHITE);
    } else {
        snprintf(osk_buf, sizeof(osk_buf), "%s", g_current_url);
        int max_chars = 58;
        if ((int)strlen(osk_buf) > max_chars) {
            char *end_p = osk_buf + strlen(osk_buf) - max_chars;
            fb_draw_utf8_string(216, 1282, end_p, 2, COLOR_BLACK, COLOR_WHITE);
        } else {
            fb_draw_utf8_string(216, 1282, osk_buf, 2, COLOR_BLACK, COLOR_WHITE);
        }
    }
}

/* On-Screen Keyboard (OSK) Definition & Rendering */

enum KeyAction {
    ACT_CHAR = 0,
    ACT_BACKSPACE,
    ACT_ENTER,
    ACT_SPACE,
    ACT_SHIFT,
    ACT_SYMBOLS,
    ACT_LANG,
    ACT_HIDE,
    ACT_CLEAR,
    ACT_DOTCOM
};

struct OSKKey {
    int x, y, w, h;
    char normal_label[16];
    char shift_label[16];
    char sym_label[16];
    enum KeyAction action;
    int sym;
    uint32_t unicode_norm;
    uint32_t unicode_shift;
    uint32_t unicode_sym;
    uint16_t bg;
    uint16_t fg;
};

#define MAX_OSK_KEYS 64
static struct OSKKey osk_keys[MAX_OSK_KEYS];
static int num_osk_keys = 0;

static void build_osk_layout(void) {
    num_osk_keys = 0;

    /* Header Bar: Y = 1272, H = 52 */
    /* Key 0: Hide */
    osk_keys[num_osk_keys++] = (struct OSKKey){
        .x = 12, .y = 1275, .w = 180, .h = 46,
        .normal_label = "Hide Kbd", .shift_label = "Hide Kbd", .sym_label = "Hide Kbd",
        .action = ACT_HIDE, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
    };
    /* Key 1: Clear */
    osk_keys[num_osk_keys++] = (struct OSKKey){
        .x = 1212, .y = 1275, .w = 180, .h = 46,
        .normal_label = "Clear", .shift_label = "Clear", .sym_label = "Clear",
        .action = ACT_CLEAR, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
    };

    if (osk_lang == 0) {
        /* ================= ENGLISH QWERTY ================= */
        /* Row 1: Numbers & Backspace: Y = 1328, H = 98 */
        const char *nums_norm[] = { "1","2","3","4","5","6","7","8","9","0" };
        const char *nums_shift[] = { "!","@","#","$","%","^","&","*","(",")" };
        const char *nums_sym[]   = { "[","]","{","}","#","%","^","*","+","=" };
        for (int i = 0; i < 10; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 12 + i * 116, .y = 1328, .w = 110, .h = 98,
                .normal_label = "", .shift_label = "", .sym_label = "",
                .action = ACT_CHAR,
                .unicode_norm = nums_norm[i][0],
                .unicode_shift = nums_shift[i][0],
                .unicode_sym = nums_sym[i][0],
                .sym = nums_norm[i][0],
                .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, nums_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, nums_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, nums_sym[i]);
        }
        /* Backspace */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1172, .y = 1328, .w = 220, .h = 98,
            .normal_label = "Backsp", .shift_label = "Backsp", .sym_label = "Backsp",
            .action = ACT_BACKSPACE, .sym = SDLK_BACKSPACE, .unicode_norm = 8,
            .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };

        /* Row 2: QWERTY: Y = 1432, H = 98 */
        const char *r2_norm[] = { "q","w","e","r","t","y","u","i","o","p" };
        const char *r2_shift[] = { "Q","W","E","R","T","Y","U","I","O","P" };
        const char *r2_sym[]   = { "~","-","_","=","+","\\","|","<",">","/" };
        for (int i = 0; i < 10; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 12 + i * 138, .y = 1432, .w = 130, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r2_norm[i][0],
                .unicode_shift = r2_shift[i][0],
                .unicode_sym = r2_sym[i][0],
                .sym = r2_norm[i][0],
                .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r2_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r2_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r2_sym[i]);
        }

        /* Row 3: ASDF: Y = 1536, H = 98 */
        const char *r3_norm[] = { "a","s","d","f","g","h","j","k","l" };
        const char *r3_shift[] = { "A","S","D","F","G","H","J","K","L" };
        const char *r3_sym[]   = { ":",";","\"","'","?","!","@","$","&" };
        for (int i = 0; i < 9; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 80 + i * 138, .y = 1536, .w = 130, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r3_norm[i][0],
                .unicode_shift = r3_shift[i][0],
                .unicode_sym = r3_sym[i][0],
                .sym = r3_norm[i][0],
                .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r3_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r3_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r3_sym[i]);
        }

        /* Row 4: ZXCV: Y = 1640, H = 98 */
        /* Shift */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 12, .y = 1640, .w = 170, .h = 98,
            .normal_label = "Shift", .shift_label = "SHIFT", .sym_label = "Shift",
            .action = ACT_SHIFT, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        const char *r4_norm[] = { "z","x","c","v","b","n","m" };
        const char *r4_shift[] = { "Z","X","C","V","B","N","M" };
        const char *r4_sym[]   = { "(",")","[","]","{","}","_" };
        for (int i = 0; i < 7; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 192 + i * 134, .y = 1640, .w = 126, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r4_norm[i][0],
                .unicode_shift = r4_shift[i][0],
                .unicode_sym = r4_sym[i][0],
                .sym = r4_norm[i][0],
                .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r4_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r4_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r4_sym[i]);
        }
        /* Dot */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1130, .y = 1640, .w = 126, .h = 98,
            .normal_label = ".", .shift_label = ",", .sym_label = ".",
            .action = ACT_CHAR, .unicode_norm = '.', .unicode_shift = ',', .unicode_sym = '.',
            .sym = '.', .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
        };
        /* Slash */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1266, .y = 1640, .w = 126, .h = 98,
            .normal_label = "/", .shift_label = "?", .sym_label = "/",
            .action = ACT_CHAR, .unicode_norm = '/', .unicode_shift = '?', .unicode_sym = '/',
            .sym = '/', .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
        };

        /* Row 5: Space, Mode, Lang, Enter: Y = 1744, H = 104 */
        /* ?123 */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 12, .y = 1744, .w = 170, .h = 104,
            .normal_label = "?123", .shift_label = "?123", .sym_label = "ABC",
            .action = ACT_SYMBOLS, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Language Toggle */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 190, .y = 1744, .w = 140, .h = 104,
            .normal_label = "EN", .shift_label = "EN", .sym_label = "EN",
            .action = ACT_LANG, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Space */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 338, .y = 1744, .w = 540, .h = 104,
            .normal_label = "Space", .shift_label = "Space", .sym_label = "Space",
            .action = ACT_SPACE, .sym = SDLK_SPACE, .unicode_norm = ' ',
            .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
        };
        /* .com */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 886, .y = 1744, .w = 190, .h = 104,
            .normal_label = ".com", .shift_label = ".com", .sym_label = ".com",
            .action = ACT_DOTCOM, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Go / Enter */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1084, .y = 1744, .w = 308, .h = 104,
            .normal_label = "Go / Enter", .shift_label = "Go / Enter", .sym_label = "Go / Enter",
            .action = ACT_ENTER, .sym = SDLK_RETURN, .unicode_norm = 13,
            .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
    } else {
        /* ================= RUSSIAN JCUKEN ================= */
        /* Row 1: Numbers & Backspace: Y = 1328, H = 98 */
        const char *ru_nums[] = { "1","2","3","4","5","6","7","8","9","0" };
        for (int i = 0; i < 10; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 12 + i * 116, .y = 1328, .w = 110, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = ru_nums[i][0], .unicode_shift = ru_nums[i][0], .unicode_sym = ru_nums[i][0],
                .sym = ru_nums[i][0], .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, ru_nums[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, ru_nums[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, ru_nums[i]);
        }
        /* Backspace */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1172, .y = 1328, .w = 220, .h = 98,
            .normal_label = "Backsp", .shift_label = "Backsp", .sym_label = "Backsp",
            .action = ACT_BACKSPACE, .sym = SDLK_BACKSPACE, .unicode_norm = 8,
            .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };

        /* Row 2: 11 Russian keys: й ц у к е н г ш щ з х */
        const char *r2_ru_norm[]  = { "й","ц","у","к","е","н","г","ш","щ","з","х" };
        const char *r2_ru_shift[] = { "Й","Ц","У","К","Е","Н","Г","Ш","Щ","З","Х" };
        const uint32_t r2_ru_cp_n[] = { 0x0439, 0x0446, 0x0443, 0x043A, 0x0435, 0x043D, 0x0433, 0x0448, 0x0449, 0x0437, 0x0445 };
        const uint32_t r2_ru_cp_s[] = { 0x0419, 0x0426, 0x0423, 0x041A, 0x0415, 0x041D, 0x0413, 0x0428, 0x0429, 0x0417, 0x0425 };
        for (int i = 0; i < 11; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 12 + i * 125, .y = 1432, .w = 118, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r2_ru_cp_n[i], .unicode_shift = r2_ru_cp_s[i], .unicode_sym = r2_ru_cp_n[i],
                .sym = r2_ru_cp_n[i], .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r2_ru_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r2_ru_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r2_ru_norm[i]);
        }

        /* Row 3: 11 Russian keys: ф ы в а п р о л д ж э */
        const char *r3_ru_norm[]  = { "ф","ы","в","а","п","р","о","л","д","ж","э" };
        const char *r3_ru_shift[] = { "Ф","Ы","В","А","П","Р","О","Л","Д","Ж","Э" };
        const uint32_t r3_ru_cp_n[] = { 0x0444, 0x044B, 0x0432, 0x0430, 0x043F, 0x0440, 0x043E, 0x043B, 0x0434, 0x0436, 0x044D };
        const uint32_t r3_ru_cp_s[] = { 0x0424, 0x042B, 0x0412, 0x0410, 0x041F, 0x0420, 0x041E, 0x041B, 0x0414, 0x0416, 0x042D };
        for (int i = 0; i < 11; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 12 + i * 125, .y = 1536, .w = 118, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r3_ru_cp_n[i], .unicode_shift = r3_ru_cp_s[i], .unicode_sym = r3_ru_cp_n[i],
                .sym = r3_ru_cp_n[i], .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r3_ru_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r3_ru_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r3_ru_norm[i]);
        }

        /* Row 4: Shift + я ч с м и т ь б ю ё */
        /* Shift */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 12, .y = 1640, .w = 140, .h = 98,
            .normal_label = "Shift", .shift_label = "SHIFT", .sym_label = "Shift",
            .action = ACT_SHIFT, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        const char *r4_ru_norm[]  = { "я","ч","с","м","и","т","ь","б","ю","ё" };
        const char *r4_ru_shift[] = { "Я","Ч","С","М","И","Т","Ь","Б","Ю","Ё" };
        const uint32_t r4_ru_cp_n[] = { 0x044F, 0x0447, 0x0441, 0x043C, 0x0438, 0x0442, 0x044C, 0x0431, 0x044E, 0x0451 };
        const uint32_t r4_ru_cp_s[] = { 0x042F, 0x0427, 0x0421, 0x041C, 0x0418, 0x0422, 0x042C, 0x0411, 0x042E, 0x0401 };
        for (int i = 0; i < 10; i++) {
            osk_keys[num_osk_keys++] = (struct OSKKey){
                .x = 160 + i * 123, .y = 1640, .w = 116, .h = 98,
                .action = ACT_CHAR,
                .unicode_norm = r4_ru_cp_n[i], .unicode_shift = r4_ru_cp_s[i], .unicode_sym = r4_ru_cp_n[i],
                .sym = r4_ru_cp_n[i], .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
            };
            strcpy(osk_keys[num_osk_keys-1].normal_label, r4_ru_norm[i]);
            strcpy(osk_keys[num_osk_keys-1].shift_label, r4_ru_shift[i]);
            strcpy(osk_keys[num_osk_keys-1].sym_label, r4_ru_norm[i]);
        }

        /* Row 5: Space, Mode, Lang, Enter: Y = 1744, H = 104 */
        /* ?123 */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 12, .y = 1744, .w = 170, .h = 104,
            .normal_label = "?123", .shift_label = "?123", .sym_label = "АБВ",
            .action = ACT_SYMBOLS, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Language Toggle */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 190, .y = 1744, .w = 140, .h = 104,
            .normal_label = "RU", .shift_label = "RU", .sym_label = "RU",
            .action = ACT_LANG, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Space */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 338, .y = 1744, .w = 540, .h = 104,
            .normal_label = "Пробел", .shift_label = "Пробел", .sym_label = "Пробел",
            .action = ACT_SPACE, .sym = SDLK_SPACE, .unicode_norm = ' ',
            .bg = COLOR_KEY_BG, .fg = COLOR_BLACK
        };
        /* .ru */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 886, .y = 1744, .w = 190, .h = 104,
            .normal_label = ".ru", .shift_label = ".ru", .sym_label = ".ru",
            .action = ACT_DOTCOM, .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
        /* Go / Enter */
        osk_keys[num_osk_keys++] = (struct OSKKey){
            .x = 1084, .y = 1744, .w = 308, .h = 104,
            .normal_label = "Ввод", .shift_label = "Ввод", .sym_label = "Ввод",
            .action = ACT_ENTER, .sym = SDLK_RETURN, .unicode_norm = 13,
            .bg = COLOR_SPECIAL_BG, .fg = COLOR_BLACK
        };
    }
}

static void draw_osk_key(const struct OSKKey *k, bool pressed) {
    uint16_t bg = pressed ? COLOR_PRESSED_BG : k->bg;
    uint16_t fg = pressed ? COLOR_PRESSED_FG : k->fg;

    fb_draw_rect(k->x, k->y, k->w, k->h, bg);
    fb_draw_rect_outline(k->x, k->y, k->w, k->h, 2, COLOR_BORDER);

    const char *label = k->normal_label;
    if (osk_symbols) label = k->sym_label;
    else if (osk_shift) label = k->shift_label;

    int scale = 3;
    if (strlen(label) > 3) scale = 2;
    if (strlen(label) > 7) scale = 1;

    fb_draw_utf8_string_centered(k->x, k->y, k->w, k->h, label, scale, fg, bg);
}

static void draw_osk(void) {
    build_osk_layout();

    /* Fill background */
    fb_draw_rect(0, OSK_Y, OSK_W, OSK_H, COLOR_BG);
    fb_draw_rect(0, OSK_Y, OSK_W, 3, COLOR_BLACK);

    /* Draw large high-contrast input preview box */
    draw_osk_input_preview();

    for (int i = 0; i < num_osk_keys; i++) {
        draw_osk_key(&osk_keys[i], false);
    }
}

static void show_osk(void) {
    if (osk_active || !fb_mem) return;

    if (!osk_backup) {
        osk_backup = (uint16_t *)malloc(PANEL_STRIDE * OSK_H * sizeof(uint16_t));
    }
    if (osk_backup) {
        /* Save existing framebuffer area */
        for (int y = 0; y < OSK_H; y++) {
            memcpy(&osk_backup[y * PANEL_STRIDE],
                   &((uint16_t *)fb_mem)[(OSK_Y + y) * PANEL_STRIDE],
                   PANEL_STRIDE * sizeof(uint16_t));
        }
    }

    osk_active = true;
    main_surface.clip_rect.h = OSK_Y;
    draw_osk();
    epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H);
}

/* Called by the NetSurf framebuffer frontend when an HTML text control
 * receives the caret.  Unlike the URL bar, a page control must not update
 * the URL preview or submit through the browser address-bar path. */
void SDL_ShowKeyboardForTextInput(void) {
    g_url_bar_focused = false;
    show_osk();
}

static void hide_osk(void) {
    if (!osk_active || !fb_mem) return;

    main_surface.clip_rect.h = PANEL_HEIGHT;

    if (osk_backup) {
        /* Restore background */
        for (int y = 0; y < OSK_H; y++) {
            memcpy(&((uint16_t *)fb_mem)[(OSK_Y + y) * PANEL_STRIDE],
                   &osk_backup[y * PANEL_STRIDE],
                   PANEL_STRIDE * sizeof(uint16_t));
        }
    }

    osk_active = false;
    epdc_refresh_full(0, OSK_Y, OSK_W, OSK_H);
}

static void toggle_osk(void) {
    if (osk_active) hide_osk();
    else show_osk();
}

static void handle_osk_touch(int x, int y) {
    for (int i = 0; i < num_osk_keys; i++) {
        struct OSKKey *k = &osk_keys[i];
        if (x >= k->x && x < k->x + k->w && y >= k->y && y < k->y + k->h) {
            /* Visual press feedback */
            draw_osk_key(k, true);
            epdc_refresh_fast(k->x, k->y, k->w, k->h);

            switch (k->action) {
                case ACT_HIDE:
                    hide_osk();
                    return;
                case ACT_CLEAR:
                    if (g_url_bar_focused)
                        memset(g_current_url, 0, sizeof(g_current_url));
                    draw_osk_input_preview();
                    epdc_refresh_fast(202, 1275, 1000, 46);
                    if (g_url_bar_focused) {
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);
                        simulate_click(300, 35);
                        clear_browser_url_bar();
                    } else {
                        send_ctrl_key(SDLK_u, 'u');
                        for (int c = 0; c < 50; c++) {
                            osk_inject_key(SDLK_BACKSPACE, 8);
                        }
                    }
                    break;
                case ACT_SHIFT:
                    osk_shift = !osk_shift;
                    draw_osk();
                    epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H);
                    return;
                case ACT_SYMBOLS:
                    osk_symbols = !osk_symbols;
                    draw_osk();
                    epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H);
                    return;
                case ACT_LANG:
                    osk_lang = !osk_lang;
                    draw_osk();
                    epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H);
                    return;
                case ACT_BACKSPACE:
                    if (g_url_bar_focused && strlen(g_current_url) > 0) {
                        g_current_url[strlen(g_current_url) - 1] = '\0';
                        draw_osk_input_preview();
                        epdc_refresh_fast(202, 1275, 1000, 46);
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);
                    }
                    osk_inject_key(SDLK_BACKSPACE, 8);
                    break;
                case ACT_SPACE:
                    if (g_url_bar_focused && strlen(g_current_url) < sizeof(g_current_url) - 2) {
                        strcat(g_current_url, " ");
                        draw_osk_input_preview();
                        epdc_refresh_fast(202, 1275, 1000, 46);
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);
                    }
                    osk_inject_key(SDLK_SPACE, ' ');
                    break;
                case ACT_ENTER:
                    if (g_url_bar_focused && strlen(g_current_url) > 0) {
                        char target[1024];
                        const char *trimmed = g_current_url;
                        while (*trimmed == ' ') trimmed++;
                        if (strchr(trimmed, ' ') != NULL || (strstr(trimmed, "://") == NULL && strchr(trimmed, '.') == NULL)) {
                            char query_enc[1024];
                            char *q = query_enc;
                            for (const char *s = trimmed; *s && q < query_enc + sizeof(query_enc) - 2; s++) {
                                if (*s == ' ') *q++ = '+';
                                else *q++ = *s;
                            }
                            *q = '\0';
                            snprintf(target, sizeof(target), "https://lite.duckduckgo.com/lite/?q=%s", query_enc);
                        } else {
                            snprintf(target, sizeof(target), "%s", trimmed);
                        }
                        strncpy(g_current_url, target, sizeof(g_current_url) - 1);
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);

                        /* Focus and clean NetSurf's URL widget completely */
                        simulate_click(300, 35);
                        usleep(15000);
                        clear_browser_url_bar();
                        usleep(10000);

                        /* Type clean target string */
                        const char *p = target;
                        uint32_t cp;
                        while ((p = utf8_next(p, &cp))) {
                            if (cp == '\n' || cp == '\r') continue;
                            int sym = (cp < 128) ? tolower((int)cp) : (int)cp;
                            osk_inject_key(sym, cp);
                            usleep(800);
                        }
                        usleep(15000);
                    }
                    osk_inject_key(SDLK_RETURN, 13);
                    hide_osk();
                    return;
                case ACT_DOTCOM: {
                    const char *ext = (osk_lang == 0) ? ".com" : ".ru";
                    if (g_url_bar_focused && strlen(g_current_url) < sizeof(g_current_url) - 6) {
                        strcat(g_current_url, ext);
                        draw_osk_input_preview();
                        epdc_refresh_fast(202, 1275, 1000, 46);
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);
                    }
                    for (const char *p = ext; *p; p++) {
                        osk_inject_key(*p, *p);
                        usleep(2000);
                    }
                    break;
                }
                case ACT_CHAR: {
                    uint32_t cp = k->unicode_norm;
                    if (osk_symbols) cp = k->unicode_sym;
                    else if (osk_shift) cp = k->unicode_shift;

                    int sym = (cp < 128) ? tolower((int)cp) : (int)cp;
                    if (g_url_bar_focused && strlen(g_current_url) < sizeof(g_current_url) - 6) {
                        char cstr[8] = {0};
                        if (cp < 128) {
                            cstr[0] = (char)cp;
                        } else if (cp < 0x800) {
                            cstr[0] = (char)(0xC0 | (cp >> 6));
                            cstr[1] = (char)(0x80 | (cp & 0x3F));
                        }
                        strcat(g_current_url, cstr);
                        draw_osk_input_preview();
                        epdc_refresh_fast(202, 1275, 1000, 46);
                        draw_url_bar_overlay();
                        epdc_refresh_fast(145, 6, 1175, 58);
                    }

                    osk_inject_key(sym, cp);
                    if (osk_shift) {
                        osk_shift = false;
                        draw_osk();
                        epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H);
                        return;
                    }
                    break;
                }
            }

            usleep(40000);
            draw_osk_key(k, false);
            epdc_refresh_fast(k->x, k->y, k->w, k->h);
            return;
        }
    }
}

/* External FIFO Command Handler */
static void handle_fifo_command(const char *cmd) {
    if (strncmp(cmd, "KEY:", 4) == 0) {
        const char *k = cmd + 4;
        if (strcmp(k, "enter") == 0) osk_inject_key(SDLK_RETURN, 13);
        else if (strcmp(k, "backspace") == 0) osk_inject_key(SDLK_BACKSPACE, 8);
        else if (strcmp(k, "escape") == 0) osk_inject_key(SDLK_ESCAPE, 27);
        else if (strcmp(k, "tab") == 0) osk_inject_key(SDLK_TAB, 9);
        else if (strcmp(k, "pageup") == 0) osk_inject_key(SDLK_PAGEUP, 0);
        else if (strcmp(k, "pagedown") == 0) osk_inject_key(SDLK_PAGEDOWN, 0);
        else if (strcmp(k, "home") == 0) osk_inject_key(SDLK_HOME, 0);
        else if (strcmp(k, "osk") == 0) toggle_osk();
        else if (strcmp(k, "lang") == 0) {
            osk_lang = !osk_lang;
            if (osk_active) { draw_osk(); epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H); }
        }
        else if (strcmp(k, "shift") == 0) {
            osk_shift = !osk_shift;
            if (osk_active) { draw_osk(); epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H); }
        }
        else if (strcmp(k, "sym") == 0) {
            osk_symbols = !osk_symbols;
            if (osk_active) { draw_osk(); epdc_refresh_gray(0, OSK_Y, OSK_W, OSK_H); }
        }
        else if (strcmp(k, "back") == 0) simulate_click(25, 48);
        else if (strcmp(k, "focus_url") == 0) {
            g_url_bar_focused = true;
            simulate_click(300, 35);
            osk_inject_key(SDLK_END, 0);
            show_osk();
        }
    } else if (strncmp(cmd, "TEXT:", 5) == 0) {
        const char *p = cmd + 5;
        if (strlen(g_current_url) + strlen(p) < sizeof(g_current_url) - 1) {
            strcat(g_current_url, p);
            draw_url_bar_overlay();
            epdc_refresh_fast(145, 6, 1175, 58);
        }
        uint32_t cp;
        while ((p = utf8_next(p, &cp))) {
            if (cp == '\n' || cp == '\r') continue;
            int sym = (cp < 128) ? tolower((int)cp) : (int)cp;
            osk_inject_key(sym, cp);
            usleep(2000);
        }
    } else if (strncmp(cmd, "URL:", 4) == 0) {
        const char *url = cmd + 4;
        strncpy(g_current_url, url, sizeof(g_current_url) - 1);
        draw_url_bar_overlay();
        epdc_refresh_fast(145, 6, 1175, 58);
        /* Focus URL Bar */
        simulate_click(300, 35);
        usleep(25000);
        clear_browser_url_bar();
        usleep(10000);
        /* Type URL with paced characters */
        const char *p = url;
        uint32_t cp;
        while ((p = utf8_next(p, &cp))) {
            if (cp == '\n' || cp == '\r') continue;
            int sym = (cp < 128) ? tolower((int)cp) : (int)cp;
            osk_inject_key(sym, cp);
            usleep(800);
        }
        usleep(20000);
        /* Press Return */
        osk_inject_key(SDLK_RETURN, 13);
    } else if (strncmp(cmd, "CLICK:", 6) == 0) {
        int cx = 0, cy = 0;
        if (sscanf(cmd + 6, "%d,%d", &cx, &cy) == 2) {
            if (cy >= 75) g_url_bar_focused = false;
            simulate_click(cx, cy);
        }
    }
}

/* Input Worker Thread */
static pthread_t input_thread;
static volatile bool input_thread_running = false;

static void *input_worker(void *arg) {
    (void)arg;
    struct input_event ev;
    int cur_x = 0, cur_y = 0;
    bool cur_down = false;
    int touch_count = 0;

    int touch_fd = open("/dev/input/event1", O_RDONLY);
    int keys_fd = open("/dev/input/event2", O_RDONLY);
    int fifo_fd = open(FIFO_PATH, O_RDWR | O_NONBLOCK);

    struct pollfd pfd[3];
    pfd[0].fd = touch_fd;
    pfd[0].events = POLLIN;
    pfd[1].fd = keys_fd;
    pfd[1].events = POLLIN;
    pfd[2].fd = fifo_fd;
    pfd[2].events = POLLIN;

    char fifo_buf[256];

    while (input_thread_running) {
        int ret = poll(pfd, 3, 20);
        if (ret <= 0) continue;

        /* 1. Touchscreen Event Processing */
        if (pfd[0].revents & POLLIN) {
            int n = read(touch_fd, &ev, sizeof(ev));
            if (n == (int)sizeof(ev)) {
                if (ev.type == EV_ABS) {
                    /* The stock BNRV700 driver has appeared in both forms:
                     * MT-A (ABS_MT_POSITION_X/Y) and legacy single-touch
                     * (ABS_X/Y).  Accept both so page taps retain their
                     * actual coordinates on either kernel/input build. */
                    if (ev.code == ABS_MT_POSITION_X || ev.code == ABS_X) {
                        cur_x = ev.value;
                    } else if (ev.code == ABS_MT_POSITION_Y || ev.code == ABS_Y) {
                        cur_y = ev.value;
                    }
                } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    cur_down = (ev.value != 0);
                    touch_count = cur_down ? 1 : 0;
                } else if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
                    int mapped_x = 1403 - cur_y;
                    int mapped_y = cur_x;
                    if (mapped_x < 0) mapped_x = 0;
                    if (mapped_x >= PANEL_WIDTH) mapped_x = PANEL_WIDTH - 1;
                    if (mapped_y < 0) mapped_y = 0;
                    if (mapped_y >= PANEL_HEIGHT) mapped_y = PANEL_HEIGHT - 1;

                    if (osk_active) {
                        if (mapped_y >= OSK_Y) {
                            /* Touch inside OSK */
                            if (cur_down && !touch_down) {
                                touch_down = true;
                                handle_osk_touch(mapped_x, mapped_y);
                            } else if (!cur_down && touch_down) {
                                touch_down = false;
                            }
                            continue;
                        } else {
                            /* Touch outside/above OSK: dismiss OSK */
                            if (cur_down && !touch_down) {
                                hide_osk();
                                touch_down = true;
                                if (mapped_y >= 75) {
                                    simulate_click(mapped_x, mapped_y);
                                }
                                continue;
                            } else if (!cur_down && touch_down) {
                                touch_down = false;
                                continue;
                            }
                        }
                    } else {
                        /* 1. URL bar tap hotspot: open OSK directly (Y < 75, X >= 140) */
                        if (mapped_y < 75 && mapped_x >= 140 && cur_down && !touch_down) {
                            touch_down = true;
                            g_url_bar_focused = true;
                            simulate_click(300, 35);
                            osk_inject_key(SDLK_END, 0);
                            show_osk();
                            continue;
                        }

                        /* 2. Bottom-right corner toggle hotspot (X >= 1320, Y >= 1800) */
                        if (mapped_x >= 1320 && mapped_y >= 1800 && cur_down && !touch_down) {
                            touch_down = true;
                            show_osk();
                            continue;
                        }
                    }

                    /* Regular NetSurf browser touch events */
                    if (mapped_y >= 75) {
                        g_url_bar_focused = false;
                    }

                    if (cur_down && !touch_down) {
                        touch_down = true;
                        /* fbtk_click() hit-tests the internal cursor, not
                         * SDL_MouseButtonEvent.{x,y}. */
                        queue_touch_motion(mapped_x, mapped_y);
                        SDL_Event event;
                        memset(&event, 0, sizeof(event));
                        event.type = SDL_MOUSEBUTTONDOWN;
                        event.button.button = SDL_BUTTON_LEFT;
                        event.button.state = SDL_PRESSED;
                        event.button.x = mapped_x;
                        event.button.y = mapped_y;
                        queue_event(&event);
                    } else if (!cur_down && touch_down) {
                        touch_down = false;
                        SDL_Event event;
                        memset(&event, 0, sizeof(event));
                        event.type = SDL_MOUSEBUTTONUP;
                        event.button.button = SDL_BUTTON_LEFT;
                        event.button.state = SDL_RELEASED;
                        event.button.x = mapped_x;
                        event.button.y = mapped_y;
                        queue_event(&event);
                    } else if (touch_down && (mapped_x != last_touch_x || mapped_y != last_touch_y)) {
                        SDL_Event event;
                        memset(&event, 0, sizeof(event));
                        event.type = SDL_MOUSEMOTION;
                        event.motion.state = SDL_PRESSED;
                        event.motion.x = mapped_x;
                        event.motion.y = mapped_y;
                        event.motion.xrel = mapped_x - last_touch_x;
                        event.motion.yrel = mapped_y - last_touch_y;
                        queue_event(&event);
                    }

                    last_touch_x = mapped_x;
                    last_touch_y = mapped_y;
                }
            }
        }

        /* 2. Hardware Buttons */
        if (pfd[1].revents & POLLIN) {
            int n = read(keys_fd, &ev, sizeof(ev));
            if (n == (int)sizeof(ev) && ev.type == EV_KEY && ev.value == 1) {
                if (ev.code == 191) {
                    /* Top Left: Page Up */
                    osk_inject_key(SDLK_PAGEUP, 0);
                } else if (ev.code == 192) {
                    /* Bottom Left: Page Down */
                    osk_inject_key(SDLK_PAGEDOWN, 0);
                } else if (ev.code == 193) {
                    /* Top Right: History Back (or hide OSK if active) */
                    if (osk_active) {
                        hide_osk();
                    } else {
                        /* NetSurf's default toolbar padding is 2px and the
                         * back icon is 22px wide: click its actual center. */
                        simulate_click(13, 35); /* NetSurf toolbar Back */
                    }
                } else if (ev.code == 194) {
                    /* Bottom Right: Toggle On-Screen Keyboard (OSK) */
                    toggle_osk();
                } else if (ev.code == 102) {
                    /* Home Tap: Focus URL bar and show OSK */
                    g_url_bar_focused = true;
                    simulate_click(300, 35);
                    osk_inject_key(SDLK_END, 0);
                    show_osk();
                }
            }
        }

        /* 3. External FIFO Input */
        if (pfd[2].revents & POLLIN) {
            int n = read(fifo_fd, fifo_buf, sizeof(fifo_buf) - 1);
            if (n > 0) {
                fifo_buf[n] = '\0';
                char *line = strtok(fifo_buf, "\r\n");
                while (line) {
                    handle_fifo_command(line);
                    line = strtok(NULL, "\r\n");
                }
            }
        }
    }
    return NULL;
}

/* SDL API Functions */

int SDL_Init(uint32_t flags) {
    fprintf(stderr, "[SDL_fb0_shim] SDL_Init called (flags: 0x%x)\n", flags);

    touch_fd = open(TOUCH_PATH, O_RDONLY | O_NONBLOCK);
    if (touch_fd < 0) {
        fprintf(stderr, "[SDL_fb0_shim] Warning: cannot open %s (%s)\n", TOUCH_PATH, strerror(errno));
    }

    keys_fd = open(KEYS_PATH, O_RDONLY | O_NONBLOCK);
    if (keys_fd < 0) {
        keys_fd = open("/dev/input/by-path/platform-gpio-keys-event", O_RDONLY | O_NONBLOCK);
    }
    if (keys_fd < 0) {
        fprintf(stderr, "[SDL_fb0_shim] Warning: cannot open keys node (%s)\n", strerror(errno));
    }

    /* Create and open control FIFO */
    mkfifo(FIFO_PATH, 0666);
    fifo_fd = open(FIFO_PATH, O_RDWR | O_NONBLOCK);
    if (fifo_fd < 0) {
        fprintf(stderr, "[SDL_fb0_shim] Warning: cannot open %s (%s)\n", FIFO_PATH, strerror(errno));
    }

    input_thread_running = true;
    pthread_create(&input_thread, NULL, input_worker, NULL);

    g_timer_thread_running = true;
    pthread_create(&g_timer_thread, NULL, timer_worker, NULL);

    return 0;
}

void SDL_Quit(void) {
    fprintf(stderr, "[SDL_fb0_shim] SDL_Quit called\n");
    if (g_timer_thread_running) {
        g_timer_thread_running = false;
        pthread_join(g_timer_thread, NULL);
    }
    if (input_thread_running) {
        input_thread_running = false;
        pthread_join(input_thread, NULL);
    }
    if (touch_fd >= 0) { close(touch_fd); touch_fd = -1; }
    if (keys_fd >= 0) { close(keys_fd); keys_fd = -1; }
    if (fifo_fd >= 0) { close(fifo_fd); fifo_fd = -1; }
    if (osk_backup) { free(osk_backup); osk_backup = NULL; }
    if (fb_mem && fb_mem != MAP_FAILED) {
        munmap(fb_mem, fb_size);
        fb_mem = NULL;
    }
    if (fb_fd >= 0) { close(fb_fd); fb_fd = -1; }
}

SDL_Surface *SDL_SetVideoMode(int width, int height, int bpp, uint32_t flags) {
    fprintf(stderr, "[SDL_fb0_shim] SDL_SetVideoMode: %dx%d @ %dbpp\n", width, height, bpp);

    if (fb_fd < 0) {
        fb_fd = open(FB_PATH, O_RDWR);
        if (fb_fd < 0) {
            fprintf(stderr, "[SDL_fb0_shim] Error: failed to open %s: %s\n", FB_PATH, strerror(errno));
            return NULL;
        }
    }

    fb_size = PANEL_STRIDE * PANEL_HEIGHT * (PANEL_BPP / 8);
    fb_mem = (uint8_t *)mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_mem == MAP_FAILED) {
        fprintf(stderr, "[SDL_fb0_shim] Error: mmap failed: %s\n", strerror(errno));
        close(fb_fd);
        fb_fd = -1;
        return NULL;
    }

    /* Setup PixelFormat: RGB565 */
    memset(&main_format, 0, sizeof(main_format));
    main_format.BitsPerPixel = 16;
    main_format.BytesPerPixel = 2;
    main_format.Rloss = 3;
    main_format.Gloss = 2;
    main_format.Bloss = 3;
    main_format.Rshift = 11;
    main_format.Gshift = 5;
    main_format.Bshift = 0;
    main_format.Rmask = 0xF800;
    main_format.Gmask = 0x07E0;
    main_format.Bmask = 0x001F;

    /* Setup Surface */
    memset(&main_surface, 0, sizeof(main_surface));
    main_surface.flags = flags;
    main_surface.format = &main_format;
    main_surface.w = PANEL_WIDTH;
    main_surface.h = PANEL_HEIGHT;
    main_surface.pitch = PANEL_STRIDE * 2; /* 2816 bytes */
    main_surface.pixels = fb_mem;
    main_surface.clip_rect.x = 0;
    main_surface.clip_rect.y = 0;
    main_surface.clip_rect.w = PANEL_WIDTH;
    main_surface.clip_rect.h = PANEL_HEIGHT;
    main_surface.refcount = 1;

    /* Completely clear framebuffer memory to solid white (0xFFFF) */
    memset(fb_mem, 0xFF, PANEL_STRIDE * PANEL_HEIGHT * 2);

    /* Initialize target URL from cmdline */
    init_current_url();

    /* Draw initial crisp URL bar overlay */
    draw_url_bar_overlay();

    /* Initial GC16 hardware refresh to wipe out previous reader ghosting */
    epdc_refresh_full(0, 0, PANEL_WIDTH, PANEL_HEIGHT);

    return &main_surface;
}

void SDL_UpdateRect(SDL_Surface *screen, int32_t x, int32_t y, uint32_t w, uint32_t h) {
    if (fb_fd < 0) return;
    if (w == 0 || h == 0) {
        x = 0; y = 0; w = PANEL_WIDTH; h = PANEL_HEIGHT;
    }
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x >= PANEL_WIDTH || y >= PANEL_HEIGHT || w <= 0 || h <= 0) return;
    if (x + w > PANEL_WIDTH) w = PANEL_WIDTH - x;
    if (y + h > PANEL_HEIGHT) h = PANEL_HEIGHT - y;

    /* Always ensure the URL bar has large crisp text */
    if (y < 75 && (x + (int)w) > 140) {
        draw_url_bar_overlay();
    }

    /* If OSK is active, intercept any browser drawing that intersects the OSK */
    if (osk_active) {
        if (y + (int)h > OSK_Y) {
            /* Update background backup with the newly rendered page pixels */
            if (osk_backup) {
                int start_y = (y > OSK_Y) ? y : OSK_Y;
                int end_y = (y + (int)h < PANEL_HEIGHT) ? (y + (int)h) : PANEL_HEIGHT;
                for (int cy = start_y; cy < end_y; cy++) {
                    memcpy(&osk_backup[(cy - OSK_Y) * PANEL_STRIDE],
                           &((uint16_t *)fb_mem)[cy * PANEL_STRIDE],
                           PANEL_STRIDE * sizeof(uint16_t));
                }
            }
            /* Re-assert keyboard directly over fb_mem so NetSurf never hides the keys */
            draw_osk();
            if (y >= OSK_Y) {
                /* NetSurf only updated below OSK_Y: do not refresh OSK area with page content */
                return;
            }
            /* Clip browser refresh to area above keyboard */
            h = OSK_Y - y;
        }
    }


    /* Full GC16 refresh on first big frame to completely eliminate ghosting */
    static int first_full_frame = 1;
    if (first_full_frame && w >= 1000 && h >= 1000) {
        epdc_refresh_full(x, y, w, h);
        first_full_frame = 0;
    } else {
        /* 16-level grayscale partial update so links, colors, and borders are visible */
        epdc_refresh_gray(x, y, w, h);
    }
}

int SDL_Flip(SDL_Surface *screen) {
    SDL_UpdateRect(screen, 0, 0, 0, 0);
    return 0;
}

int SDL_PollEvent(SDL_Event *event) {
    if (!event) return 0;
    return dequeue_event(event) ? 1 : 0;
}

int SDL_WaitEvent(SDL_Event *event) {
    if (!event) return 0;
    while (1) {
        if (dequeue_event(event)) return 1;
        usleep(5000);
    }
}

int SDL_PushEvent(SDL_Event *event) {
    if (!event) return -1;
    queue_event(event);
    return 0;
}

int SDL_EnableKeyRepeat(int delay, int interval) {
    (void)delay; (void)interval;
    return 0;
}

int SDL_ShowCursor(int toggle) {
    (void)toggle;
    return 0;
}

char *SDL_GetError(void) {
    return "";
}

int SDL_UpperBlit(SDL_Surface *src, SDL_Rect *srcrect, SDL_Surface *dst, SDL_Rect *dstrect) {
    (void)src; (void)srcrect; (void)dst; (void)dstrect;
    return 0;
}

int SDL_SetColors(SDL_Surface *surface, SDL_Color *colors, int firstcolor, int ncolors) {
    (void)surface; (void)colors; (void)firstcolor; (void)ncolors;
    return 1;
}

static uint64_t get_time_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (ts.tv_nsec / 1000000);
}

static void *timer_worker(void *arg) {
    (void)arg;
    while (g_timer_thread_running) {
        usleep(5000); /* 5ms resolution */
        if (!g_timer_thread_running) break;
        uint64_t now = get_time_ms();
        pthread_mutex_lock(&g_timer_mutex);
        for (int i = 0; i < MAX_TIMERS; i++) {
            if (g_timers[i].active && g_timers[i].cb && now >= g_timers[i].next_expire_ms) {
                SDL_NewTimerCallback cb = g_timers[i].cb;
                void *param = g_timers[i].param;
                uint32_t interval = g_timers[i].interval_ms;
                pthread_mutex_unlock(&g_timer_mutex);

                uint32_t next = cb(interval, param);

                pthread_mutex_lock(&g_timer_mutex);
                if (g_timers[i].active) {
                    if (next == 0) {
                        g_timers[i].active = false;
                        g_timers[i].cb = NULL;
                    } else {
                        g_timers[i].interval_ms = next;
                        g_timers[i].next_expire_ms = get_time_ms() + next;
                    }
                }
            }
        }
        pthread_mutex_unlock(&g_timer_mutex);
    }
    return NULL;
}

SDL_TimerID SDL_AddTimer(uint32_t interval, SDL_NewTimerCallback callback, void *param) {
    if (!callback) return NULL;
    pthread_mutex_lock(&g_timer_mutex);
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!g_timers[i].active) {
            g_timers[i].interval_ms = interval;
            g_timers[i].next_expire_ms = get_time_ms() + interval;
            g_timers[i].cb = callback;
            g_timers[i].param = param;
            g_timers[i].active = true;
            pthread_mutex_unlock(&g_timer_mutex);
            return &g_timers[i];
        }
    }
    pthread_mutex_unlock(&g_timer_mutex);
    return NULL;
}

bool SDL_RemoveTimer(SDL_TimerID id) {
    if (!id) return false;
    pthread_mutex_lock(&g_timer_mutex);
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (&g_timers[i] == id) {
            g_timers[i].active = false;
            g_timers[i].cb = NULL;
            pthread_mutex_unlock(&g_timer_mutex);
            return true;
        }
    }
    pthread_mutex_unlock(&g_timer_mutex);
    return false;
}
