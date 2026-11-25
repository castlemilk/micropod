#include "exec_sink.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

struct exec_output {
    int fd;
    bool socket;
    bool discard;
    bool direct;
};

struct micropod_exec_sink {
    struct exec_output output[2];
    pthread_mutex_t lock;
    pthread_cond_t changed;
    pthread_t thread;
    bool started;
    bool cancelled;
    bool io_active;
    bool submitted;
    bool completed;
    int error;
    int stream;
    const unsigned char *bytes;
    size_t count;
};

static int await_io(int fd, short events) {
    struct pollfd event = { .fd = fd, .events = events };
    int result;
    do {
        pthread_testcancel();
        result = poll(&event, 1, -1);
    } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    if (event.revents & POLLNVAL) return EBADF;
    return 0;
}

static int write_buffer(struct exec_output output, const unsigned char *bytes, size_t count) {
    while (count > 0) {
        size_t length = count > INT_MAX ? INT_MAX : count;
        /* MSG_NOSIGNAL is per call. Pipes retain the caller's SIGPIPE disposition. */
        ssize_t written = output.socket
            ? send(output.fd, bytes, length, MSG_NOSIGNAL)
            : write(output.fd, bytes, length);
        if (written < 0) {
            int error = errno;
            if (error == EINTR) continue;
            if (error == EAGAIN || error == EWOULDBLOCK) {
                error = await_io(output.fd, POLLOUT);
                if (error == 0) continue;
            }
            return error;
        }
        if (written == 0) return EIO;
        bytes += (size_t)written;
        count -= (size_t)written;
    }
    return 0;
}

/* The lock is held when retiring a buffer. */
static void finish_request(micropod_exec_sink *sink, int error) {
    sink->io_active = false;
    sink->completed = true;
    sink->error = error;
    pthread_cond_broadcast(&sink->changed);
}

static void retire_cancelled_write(void *context) {
    micropod_exec_sink *sink = context;
    pthread_mutex_lock(&sink->lock);
    finish_request(sink, ECANCELED);
    pthread_mutex_unlock(&sink->lock);
}

static void *writer(void *context) {
    micropod_exec_sink *sink = context;
    /* POSIX cancellation is enabled only around the native I/O. */
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    pthread_cleanup_push(retire_cancelled_write, sink);
    pthread_mutex_lock(&sink->lock);
    while (!sink->cancelled) {
        if (!sink->submitted || sink->completed) {
            pthread_cond_wait(&sink->changed, &sink->lock);
            continue;
        }
        struct exec_output output = sink->output[sink->stream - 1];
        const unsigned char *bytes = sink->bytes;
        size_t count = sink->count;
        /* Enable before publishing io_active so cancel sees a cancellable thread. */
        pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
        sink->io_active = true;
        pthread_mutex_unlock(&sink->lock);

        pthread_testcancel();
        int error = write_buffer(output, bytes, count);
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);

        pthread_mutex_lock(&sink->lock);
        finish_request(sink, sink->cancelled ? ECANCELED : error);
    }
    /* Cancellation can also happen before the worker has picked up the request. */
    if (sink->submitted && !sink->completed) finish_request(sink, ECANCELED);
    pthread_mutex_unlock(&sink->lock);
    pthread_cleanup_pop(0);
    return NULL;
}

