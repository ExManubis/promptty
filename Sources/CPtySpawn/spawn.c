#include "CPtySpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t promptty_pty_spawn(char *const argv[], char *const envp[], const char *cwd,
                         unsigned short cols, unsigned short rows,
                         unsigned short width_px, unsigned short height_px,
                         int *master_out) {
    struct winsize size = {.ws_row = rows, .ws_col = cols, .ws_xpixel = width_px, .ws_ypixel = height_px};
    int master = -1;
    // Before forking: nothing below may allocate in the child.
    int max_fd = (int)sysconf(_SC_OPEN_MAX);
    if (max_fd < 0 || max_fd > 65536) max_fd = 65536;

    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) return -1;

    if (pid == 0) {
        // The child: forkpty made a new session with the pty's slave side as its controlling
        // terminal and as stdin, stdout and stderr.
        struct termios mode;
        if (tcgetattr(STDIN_FILENO, &mode) == 0) {
            mode.c_iflag |= IUTF8;
            tcsetattr(STDIN_FILENO, TCSANOW, &mode);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        struct sigaction defaults;
        memset(&defaults, 0, sizeof(defaults));
        defaults.sa_handler = SIG_DFL;
        for (int signal = 1; signal < NSIG; signal++) {
            if (signal == SIGKILL || signal == SIGSTOP) continue;
            sigaction(signal, &defaults, NULL);
        }
        // The daemon's other ptys and sockets stay its own.
        for (int fd = STDERR_FILENO + 1; fd < max_fd; fd++) close(fd);
        if (cwd != NULL && cwd[0] != '\0') chdir(cwd);
        execve(argv[0], argv, envp);
        _exit(127);
    }

    // The parent: the master side, not inherited by later children, never blocking.
    fcntl(master, F_SETFD, FD_CLOEXEC);
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    *master_out = master;
    return pid;
}

int promptty_pty_name(int master, char *buffer, size_t size) {
    // ptsname_r, not ptsname: the daemon reads names on more than one thread.
    return ptsname_r(master, buffer, size);
}
