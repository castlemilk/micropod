/* Read established IPv4 TCP MSS on one named relay PID and exact peer tuple. */
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/proc_info.h>

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    int pid = atoi(argv[1]), port = atoi(argv[3]);
    struct in_addr local, peer;
    if (pid <= 0 || port <= 0 || port > 65535 ||
        inet_pton(AF_INET, argv[2], &local) != 1 ||
        inet_pton(AF_INET, argv[4], &peer) != 1) return 2;
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) { perror("cannot inventory private relay FDs"); return 1; }
    int capacity = size + 64 * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc(capacity);
    if (!fds) return 1;
    int used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, capacity);
    if (used <= 0 || used >= capacity || used % sizeof(*fds) != 0) return 1;
    int matches = 0, mss = 0, remote_port = 0;
    uint32_t receive_space = 0;
    for (unsigned i = 0; i < used / sizeof(*fds); ++i) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo fd = {0};
        int got = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &fd, sizeof(fd));
        if (got != sizeof(fd) || fd.psi.soi_kind != SOCKINFO_TCP) continue;
        const struct tcp_sockinfo *tcp = &fd.psi.soi_proto.pri_tcp;
        const struct in_sockinfo *ip = &tcp->tcpsi_ini;
        if (tcp->tcpsi_state != TSI_S_ESTABLISHED || !(ip->insi_vflag & INI_IPV4) ||
            ip->insi_laddr.ina_46.i46a_addr4.s_addr != local.s_addr ||
            ntohs(ip->insi_lport) != port || ip->insi_faddr.ina_46.i46a_addr4.s_addr != peer.s_addr)
            continue;
        matches++;
        mss = tcp->tcpsi_mss;
        receive_space = fd.psi.soi_rcv.sbi_hiwat;
        remote_port = ntohs(ip->insi_fport);
    }
    free(fds);
    if (matches != 1 || mss <= 0) {
        fprintf(stderr, "expected exactly one readable, established private relay backend, found %d\n", matches);
        return 1;
    }
    printf("{\"pid\":%d,\"local_address\":\"%s\",\"local_port\":%d,"
           "\"peer_address\":\"%s\",\"peer_port\":%d,\"send_mss\":%d,\"receive_space\":%u}\n",
           pid, argv[2], port, argv[4], remote_port, mss, receive_space);
    return 0;
}
