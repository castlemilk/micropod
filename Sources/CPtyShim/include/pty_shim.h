#ifndef MICROPOD_PTY_SHIM_H
#define MICROPOD_PTY_SHIM_H

#include <sys/types.h>

/*
 * Spawns `argv[0]` attached to a fresh pseudo-terminal, which becomes the
 * child's controlling terminal. Returns the child pid, with the master fd
 * written to *master_out. Returns -1 on failure.
 *
 * The child's stdin/stdout/stderr are the pty slave. This gives full
 * interactive terminal semantics (job control, SIGINT from ^C, etc.).
 */
int micropod_spawn_pty(char *const argv[], char *const envp[], const char *cwd, int *master_out);

#endif
