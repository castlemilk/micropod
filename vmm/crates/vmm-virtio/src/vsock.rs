//! Single-reactor zero-alloc `kqueue` Virtio-Vsock (Device ID 19) multiplexer.
//!
//! Bridges macOS host Unix domain sockets (`docker.sock`, `oci.sock`, `buildkit.sock`)
//! and in-process guest->host service hooks (e.g. Micropod's 4-byte published-port
//! broker on host port 2378) onto guest Linux `AF_VSOCK` CID 3:
//! - Zero threads spawned per `docker.sock` / `oci.sock` / `buildkit.sock` connection
//!   (single `QOS_CLASS_USER_INTERACTIVE` Darwin `kqueue` reactor thread `vmm-vsock-io`).
//! - Zero-copy Guest->Host TX (`GuestMemory` scatter-gather -> `libc::writev()`).
//! - Zero-alloc Host->Guest RX (direct 2-slice scatter into guest RX VirtQueue descriptors).
//! - Coalesced `OP_CREDIT_UPDATE` and batched GICv3 IRQ delivery with `guest_wants_irq()`.

use std::collections::{HashMap, VecDeque};
use std::os::fd::{AsRawFd, IntoRawFd, RawFd};
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::{DescBuf, GuestMemory, IrqLine, VirtQueue, VirtioBackend};

pub const HOST_CID: u64 = 2;
pub const GUEST_CID: u64 = 3;

const VIRTIO_VSOCK_TYPE_STREAM: u16 = 1;
const VIRTIO_VSOCK_OP_REQUEST: u16 = 1;
const VIRTIO_VSOCK_OP_RESPONSE: u16 = 2;
const VIRTIO_VSOCK_OP_RST: u16 = 3;
const VIRTIO_VSOCK_OP_SHUTDOWN: u16 = 4;
const VIRTIO_VSOCK_OP_RW: u16 = 5;
const VIRTIO_VSOCK_OP_CREDIT_UPDATE: u16 = 6;
const VIRTIO_VSOCK_OP_CREDIT_REQUEST: u16 = 7;

const SHUTDOWN_RCV: u32 = 1;
const SHUTDOWN_SEND: u32 = 2;

const VSOCK_HDR_LEN: usize = 44;
const BUF_ALLOC: u32 = 256 * 1024;
const CREDIT_UPDATE_THRESHOLD: u32 = 64 * 1024;
const MAX_PKT_PAYLOAD: usize = 64 * 1024;

const VSOCK_WAKE_IDENT: usize = 0x4d50_5653; // "MPVS"
const UDATA_LISTENER_TAG: usize = 0x1000_0000;
const UDATA_CONN_TAG: usize = 0x2000_0000;

#[derive(Debug, Clone, Copy)]
pub struct VsockHdr {
    pub src_cid: u64,
    pub dst_cid: u64,
    pub src_port: u32,
    pub dst_port: u32,
    pub len: u32,
    pub sock_type: u16,
    pub op: u16,
    pub flags: u32,
    pub buf_alloc: u32,
    pub fwd_cnt: u32,
}

impl VsockHdr {
    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() < VSOCK_HDR_LEN {
            return None;
        }
        Some(Self {
            src_cid: u64::from_le_bytes(b[0..8].try_into().ok()?),
            dst_cid: u64::from_le_bytes(b[8..16].try_into().ok()?),
            src_port: u32::from_le_bytes(b[16..20].try_into().ok()?),
            dst_port: u32::from_le_bytes(b[20..24].try_into().ok()?),
            len: u32::from_le_bytes(b[24..28].try_into().ok()?),
            sock_type: u16::from_le_bytes(b[28..30].try_into().ok()?),
            op: u16::from_le_bytes(b[30..32].try_into().ok()?),
            flags: u32::from_le_bytes(b[32..36].try_into().ok()?),
            buf_alloc: u32::from_le_bytes(b[36..40].try_into().ok()?),
            fwd_cnt: u32::from_le_bytes(b[40..44].try_into().ok()?),
        })
    }

    pub fn encode(&self) -> [u8; VSOCK_HDR_LEN] {
        let mut b = [0u8; VSOCK_HDR_LEN];
        b[0..8].copy_from_slice(&self.src_cid.to_le_bytes());
        b[8..16].copy_from_slice(&self.dst_cid.to_le_bytes());
        b[16..20].copy_from_slice(&self.src_port.to_le_bytes());
        b[20..24].copy_from_slice(&self.dst_port.to_le_bytes());
        b[24..28].copy_from_slice(&self.len.to_le_bytes());
        b[28..30].copy_from_slice(&self.sock_type.to_le_bytes());
        b[30..32].copy_from_slice(&self.op.to_le_bytes());
        b[32..36].copy_from_slice(&self.flags.to_le_bytes());
        b[36..40].copy_from_slice(&self.buf_alloc.to_le_bytes());
        b[40..44].copy_from_slice(&self.fwd_cnt.to_le_bytes());
        b
    }

    #[inline]
    fn host_ctrl(host_port: u32, guest_port: u32, op: u16, flags: u32, fwd_cnt: u32) -> Self {
        Self {
            src_cid: HOST_CID,
            dst_cid: GUEST_CID,
            src_port: host_port,
            dst_port: guest_port,
            len: 0,
            sock_type: VIRTIO_VSOCK_TYPE_STREAM,
            op,
            flags,
            buf_alloc: BUF_ALLOC,
            fwd_cnt,
        }
    }
}

#[derive(Clone)]
pub struct VsockExposeSpec {
    pub host_unix_path: PathBuf,
    pub guest_port: u32,
}

/// Longest path that fits Darwin's `sockaddr_un.sun_path` (104 bytes) with its NUL.
pub const MAX_UNIX_SOCKET_PATH: usize = 103;

/// The host Unix listener for one `--vsock-expose` mapping.
///
/// It is bound before the guest boots so an unusable path is a startup error the
/// supervisor sees, not a running VM without its API. Dropping it removes the
/// socket file, but only while that path still names the socket bound here.
pub struct ExposeListener {
    listener: UnixListener,
    path: PathBuf,
    guest_port: u32,
    identity: (u64, u64),
}

