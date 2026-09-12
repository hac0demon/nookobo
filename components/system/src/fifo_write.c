#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command>\n", argv[0]);
        return 1;
    }

    int fd = open("/data/linuxroot/tmp/netsurf_input.fifo", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open FIFO");
        return 1;
    }

    char buf[256];
    snprintf(buf, sizeof(buf), "%s\n", argv[1]);
    ssize_t n = write(fd, buf, strlen(buf));
    if (n < 0) {
        perror("write FIFO");
        close(fd);
        return 1;
    }

    printf("Wrote %zd bytes to FIFO: %s\n", n, buf);
    close(fd);
    return 0;
}
