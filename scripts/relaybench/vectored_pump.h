// Compile the production relay into the fixture with only its two payload syscalls interposed.
#include <errno.h>
#include <sys/uio.h>
#include <unistd.h>

static unsigned payload_reads, payload_writes, short_inside_second, blocked_payload_writes;

// A short write of half a 32 KiB buffer lands inside segment two. Count the
// same boundary on the scalar control to detect differences in actual offsets.
static size_t first_segment(size_t size) { return size / 3; }

#if USE_IOV
static int segments(struct iovec iov[2], void *buffer, size_t size) {
    size_t first = first_segment(size);
    if (first == 0) {
        iov[0] = (struct iovec){buffer, size};
        return 1;
    }
    iov[0] = (struct iovec){buffer, first};
    iov[1] = (struct iovec){(char *)buffer + first, size - first};
    return 2;
}
#endif

static ssize_t payload_read(int fd, void *buffer, size_t size) {
    ++payload_reads;
#if USE_IOV
    struct iovec iov[2];
    int count = segments(iov, buffer, size);
    return readv(fd, iov, count);
#else
    return read(fd, buffer, size);
#endif
}

static ssize_t payload_write(int fd, const void *buffer, size_t size) {
    ++payload_writes;
#if USE_IOV
    struct iovec iov[2];
    int count = segments(iov, (void *)buffer, size);
    ssize_t n = writev(fd, iov, count);
#else
    ssize_t n = write(fd, buffer, size);
#endif
    if (n > 0 && (size_t)n > first_segment(size) && (size_t)n < size) ++short_inside_second;
    if (n < 0 && errno == EAGAIN) ++blocked_payload_writes;
    return n;
}

#define read(...) payload_read(__VA_ARGS__)
#define write(...) payload_write(__VA_ARGS__)
#include "../../Sources/CPublishedTCP/PublishedTCP.c"
#undef write
#undef read
