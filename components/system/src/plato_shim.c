#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>

#define RTLD_NEXT ((void *) -1l)
extern void *dlsym(void *handle, const char *symbol);

struct mxcfb_rect {
    uint32_t top;
    uint32_t left;
    uint32_t width;
    uint32_t height;
};

struct mxcfb_alt_buffer_data {
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
    struct mxcfb_alt_buffer_data alt_buffer_data;
};

struct mxcfb_update_data_v2 {
    struct mxcfb_rect update_region;
    uint32_t waveform_mode;
    uint32_t update_mode;
    uint32_t update_marker;
    int temp;
    unsigned int flags;
    int dither_mode;
    int quant_bit;
    struct mxcfb_alt_buffer_data alt_buffer_data;
};

struct mxcfb_alt_buffer_data_plato_v1 {
    const void *virt_addr;
    uint32_t phys_addr;
    uint32_t width;
    uint32_t height;
    struct mxcfb_rect alt_update_region;
};

struct mxcfb_update_data_plato_v1 {
    struct mxcfb_rect update_region;
    uint32_t waveform_mode;
    uint32_t update_mode;
    uint32_t update_marker;
    int temp;
    unsigned int flags;
    struct mxcfb_alt_buffer_data_plato_v1 alt_buffer_data;
};

struct mxcfb_update_marker_data {
    uint32_t update_marker;
    uint32_t collision_test;
};

#define MXCFB_SEND_UPDATE_V1 0x4040462e
#define MXCFB_SEND_UPDATE_PLATO_V1 0x4044462e
#define MXCFB_SEND_UPDATE_V2 0x4048462e
#define MXCFB_WAIT_FOR_UPDATE_COMPLETE_V2 0x4004462f
#define MXCFB_WAIT_FOR_UPDATE_COMPLETE_V1 3221767727UL /* 0xc008462f */

static int (*real_ioctl)(int, int, ...) = NULL;
static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static ssize_t (*real_read)(int, void *, size_t) = NULL;
static int (*real_close)(int) = NULL;
static int (*real_poll)(struct pollfd *, nfds_t, int) = NULL;
static ssize_t (*real_write)(int, const void *, size_t) = NULL;

/* Opt-in EPDC tracing: set PLATO_SHIM_LOG=/path/to/log to record every update rect. */
static int s_logfd = -2;

typedef struct { char b[384]; int n; } lbuf;

static void log_init(void) {
    if (s_logfd != -2) return;
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    const char *p = getenv("PLATO_SHIM_LOG");
    if ((!p || !*p) && access("/tmp/plato_shim_log_on", F_OK) == 0) p = "/tmp/plato_shim.log";
    s_logfd = (p && *p && real_open) ? real_open(p, O_WRONLY | O_CREAT | O_APPEND, 0666) : -1;
}

static void lb_str(lbuf *l, const char *s) {
    int n = strlen(s);
    if (l->n + n > (int)sizeof(l->b)) return;
    memcpy(l->b + l->n, s, n);
    l->n += n;
}

static void lb_u(lbuf *l, unsigned int v, int hexa) {
    char t[12];
    int n = 0;
    if (hexa) {
        t[n++] = '0'; t[n++] = 'x';
        int started = 0;
        for (int i = 28; i >= 0; i -= 4) {
            int d = (v >> i) & 0xf;
            if (!started && d == 0 && i > 0) continue;
            started = 1;
            t[n++] = (char)(d < 10 ? '0' + d : 'a' + d);
        }
    } else {
        if (v == 0) t[n++] = '0';
        while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
        for (int i = 0; i < n / 2; i++) { char c = t[i]; t[i] = t[n - 1 - i]; t[n - 1 - i] = c; }
    }
    if (l->n + n > (int)sizeof(l->b)) return;
    memcpy(l->b + l->n, t, n);
    l->n += n;
}

static void lb_i(lbuf *l, int v) {
    if (v < 0) { lb_str(l, "-"); lb_u(l, (unsigned int)(-v), 0); }
    else lb_u(l, (unsigned int)v, 0);
}