impl ExposeListener {
    /// Bind `spec.host_unix_path` (mode 0600), replacing a stale socket file that
    /// no process accepts on. A live socket or any other kind of file is an error.
    pub fn bind(spec: &VsockExposeSpec) -> Result<Self, String> {
        let path = &spec.host_unix_path;
        let what = || format!("--vsock-expose {}", path.display());
        let len = path.as_os_str().len();
        if len == 0 {
            return Err(format!("{}: empty socket path", what()));
        }
        if len > MAX_UNIX_SOCKET_PATH {
            return Err(format!(
                "{}: path is {len} bytes; macOS Unix socket paths are limited to {MAX_UNIX_SOCKET_PATH} bytes",
                what()
            ));
        }
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("{}: create {}: {e}", what(), parent.display()))?;
        }
        remove_stale_socket(path).map_err(|e| format!("{}: {e}", what()))?;
        let listener = UnixListener::bind(path).map_err(|e| format!("{}: bind: {e}", what()))?;
        // Owner-only access, matching Micropod's socket security invariant.
        std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600))
            .map_err(|e| format!("{}: chmod 0600: {e}", what()))?;
        listener
            .set_nonblocking(true)
            .map_err(|e| format!("{}: set non-blocking: {e}", what()))?;
        let md = std::fs::symlink_metadata(path).map_err(|e| format!("{}: stat: {e}", what()))?;
        Ok(Self {
            listener,
            path: path.clone(),
            guest_port: spec.guest_port,
            identity: (md.dev(), md.ino()),
        })
    }

    pub fn path(&self) -> &std::path::Path {
        &self.path
    }

    pub fn guest_port(&self) -> u32 {
        self.guest_port
    }
}

