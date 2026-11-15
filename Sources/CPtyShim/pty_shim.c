#include "pty_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>
#include <sys/sysctl.h>
#include <libproc.h>

int micropod_process_birth(pid_t pid, uid_t *uid, int64_t *seconds, int64_t *microseconds) {
    int query[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (pid <= 0 || sysctl(query, 4, &info, &size, NULL, 0) != 0) return -1;
    if (size == 0) return 1;
    if (size != sizeof(info) || info.kp_proc.p_pid != pid) return -1;
    *uid = info.kp_eproc.e_ucred.cr_uid;
    *seconds = info.kp_proc.p_starttime.tv_sec;
    *microseconds = info.kp_proc.p_starttime.tv_usec;
    return 0;
}

/* Refuse a full/truncated process inventory rather than treating it as idle. */
int micropod_uid_processes(uid_t uid, pid_t *pids, int capacity) {
    if (capacity <= 0 || capacity > 16384) { errno = EINVAL; return -1; }
    int size = capacity * (int)sizeof(pid_t);
    errno = 0;
    int bytes = proc_listpids(PROC_UID_ONLY, uid, pids, size);
    if (bytes < 0 || (bytes == 0 && errno != 0)) return -1;
    if (bytes >= size || bytes % sizeof(pid_t) != 0) { errno = EOVERFLOW; return -1; }
    return bytes / (int)sizeof(pid_t);
}
/* 1 = a kernel-observed zombie (cannot issue an action), -1 = unknown. */
int micropod_process_path(pid_t pid, char *path, int capacity) {
    int query[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(query, 4, &info, &size, NULL, 0) != 0 || size != sizeof(info)) return -1;
    if (info.kp_proc.p_stat == SZOMB) return 1;
    if (proc_pidpath(pid, path, capacity) <= 0) return -1;
    return 0;
}

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
