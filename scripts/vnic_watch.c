// Observe the private bridge address and dial only its benchmark service.
// Uses ordinary sockets so a Mac host packet-capture entitlement is unnecessary.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) {
    (void)sig;
    stopping = 1;
}

static unsigned bridge_index(struct in_addr gateway) {
    struct ifaddrs *all;
    if (getifaddrs(&all) != 0) return UINT32_MAX;
    unsigned index = 0;
    for (struct ifaddrs *a = all; a; a = a->ifa_next) {
        if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && (a->ifa_flags & IFF_UP) &&
            ((struct sockaddr_in *)a->ifa_addr)->sin_addr.s_addr == gateway.s_addr) {
            index = if_nametoindex(a->ifa_name);
            break;
        }
    }
    freeifaddrs(all);
    return index;
}

static uint64_t ns(clockid_t c) { return clock_gettime_nsec_np(c); }
static void receipt(int fd, int error, uint64_t start, unsigned index) {
    struct tcp_connection_info tcp = {0};
    struct sockaddr_in local = {0};
    socklen_t n = sizeof(tcp), len = sizeof(local);
    bool info = getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &tcp, &n) == 0;
    getsockname(fd, (struct sockaddr *)&local, &len);
    printf("{\"event\":\"dial\",\"ns\":%llu,\"elapsed_us\":%llu,\"ifindex\":%u,\"sport\":%u,"
           "\"errno\":%d,\"tcp_info\":%s,\"state\":%u,\"sent\":%llu,\"retransmitted\":%llu,\"received\":%llu}\n",
           ns(CLOCK_REALTIME), (ns(CLOCK_MONOTONIC) - start) / 1000, index, ntohs(local.sin_port), error,
           info ? "true" : "false", tcp.tcpi_state, tcp.tcpi_txpackets, tcp.tcpi_txretransmitpackets,
           tcp.tcpi_rxpackets);
}

// UDP connect selects a local route without transmitting an application packet.
// Report only whether an unscoped socket would use this worker's gateway.
static int unscoped_uses_gateway(const struct sockaddr_in *target, struct in_addr gateway) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in source = {0};
    socklen_t size = sizeof(source);
    int match = -1;
    if (connect(fd, (const struct sockaddr *)target, sizeof(*target)) == 0 &&
        getsockname(fd, (struct sockaddr *)&source, &size) == 0)
        match = source.sin_addr.s_addr == gateway.s_addr;
    close(fd);
    return match;
}

int main(int argc, char **argv) {
    struct sockaddr_in target = {.sin_len = sizeof(target), .sin_family = AF_INET};
    struct in_addr gateway;
    char *end;
    if (argc != 4) {
        fprintf(stderr, "usage: %s GATEWAY GUEST PORT\n", argv[0]);
        return 2;
    }
    long port = strtol(argv[3], &end, 10);
    if (*end || port < 1024 || port > 65535 || inet_pton(AF_INET, argv[1], &gateway) != 1 ||
        inet_pton(AF_INET, argv[2], &target.sin_addr) != 1)
        return 2;
    target.sin_port = htons((uint16_t)port);
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    unsigned previous = UINT32_MAX;
    int fd = -1;
    uint64_t next = 0, start = 0, last = 0;
    while (!stopping) {
        uint64_t now = ns(CLOCK_MONOTONIC);
        unsigned index = bridge_index(gateway);
        if (index != previous || now - last >= 1000000000) {
            printf("{\"event\":\"gateway\",\"ns\":%llu,\"ifindex\":%u,\"unscoped_uses_gateway\":%d}\n",
                   ns(CLOCK_REALTIME), index, unscoped_uses_gateway(&target, gateway));
            previous = index;
            last = now;
        }
        if (fd < 0 && now >= next && index && index != UINT32_MAX) {
            fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                perror("socket");
                return 1;
            }
            if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
                perror("fcntl");
                return 1;
            }
            start = now;
            next = now + 200000000;
            // Never follow the Mac's default route if this private bridge disappears.
            if (setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, sizeof(index)) < 0 ||
                (connect(fd, (struct sockaddr *)&target, sizeof(target)) < 0 && errno != EINPROGRESS)) {
                receipt(fd, errno, start, index);
                close(fd);
                fd = -1;
            }
        }
        struct pollfd p = {.fd = fd, .events = POLLOUT};
        int ready = poll(&p, 1, 20);
        if (fd >= 0 && (ready > 0 || ns(CLOCK_MONOTONIC) - start >= 3000000000)) {
            int error = ETIMEDOUT;
            socklen_t n = sizeof(error);
            if (ready > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &n) < 0) error = errno;
            receipt(fd, error, start, index);
            close(fd);
            fd = -1;
        }
    }
    if (fd >= 0) close(fd);
    return 0;
}