static void lb_flush(lbuf *l) {
    log_init();
    if (s_logfd < 0 || !real_write) return;
    if (l->n + 1 < (int)sizeof(l->b)) {
        l->b[l->n++] = '\n';
        real_write(s_logfd, l->b, l->n);
    }
}

static void log_rect(lbuf *l, const char *tag, struct mxcfb_rect r) {
    lb_str(l, tag); lb_u(l, r.top, 0); lb_str(l, ",");
    lb_u(l, r.left, 0); lb_str(l, ","); lb_u(l, r.width, 0); lb_str(l, "x");
    lb_u(l, r.height, 0); lb_str(l, " ");
}

static void log_update(lbuf *l, const char *tag, struct mxcfb_update_data_v1 *v1) {
    lb_str(l, tag);
    log_rect(l, " dst=", v1->update_region);
    lb_str(l, "wf="); lb_u(l, v1->waveform_mode, 0);
    lb_str(l, " mode="); lb_u(l, v1->update_mode, 0);
    lb_str(l, " flags="); lb_u(l, v1->flags, 1);
    lb_str(l, " marker="); lb_u(l, v1->update_marker, 0);
}

static void log_msg(const char *s) {
    log_init();
    if (s_logfd < 0 || !real_write) return;
    real_write(s_logfd, s, strlen(s));
}

struct plato_input_event {
    uint32_t tv_sec;
    uint32_t tv_usec;
    uint16_t type;
    uint16_t code;
    int32_t value;
};

#define SHIM_QUEUE_SIZE 128
static struct plato_input_event s_queue[SHIM_QUEUE_SIZE];
static int s_qhead = 0;
static int s_qtail = 0;
static int s_touch_fd = -1;
static int s_is_down = 0;
static int s_new_down = 0;
static int32_t s_tracking_id = 0;
static int32_t s_last_x = 0;
static int32_t s_last_y = 0;

static void enqueue_event(uint16_t type, uint16_t code, int32_t val, uint32_t sec, uint32_t usec) {
    int next = (s_qtail + 1) % SHIM_QUEUE_SIZE;
    if (next == s_qhead) {
        s_qhead = (s_qhead + 1) % SHIM_QUEUE_SIZE;
    }
    s_queue[s_qtail].tv_sec = sec;
    s_queue[s_qtail].tv_usec = usec;
    s_queue[s_qtail].type = type;
    s_queue[s_qtail].code = code;
    s_queue[s_qtail].value = val;
    s_qtail = next;
}

static int is_touch_fd(int fd) {
    if (fd < 0) return 0;
    if (fd == s_touch_fd) return 1;
    if (s_touch_fd >= 0) return 0;
    char path[64], link[128];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t len = readlink(path, link, sizeof(link) - 1);
    if (len > 0) {
        link[len] = '\0';
        if (strstr(link, "event1")) {
            s_touch_fd = fd;
            return 1;
        }
    }
    return 0;
}

__attribute__((constructor))
static void init_shim(void) {
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_open = dlsym(RTLD_NEXT, "open");
    real_open64 = dlsym(RTLD_NEXT, "open64");
    real_read = dlsym(RTLD_NEXT, "read");
    real_close = dlsym(RTLD_NEXT, "close");
    real_poll = dlsym(RTLD_NEXT, "poll");
    real_write = dlsym(RTLD_NEXT, "write");
    log_init();
    if (s_logfd >= 0) log_msg("=== shim load\n");
}

