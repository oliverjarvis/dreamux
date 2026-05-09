#ifndef CLAYSPACE_PTY_H
#define CLAYSPACE_PTY_H

#include <sys/types.h>
#include <sys/ioctl.h>
#include <termios.h>

// Fork a child with a pseudoterminal. On success, *master_fd is the master
// side of the PTY (read/write to communicate with the child) and the return
// value is the child's PID in the parent, or 0 in the child.
// Returns -1 on failure.
pid_t clayspace_forkpty(int *master_fd, unsigned short cols, unsigned short rows);

// Update the window size of the PTY so the child shell can SIGWINCH itself.
int clayspace_set_winsize(int master_fd,
                          unsigned short cols,
                          unsigned short rows,
                          unsigned short xpix,
                          unsigned short ypix);

// Set the FD_CLOEXEC flag on a file descriptor.
int clayspace_set_cloexec(int fd);

#endif
