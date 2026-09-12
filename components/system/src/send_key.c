#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <linux/input.h>

struct raw_ev {
    uint32_t sec;
    uint32_t usec;
    uint16_t type;
    uint16_t code;
    int32_t value;
};

static void emit(int fd, uint16_t type, uint16_t code, int32_t val) {
    struct raw_ev ev = {0, 0, type, code, val};
    write(fd, &ev, sizeof(ev));
}

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/input/event0";
    int code = argc > 2 ? atoi(argv[2]) : 102; // KEY_HOME default
    int count = argc > 3 ? atoi(argv[3]) : 2;  // Double tap default

    int fd = open(dev, O_WRONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    printf("Sending %d tap(s) of key %d to %s...\n", count, code, dev);
    for (int i = 0; i < count; i++) {
        emit(fd, EV_KEY, code, 1);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        usleep(50000); // 50ms hold
        emit(fd, EV_KEY, code, 0);
        emit(fd, EV_SYN, SYN_REPORT, 0);
        if (i < count - 1) {
            usleep(120000); // 120ms between taps
        }
    }
    close(fd);
    printf("Done.\n");
    return 0;
}