int ioctl(int fd, int request, ...) {
    if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");

    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    if (request == MXCFB_SEND_UPDATE_V2) {
        struct mxcfb_update_data_v2 *v2 = (struct mxcfb_update_data_v2 *)arg;
        struct mxcfb_update_data_v1 v1;
        memset(&v1, 0, sizeof(v1));
        v1.update_region = v2->update_region;
        v1.waveform_mode = v2->waveform_mode;
        v1.update_mode = v2->update_mode;
        v1.update_marker = v2->update_marker;
        v1.temp = v2->temp;
        v1.flags = v2->flags;
        v1.alt_buffer_data = v2->alt_buffer_data;

        int ret = real_ioctl(fd, MXCFB_SEND_UPDATE_V1, &v1);
        if (s_logfd != -1) {
            lbuf l; l.n = 0;
            log_update(&l, "SU2 ", &v1);
            log_rect(&l, "alt=", v1.alt_buffer_data.alt_update_region);
            lb_str(&l, "altw="); lb_u(&l, v1.alt_buffer_data.width, 0);
            lb_str(&l, " alth="); lb_u(&l, v1.alt_buffer_data.height, 0);
            lb_str(&l, " altpa="); lb_u(&l, v1.alt_buffer_data.phys_addr, 1);
            lb_str(&l, " -> "); lb_i(&l, ret);
            lb_flush(&l);
        }
        return ret;
    } else if (request == MXCFB_SEND_UPDATE_PLATO_V1) {
        struct mxcfb_update_data_plato_v1 *pv1 = (struct mxcfb_update_data_plato_v1 *)arg;
        struct mxcfb_update_data_v1 v1;
        memset(&v1, 0, sizeof(v1));
        v1.update_region = pv1->update_region;
        v1.waveform_mode = pv1->waveform_mode;
        v1.update_mode = pv1->update_mode;
        v1.update_marker = pv1->update_marker;
        v1.temp = pv1->temp;
        v1.flags = pv1->flags;
        v1.alt_buffer_data.phys_addr = pv1->alt_buffer_data.phys_addr;
        v1.alt_buffer_data.width = pv1->alt_buffer_data.width;
        v1.alt_buffer_data.height = pv1->alt_buffer_data.height;
        v1.alt_buffer_data.alt_update_region = pv1->alt_buffer_data.alt_update_region;

        int ret = real_ioctl(fd, MXCFB_SEND_UPDATE_V1, &v1);
        if (s_logfd != -1) {
            lbuf l; l.n = 0;
            log_update(&l, "SUP ", &v1);
            log_rect(&l, "alt=", pv1->alt_buffer_data.alt_update_region);
            lb_str(&l, "altw="); lb_u(&l, pv1->alt_buffer_data.width, 0);
            lb_str(&l, " alth="); lb_u(&l, pv1->alt_buffer_data.height, 0);
            lb_str(&l, " altpa="); lb_u(&l, pv1->alt_buffer_data.phys_addr, 1);
            lb_str(&l, " virt="); lb_u(&l, (unsigned int)(uintptr_t)pv1->alt_buffer_data.virt_addr, 1);
            lb_str(&l, " -> "); lb_i(&l, ret);
            lb_flush(&l);
        }
        return ret;
    } else if (request == MXCFB_WAIT_FOR_UPDATE_COMPLETE_V2) {
        uint32_t marker = 0;
        if (arg) marker = *(uint32_t *)arg;
        struct mxcfb_update_marker_data md;
        md.update_marker = marker;
        md.collision_test = 0;
        int ret = real_ioctl(fd, MXCFB_WAIT_FOR_UPDATE_COMPLETE_V1, &md);
        if (s_logfd != -1) {
            lbuf l; l.n = 0;
            lb_str(&l, "WU  marker="); lb_u(&l, marker, 0);
            lb_str(&l, " collide="); lb_u(&l, md.collision_test, 0);
            lb_str(&l, " -> "); lb_i(&l, ret);
            lb_flush(&l);
        }
        return ret;
    } else if (request == FBIOPAN_DISPLAY) {
        struct fb_var_screeninfo *var = (struct fb_var_screeninfo *)arg;
        int ret = real_ioctl(fd, request, arg);
        if (s_logfd != -1 && var) {
            lbuf l; l.n = 0;
            lb_str(&l, "PAN xoff="); lb_u(&l, var->xoffset, 0);
            lb_str(&l, " yoff="); lb_u(&l, var->yoffset, 0);
            lb_str(&l, " mode="); lb_u(&l, var->vmode, 1);
            lb_str(&l, " -> "); lb_i(&l, ret);
            lb_flush(&l);
        }
        return ret;
    } else if (request == FBIOPUT_VSCREENINFO) {
        struct fb_var_screeninfo *var = (struct fb_var_screeninfo *)arg;
        if (var) {
            /* Remap rotation by 180 degrees: (rotate + 2) % 4 for BNRV700 panel */
            var->rotate = (var->rotate + 2) % 4;
            int ret = real_ioctl(fd, request, var);
            var->rotate = (var->rotate + 2) % 4;
            if (s_logfd != -1) {
                lbuf l; l.n = 0;
                lb_str(&l, "PUT v="); lb_u(&l, var->xres, 0); lb_str(&l, "x"); lb_u(&l, var->yres, 0);
                lb_str(&l, " virt="); lb_u(&l, var->xres_virtual, 0); lb_str(&l, "x"); lb_u(&l, var->yres_virtual, 0);
                lb_str(&l, " off="); lb_u(&l, var->xoffset, 0); lb_str(&l, ","); lb_u(&l, var->yoffset, 0);
                lb_str(&l, " rot="); lb_u(&l, var->rotate, 0);
                lb_str(&l, " bpp="); lb_u(&l, var->bits_per_pixel, 0);
                lb_str(&l, " -> "); lb_i(&l, ret);
                lb_flush(&l);
            }
            return ret;
        }
    } else if (request == FBIOGET_VSCREENINFO) {
        int ret = real_ioctl(fd, request, arg);
        struct fb_var_screeninfo *var = (struct fb_var_screeninfo *)arg;
        if (ret == 0 && var) {
            /* Report rotation back to Plato mapped by 180 degrees */
            var->rotate = (var->rotate + 2) % 4;
            if (s_logfd != -1) {
                lbuf l; l.n = 0;
                lb_str(&l, "GET v="); lb_u(&l, var->xres, 0); lb_str(&l, "x"); lb_u(&l, var->yres, 0);
                lb_str(&l, " virt="); lb_u(&l, var->xres_virtual, 0); lb_str(&l, "x"); lb_u(&l, var->yres_virtual, 0);
                lb_str(&l, " off="); lb_u(&l, var->xoffset, 0); lb_str(&l, ","); lb_u(&l, var->yoffset, 0);
                lb_str(&l, " rot="); lb_u(&l, var->rotate, 0);
                lb_str(&l, " bpp="); lb_u(&l, var->bits_per_pixel, 0);
                lb_flush(&l);
            }
        }
        return ret;
    } else if (request == EVIOCGRAB) {
        /* Never let Plato exclusively grab event nodes so supervisor/switcher can share touch */
        return 0;
    }

    return real_ioctl(fd, request, arg);
}