impl Drop for ExposeListener {
    fn drop(&mut self) {
        // A successor may already have replaced a socket this process was told to
        // abandon; never delete a file that is not the one bound here.
        if let Ok(md) = std::fs::symlink_metadata(&self.path)
            && (md.dev(), md.ino()) == self.identity
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Remove `path` if it is a socket file nothing accepts connections on.
fn remove_stale_socket(path: &std::path::Path) -> Result<(), String> {
    let md = match std::fs::symlink_metadata(path) {
        Ok(md) => md,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(format!("stat existing path: {e}")),
    };
    if !md.file_type().is_socket() {
        return Err("path exists and is not a socket; refusing to replace it".into());
    }
    match UnixStream::connect(path) {
        Ok(_) => Err("socket is in use: another process is accepting connections on it".into()),
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => std::fs::remove_file(path)
            .or_else(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    Ok(())
                } else {
                    Err(e)
                }
            })
            .map_err(|e| format!("remove stale socket: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("probe existing socket: {e}")),
    }
}

/// Callback invoked when the guest opens a vsock stream to a registered host port.
/// Receives a host-side `UnixStream` paired directly with the guest vsock stream.
pub type HostServiceHandler = Arc<dyn Fn(UnixStream) + Send + Sync>;

#[inline]
fn trigger_kq_wake(kq: RawFd) {
    if kq < 0 {
        return;
    }
    let kev = libc::kevent {
        ident: VSOCK_WAKE_IDENT,
        filter: libc::EVFILT_USER,
        flags: 0,
        fflags: libc::NOTE_TRIGGER,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    unsafe {
        libc::kevent(kq, &kev, 1, std::ptr::null_mut(), 0, std::ptr::null());
    }
}

#[inline]
fn kq_ctl(kq: RawFd, fd: RawFd, filter: i16, flags: u16, udata: usize) {
    if kq < 0 || fd < 0 {
        return;
    }
    let kev = libc::kevent {
        ident: fd as usize,
        filter,
        flags,
        fflags: 0,
        data: 0,
        udata: udata as *mut libc::c_void,
    };
    unsafe {
        libc::kevent(kq, &kev, 1, std::ptr::null_mut(), 0, std::ptr::null());
    }
}

#[inline]
fn set_nosigpipe(fd: RawFd) {
    let one: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&one as *const libc::c_int).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

#[inline]
fn scatter_two_slices(bufs: &[DescBuf], mem: &GuestMemory, mut a: &[u8], mut b: &[u8]) -> u32 {
    let mut written = 0u32;
    for d in bufs {
        if !d.is_write {
            continue;
        }
        let Some(mut dst) = mem.write_slice(d.addr, d.len as usize) else {
            continue;
        };
        if !a.is_empty() {
            let n = dst.len().min(a.len());
            dst[..n].copy_from_slice(&a[..n]);
            a = &a[n..];
            dst = &mut dst[n..];
            written += n as u32;
        }
        if !b.is_empty() && !dst.is_empty() {
            let n = dst.len().min(b.len());
            dst[..n].copy_from_slice(&b[..n]);
            b = &b[n..];
            written += n as u32;
        }
        if a.is_empty() && b.is_empty() {
            break;
        }
    }
    written
}

#[inline]
fn copy_chain_after_offset(
    bufs: &[DescBuf],
    mem: &GuestMemory,
    mut skip: usize,
    mut rem: usize,
    dst: &mut VecDeque<u8>,
) {
    for b in bufs {
        if b.is_write || rem == 0 {
            continue;
        }
        let blen = b.len as usize;
        if skip >= blen {
            skip -= blen;
            continue;
        }
        if let Some(s) = mem.read_slice(b.addr, blen) {
            let slice = &s[skip..];
            skip = 0;
            let take = slice.len().min(rem);
            dst.extend(&slice[..take]);
            rem -= take;
        }
    }
}

struct RxPending {
    hdr: VsockHdr,
    payload: Vec<u8>,
}

struct Conn {
    host_port: u32,
    guest_port: u32,
    fd: RawFd,
    connected: bool,
    closed: bool,
    guest_send_eof: bool,
    host_send_eof: bool,
    host_readable: bool,
    write_ev_armed: bool,
    credit_requested: bool,
    rst_sent: bool,
    tx_cnt: u32,          // bytes host has sent to guest
    fwd_cnt: u32,         // bytes host has forwarded from guest to host UnixStream
    last_credit_fwd: u32, // last fwd_cnt advertised to guest
    peer_buf_alloc: u32,
    peer_fwd_cnt: u32,
    to_host_buf: VecDeque<u8>,
    created: Instant,
}

impl Conn {
    fn new(host_port: u32, guest_port: u32, fd: RawFd, connected: bool) -> Self {
        Self {
            host_port,
            guest_port,
            fd,
            connected,
            closed: false,
            guest_send_eof: false,
            host_send_eof: false,
            host_readable: true,
            write_ev_armed: false,
            credit_requested: false,
            rst_sent: false,
            tx_cnt: 0,
            fwd_cnt: 0,
            last_credit_fwd: 0,
            peer_buf_alloc: 0,
            peer_fwd_cnt: 0,
            to_host_buf: VecDeque::new(),
            created: Instant::now(),
        }
    }

    #[inline]
    fn peer_credit(&self) -> u32 {
        self.peer_buf_alloc
            .saturating_sub(self.tx_cnt.wrapping_sub(self.peer_fwd_cnt))
    }

    fn close_fd(&mut self) {
        if self.fd >= 0 {
            unsafe {
                libc::close(self.fd);
            }
            self.fd = -1;
        }
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.close_fd();
    }
}

struct MuxInner {
    kq_fd: RawFd,
    rx_queue: Option<VirtQueue>,
    rx_pending: VecDeque<RxPending>,
    streams: HashMap<(u32, u32), Conn>,
    fd_to_key: HashMap<RawFd, (u32, u32)>,
    host_services: HashMap<u32, HostServiceHandler>,
    mem: Option<Arc<GuestMemory>>,
    irq: Option<IrqLine>,
    rx_desc_scratch: Vec<DescBuf>,
}

impl MuxInner {
    fn remove_conn(&mut self, key: (u32, u32)) {
        if let Some(conn) = self.streams.remove(&key) {
            if conn.fd >= 0 {
                self.fd_to_key.remove(&conn.fd);
            }
            drop(conn);
        }
    }

    /// Drain queued `rx_pending` frames into guest RX ring. Returns true if any frame was pushed.
    fn drain_rx_pending(&mut self) -> bool {
        if self.rx_pending.is_empty() {
            return false;
        }
        let (Some(mem), Some(rxq)) = (self.mem.as_ref(), self.rx_queue.as_mut()) else {
            return false;
        };
        let mut pushed = false;
        while self.rx_pending.front().is_some() {
            let Some(head) = rxq.pop_into(mem, &mut self.rx_desc_scratch) else {
                break;
            };
            let mut pkt = self.rx_pending.pop_front().unwrap();
            let writable_total: usize = self
                .rx_desc_scratch
                .iter()
                .filter(|b| b.is_write)
                .map(|b| b.len as usize)
                .sum();
            let max_payload = writable_total.saturating_sub(VSOCK_HDR_LEN);
            if pkt.hdr.op == VIRTIO_VSOCK_OP_RW
                && pkt.payload.len() > max_payload
                && max_payload > 0
            {
                let tail = pkt.payload.split_off(max_payload);
                let mut rem_hdr = pkt.hdr;
                rem_hdr.len = tail.len() as u32;
                pkt.hdr.len = max_payload as u32;
                self.rx_pending.push_front(RxPending {
                    hdr: rem_hdr,
                    payload: tail,
                });
            }
            let hdr_bytes = pkt.hdr.encode();
            let written = scatter_two_slices(&self.rx_desc_scratch, mem, &hdr_bytes, &pkt.payload);
            rxq.push_used(mem, head, written);
            pushed = true;
        }
        pushed
    }

    /// Zero-alloc fast path: inject a single `VsockHdr` + payload directly into guest RX ring,
    /// splitting across multiple RX descriptors if `payload.len()` exceeds one RX buffer!
    /// Returns true if any RX descriptor was pushed.
    fn send_rx(&mut self, mut hdr: VsockHdr, mut payload: &[u8]) -> bool {
        let mut pushed = self.drain_rx_pending();
        if !self.rx_pending.is_empty() {
            self.rx_pending.push_back(RxPending {
                hdr,
                payload: payload.to_vec(),
            });
            return pushed;
        }

        if let (Some(mem), Some(rxq)) = (self.mem.as_ref(), self.rx_queue.as_mut()) {
            loop {
                let Some(head) = rxq.pop_into(mem, &mut self.rx_desc_scratch) else {
                    // Guest RX ring momentarily dry -> spill remainder into rx_pending
                    hdr.len = payload.len() as u32;
                    self.rx_pending.push_back(RxPending {
                        hdr,
                        payload: payload.to_vec(),
                    });
                    return pushed;
                };
                let writable_total: usize = self
                    .rx_desc_scratch
                    .iter()
                    .filter(|b| b.is_write)
                    .map(|b| b.len as usize)
                    .sum();
                let max_payload = writable_total.saturating_sub(VSOCK_HDR_LEN);
                let take = if hdr.op == VIRTIO_VSOCK_OP_RW && max_payload > 0 {
                    payload.len().min(max_payload)
                } else {
                    payload.len()
                };
                hdr.len = take as u32;
                let hdr_bytes = hdr.encode();
                let written =
                    scatter_two_slices(&self.rx_desc_scratch, mem, &hdr_bytes, &payload[..take]);
                rxq.push_used(mem, head, written);
                pushed = true;
                payload = &payload[take..];
                if payload.is_empty() {
                    return true;
                }
            }
        }

        self.rx_pending.push_back(RxPending {
            hdr,
            payload: payload.to_vec(),
        });
        pushed
    }

    #[inline]
    fn raise_irq_if_wanted(&self) {
        if let (Some(mem), Some(rxq), Some(irq)) =
            (self.mem.as_ref(), self.rx_queue.as_ref(), self.irq.as_ref())
            && rxq.guest_wants_irq(mem)
        {
            irq.raise_used_buffer();
        }
    }

    /// Pump readable bytes from a non-blocking host UnixStream FD into guest RX descriptors.
    /// Returns true if any RX frame was pushed.
    fn pump_conn_host_to_guest(&mut self, key: (u32, u32), scratch: &mut [u8]) -> bool {
        let mut pushed = false;
        loop {
            // Stop pumping if guest RX ring has backlog so we don't allocate unbounded memory
            if self.rx_pending.len() >= 64 {
                break;
            }
            let (fd, hp, gp, fwd, credit) = {
                let Some(c) = self.streams.get(&key) else {
                    return pushed;
                };
                if !c.connected || c.closed || c.host_send_eof || !c.host_readable || c.fd < 0 {
                    return pushed;
                }
                (c.fd, c.host_port, c.guest_port, c.fwd_cnt, c.peer_credit())
            };

            if credit == 0 {
                let need_req = {
                    let Some(c) = self.streams.get_mut(&key) else {
                        return pushed;
                    };
                    if !c.credit_requested {
                        c.credit_requested = true;
                        true
                    } else {
                        false
                    }
                };
                if need_req {
                    pushed |= self.send_rx(
                        VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_CREDIT_REQUEST, 0, fwd),
                        &[],
                    );
                }
                break;
            }

            let cap = (credit as usize).min(scratch.len()).min(MAX_PKT_PAYLOAD);
            let rc = unsafe { libc::read(fd, scratch.as_mut_ptr().cast(), cap) };
            if rc > 0 {
                let n = rc as usize;
                let fwd_now = {
                    let Some(c) = self.streams.get_mut(&key) else {
                        return pushed;
                    };
                    c.tx_cnt = c.tx_cnt.wrapping_add(n as u32);
                    c.credit_requested = false;
                    c.fwd_cnt
                };
                pushed |= self.send_rx(
                    VsockHdr {
                        src_cid: HOST_CID,
                        dst_cid: GUEST_CID,
                        src_port: hp,
                        dst_port: gp,
                        len: n as u32,
                        sock_type: VIRTIO_VSOCK_TYPE_STREAM,
                        op: VIRTIO_VSOCK_OP_RW,
                        flags: 0,
                        buf_alloc: BUF_ALLOC,
                        fwd_cnt: fwd_now,
                    },
                    &scratch[..n],
                );
                // Under EV_CLEAR, always keep looping until WouldBlock, EOF, or credit == 0!
            } else if rc == 0 {
                let (send_rst, fwd_now) = {
                    let Some(c) = self.streams.get_mut(&key) else {
                        return pushed;
                    };
                    c.host_send_eof = true;
                    c.host_readable = false;
                    let both = c.guest_send_eof && c.to_host_buf.is_empty() && !c.rst_sent;
                    if both {
                        c.rst_sent = true;
                    }
                    (both, c.fwd_cnt)
                };
                if send_rst {
                    self.remove_conn(key);
                    pushed |= self.send_rx(
                        VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_RST, 0, fwd_now),
                        &[],
                    );
                } else {
                    pushed |= self.send_rx(
                        VsockHdr::host_ctrl(
                            hp,
                            gp,
                            VIRTIO_VSOCK_OP_SHUTDOWN,
                            SHUTDOWN_SEND,
                            fwd_now,
                        ),
                        &[],
                    );
                }
                break;
            } else {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::WouldBlock {
                    if let Some(c) = self.streams.get_mut(&key) {
                        c.host_readable = false;
                    }
                    break;
                }
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                // Fatal host read error -> RST & remove
                let fwd_now = self.streams.get(&key).map_or(fwd, |c| c.fwd_cnt);
                self.remove_conn(key);
                pushed |= self.send_rx(
                    VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_RST, 0, fwd_now),
                    &[],
                );
                break;
            }
        }
        pushed
    }

