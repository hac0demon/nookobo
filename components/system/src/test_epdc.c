#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/ioctl.h>

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

#define MXCFB_SEND_UPDATE_V1 0x4040462e

int main(int argc, char **argv) {
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) {
        perror("open /dev/fb0");
        return 1;
    }
    int waveform = (argc > 1) ? atoi(argv[1]) : 257; // default AUTO (257)
    int update_mode = (argc > 2) ? atoi(argv[2]) : 0; // default PARTIAL (0)
    int flags = (argc > 3) ? atoi(argv[3]) : 0;

    struct mxcfb_update_data_v1 upd;
    memset(&upd, 0, sizeof(upd));
    upd.update_region.top = 0;
    upd.update_region.left = 0;
    upd.update_region.width = 1404;
    upd.update_region.height = 1872;
    upd.waveform_mode = waveform;
    upd.update_mode = update_mode;
    upd.temp = 0x1001;
    upd.flags = flags;

    int ret = ioctl(fd, MXCFB_SEND_UPDATE_V1, &upd);
    printf("EPDC update waveform=%d update_mode=%d flags=%d ret=%d\n", waveform, update_mode, flags, ret);
    close(fd);
    return 0;
}