static int handle_open(const char *pathname, int flags, mode_t mode, int is_64) {
    if (pathname && strstr(pathname, "als_vis_data")) {
        /* Create dummy als_vis_data if hardware light sensor is absent */
        int fd_als = real_open ? real_open("/tmp/als_vis_data", O_RDWR | O_CREAT, 0666)
                               : (real_open64 ? real_open64("/tmp/als_vis_data", O_RDWR | O_CREAT, 0666) : -1);
        if (fd_als >= 0) {
            write(fd_als, "100\n", 4);
            lseek(fd_als, 0, SEEK_SET);
            return fd_als;
        }
    }

    int ret = is_64 ? (real_open64 ? real_open64(pathname, flags, mode) : (real_open ? real_open(pathname, flags, mode) : -1))
                    : (real_open ? real_open(pathname, flags, mode) : (real_open64 ? real_open64(pathname, flags, mode) : -1));

    if (ret < 0 && pathname && strstr(pathname, "rtc0")) {
        /* If /dev/rtc0 is busy or unavailable, open /dev/null fallback so caller proceeds */
        return is_64 ? (real_open64 ? real_open64("/dev/null", flags, mode) : real_open("/dev/null", flags, mode))
                     : (real_open ? real_open("/dev/null", flags, mode) : real_open64("/dev/null", flags, mode));
    }

    if (ret >= 0 && pathname && strstr(pathname, "event1")) {
        s_touch_fd = ret;
        s_qhead = 0;
        s_qtail = 0;
        s_is_down = 0;
        s_new_down = 0;
        s_tracking_id = 0;
        s_last_x = 0;
        s_last_y = 0;
    }

    return ret;
}

int open(const char *pathname, int flags, ...) {
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    return handle_open(pathname, flags, mode, 0);
}

