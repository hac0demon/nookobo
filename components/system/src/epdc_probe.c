/*
 * epdc_probe.c - BNRV700 EPDC / framebuffer health probe (device-check).
 *
 * Verifies the i.MX6 EPDC V1 path end to end on the live device:
 *   1. /dev/fb0 opens
 *   2. Framebuffer geometry matches 1404x1872 @ 16bpp, 2816-byte stride
 *   3. A full-frame MXCFB_SEND_UPDATE_V1 (GC16) is accepted by the kernel
 *   4. MXCFB_WAIT_FOR_UPDATE_COMPLETE reports completion
 *
 * The probe silences EPDC auto-refresh (epdc_auto_update sysfs node) while
 * the round-trip runs, so marker waits are not disturbed by other
 * framebuffer clients (e.g. netSurf's auto-refresh). The previous state is
 * restored before exit.
 *
 * NOTE: on a healthy system the probe triggers one visible full-frame
 * panel refresh (GC16 flash).
 *
 * Exits 0 with "EPDC-PROBE: PASS" lines when healthy, 1 otherwise.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

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

struct mxcfb_update_marker_data {
    uint32_t update_marker;
    uint32_t collision_test;
};

#define MXCFB_SEND_UPDATE_V1           0x4040462e
#define MXCFB_WAIT_FOR_UPDATE_COMPLETE 0xc008462f

#define EXPECT_XRES   1404
#define EXPECT_YRES   1872
#define EXPECT_BPP    16
#define EXPECT_STRIDE 2816 /* 1408 px * 2 bytes (16-byte aligned) */

static int g_fails = 0;

static void report(const char *what, int ok, const char *fmt, ...) {
    char detail[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(detail, sizeof(detail), fmt, ap);
    va_end(ap);
    if (!ok) g_fails = 1;
    printf("EPDC-PROBE: %s %s\n", ok ? "PASS" : "FAIL", what);
    if (detail[0]) printf("EPDC-PROBE:      %s\n", detail);
}

int main(void) {
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "EPDC-PROBE: FAIL open /dev/fb0 [%s]\n", strerror(errno));
        return 1;
    }
    report("open /dev/fb0", 1, "fd=%d", fd);

    struct fb_var_screeninfo vinfo;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) != 0) {
        report("FBIOGET_VSCREENINFO", 0, "%s", strerror(errno));
        close(fd);
        return 1;
    }
    report("geometry xres/yres",
           vinfo.xres == EXPECT_XRES && vinfo.yres == EXPECT_YRES,
           "%d x %d (expect %d x %d)",
           (int)vinfo.xres, (int)vinfo.yres, EXPECT_XRES, EXPECT_YRES);
    report("bits_per_pixel", vinfo.bits_per_pixel == EXPECT_BPP,
           "%d (expect %d)", (int)vinfo.bits_per_pixel, EXPECT_BPP);

    struct fb_fix_screeninfo finfo;
    if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) != 0) {
        report("FBIOGET_FSCREENINFO", 0, "%s", strerror(errno));
    } else {
        report("stride line_length", finfo.line_length == EXPECT_STRIDE,
               "%d (expect %d)", (int)finfo.line_length, EXPECT_STRIDE);
    }

    /* Silence EPDC auto-refresh for the duration of the round-trip;
     * restore the original value before exit. */
    const char *auto_path = "/sys/class/graphics/fb0/epdc_auto_update";
    int auto_orig = -1;
    FILE *af = fopen(auto_path, "r");
    if (af) {
        if (fscanf(af, "%d", &auto_orig) != 1) auto_orig = -1;
        fclose(af);
    }
    if (auto_orig >= 0) {
        af = fopen(auto_path, "w");
        if (af) {
            fprintf(af, "0\n");
            fclose(af);
        }
    }

    struct mxcfb_update_data_v1 upd;
    memset(&upd, 0, sizeof(upd));
    upd.update_region.top = 0;
    upd.update_region.left = 0;
    upd.update_region.width = EXPECT_XRES;
    upd.update_region.height = EXPECT_YRES;
    upd.waveform_mode = 2; /* GC16 */
    upd.update_mode = 1;   /* FULL */
    upd.update_marker = 1;
    upd.temp = 4096;       /* TEMP_USE_AMBIENT */
    upd.flags = 0;

    int ret = ioctl(fd, MXCFB_SEND_UPDATE_V1, &upd);
    if (ret != 0) {
        report("MXCFB_SEND_UPDATE_V1 full-frame", 0, "%s", strerror(errno));
    } else {
        struct mxcfb_update_marker_data marker;
        memset(&marker, 0, sizeof(marker));
        marker.update_marker = 1;
        int wret = ioctl(fd, MXCFB_WAIT_FOR_UPDATE_COMPLETE, &marker);
        if (wret != 0) {
            /* One retry: the kernel may have already consumed the marker
             * state between the update and the wait call. */
            usleep(500000);
            wret = ioctl(fd, MXCFB_WAIT_FOR_UPDATE_COMPLETE, &marker);
        }
        if (wret != 0) {
            report("MXCFB_WAIT_FOR_UPDATE_COMPLETE", 0,
                   "%s (marker=1, retried)", strerror(errno));
        } else {
            report("full-frame V1 update + wait", 1, "GC16 marker=1");
        }
    }

    if (auto_orig >= 0) {
        af = fopen(auto_path, "w");
        if (af) {
            fprintf(af, "%d\n", auto_orig);
            fclose(af);
        }
    }

    close(fd);
    if (g_fails) {
        printf("EPDC-PROBE: FAIL overall\n");
        return 1;
    }
    printf("EPDC-PROBE: PASS overall\n");
    return 0;
}
