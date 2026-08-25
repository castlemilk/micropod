#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int micropod_spawn_pty(char *const argv[], char *const envp[], const char *cwd, int *master_out) {
    int master = -1, slave = -1;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0) {
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        close(slave);
        return -1;
    }

    if (pid == 0) {
        /* Child: detach from session and claim the pty as controlling terminal. */
        if (setsid() < 0) _exit(127);
        if (ioctl(slave, TIOCSCTTY, 0) < 0) _exit(127);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        close(master);
        if (cwd != NULL && cwd[0] != '\0' && chdir(cwd) != 0) _exit(127);
        execve(argv[0], argv, envp);
        _exit(127);
    }

    close(slave);
    *master_out = master;
    return (int)pid;
}