static int open_output(struct exec_output *output, int borrowed_fd, const struct stat *null_device) {
    if (borrowed_fd == -1) {
        output->discard = true;
        return 0;
    }
    /* Avoid allocating an alias into a closed standard descriptor. */
    int fd = fcntl(borrowed_fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (fd < 0) return errno;
    struct stat info;
    if (fstat(fd, &info) < 0) {
        int error = errno;
        close(fd);
        return error;
    }
    output->fd = fd;
    output->socket = S_ISSOCK(info.st_mode);
    output->direct = null_device && S_ISCHR(info.st_mode) && info.st_rdev == null_device->st_rdev;
    return 0;
}

int micropod_exec_sink_create(int stdout_fd, int stderr_fd, micropod_exec_sink **result) {
    if (!result) return EINVAL;
    *result = NULL;
    micropod_exec_sink *sink = calloc(1, sizeof(*sink));
    if (!sink) return ENOMEM;
    sink->output[0].fd = -1;
    sink->output[1].fd = -1;

    struct stat info;
    const struct stat *null_device = NULL;
    if ((stdout_fd != -1 || stderr_fd != -1) && stat("/dev/null", &info) == 0 && S_ISCHR(info.st_mode)) {
        null_device = &info;
    }
    int error = open_output(&sink->output[0], stdout_fd, null_device);
    if (error) goto fail;
    error = open_output(&sink->output[1], stderr_fd, null_device);
    if (error) goto fail;
    error = pthread_mutex_init(&sink->lock, NULL);
    if (error) goto fail;
    error = pthread_cond_init(&sink->changed, NULL);
    if (error) {
        pthread_mutex_destroy(&sink->lock);
        goto fail;
    }
    *result = sink;
    return 0;

fail:
    if (sink->output[0].fd >= 0) close(sink->output[0].fd);
    if (sink->output[1].fd >= 0) close(sink->output[1].fd);
    free(sink);
    return error;
}

int micropod_exec_sink_write(micropod_exec_sink *sink, int stream, const void *bytes, size_t count) {
    if (!sink || stream < 1 || stream > 2 || (!bytes && count)) return EINVAL;
    pthread_mutex_lock(&sink->lock);
    int error = 0;
    if (sink->cancelled) {
        error = ECANCELED;
        goto out;
    }
    if (sink->submitted) {
        error = EBUSY;
        goto out;
    }
    struct exec_output output = sink->output[stream - 1];
    if (count == 0 || output.discard) goto out;
    if (output.direct) {
        error = write_buffer(output, bytes, count);
        goto out;
    }
    if (!sink->started) {
        error = pthread_create(&sink->thread, NULL, writer, sink);
        if (error) goto out;
        sink->started = true;
    }

    sink->stream = stream;
    sink->bytes = bytes;
    sink->count = count;
    sink->submitted = true;
    sink->completed = false;
    pthread_cond_signal(&sink->changed);
    while (!sink->completed) pthread_cond_wait(&sink->changed, &sink->lock);
    error = sink->error;
    sink->submitted = false;
    sink->bytes = NULL;

out:
    pthread_mutex_unlock(&sink->lock);
    return error;
}

void micropod_exec_sink_cancel(micropod_exec_sink *sink) {
    if (!sink) return;
    pthread_mutex_lock(&sink->lock);
    if (!sink->cancelled) {
        sink->cancelled = true;
        if (sink->io_active) pthread_cancel(sink->thread);
        pthread_cond_broadcast(&sink->changed);
    }
    pthread_mutex_unlock(&sink->lock);
}

void micropod_exec_sink_destroy(micropod_exec_sink *sink) {
    if (!sink) return;
    micropod_exec_sink_cancel(sink);
    if (sink->started) pthread_join(sink->thread, NULL);
    if (sink->output[0].fd >= 0) close(sink->output[0].fd);
    if (sink->output[1].fd >= 0) close(sink->output[1].fd);
    pthread_cond_destroy(&sink->changed);
    pthread_mutex_destroy(&sink->lock);
    free(sink);
}

struct micropod_exec_input {
    int source;
    int socket;
    pthread_t thread;
    int error;
};

static void *copy_input(void *context) {
    micropod_exec_input *input = context;
    struct exec_output output = { .fd = input->socket, .socket = true };
    unsigned char bytes[65536];
    for (;;) {
        pthread_testcancel();
        ssize_t count = read(input->source, bytes, sizeof(bytes));
        if (count == 0) {
            shutdown(input->socket, SHUT_WR);
            return NULL;
        }
        if (count < 0) {
            int error = errno;
            if (error == EINTR) continue;
            if (error == EAGAIN || error == EWOULDBLOCK) {
                error = await_io(input->source, POLLIN);
                if (error == 0) continue;
            }
            input->error = error;
            break;
        }
        int error = write_buffer(output, bytes, (size_t)count);
        if (error == EPIPE || error == ECONNRESET || error == ENOTCONN) return NULL;
        if (error) {
            input->error = error;
            break;
        }
    }
    shutdown(input->socket, SHUT_RDWR);
    return NULL;
}

int micropod_exec_input_start(int source_fd, int socket_fd, micropod_exec_input **result) {
    if (!result) return EINVAL;
    *result = NULL;
    micropod_exec_input *input = calloc(1, sizeof(*input));
    if (!input) return ENOMEM;
    input->source = -1;
    input->socket = fcntl(socket_fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    int error;
    if (input->socket < 0) {
        error = errno;
        goto fail;
    }
    if (source_fd == -1) {
        shutdown(input->socket, SHUT_WR);
    } else {
        input->source = fcntl(source_fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        if (input->source < 0) {
            error = errno;
            goto fail;
        }
        error = pthread_create(&input->thread, NULL, copy_input, input);
        if (error) goto fail;
    }
    *result = input;
    return 0;

fail:
    if (input->source >= 0) close(input->source);
    if (input->socket >= 0) close(input->socket);
    free(input);
    return error;
}

int micropod_exec_input_stop(micropod_exec_input *input) {
    if (!input) return 0;
    if (input->source >= 0) {
        pthread_cancel(input->thread);
        pthread_join(input->thread, NULL);
        close(input->source);
    }
    close(input->socket);
    int error = input->error;
    free(input);
    return error;
}
