#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/input.h>
#include <sys/ioctl.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <x> <y>\n", argv[0]);
        fprintf(stderr, "Injects touch event at logical coordinates (0-1403, 0-1871)\n");
        return 1;
    }

    int x = atoi(argv[1]);
    int y = atoi(argv[2]);

    // Map logical (portrait) to physical (landscape) coordinates
    // Physical panel: 1872 x 1404, rotated 180° (rotate=1 in kernel)
    // Logical: 1404 x 1872
    // Mapping: physical_x = y, physical_y = 1403 - x (for rotate=1 + 180°)
    int phys_x = y;
    int phys_y = 1403 - x;

    int fd = open("/dev/input/event1", O_WRONLY);
    if (fd < 0) {
        perror("open /dev/input/event1");
        return 1;
    }

    struct input_event ev[4];
    memset(ev, 0, sizeof(ev));

    // Touch down
    ev[0].type = EV_ABS; ev[0].code = ABS_MT_SLOT; ev[0].value = 0;
    ev[1].type = EV_ABS; ev[1].code = ABS_MT_TRACKING_ID; ev[1].value = 0;
    ev[2].type = EV_ABS; ev[2].code = ABS_MT_POSITION_X; ev[2].value = phys_x;
    ev[3].type = EV_ABS; ev[3].code = ABS_MT_POSITION_Y; ev[3].value = phys_y;
    write(fd, ev, 4 * sizeof(struct input_event));

    ev[0].type = EV_ABS; ev[0].code = ABS_MT_TOUCH_MAJOR; ev[0].value = 100;
    ev[1].type = EV_ABS; ev[1].code = ABS_MT_WIDTH_MAJOR; ev[1].value = 10;
    ev[2].type = EV_KEY; ev[2].code = BTN_TOUCH; ev[2].value = 1;
    ev[3].type = EV_SYN; ev[3].code = SYN_REPORT; ev[3].value = 0;
    write(fd, ev, 4 * sizeof(struct input_event));

    usleep(50000); // 50ms hold

    // Touch up
    ev[0].type = EV_ABS; ev[0].code = ABS_MT_SLOT; ev[0].value = 0;
    ev[1].type = EV_ABS; ev[1].code = ABS_MT_TRACKING_ID; ev[1].value = -1;
    ev[2].type = EV_KEY; ev[2].code = BTN_TOUCH; ev[2].value = 0;
    ev[3].type = EV_SYN; ev[3].code = SYN_REPORT; ev[3].value = 0;
    write(fd, ev, 4 * sizeof(struct input_event));

    close(fd);
    printf("Injected touch at logical (%d,%d) -> physical (%d,%d)\n", x, y, phys_x, phys_y);
    return 0;
}
