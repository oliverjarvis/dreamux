#include "DreamuxPTY.h"

#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>

pid_t dreamux_forkpty(int *master_fd, unsigned short cols, unsigned short rows) {
    struct winsize ws;
    ws.ws_row = rows ? rows : 24;
    ws.ws_col = cols ? cols : 80;
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    return forkpty(master_fd, NULL, NULL, &ws);
}

int dreamux_set_winsize(int master_fd,
                          unsigned short cols,
                          unsigned short rows,
                          unsigned short xpix,
                          unsigned short ypix) {
    struct winsize ws;
    ws.ws_col = cols;
    ws.ws_row = rows;
    ws.ws_xpixel = xpix;
    ws.ws_ypixel = ypix;
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}

int dreamux_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}