    /// Drain buffered `to_host_buf` bytes to a non-blocking host UnixStream FD.
    /// Returns true if any RX control packet was pushed.
    fn drain_conn_to_host(&mut self, key: (u32, u32)) -> bool {
        let mut pushed = false;
        let kq_fd = self.kq_fd;
        let (hp, gp, fatal, send_credit_fwd, send_rst_fwd) = {
            let Some(c) = self.streams.get_mut(&key) else {
                return false;
            };
            if c.fd < 0 {
                return false;
            }
            let mut fatal = false;
            while !c.to_host_buf.is_empty() {
                let (s1, s2) = c.to_host_buf.as_slices();
                let iovs = [
                    libc::iovec {
                        iov_base: s1.as_ptr() as *mut libc::c_void,
                        iov_len: s1.len(),
                    },
                    libc::iovec {
                        iov_base: s2.as_ptr() as *mut libc::c_void,
                        iov_len: s2.len(),
                    },
                ];
                let niov = if s2.is_empty() { 1 } else { 2 };
                let rc = unsafe { libc::writev(c.fd, iovs.as_ptr(), niov) };
                if rc > 0 {
                    let n = rc as usize;
                    c.to_host_buf.drain(..n);
                    c.fwd_cnt = c.fwd_cnt.wrapping_add(n as u32);
                } else if rc < 0 {
                    let err = std::io::Error::last_os_error();
                    if err.kind() == std::io::ErrorKind::WouldBlock {
                        if !c.write_ev_armed {
                            kq_ctl(
                                kq_fd,
                                c.fd,
                                libc::EVFILT_WRITE,
                                libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                                UDATA_CONN_TAG | (c.fd as usize),
                            );
                            c.write_ev_armed = true;
                        }
                        break;
                    }
                    if err.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    fatal = true;
                    break;
                } else {
                    break;
                }
            }

            if !fatal && c.guest_send_eof && c.to_host_buf.is_empty() {
                unsafe {
                    libc::shutdown(c.fd, libc::SHUT_WR);
                }
            }

            let send_rst_fwd = if !fatal
                && c.guest_send_eof
                && (c.host_send_eof || c.closed)
                && c.to_host_buf.is_empty()
                && !c.rst_sent
            {
                c.rst_sent = true;
                Some(c.fwd_cnt)
            } else {
                None
            };

            let send_credit_fwd = if !fatal
                && send_rst_fwd.is_none()
                && (c.fwd_cnt.wrapping_sub(c.last_credit_fwd) >= CREDIT_UPDATE_THRESHOLD
                    || (c.to_host_buf.is_empty() && c.fwd_cnt != c.last_credit_fwd))
            {
                c.last_credit_fwd = c.fwd_cnt;
                Some(c.fwd_cnt)
            } else {
                None
            };

            (
                c.host_port,
                c.guest_port,
                fatal,
                send_credit_fwd,
                send_rst_fwd,
            )
        };

        if fatal {
            let fwd_now = self.streams.get(&key).map_or(0, |c| c.fwd_cnt);
            self.remove_conn(key);
            pushed |= self.send_rx(
                VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_RST, 0, fwd_now),
                &[],
            );
        } else if let Some(fwd) = send_rst_fwd {
            self.remove_conn(key);
            pushed |= self.send_rx(
                VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_RST, 0, fwd),
                &[],
            );
        } else if let Some(fwd) = send_credit_fwd {
            pushed |= self.send_rx(
                VsockHdr::host_ctrl(hp, gp, VIRTIO_VSOCK_OP_CREDIT_UPDATE, 0, fwd),
                &[],
            );
        }
        pushed
    }
}

