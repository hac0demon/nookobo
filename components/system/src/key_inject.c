#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/input.h>
#include <linux/uinput.h>

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <keycode>\n", argv[0]);
        fprintf(stderr, "Keycodes: 104=PageDown, 109=PageUp, 174=Left, 175=Right, 28=Enter, 1=Esc\n");
        return 1;
    }

    int code = atoi(argv[1]);

    int fd = open("/dev/input/event2", O_WRONLY);
    if (fd < 0) {
        perror("open /dev/input/event2 (uinput virtual keys)");
        return 1;
    }

    struct input_event ev[3];
    memset(ev, 0, sizeof(ev));

    // Key down
    ev[0].type = EV_KEY; ev[0].code = code; ev[0].value = 1;
    ev[1].type = EV_SYN; ev[1].code = SYN_REPORT; ev[1].value = 0;
    write(fd, ev, 2 * sizeof(struct input_event));

    usleep(20000); // 20ms

    // Key up
    ev[0].type = EV_KEY; ev[0].code = code; ev[0].value = 0;
    ev[1].type = EV_SYN; ev[1].code = SYN_REPORT; ev[1].value = 0;
    write(fd, ev, 2 * sizeof(struct input_event));

    close(fd);
    printf("Injected key code %d\n", code);
    return 0;
}
