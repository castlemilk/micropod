import Darwin
import Foundation

/// Which processes hold a listening endpoint, read straight from the kernel
/// via libproc — the same data `lsof` reports, without forking it. On a host
/// at load average 100+ an `lsof` run took seconds and blew its timeout,
/// which made agent ownership checks undecidable; this is a few syscalls per
/// process and needs no timeout.
///
/// Only *bound* addresses match: a TCP socket in LISTEN on the port, or a
/// unix socket whose local address is the path. Connected clients (whose
/// local unix address is empty) never count as owners.
enum EndpointOwners {
    /// PIDs with a TCP socket listening on `port`. Nil when the process list
    /// itself can't be read (unknown, not "nobody").
    static func tcpListeners(port: UInt16) -> [pid_t]? {
        scan { info in
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { return false }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return false }
            // insi_lport holds the port in network byte order.
            let raw = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            return UInt16(bigEndian: raw) == port
        }
    }

    /// PIDs with a unix socket bound to `path`. Nil when unknown.
    static func unixListeners(path: String) -> [pid_t]? {
        let wanted = Set([path, canonical(path)])
        return scan { info in
            guard info.psi.soi_kind == Int32(SOCKINFO_UN) else { return false }
            var addr = info.psi.soi_proto.pri_un.unsi_addr.ua_sun
            let bound = withUnsafeBytes(of: &addr.sun_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return !bound.isEmpty && (wanted.contains(bound) || wanted.contains(canonical(bound)))
        }
    }

    /// Every pid that has at least one socket fd satisfying `matches`.
    /// Processes we can't inspect (another user's, or gone mid-scan) are
    /// skipped — they can't be our agents' owners in any case we act on.
    private static func scan(_ matches: (socket_fdinfo) -> Bool) -> [pid_t]? {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return nil }
        // Headroom for processes spawned between the size query and the list.
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }

        var owners: [pid_t] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            if holdsMatchingSocket(pid: pid, matches) { owners.append(pid) }
        }
        return owners
    }

    private static func holdsMatchingSocket(pid: pid_t, _ matches: (socket_fdinfo) -> Bool) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return false }
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            if got == Int32(MemoryLayout<socket_fdinfo>.size), matches(info) { return true }
        }
        return false
    }

    /// realpath(3), or the path unchanged when it can't be resolved.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