fn run_vsock_io_loop(
    inner: Arc<Mutex<MuxInner>>,
    next_host_port: Arc<AtomicU32>,
    listeners: Vec<ExposeListener>,
    shutdown: Arc<AtomicBool>,
) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let kq = inner.lock().unwrap().kq_fd;

    // Listeners were bound at startup; clients that connected before the guest
    // driver came up wait in the backlog and are accepted on the first event.
    for (idx, expose) in listeners.iter().enumerate() {
        kq_ctl(
            kq,
            expose.listener.as_raw_fd(),
            libc::EVFILT_READ,
            libc::EV_ADD | libc::EV_ENABLE,
            UDATA_LISTENER_TAG | idx,
        );
    }

    let mut scratch = vec![0u8; MAX_PKT_PAYLOAD];
    let mut events = [libc::kevent {
        ident: 0,
        filter: 0,
        flags: 0,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    }; 128];
    let mut last_sweep = Instant::now();

    loop {
        if shutdown.load(Ordering::Relaxed) {
            break;
        }
        let ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 50_000_000,
        };
        let n = unsafe {
            libc::kevent(
                kq,
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                events.len() as libc::c_int,
                &ts,
            )
        };

        let mut wake_triggered = false;
        let mut pushed_any = false;

        if n > 0 {
            let mut g = inner.lock().unwrap();
            if shutdown.load(Ordering::Relaxed) {
                break;
            }
            for ev in &events[..n as usize] {
                if ev.filter == libc::EVFILT_USER {
                    wake_triggered = true;
                    continue;
                }
                let udata = ev.udata as usize;
                if (udata & UDATA_LISTENER_TAG) != 0 {
                    let l_idx = udata & !UDATA_LISTENER_TAG;
                    if let Some(expose) = listeners.get(l_idx) {
                        let guest_port = &expose.guest_port;
                        while !shutdown.load(Ordering::Relaxed) {
                            match expose.listener.accept() {
                                Ok((unix_stream, _)) => {
                                    if unix_stream.set_nonblocking(true).is_err() {
                                        continue;
                                    }
                                    let fd = unix_stream.into_raw_fd();
                                    set_nosigpipe(fd);
                                    let host_port = next_host_port.fetch_add(1, Ordering::Relaxed);
                                    let key = (host_port, *guest_port);
                                    kq_ctl(
                                        kq,
                                        fd,
                                        libc::EVFILT_READ,
                                        libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                                        UDATA_CONN_TAG | (fd as usize),
                                    );
                                    g.fd_to_key.insert(fd, key);
                                    g.streams
                                        .insert(key, Conn::new(host_port, *guest_port, fd, false));
                                    pushed_any |= g.send_rx(
                                        VsockHdr::host_ctrl(
                                            host_port,
                                            *guest_port,
                                            VIRTIO_VSOCK_OP_REQUEST,
                                            0,
                                            0,
                                        ),
                                        &[],
                                    );
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                                Err(_) => break,
                            }
                        }
                    }
                } else if (udata & UDATA_CONN_TAG) != 0 {
                    let fd = (udata & !UDATA_CONN_TAG) as RawFd;
                    let Some(&key) = g.fd_to_key.get(&fd) else {
                        continue;
                    };
                    if ev.filter == libc::EVFILT_READ {
                        if let Some(c) = g.streams.get_mut(&key) {
                            c.host_readable = true;
                        }
                        pushed_any |= g.pump_conn_host_to_guest(key, &mut scratch);
                    } else if ev.filter == libc::EVFILT_WRITE {
                        if let Some(c) = g.streams.get_mut(&key) {
                            c.write_ev_armed = false;
                        }
                        pushed_any |= g.drain_conn_to_host(key);
                    }
                }
            }

            if wake_triggered {
                pushed_any |= g.drain_rx_pending();
                if g.rx_pending.len() < 32 {
                    let readable_keys: Vec<(u32, u32)> = g
                        .streams
                        .iter()
                        .filter(|(_, c)| {
                            c.connected
                                && !c.closed
                                && !c.host_send_eof
                                && c.host_readable
                                && c.peer_credit() > 0
                        })
                        .map(|(&k, _)| k)
                        .collect();
                    for key in readable_keys {
                        pushed_any |= g.pump_conn_host_to_guest(key, &mut scratch);
                    }
                }
            }

            if pushed_any {
                g.raise_irq_if_wanted();
            }
        }

        // Periodic 500ms sweep: expire stalled host-initiated handshakes (> 5s without OP_RESPONSE)
        if last_sweep.elapsed() >= Duration::from_millis(500) {
            last_sweep = Instant::now();
            let mut g = inner.lock().unwrap();
            let expired: Vec<(u32, u32)> = g
                .streams
                .iter()
                .filter(|(_, c)| !c.connected && c.created.elapsed() >= Duration::from_secs(5))
                .map(|(&k, _)| k)
                .collect();
            for key in expired {
                g.remove_conn(key);
            }
        }
    }
}

pub struct VirtioVsock {
    inner: Arc<Mutex<MuxInner>>,
    next_host_port: Arc<AtomicU32>,
    /// Bound host listeners, handed to the reactor when the guest driver starts.
    exposes: Option<Vec<ExposeListener>>,
    reactor_handle: Option<thread::JoinHandle<()>>,
    shutdown: Arc<AtomicBool>,
    tx_scratch: Vec<u8>,
    tx_desc_scratch: Vec<DescBuf>,
}

