#ifndef MICROPOD_PTY_SHIM_H
#define MICROPOD_PTY_SHIM_H

#include <sys/types.h>
#include <stdint.h>

/*
 * Spawns `argv[0]` attached to a fresh pseudo-terminal, which becomes the
 * child's controlling terminal. Returns the child pid, with the master fd
 * written to *master_out. Returns -1 on failure.
 *
 * The child's stdin/stdout/stderr are the pty slave. This gives full
 * interactive terminal semantics (job control, SIGINT from ^C, etc.).
 */
int micropod_spawn_pty(char *const argv[], char *const envp[], const char *cwd, int *master_out);

/* 0 = observed incarnation, 1 = kernel-confirmed absence, -1 = unknown. */
int micropod_process_birth(pid_t pid, uid_t *uid, int64_t *seconds, int64_t *microseconds);

int micropod_uid_processes(uid_t uid, pid_t *pids, int capacity);
int micropod_process_path(pid_t pid, char *path, int capacity);

#endif