int open64(const char *pathname, int flags, ...) {
    if (!real_open64) real_open64 = dlsym(RTLD_NEXT, "open64");

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    return handle_open(pathname, flags, mode, 1);
}

int close(int fd) {
    if (!real_close) real_close = dlsym(RTLD_NEXT, "close");
    if (fd == s_touch_fd) {
        s_touch_fd = -1;
        s_qhead = 0;
        s_qtail = 0;
        s_is_down = 0;
        s_new_down = 0;
    }
    return real_close(fd);
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout) {
    if (!real_poll) real_poll = dlsym(RTLD_NEXT, "poll");

    if (s_touch_fd >= 0 && s_qhead != s_qtail) {
        int found = 0;
        for (nfds_t i = 0; i < nfds; i++) {
            if (fds[i].fd == s_touch_fd && (fds[i].events & POLLIN)) {
                fds[i].revents = POLLIN;
                found++;
            } else {
                fds[i].revents = 0;
            }
        }
        if (found > 0) {
            return found;
        }
    }

    return real_poll(fds, nfds, timeout);
}

ssize_t read(int fd, void *buf, size_t count) {
    if (!real_read) real_read = dlsym(RTLD_NEXT, "read");

    if (is_touch_fd(fd)) {
        while (s_qhead == s_qtail) {
            struct plato_input_event raw[16];
            ssize_t n = real_read(fd, raw, sizeof(raw));
            if (n <= 0) {
                return n;
            }
            int num_raw = (int)(n / sizeof(struct plato_input_event));
            for (int i = 0; i < num_raw; i++) {
                uint32_t sec = raw[i].tv_sec;
                uint32_t usec = raw[i].tv_usec;
                if (raw[i].type == EV_ABS) {
                    if (raw[i].code == ABS_MT_TRACKING_ID) {
                        if (raw[i].value >= 0) {
                            s_tracking_id = raw[i].value;
                        }
                    } else if (raw[i].code == ABS_MT_POSITION_X) {
                        s_last_x = raw[i].value;
                    } else if (raw[i].code == ABS_MT_POSITION_Y) {
                        s_last_y = raw[i].value;
                    }
                } else if (raw[i].type == EV_KEY) {
                    if (raw[i].code == BTN_TOUCH) {
                        s_new_down = (raw[i].value != 0);
                    }
                } else if (raw[i].type == EV_SYN && raw[i].code == SYN_REPORT) {
                    if (!s_is_down && s_new_down) {
                        s_is_down = 1;
                        enqueue_event(EV_ABS, ABS_MT_TRACKING_ID, s_tracking_id, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_X, s_last_x, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_Y, s_last_y, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_TOUCH_MAJOR, 100, sec, usec);
                        enqueue_event(EV_SYN, SYN_REPORT, 0, sec, usec);
                    } else if (s_is_down && s_new_down) {
                        enqueue_event(EV_ABS, ABS_MT_TRACKING_ID, s_tracking_id, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_X, s_last_x, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_Y, s_last_y, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_TOUCH_MAJOR, 100, sec, usec);
                        enqueue_event(EV_SYN, SYN_REPORT, 0, sec, usec);
                    } else if (s_is_down && !s_new_down) {
                        s_is_down = 0;
                        enqueue_event(EV_ABS, ABS_MT_TRACKING_ID, s_tracking_id, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_X, s_last_x, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_POSITION_Y, s_last_y, sec, usec);
                        enqueue_event(EV_ABS, ABS_MT_TOUCH_MAJOR, 0, sec, usec);
                        enqueue_event(EV_SYN, SYN_REPORT, 0, sec, usec);
                    }
                }
            }
        }

        struct plato_input_event *out = (struct plato_input_event *)buf;
        int max_out = (int)(count / sizeof(struct plato_input_event));
        int copied = 0;
        while (copied < max_out && s_qhead != s_qtail) {
            out[copied++] = s_queue[s_qhead];
            s_qhead = (s_qhead + 1) % SHIM_QUEUE_SIZE;
        }
        return copied * (ssize_t)sizeof(struct plato_input_event);
    }

    return real_read(fd, buf, count);
}