impl VirtioVsock {
    pub fn new(
        exposes: Vec<ExposeListener>,
        host_services: HashMap<u32, HostServiceHandler>,
    ) -> Self {
        let kq_fd = unsafe { libc::kqueue() };
        if kq_fd >= 0 {
            let user_ev = libc::kevent {
                ident: VSOCK_WAKE_IDENT,
                filter: libc::EVFILT_USER,
                flags: libc::EV_ADD | libc::EV_CLEAR,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            unsafe {
                libc::kevent(
                    kq_fd,
                    &user_ev,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                );
            }
        }
        Self {
            inner: Arc::new(Mutex::new(MuxInner {
                kq_fd,
                rx_queue: None,
                rx_pending: VecDeque::with_capacity(256),
                streams: HashMap::with_capacity(64),
                fd_to_key: HashMap::with_capacity(64),
                host_services,
                mem: None,
                irq: None,
                rx_desc_scratch: Vec::with_capacity(8),
            })),
            next_host_port: Arc::new(AtomicU32::new(40_000)),
            exposes: Some(exposes),
            reactor_handle: None,
            shutdown: Arc::new(AtomicBool::new(false)),
            tx_scratch: vec![0u8; MAX_PKT_PAYLOAD],
            tx_desc_scratch: Vec::with_capacity(8),
        }
    }

    fn start_reactor(&mut self) {
        if self.reactor_handle.is_some() {
            return;
        }
        let inner = self.inner.clone();
        let next_port = self.next_host_port.clone();
        let exposes = self.exposes.take().unwrap_or_default();
        let shutdown = self.shutdown.clone();
        let handle = thread::Builder::new()
            .name("vmm-vsock-io".into())
            .spawn(move || run_vsock_io_loop(inner, next_port, exposes, shutdown))
            .expect("spawn vmm-vsock-io reactor");
        self.reactor_handle = Some(handle);
    }

    /// Process one guest TX packet directly from `GuestMemory` descriptors (0 intermediate `Vec`s!).
    /// Returns `(pushed_rx, wake_reactor)`.
    fn handle_tx_chain(
        g: &mut MuxInner,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        scratch: &mut [u8],
    ) -> (bool, bool) {
        let mut hdr_raw = [0u8; VSOCK_HDR_LEN];
        let mut copied = 0usize;
        let mut total_readable = 0usize;
        for b in bufs {
            if b.is_write {
                continue;
            }
            let blen = b.len as usize;
            total_readable += blen;
            if copied < VSOCK_HDR_LEN
                && let Some(s) = mem.read_slice(b.addr, blen)
            {
                let take = s.len().min(VSOCK_HDR_LEN - copied);
                hdr_raw[copied..copied + take].copy_from_slice(&s[..take]);
                copied += take;
            }
        }
        if copied < VSOCK_HDR_LEN {
            return (false, false);
        }
        let Some(hdr) = VsockHdr::decode(&hdr_raw) else {
            return (false, false);
        };
        let payload_len = (hdr.len as usize).min(total_readable.saturating_sub(VSOCK_HDR_LEN));
        let key = (hdr.dst_port, hdr.src_port); // (host_port, guest_port)
        let mut pushed_rx = false;
        let mut wake_reactor = false;

        match hdr.op {
            VIRTIO_VSOCK_OP_REQUEST => {
                // Guest -> Host service connection (e.g. ports.sock on host port 2378)
                let handler = g.host_services.get(&hdr.dst_port).cloned();
                if let Some(handler) = handler
                    && let Ok((a, b)) = UnixStream::pair()
                    && a.set_nonblocking(true).is_ok()
                {
                    let fd = a.into_raw_fd();
                    set_nosigpipe(fd);
                    let mut conn = Conn::new(hdr.dst_port, hdr.src_port, fd, true);
                    conn.peer_buf_alloc = hdr.buf_alloc;
                    conn.peer_fwd_cnt = hdr.fwd_cnt;
                    kq_ctl(
                        g.kq_fd,
                        fd,
                        libc::EVFILT_READ,
                        libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                        UDATA_CONN_TAG | (fd as usize),
                    );
                    g.fd_to_key.insert(fd, key);
                    g.streams.insert(key, conn);
                    pushed_rx |= g.send_rx(
                        VsockHdr::host_ctrl(
                            hdr.dst_port,
                            hdr.src_port,
                            VIRTIO_VSOCK_OP_RESPONSE,
                            0,
                            0,
                        ),
                        &[],
                    );
                    thread::spawn(move || handler(b));
                    return (pushed_rx, false);
                }
                pushed_rx |= g.send_rx(
                    VsockHdr::host_ctrl(hdr.dst_port, hdr.src_port, VIRTIO_VSOCK_OP_RST, 0, 0),
                    &[],
                );
            }
            VIRTIO_VSOCK_OP_RESPONSE => {
                if let Some(c) = g.streams.get_mut(&key) {
                    c.connected = true;
                    c.peer_buf_alloc = hdr.buf_alloc;
                    c.peer_fwd_cnt = hdr.fwd_cnt;
                    c.credit_requested = false;
                    pushed_rx |= g.pump_conn_host_to_guest(key, scratch);
                }
            }
            VIRTIO_VSOCK_OP_RW => {
                let kq_fd = g.kq_fd;
                let mut fatal = false;
                let mut send_credit_fwd: Option<u32> = None;
                let mut try_pump = false;
                if let Some(c) = g.streams.get_mut(&key) {
                    c.peer_buf_alloc = hdr.buf_alloc;
                    c.peer_fwd_cnt = hdr.fwd_cnt;
                    if c.peer_credit() > 0 && c.host_readable {
                        c.credit_requested = false;
                        try_pump = true;
                    }
                    if payload_len > 0 && c.fd >= 0 {
                        if c.to_host_buf.is_empty() {
                            // ZERO-COPY FAST PATH: writev() straight from GuestMemory into UnixStream!
                            let mut iovs = [libc::iovec {
                                iov_base: std::ptr::null_mut(),
                                iov_len: 0,
                            }; 32];
                            let mut niov = 0usize;
                            let mut skip = VSOCK_HDR_LEN;
                            let mut collected = 0usize;
                            for b in bufs {
                                if b.is_write {
                                    continue;
                                }
                                let blen = b.len as usize;
                                if skip >= blen {
                                    skip -= blen;
                                    continue;
                                }
                                let Some(s) = mem.read_slice(b.addr, blen) else {
                                    break;
                                };
                                let slice = &s[skip..];
                                skip = 0;
                                let take = slice.len().min(payload_len - collected);
                                if take > 0 && niov < iovs.len() {
                                    iovs[niov] = libc::iovec {
                                        iov_base: slice.as_ptr() as *mut libc::c_void,
                                        iov_len: take,
                                    };
                                    niov += 1;
                                    collected += take;
                                    if collected >= payload_len {
                                        break;
                                    }
                                }
                            }
                            let mut written = 0usize;
                            if niov > 0 {
                                loop {
                                    let rc = unsafe {
                                        libc::writev(c.fd, iovs.as_ptr(), niov as libc::c_int)
                                    };
                                    if rc >= 0 {
                                        written = rc as usize;
                                        break;
                                    }
                                    let err = std::io::Error::last_os_error();
                                    if err.kind() == std::io::ErrorKind::Interrupted {
                                        continue;
                                    }
                                    if err.kind() == std::io::ErrorKind::WouldBlock {
                                        break;
                                    }
                                    fatal = true;
                                    break;
                                }
                            }
                            if !fatal {
                                c.fwd_cnt = c.fwd_cnt.wrapping_add(written as u32);
                                if written < payload_len {
                                    copy_chain_after_offset(
                                        bufs,
                                        mem,
                                        VSOCK_HDR_LEN + written,
                                        payload_len - written,
                                        &mut c.to_host_buf,
                                    );
                                    if !c.write_ev_armed {
                                        kq_ctl(
                                            kq_fd,
                                            c.fd,
                                            libc::EVFILT_WRITE,
                                            libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                                            UDATA_CONN_TAG | (c.fd as usize),
                                        );
                                        c.write_ev_armed = true;
                                    }
                                }
                            }
                        } else {
                            copy_chain_after_offset(
                                bufs,
                                mem,
                                VSOCK_HDR_LEN,
                                payload_len,
                                &mut c.to_host_buf,
                            );
                            if !c.write_ev_armed {
                                kq_ctl(
                                    kq_fd,
                                    c.fd,
                                    libc::EVFILT_WRITE,
                                    libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                                    UDATA_CONN_TAG | (c.fd as usize),
                                );
                                c.write_ev_armed = true;
                            }
                        }
                        if !fatal
                            && c.fwd_cnt.wrapping_sub(c.last_credit_fwd) >= CREDIT_UPDATE_THRESHOLD
                        {
                            c.last_credit_fwd = c.fwd_cnt;
                            send_credit_fwd = Some(c.fwd_cnt);
                        }
                    }
                }
                if fatal {
                    let fwd = g.streams.get(&key).map_or(0, |c| c.fwd_cnt);
                    g.remove_conn(key);
                    pushed_rx |= g.send_rx(
                        VsockHdr::host_ctrl(
                            hdr.dst_port,
                            hdr.src_port,
                            VIRTIO_VSOCK_OP_RST,
                            0,
                            fwd,
                        ),
                        &[],
                    );
                } else {
                    if let Some(fwd) = send_credit_fwd {
                        pushed_rx |= g.send_rx(
                            VsockHdr::host_ctrl(
                                hdr.dst_port,
                                hdr.src_port,
                                VIRTIO_VSOCK_OP_CREDIT_UPDATE,
                                0,
                                fwd,
                            ),
                            &[],
                        );
                    }
                    if try_pump {
                        pushed_rx |= g.pump_conn_host_to_guest(key, scratch);
                    }
                }
            }
            VIRTIO_VSOCK_OP_CREDIT_UPDATE => {
                let try_pump = if let Some(c) = g.streams.get_mut(&key) {
                    c.peer_buf_alloc = hdr.buf_alloc;
                    c.peer_fwd_cnt = hdr.fwd_cnt;
                    c.credit_requested = false;
                    c.host_readable && c.peer_credit() > 0
                } else {
                    false
                };
                if try_pump {
                    pushed_rx |= g.pump_conn_host_to_guest(key, scratch);
                    wake_reactor = true;
                }
            }
            VIRTIO_VSOCK_OP_CREDIT_REQUEST => {
                if let Some(c) = g.streams.get_mut(&key) {
                    c.last_credit_fwd = c.fwd_cnt;
                    let fwd = c.fwd_cnt;
                    pushed_rx |= g.send_rx(
                        VsockHdr::host_ctrl(
                            hdr.dst_port,
                            hdr.src_port,
                            VIRTIO_VSOCK_OP_CREDIT_UPDATE,
                            0,
                            fwd,
                        ),
                        &[],
                    );
                }
            }
            VIRTIO_VSOCK_OP_SHUTDOWN => {
                let send_rst = if let Some(c) = g.streams.get_mut(&key) {
                    if (hdr.flags & SHUTDOWN_SEND) != 0 {
                        c.guest_send_eof = true;
                        if c.to_host_buf.is_empty() && c.fd >= 0 {
                            unsafe {
                                libc::shutdown(c.fd, libc::SHUT_WR);
                            }
                        }
                    }
                    if (hdr.flags & SHUTDOWN_RCV) != 0 {
                        c.closed = true;
                    }
                    let both = c.guest_send_eof
                        && (c.host_send_eof || c.closed)
                        && c.to_host_buf.is_empty();
                    if both && !c.rst_sent {
                        c.rst_sent = true;
                        Some(c.fwd_cnt)
                    } else {
                        None
                    }
                } else {
                    None
                };
                if let Some(fwd) = send_rst {
                    g.remove_conn(key);
                    pushed_rx |= g.send_rx(
                        VsockHdr::host_ctrl(
                            hdr.dst_port,
                            hdr.src_port,
                            VIRTIO_VSOCK_OP_RST,
                            0,
                            fwd,
                        ),
                        &[],
                    );
                }
            }
            VIRTIO_VSOCK_OP_RST => {
                g.remove_conn(key);
            }
            _ => {}
        }

        (pushed_rx, wake_reactor)
    }
}

impl VirtioBackend for VirtioVsock {
    fn device_id(&self) -> u32 {
        19
    }
    fn features(&self) -> u64 {
        0
    }
    fn num_queues(&self) -> usize {
        3 // 0 = RX, 1 = TX, 2 = Event
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        256
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let cfg = GUEST_CID.to_le_bytes();
        let start = offset as usize;
        for (i, b) in data.iter_mut().enumerate() {
            *b = cfg.get(start + i).copied().unwrap_or(0);
        }
    }
    fn attach(&mut self, mem: Arc<GuestMemory>, irq: IrqLine) {
        let mut g = self.inner.lock().unwrap();
        g.mem = Some(mem);
        g.irq = Some(irq);
    }
    fn queue_ready(&mut self, q_idx: usize, q: &VirtQueue) {
        if q_idx == 0 {
            let mut g = self.inner.lock().unwrap();
            g.rx_queue = Some(q.clone());
            if g.drain_rx_pending() {
                g.raise_irq_if_wanted();
            }
            drop(g);
            self.start_reactor();
        }
    }
    fn reset(&mut self) {
        let mut g = self.inner.lock().unwrap();
        g.rx_queue = None;
        g.rx_pending.clear();
        g.fd_to_key.clear();
        g.streams.clear();
    }
    fn snapshot_pause(&mut self, queues: &mut [VirtQueue], _mem: &GuestMemory) -> Vec<u8> {
        let g = self.inner.lock().unwrap();
        if let Some(ref rxq) = g.rx_queue {
            queues[0].next_avail = rxq.next_avail;
            queues[0].next_used = rxq.next_used;
        }
        // Record active (host_port, guest_port) streams so restored forks immediately emit
        // VIRTIO_VSOCK_OP_RST for stale pre-snapshot streams (e.g. guest-init control channel).
        let mut keys: Vec<(u32, u32)> = g.streams.keys().copied().collect();
        keys.sort_unstable();
        let mut blob = Vec::with_capacity(4 + keys.len() * 8);
        blob.extend_from_slice(&(keys.len() as u32).to_le_bytes());
        for (hp, gp) in keys {
            blob.extend_from_slice(&hp.to_le_bytes());
            blob.extend_from_slice(&gp.to_le_bytes());
        }
        blob
    }
    fn snapshot_restore(&mut self, blob: &[u8], queues: &[VirtQueue]) {
        if blob.len() >= 4 {
            let count = u32::from_le_bytes(blob[0..4].try_into().unwrap()) as usize;
            let mut g = self.inner.lock().unwrap();
            let mut pos = 4usize;
            for _ in 0..count {
                if pos + 8 > blob.len() {
                    break;
                }
                let host_port = u32::from_le_bytes(blob[pos..pos + 4].try_into().unwrap());
                let guest_port = u32::from_le_bytes(blob[pos + 4..pos + 8].try_into().unwrap());
                pos += 8;
                g.rx_pending.push_back(RxPending {
                    hdr: VsockHdr::host_ctrl(host_port, guest_port, VIRTIO_VSOCK_OP_RST, 0, 0),
                    payload: Vec::new(),
                });
            }
        }
        if let Some(rxq) = queues.first()
            && rxq.ready
        {
            self.queue_ready(0, rxq);
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool {
        match q_idx {
            0 => {
                // Guest refilled RX descriptors -> sync rx_queue state and flush pending packets
                let mut g = self.inner.lock().unwrap();
                if let Some(ref mut rxq) = g.rx_queue {
                    rxq.ready = queues[0].ready;
                    rxq.size = queues[0].size;
                    rxq.desc_addr = queues[0].desc_addr;
                    rxq.avail_addr = queues[0].avail_addr;
                    rxq.used_addr = queues[0].used_addr;
                } else {
                    g.rx_queue = Some(queues[0].clone());
                }
                let pushed = g.drain_rx_pending();
                let need_wake = g.rx_pending.is_empty()
                    && g.streams.values().any(|c| c.connected && c.host_readable);
                let kq = g.kq_fd;
                if pushed {
                    g.raise_irq_if_wanted();
                }
                drop(g);
                if need_wake {
                    trigger_kq_wake(kq);
                }
                false
            }
            1 => {
                // Drain entire TX batch under a single lock acquisition (0 intermediate Vecs!)
                let mut g = self.inner.lock().unwrap();
                let mut had_tx = false;
                let mut pushed_rx = false;
                let mut wake_reactor = false;
                while let Some(head) = queues[1].pop_into(mem, &mut self.tx_desc_scratch) {
                    let (prx, wake) = Self::handle_tx_chain(
                        &mut g,
                        &self.tx_desc_scratch,
                        mem,
                        &mut self.tx_scratch,
                    );
                    pushed_rx |= prx;
                    wake_reactor |= wake;
                    queues[1].push_used(mem, head, 0);
                    had_tx = true;
                }
                let kq = g.kq_fd;
                let want_rx_irq = pushed_rx
                    && g.rx_queue
                        .as_ref()
                        .is_some_and(|rxq| rxq.guest_wants_irq(mem));
                drop(g);
                if wake_reactor {
                    trigger_kq_wake(kq);
                }
                want_rx_irq || (had_tx && queues[1].guest_wants_irq(mem))
            }
            _ => false,
        }
    }
}

impl Drop for VirtioVsock {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let kq = self
            .inner
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .kq_fd;
        if let Some(h) = self.reactor_handle.take() {
            trigger_kq_wake(kq);
            // The reactor owns the listeners; they remove their socket files on exit.
            let _ = h.join();
        }
        self.exposes = None;
        if kq >= 0 {
            unsafe { libc::close(kq) };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let base = std::env::temp_dir().join(format!(
                "mpvs-{}-{}",
                std::process::id(),
                NEXT_DIR.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&base).unwrap();
            Self(base)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    static NEXT_DIR: AtomicU32 = AtomicU32::new(0);

    fn spec(path: &Path) -> VsockExposeSpec {
        VsockExposeSpec {
            host_unix_path: path.to_path_buf(),
            guest_port: 2375,
        }
    }

    #[test]
    fn expose_binds_owner_only_and_removes_its_socket_on_drop() {
        let dir = TempDir::new();
        let path = dir.0.join("sub").join("docker.sock");
        let expose = ExposeListener::bind(&spec(&path)).unwrap();
        assert_eq!(expose.guest_port(), 2375);
        let md = std::fs::symlink_metadata(&path).unwrap();
        assert!(md.file_type().is_socket());
        assert_eq!(md.permissions().mode() & 0o777, 0o600);
        UnixStream::connect(&path).expect("clients reach the bound listener");
        drop(expose);
        assert!(!path.exists());
    }

    #[test]
    fn expose_replaces_a_stale_socket_but_not_a_live_one() {
        let dir = TempDir::new();
        let path = dir.0.join("docker.sock");
        // A crashed VMM leaves its socket file behind with nothing accepting on it.
        drop(UnixListener::bind(&path).unwrap());
        assert!(path.exists());
        let expose = ExposeListener::bind(&spec(&path)).expect("stale socket is replaced");

        let err = ExposeListener::bind(&spec(&path)).err().unwrap();
        assert!(err.contains("in use"), "{err}");
        // The failed attempt left the live socket alone.
        UnixStream::connect(&path).unwrap();
        drop(expose);
    }

    #[test]
    fn expose_rejects_long_paths_and_non_socket_files() {
        let dir = TempDir::new();
        let long = dir.0.join("x".repeat(MAX_UNIX_SOCKET_PATH));
        let err = ExposeListener::bind(&spec(&long)).err().unwrap();
        assert!(err.contains("limited to 103 bytes"), "{err}");

        let file = dir.0.join("not-a-socket");
        std::fs::write(&file, b"keep me").unwrap();
        let err = ExposeListener::bind(&spec(&file)).err().unwrap();
        assert!(err.contains("not a socket"), "{err}");
        assert_eq!(std::fs::read(&file).unwrap(), b"keep me");
    }

    #[test]
    fn expose_drop_leaves_a_successor_socket_in_place() {
        let dir = TempDir::new();
        let path = dir.0.join("docker.sock");
        let old = ExposeListener::bind(&spec(&path)).unwrap();
        std::fs::remove_file(&path).unwrap();
        let successor = UnixListener::bind(&path).unwrap();
        drop(old);
        assert!(path.exists(), "a newer machine's socket must survive");
        drop(successor);
    }

    #[test]
    fn vsock_hdr_roundtrip() {
        let hdr = VsockHdr {
            src_cid: HOST_CID,
            dst_cid: GUEST_CID,
            src_port: 40001,
            dst_port: 2375,
            len: 512,
            sock_type: VIRTIO_VSOCK_TYPE_STREAM,
            op: VIRTIO_VSOCK_OP_RW,
            flags: 0,
            buf_alloc: BUF_ALLOC,
            fwd_cnt: 1024,
        };
        let enc = hdr.encode();
        let dec = VsockHdr::decode(&enc).unwrap();
        assert_eq!(dec.src_cid, HOST_CID);
        assert_eq!(dec.dst_cid, GUEST_CID);
        assert_eq!(dec.src_port, 40001);
        assert_eq!(dec.dst_port, 2375);
        assert_eq!(dec.len, 512);
        assert_eq!(dec.op, VIRTIO_VSOCK_OP_RW);
        assert_eq!(dec.fwd_cnt, 1024);
    }

    #[test]
    fn vsock_zero_alloc_scatter_splits_across_descriptors() {
        let mut backing = vec![0u8; 4096];
        let ram_base = 0x4000_0000u64;
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), ram_base, backing.len()) };
        let bufs = [
            DescBuf {
                addr: ram_base,
                len: 32,
                is_write: true,
            },
            DescBuf {
                addr: ram_base + 64,
                len: 64,
                is_write: true,
            },
        ];
        let hdr = VsockHdr::host_ctrl(40000, 2375, VIRTIO_VSOCK_OP_RW, 0, 0).encode();
        let payload = b"hello-kqueue-vsock!";
        let written = scatter_two_slices(&bufs, &mem, &hdr, payload);
        assert_eq!(written as usize, VSOCK_HDR_LEN + payload.len());
        let mut rebuilt = Vec::new();
        rebuilt.extend_from_slice(&backing[0..32]);
        rebuilt.extend_from_slice(&backing[64..64 + (written as usize - 32)]);
        assert_eq!(&rebuilt[..VSOCK_HDR_LEN], &hdr);
        assert_eq!(&rebuilt[VSOCK_HDR_LEN..], payload);
    }

    #[test]
    fn vsock_snapshot_restore_resets_stale_pre_snapshot_streams() {
        let mut backing = vec![0u8; 4096];
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), 0x4000_0000, backing.len()) };
        let mut src = VirtioVsock::new(Vec::new(), HashMap::new());
        {
            let mut g = src.inner.lock().unwrap();
            g.streams
                .insert((2379, 10001), Conn::new(2379, 10001, -1, true));
            g.streams
                .insert((40000, 2375), Conn::new(40000, 2375, -1, true));
        }
        let mut queues = vec![
            VirtQueue::new(256),
            VirtQueue::new(256),
            VirtQueue::new(256),
        ];
        let blob = src.snapshot_pause(&mut queues, &mem);
        assert_eq!(blob.len(), 4 + 2 * 8);

        let mut dst = VirtioVsock::new(Vec::new(), HashMap::new());
        dst.snapshot_restore(&blob, &queues);
        let g = dst.inner.lock().unwrap();
        assert_eq!(g.rx_pending.len(), 2);
        let pairs: Vec<(u32, u32, u16)> = g
            .rx_pending
            .iter()
            .map(|p| (p.hdr.src_port, p.hdr.dst_port, p.hdr.op))
            .collect();
        assert_eq!(
            pairs,
            vec![
                (2379, 10001, VIRTIO_VSOCK_OP_RST),
                (40000, 2375, VIRTIO_VSOCK_OP_RST),
            ]
        );
    }
}
