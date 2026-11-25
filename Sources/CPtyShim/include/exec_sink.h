#ifndef MICROPOD_EXEC_SINK_H
#define MICROPOD_EXEC_SINK_H

#include <stddef.h>

typedef struct micropod_exec_sink micropod_exec_sink;

/* Owns CLOEXEC duplicates of the output descriptors. Use -1 to discard a stream. */
int micropod_exec_sink_create(int stdout_fd, int stderr_fd, micropod_exec_sink **result);

/*
 * Writes a complete buffer to stream 1 (stdout) or 2 (stderr). One caller
 * writes at a time. The sink borrows the bytes only until this call returns.
 */
int micropod_exec_sink_write(micropod_exec_sink *sink, int stream, const void *bytes, size_t count);

/* May run concurrently with a write. A cancelled write returns ECANCELED. */
void micropod_exec_sink_cancel(micropod_exec_sink *sink);

/* Called after all other callers have returned. Joins the writer if it started. */
void micropod_exec_sink_destroy(micropod_exec_sink *sink);

typedef struct micropod_exec_input micropod_exec_input;

/* Copies source_fd to socket_fd using owned aliases, half-closing on EOF. Use -1 for EOF. */
int micropod_exec_input_start(int source_fd, int socket_fd, micropod_exec_input **result);

/* Cancels, joins and destroys the input pump. Returns a copy error or zero. */
int micropod_exec_input_stop(micropod_exec_input *input);

#endif
