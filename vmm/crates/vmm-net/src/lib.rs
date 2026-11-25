//! Zero-copy, O(1)-lookup Virtio-Net + Direct TCP/IP Published-Port Engine.
//!
//! Bridges macOS host `127.0.0.1:<port>` listeners directly to Linux guest `eth1`
//! (`10.43.0.2`, macvlan `mppub0`) over Hypervisor.framework shared guest RAM:
//! - Guest -> Host (downloads / bulk): `libc::writev()` straight from GuestMemory
//!   scatter-gather descriptors into the Darwin socket (0 heap allocs, 0 copies).
//! - Host -> Guest (SYN / ACK / requests / uploads): writes Eth+IPv4+TCP+payload
//!   directly into guest VirtQueue RX descriptors (0 heap allocs on fast path).
//! - O(1) per-flow slot array (`flows[dst_port - 32768]`) with per-flow locking.
//! - Priority fresh-connection lane (`< 64 KiB`) jumps ahead of bulk streams.
//! - Zero `vmnet`, zero macOS Local Network TCC prompts, full `VIRTIO_NET_F_HOST_TSO4`.

pub mod egress;
pub use egress::VirtioNetEgress;

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use vmm_virtio::vsock::HostServiceHandler;
use vmm_virtio::{
    DescBuf, GuestMemory, IrqLine, VirtQueue, VirtioBackend, collect_readable, scatter_writable,
};

pub(crate) const VIRTIO_NET_F_CSUM: u64 = 1 << 0;
pub(crate) const VIRTIO_NET_F_GUEST_CSUM: u64 = 1 << 1;
pub(crate) const VIRTIO_NET_F_MTU: u64 = 1 << 3;
pub(crate) const VIRTIO_NET_F_MAC: u64 = 1 << 5;
const VIRTIO_NET_F_GUEST_TSO4: u64 = 1 << 7;
pub(crate) const VIRTIO_NET_F_HOST_TSO4: u64 = 1 << 11;
const VIRTIO_NET_F_MRG_RXBUF: u64 = 1 << 15;
pub(crate) const VIRTIO_NET_F_STATUS: u64 = 1 << 16;
const VIRTIO_NET_F_CTRL_VQ: u64 = 1 << 17;
const VIRTIO_NET_F_MQ: u64 = 1 << 22;

const VIRTIO_NET_CTRL_RX: u8 = 0;
const VIRTIO_NET_CTRL_MAC: u8 = 1;
const VIRTIO_NET_CTRL_VLAN: u8 = 2;
const VIRTIO_NET_CTRL_MQ: u8 = 4;
const VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET: u8 = 0;
const VIRTIO_NET_OK: u8 = 0;
const VIRTIO_NET_ERR: u8 = 1;

const MAX_VQ_PAIRS: usize = 4;

const VIRTIO_NET_HDR_F_NEEDS_CSUM: u8 = 1;
const VIRTIO_NET_HDR_F_DATA_VALID: u8 = 2;
const VIRTIO_NET_HDR_GSO_TCPV4: u8 = 1;
pub(crate) const VIRTIO_NET_HDR_LEN: usize = 12;

pub(crate) const TCP_FIN: u8 = 0x01;
pub(crate) const TCP_SYN: u8 = 0x02;
pub(crate) const TCP_RST: u8 = 0x04;
pub(crate) const TCP_PSH: u8 = 0x08;
pub(crate) const TCP_ACK: u8 = 0x10;

const EPHEMERAL_BASE: u16 = 32768;
const MAX_SLOTS: usize = 4096; // Ephemeral ports 32768..36864 -> O(1) direct index
pub(crate) const HOST_WS_SHIFT: u8 = 7; // Window scale 128x (allows up to 8 MiB advertised window)
const DEFAULT_HOST_RCV_WND: usize = 512 * 1024; // 512 KiB backpressure buffer per flow
const MAX_TX_INFLIGHT: usize = 512 * 1024; // 512 KiB Host->Guest pipeline (enables 60 KiB GUEST_TSO4 bursts)
const MAX_GUEST_TSO4_PAYLOAD: usize = 60 * 1024;
const FRESH_BYTE_THRESHOLD: u64 = 64 * 1024;
const ACK_COALESCE_BYTES: usize = 128 * 1024; // 1 ACK per 128 KiB (2 TSO4 super-frames)

const WAKE_IDENT: usize = 0x4d50_4e45; // "MPNE" EVFILT_USER ident
const UDATA_LISTENER: usize = 1;
const UDATA_CONN_TAG: usize = 0x8000_0000;

#[derive(Default)]
pub struct NetMetrics {
    pub tx_packets: AtomicU64,
    pub tx_bytes: AtomicU64,
    pub rx_packets: AtomicU64,
    pub rx_bytes: AtomicU64,
    pub published_binds: AtomicU64,
    pub published_conns: AtomicU64,
    /// Published connections the guest never accepted within the handshake timeout.
    pub published_refused: AtomicU64,
}

#[derive(Clone, Debug)]
pub struct NetConfig {
    pub guest_mac: [u8; 6],
    pub host_mac: [u8; 6],
    pub host_ip: Ipv4Addr,
    pub guest_ip: Ipv4Addr,
    pub mtu: u16,
    pub enable_port_broker: bool,
    /// Other guest addresses a published connection may be accepted on. The port
    /// broker protocol names only the guest port, and guest engines differ in
    /// which address listens: current engines use the published link address
    /// (`guest_ip`), older ones bind their relay to the primary `eth0` address.
    /// Linux accepts a segment for any local address on any interface, so the
    /// handshake falls back to these when `guest_ip` refuses the connection.
    pub fallback_guest_ips: Vec<Ipv4Addr>,
}

impl NetConfig {
    pub fn primary_egress() -> Self {
        Self {
            guest_mac: [0x52, 0x54, 0x00, 0x12, 0x34, 0x56],
            host_mac: [0x52, 0x54, 0x00, 0xab, 0xcd, 0x01],
            host_ip: Ipv4Addr::new(10, 42, 0, 1),
            guest_ip: Ipv4Addr::new(10, 42, 0, 2),
            mtu: 1500,
            enable_port_broker: false,
            fallback_guest_ips: Vec::new(),
        }
    }

    pub fn published_link(mtu: u16) -> Self {
        Self {
            guest_mac: [0x52, 0x54, 0x00, 0x12, 0x34, 0x57],
            host_mac: [0x52, 0x54, 0x00, 0xab, 0xcd, 0x02],
            host_ip: Ipv4Addr::new(10, 43, 0, 1),
            guest_ip: Ipv4Addr::new(10, 43, 0, 2),
            mtu,
            enable_port_broker: true,
            fallback_guest_ips: Vec::new(),
        }
    }

    /// Also offer published connections to `ip` (another address of the same guest).
    pub fn with_fallback_guest_ip(mut self, ip: Ipv4Addr) -> Self {
        if ip != self.guest_ip && !self.fallback_guest_ips.contains(&ip) {
            self.fallback_guest_ips.push(ip);
        }
        self
    }
}

/// Upper bound on guest addresses a published handshake alternates between.
const MAX_SYN_TARGETS: usize = 4;
/// Retransmit an unanswered SYN after this long (alternating guest addresses).
const SYN_RTO: Duration = Duration::from_millis(200);
/// Give up on a published connection the guest has not accepted within this long.
/// A refusal (RST) from every candidate address is retried with backoff until
/// then, so a client that connects just before the container starts listening
/// is accepted once it does instead of being reset immediately.
const SYN_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);
const SYN_REFUSED_BACKOFF_MIN: Duration = Duration::from_millis(25);
const SYN_REFUSED_BACKOFF_MAX: Duration = Duration::from_millis(250);

/// What the published-port handshake should do next.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SynAction {
    /// (Re)send the SYN to this guest address now.
    Send(Ipv4Addr),
    /// Nothing to send yet; check again on the next timer tick.
    Wait,
    /// The deadline passed: reset the host client.
    GiveUp,
}

/// Host -> guest connection establishment for one published connection: which
/// guest address to offer the SYN to, how to react to refusals, and when to
/// stop. Pure state so the policy can be tested without a guest.
#[derive(Debug, Clone)]
struct SynHandshake {
    targets: [Ipv4Addr; MAX_SYN_TARGETS],
    count: usize,
    current: usize,
    refused_this_round: usize,
    backoff: Duration,
    retry_at: Option<Instant>,
    deadline: Instant,
}

impl SynHandshake {
    /// `preferred` goes first (the address that last accepted this port), then
    /// the remaining candidates in configuration order.
    fn new(preferred: Ipv4Addr, candidates: &[Ipv4Addr], now: Instant) -> Self {
        let mut targets = [preferred; MAX_SYN_TARGETS];
        let mut count = 1;
        for &ip in candidates {
            if count < MAX_SYN_TARGETS && !targets[..count].contains(&ip) {
                targets[count] = ip;
                count += 1;
            }
        }
        Self {
            targets,
            count,
            current: 0,
            refused_this_round: 0,
            backoff: SYN_REFUSED_BACKOFF_MIN,
            retry_at: None,
            deadline: now + SYN_HANDSHAKE_TIMEOUT,
        }
    }

    fn target(&self) -> Ipv4Addr {
        self.targets[self.current]
    }

    fn is_candidate(&self, ip: Ipv4Addr) -> bool {
        self.targets[..self.count].contains(&ip)
    }

    /// `from` answered the current SYN with a reset: nothing listens there (yet).
    fn on_refused(&mut self, from: Ipv4Addr, now: Instant) -> SynAction {
        if from != self.target() || self.retry_at.is_some() {
            return SynAction::Wait; // late reset for a SYN already superseded
        }
        self.refused_this_round += 1;
        if self.refused_this_round < self.count {
            self.current = (self.current + 1) % self.count;
            return SynAction::Send(self.target());
        }
        // Every address refused: the listener is not up yet. Back off and retry.
        self.refused_this_round = 0;
        self.current = 0;
        if now + self.backoff >= self.deadline {
            return SynAction::GiveUp;
        }
        self.retry_at = Some(now + self.backoff);
        self.backoff = (self.backoff * 2).min(SYN_REFUSED_BACKOFF_MAX);
        SynAction::Wait
    }

    /// Periodic check: retry after backoff, retransmit an unanswered SYN, or give up.
    fn on_timer(&mut self, now: Instant, last_syn: Instant) -> SynAction {
        if now >= self.deadline {
            return SynAction::GiveUp;
        }
        if let Some(at) = self.retry_at {
            if now < at {
                return SynAction::Wait;
            }
            self.retry_at = None;
            return SynAction::Send(self.target());
        }
        if now.duration_since(last_syn) >= SYN_RTO {
            // A silently dropped SYN says nothing about the address: try the next one.
            self.current = (self.current + 1) % self.count;
            self.refused_this_round = 0;
            return SynAction::Send(self.target());
        }
        SynAction::Wait
    }
}

/// Addressing of one published flow as seen from the guest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FlowPeer {
    guest_ip: Ipv4Addr,
    local_port: u16,
    guest_port: u16,
}

enum BrokerCmd {
    Prepare {
        guest_port: u16,
        reply: mpsc::SyncSender<bool>,
    },
    FinishPrepare {
        guest_port: u16,
    },
    Bind {
        host_port: u16,
        guest_port: u16,
        reply: mpsc::SyncSender<Result<u16, String>>,
    },
    Release {
        host_port: u16,
        reply: mpsc::SyncSender<()>,
    },
    QueryReleased {
        guest_port: u16,
        reply: mpsc::SyncSender<bool>,
    },
}

/// Thread-safe handle to register Micropod's `ports.sock` broker on VirtioVsock.
#[derive(Clone)]
pub struct PortBrokerHandle {
    cmd_tx: mpsc::Sender<BrokerCmd>,
    kq_fd: Arc<OwnedFd>,
}

impl PortBrokerHandle {
    fn wake(&self) {
        trigger_kq_wake(self.kq_fd.as_raw_fd());
    }

    pub fn vsock_handler(&self) -> HostServiceHandler {
        let handle = self.clone();
        Arc::new(move |stream| {
            handle.serve_control_stream(stream);
        })
    }

    /// Implements Micropod's exact 4-byte binary published-port control protocol
    /// (matching `CIWorkerPorts.swift` & `docker_port_direct_linux.go`).
    fn serve_control_stream(&self, mut stream: UnixStream) {
        let mut selected: Option<u16> = None;
        let mut pending_guest: Option<u16> = None;
        let mut submitted = false;

        let cleanup = |this: &Self, sel: &mut Option<u16>, pend: &mut Option<u16>| {
            if let Some(g) = pend.take() {
                let _ = this.cmd_tx.send(BrokerCmd::FinishPrepare { guest_port: g });
                this.wake();
            }
            if let Some(h) = sel.take() {
                let (tx, rx) = mpsc::sync_channel(1);
                let _ = this.cmd_tx.send(BrokerCmd::Release {
                    host_port: h,
                    reply: tx,
                });
                this.wake();
                let _ = rx.recv_timeout(Duration::from_secs(5));
            }
        };

        loop {
            if submitted {
                let mut cmd = [0u8; 1];
                if stream.read_exact(&mut cmd).is_err() {
                    break;
                }
                if cmd[0] != 0x52 {
                    break;
                }
                if let Some(h) = selected.take() {
                    let (tx, rx) = mpsc::sync_channel(1);
                    let _ = self.cmd_tx.send(BrokerCmd::Release {
                        host_port: h,
                        reply: tx,
                    });
                    self.wake();
                    let _ = rx.recv_timeout(Duration::from_secs(5));
                    let _ = stream.write_all(&[0x52]);
                }
                break;
            }

            if let Some(guest_port) = pending_guest {
                let mut buf = [0u8; 2];
                if stream.read_exact(&mut buf).is_err() {
                    break;
                }
                let host_port = u16::from_be_bytes(buf);
                let (tx, rx) = mpsc::sync_channel(1);
                let _ = self.cmd_tx.send(BrokerCmd::Bind {
                    host_port,
                    guest_port,
                    reply: tx,
                });
                self.wake();
                let res = rx.recv_timeout(Duration::from_secs(5));
                let _ = self.cmd_tx.send(BrokerCmd::FinishPrepare { guest_port });
                self.wake();
                pending_guest = None;
                submitted = true;
                match res {
                    Ok(Ok(bound)) => {
                        selected = Some(bound);
                        if stream.write_all(&bound.to_be_bytes()).is_err() {
                            break;
                        }
                    }
                    _ => break,
                }
                continue;
            }

            let mut frame = [0u8; 4];
            if stream.read_exact(&mut frame).is_err() {
                break;
            }
            let first = u16::from_be_bytes([frame[0], frame[1]]);
            let second = u16::from_be_bytes([frame[2], frame[3]]);

            if second == 1 && first >= 1024 {
                let (tx, rx) = mpsc::sync_channel(1);
                let _ = self.cmd_tx.send(BrokerCmd::Prepare {
                    guest_port: first,
                    reply: tx,
                });
                self.wake();
                if matches!(rx.recv_timeout(Duration::from_secs(5)), Ok(true)) {
                    pending_guest = Some(first);
                    if stream.write_all(&[0x50]).is_err() {
                        break;
                    }
                    continue;
                }
                break;
            }
            if second == 0 && first >= 1024 {
                let (tx, rx) = mpsc::sync_channel(1);
                let _ = self.cmd_tx.send(BrokerCmd::QueryReleased {
                    guest_port: first,
                    reply: tx,
                });
                self.wake();
                let released = matches!(rx.recv_timeout(Duration::from_secs(5)), Ok(true));
                let _ = stream.write_all(&[if released { 0x52 } else { 0x00 }]);
                break;
            }
            if second < 1024 {
                break;
            }
            submitted = true;
            let (tx, rx) = mpsc::sync_channel(1);
            let _ = self.cmd_tx.send(BrokerCmd::Bind {
                host_port: first,
                guest_port: second,
                reply: tx,
            });
            self.wake();
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(bound)) => {
                    selected = Some(bound);
                    if stream.write_all(&bound.to_be_bytes()).is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
        cleanup(self, &mut selected, &mut pending_guest);
    }
}

fn create_wake_queue(ident: usize) -> std::io::Result<OwnedFd> {
    let fd = unsafe { libc::kqueue() };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let queue = unsafe { OwnedFd::from_raw_fd(fd) };
    let event = libc::kevent {
        ident,
        filter: libc::EVFILT_USER,
        flags: libc::EV_ADD | libc::EV_CLEAR,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    if unsafe { libc::kevent(fd, &event, 1, std::ptr::null_mut(), 0, std::ptr::null()) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(queue)
}

#[inline]
pub(crate) fn trigger_kq_wake(kq: RawFd) {
    trigger_kq_event(kq, WAKE_IDENT);
}

fn trigger_kq_event(kq: RawFd, ident: usize) {
    if kq < 0 {
        return;
    }
    let kev = libc::kevent {
        ident,
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
pub(crate) fn kq_ctl(kq: RawFd, fd: RawFd, filter: i16, flags: u16, udata: usize) {
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

// ============================================================================
// Pure-Rust IPv4 / TCP / ARP Packet Primitives (Zero Allocations on Fast Path)
// ============================================================================
#[inline]
pub(crate) fn ipv4_checksum(hdr: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut i = 0;
    while i + 1 < hdr.len() {
        sum += u16::from_be_bytes([hdr[i], hdr[i + 1]]) as u32;
        i += 2;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

#[inline]
pub(crate) fn parse_tcp_syn_options(opts: &[u8]) -> (usize, u8, bool) {
    let mut mss: usize = 1460;
    let mut peer_ws: u8 = 0;
    let mut has_ws = false;
    let mut i = 0;
    while i < opts.len() {
        match opts[i] {
            0 => break,  // EOL
            1 => i += 1, // NOP
            kind => {
                if i + 1 >= opts.len() {
                    break;
                }
                let len = opts[i + 1] as usize;
                if len < 2 || i + len > opts.len() {
                    break;
                }
                if kind == 2 && len == 4 {
                    let v = u16::from_be_bytes([opts[i + 2], opts[i + 3]]) as usize;
                    if v >= 536 {
                        mss = v;
                    }
                } else if kind == 3 && len == 3 {
                    peer_ws = opts[i + 2].min(14);
                    has_ws = true;
                }
                i += len;
            }
        }
    }
    (mss, peer_ws, has_ws)
}

pub(crate) fn build_arp_reply_for_request(cfg: &NetConfig, req: &[u8]) -> Option<[u8; 42]> {
    if req.len() < 42 || u16::from_be_bytes([req[12], req[13]]) != 0x0806 {
        return None;
    }
    if u16::from_be_bytes([req[14], req[15]]) != 1
        || u16::from_be_bytes([req[16], req[17]]) != 0x0800
        || u16::from_be_bytes([req[20], req[21]]) != 1
    {
        return None;
    }
    if req[38..42] != cfg.host_ip.octets() {
        return None;
    }
    let mut rep = [0u8; 42];
    rep[0..6].copy_from_slice(&req[22..28]); // dst MAC = requester SHA (pod mppub0 MAC)
    rep[6..12].copy_from_slice(&cfg.host_mac);
    rep[12..14].copy_from_slice(&0x0806u16.to_be_bytes());
    rep[14..16].copy_from_slice(&1u16.to_be_bytes());
    rep[16..18].copy_from_slice(&0x0800u16.to_be_bytes());
    rep[18] = 6;
    rep[19] = 4;
    rep[20..22].copy_from_slice(&2u16.to_be_bytes()); // ARP Reply
    rep[22..28].copy_from_slice(&cfg.host_mac);
    rep[28..32].copy_from_slice(&cfg.host_ip.octets());
    rep[32..38].copy_from_slice(&req[22..28]);
    rep[38..42].copy_from_slice(&req[28..32]);
    Some(rep)
}

#[inline]
fn tcp_ipv4_pseudo_csum(src: Ipv4Addr, dst: Ipv4Addr, tcp_len: usize) -> u16 {
    let s = src.octets();
    let d = dst.octets();
    let mut sum: u32 = 0;
    sum += u16::from_be_bytes([s[0], s[1]]) as u32;
    sum += u16::from_be_bytes([s[2], s[3]]) as u32;
    sum += u16::from_be_bytes([d[0], d[1]]) as u32;
    sum += u16::from_be_bytes([d[2], d[3]]) as u32;
    sum += 6u32; // IPPROTO_TCP
    sum += tcp_len as u32;
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum as u16
}

/// Encode Ethernet (14) + IPv4 (20) + TCP (20 or 28 for SYN) header into `hdr_buf`.
/// Returns header length (54 or 62 bytes).
#[inline]
#[allow(clippy::too_many_arguments)]
fn encode_tcp_headers(
    cfg: &NetConfig,
    ip_id: u16,
    peer: FlowPeer,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    payload_len: usize,
    syn_mss: Option<u16>,
    needs_pseudo_csum: bool,
    hdr_buf: &mut [u8; 64],
) -> usize {
    let tcp_len = if syn_mss.is_some() { 28 } else { 20 };
    let ip_tot_len = (20 + tcp_len + payload_len) as u16;

    // Ethernet (14 bytes) -> always target guest eth1 MAC for macvlan rootDirectRules
    hdr_buf[0..6].copy_from_slice(&cfg.guest_mac);
    hdr_buf[6..12].copy_from_slice(&cfg.host_mac);
    hdr_buf[12..14].copy_from_slice(&0x0800u16.to_be_bytes());

    // IPv4 (20 bytes)
    hdr_buf[14] = 0x45;
    hdr_buf[15] = 0x00;
    hdr_buf[16..18].copy_from_slice(&ip_tot_len.to_be_bytes());
    hdr_buf[18..20].copy_from_slice(&ip_id.to_be_bytes());
    hdr_buf[20..22].copy_from_slice(&0x4000u16.to_be_bytes()); // DF
    hdr_buf[22] = 64; // TTL
    hdr_buf[23] = 6; // TCP
    hdr_buf[24..26].copy_from_slice(&0u16.to_be_bytes());
    hdr_buf[26..30].copy_from_slice(&cfg.host_ip.octets());
    hdr_buf[30..34].copy_from_slice(&peer.guest_ip.octets());
    let csum = ipv4_checksum(&hdr_buf[14..34]);
    hdr_buf[24..26].copy_from_slice(&csum.to_be_bytes());

    // TCP (20 bytes + optional 8 bytes SYN options)
    hdr_buf[34..36].copy_from_slice(&peer.local_port.to_be_bytes());
    hdr_buf[36..38].copy_from_slice(&peer.guest_port.to_be_bytes());
    hdr_buf[38..42].copy_from_slice(&seq.to_be_bytes());
    hdr_buf[42..46].copy_from_slice(&ack.to_be_bytes());
    hdr_buf[46] = ((tcp_len / 4) as u8) << 4;
    hdr_buf[47] = flags;
    hdr_buf[48..50].copy_from_slice(&window.to_be_bytes());
    let tcp_csum = if needs_pseudo_csum {
        tcp_ipv4_pseudo_csum(cfg.host_ip, peer.guest_ip, tcp_len + payload_len)
    } else {
        0 // Offloaded via VIRTIO_NET_HDR_F_DATA_VALID
    };
    hdr_buf[50..52].copy_from_slice(&tcp_csum.to_be_bytes());
    hdr_buf[52..54].copy_from_slice(&0u16.to_be_bytes());

    if let Some(mss) = syn_mss {
        // MSS(4) + NOP(1) + WindowScale(3) = 8 bytes
        hdr_buf[54] = 2;
        hdr_buf[55] = 4;
        hdr_buf[56..58].copy_from_slice(&mss.to_be_bytes());
        hdr_buf[58] = 1; // NOP
        hdr_buf[59] = 3; // WS
        hdr_buf[60] = 3;
        hdr_buf[61] = HOST_WS_SHIFT;
    }

    14 + 20 + tcp_len
}

#[inline]
fn writable_desc_cap(bufs: &[DescBuf]) -> usize {
    bufs.iter()
        .filter(|b| b.is_write)
        .map(|b| b.len as usize)
        .sum()
}

#[inline]
fn scatter_slices_into_bufs(bufs: &[DescBuf], mem: &GuestMemory, slices: &mut [&[u8]; 4]) -> u32 {
    let mut written = 0u32;
    for b in bufs {
        if !b.is_write {
            continue;
        }
        let Some(mut dst) = mem.write_slice(b.addr, b.len as usize) else {
            continue;
        };
        for part in slices.iter_mut() {
            if part.is_empty() || dst.is_empty() {
                continue;
            }
            let n = dst.len().min(part.len());
            dst[..n].copy_from_slice(&part[..n]);
            *part = &part[n..];
            dst = &mut dst[n..];
            written += n as u32;
        }
        if slices.iter().all(|s| s.is_empty()) {
            break;
        }
    }
    written
}

// ============================================================================
// Guest RX Ring (Host -> Guest frames, priority fresh/control ahead of normal)
// Supports both standard single-buffer RX and Virtio 1.2 MRG_RXBUF chaining.
// ============================================================================
pub(crate) struct OverflowFrame {
    vhdr: [u8; VIRTIO_NET_HDR_LEN],
    data: Vec<u8>,
}

pub(crate) struct RxRingState {
    pub(crate) rx_queue: Option<VirtQueue>,
    pub(crate) mem: Option<Arc<GuestMemory>>,
    pub(crate) irq: Option<IrqLine>,
    pub(crate) mrg_rxbuf: bool,
    pub(crate) overflow_prio: VecDeque<OverflowFrame>,
    pub(crate) overflow_norm: VecDeque<OverflowFrame>,
    ip_id: AtomicU32,
}

impl RxRingState {
    pub(crate) fn new() -> Self {
        Self {
            rx_queue: None,
            mem: None,
            irq: None,
            mrg_rxbuf: false,
            overflow_prio: VecDeque::with_capacity(256),
            overflow_norm: VecDeque::with_capacity(512),
            ip_id: AtomicU32::new(1),
        }
    }

    #[inline]
    pub(crate) fn next_ip_id(&self) -> u16 {
        self.ip_id.fetch_add(1, Ordering::Relaxed) as u16
    }

    #[allow(clippy::too_many_arguments)]
    fn try_push_direct(
        rxq: &mut VirtQueue,
        mem: &GuestMemory,
        mut vhdr: [u8; VIRTIO_NET_HDR_LEN],
        hdr: &[u8],
        payload_a: &[u8],
        payload_b: &[u8],
        mrg_rxbuf: bool,
        metrics: &NetMetrics,
    ) -> bool {
        let frame_bytes = hdr.len() + payload_a.len() + payload_b.len();
        let total = VIRTIO_NET_HDR_LEN + frame_bytes;
        if !mrg_rxbuf {
            let Some((head, bufs)) = rxq.pop(mem) else {
                return false;
            };
            let mut parts = [&vhdr[..], hdr, payload_a, payload_b];
            let written = scatter_slices_into_bufs(&bufs, mem, &mut parts);
            rxq.push_used(mem, head, written);
            metrics.rx_packets.fetch_add(1, Ordering::Relaxed);
            metrics
                .rx_bytes
                .fetch_add(frame_bytes as u64, Ordering::Relaxed);
            return true;
        }

        let saved_avail = rxq.next_avail;
        let Some((h0, b0)) = rxq.pop(mem) else {
            return false;
        };
        let cap0 = writable_desc_cap(&b0);
        if cap0 >= total {
            // Fast path (0 heap allocs): fits inside a single mergeable RX buffer!
            vhdr[10..12].copy_from_slice(&1u16.to_le_bytes());
            let mut parts = [&vhdr[..], hdr, payload_a, payload_b];
            let written = scatter_slices_into_bufs(&b0, mem, &mut parts);
            rxq.push_used(mem, h0, written);
            metrics.rx_packets.fetch_add(1, Ordering::Relaxed);
            metrics
                .rx_bytes
                .fetch_add(frame_bytes as u64, Ordering::Relaxed);
            return true;
        }

        // Multi-buffer mergeable RX chain (e.g. 60 KiB GUEST_TSO4 super-frame across page_frags)
        let mut chains: Vec<(u16, Vec<DescBuf>)> = Vec::with_capacity(8);
        chains.push((h0, b0));
        let mut acc = cap0;
        while acc < total {
            let Some((hi, bi)) = rxq.pop(mem) else {
                // Atomic rollback so zero RX descriptors are ever leaked!
                rxq.next_avail = saved_avail;
                return false;
            };
            acc += writable_desc_cap(&bi);
            chains.push((hi, bi));
        }

        vhdr[10..12].copy_from_slice(&(chains.len() as u16).to_le_bytes());
        let mut parts = [&vhdr[..], hdr, payload_a, payload_b];
        let mut used_items: Vec<(u16, u32)> = Vec::with_capacity(chains.len());
        for (hi, bi) in &chains {
            let written = scatter_slices_into_bufs(bi, mem, &mut parts);
            used_items.push((*hi, written));
        }
        // Single atomic Release store makes all `num_buffers` descriptors visible together on ARM64!
        rxq.push_used_batch(mem, &used_items);
        metrics.rx_packets.fetch_add(1, Ordering::Relaxed);
        metrics
            .rx_bytes
            .fetch_add(frame_bytes as u64, Ordering::Relaxed);
        true
    }

    pub(crate) fn drain_overflow(&mut self, metrics: &NetMetrics) -> bool {
        if self.overflow_prio.is_empty() && self.overflow_norm.is_empty() {
            return false;
        }
        let (Some(mem), Some(rxq)) = (self.mem.as_ref(), self.rx_queue.as_mut()) else {
            return false;
        };
        let mut pushed = false;
        while !self.overflow_prio.is_empty() || !self.overflow_norm.is_empty() {
            let is_prio = !self.overflow_prio.is_empty();
            let front = if is_prio {
                self.overflow_prio.front().unwrap()
            } else {
                self.overflow_norm.front().unwrap()
            };
            if !Self::try_push_direct(
                rxq,
                mem,
                front.vhdr,
                &front.data,
                &[],
                &[],
                self.mrg_rxbuf,
                metrics,
            ) {
                break;
            }
            if is_prio {
                self.overflow_prio.pop_front();
            } else {
                self.overflow_norm.pop_front();
            }
            pushed = true;
        }
        pushed
    }

    /// Zero-alloc fast-path frame injection straight into guest VirtQueue RX descriptors.
    pub(crate) fn send_parts_with_vhdr(
        &mut self,
        vhdr: [u8; VIRTIO_NET_HDR_LEN],
        hdr: &[u8],
        payload_a: &[u8],
        payload_b: &[u8],
        priority: bool,
        metrics: &NetMetrics,
    ) -> bool {
        let pushed = self.drain_overflow(metrics);
        let queue_blocked = if priority {
            !self.overflow_prio.is_empty()
        } else {
            !self.overflow_prio.is_empty() || !self.overflow_norm.is_empty()
        };
        if !queue_blocked
            && let (Some(mem), Some(rxq)) = (self.mem.as_ref(), self.rx_queue.as_mut())
            && Self::try_push_direct(
                rxq,
                mem,
                vhdr,
                hdr,
                payload_a,
                payload_b,
                self.mrg_rxbuf,
                metrics,
            )
        {
            return true;
        }
        // Only allocate when guest RX ring is momentarily dry
        let mut full = Vec::with_capacity(hdr.len() + payload_a.len() + payload_b.len());
        full.extend_from_slice(hdr);
        full.extend_from_slice(payload_a);
        full.extend_from_slice(payload_b);
        let item = OverflowFrame { vhdr, data: full };
        if priority {
            if self.overflow_prio.len() < 4096 {
                self.overflow_prio.push_back(item);
            }
        } else if self.overflow_norm.len() < 8192 {
            self.overflow_norm.push_back(item);
        }
        pushed
    }

    pub(crate) fn send_parts(
        &mut self,
        hdr: &[u8],
        payload: &[u8],
        priority: bool,
        metrics: &NetMetrics,
    ) -> bool {
        let mut vhdr = [0u8; VIRTIO_NET_HDR_LEN];
        vhdr[0] = VIRTIO_NET_HDR_F_DATA_VALID;
        self.send_parts_with_vhdr(vhdr, hdr, payload, &[], priority, metrics)
    }

    #[inline]
    fn guest_wants_irq(&self) -> bool {
        if let (Some(mem), Some(rxq)) = (self.mem.as_ref(), self.rx_queue.as_ref()) {
            rxq.guest_wants_irq(mem)
        } else {
            false
        }
    }

    #[inline]
    fn raise_irq_if_wanted(&self) -> bool {
        if let (Some(mem), Some(rxq), Some(irq)) =
            (self.mem.as_ref(), self.rx_queue.as_ref(), self.irq.as_ref())
            && rxq.guest_wants_irq(mem)
        {
            irq.raise_used_buffer();
            return true;
        }
        false
    }

    #[inline]
    pub(crate) fn raise_irq(&self) {
        let _ = self.raise_irq_if_wanted();
    }
}

// ============================================================================
// Per-Connection Direct TCP State Machine (O(1) Slot Table)
// ============================================================================
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TcpState {
    SynSent,
    Established,
    FinWait,
}

struct TcpFlow {
    slot: usize,
    host_port: u16,
    local_port: u16,
    guest_port: u16,
    /// Guest address of this connection: the current SYN target until the
    /// handshake completes, then the address that accepted it.
    guest_ip: Ipv4Addr,
    handshake: SynHandshake,
    host_fd: RawFd,
    state: TcpState,
    // Sequence numbers (Host -> Guest)
    snd_una: u32,
    snd_nxt: u32,
    snd_wnd: u32,
    peer_mss: usize,
    peer_ws: u8,
    host_ws: u8,
    // Sequence numbers (Guest -> Host)
    rcv_nxt: u32,
    last_adv_wnd: usize,
    bytes_since_ack: usize,
    // Buffers
    pending_to_host: VecDeque<u8>, // Only populated when writev() hits EAGAIN/short write
    tx_unacked: VecDeque<u8>,      // Host -> Guest bytes sent starting at snd_una
    tx_unsent_off: usize,          // Offset inside tx_unacked of next unsent byte
    // Flags & lifecycle
    host_readable: bool,
    host_writable: bool,
    write_ev_armed: bool,
    host_fin_queued: bool,
    host_fin_sent: bool,
    guest_fin: bool,
    bytes_relayed: u64,
    last_tx: Instant,
    fin_time: Option<Instant>,
}

impl TcpFlow {
    fn new(
        slot: usize,
        host_port: u16,
        guest_port: u16,
        host_fd: RawFd,
        iss: u32,
        mtu: u16,
        handshake: SynHandshake,
    ) -> Self {
        Self {
            slot,
            host_port,
            local_port: EPHEMERAL_BASE + slot as u16,
            guest_port,
            guest_ip: handshake.target(),
            handshake,
            host_fd,
            state: TcpState::SynSent,
            snd_una: iss,
            snd_nxt: iss.wrapping_add(1), // SYN consumes 1 seq
            snd_wnd: 65535,
            peer_mss: (mtu as usize).saturating_sub(40).max(536),
            peer_ws: 0,
            host_ws: 0,
            rcv_nxt: 0,
            last_adv_wnd: DEFAULT_HOST_RCV_WND,
            bytes_since_ack: 0,
            pending_to_host: VecDeque::new(),
            tx_unacked: VecDeque::new(),
            tx_unsent_off: 0,
            host_readable: true,
            host_writable: true,
            write_ev_armed: false,
            host_fin_queued: false,
            host_fin_sent: false,
            guest_fin: false,
            bytes_relayed: 0,
            last_tx: Instant::now(),
            fin_time: None,
        }
    }

    #[inline]
    fn peer(&self) -> FlowPeer {
        FlowPeer {
            guest_ip: self.guest_ip,
            local_port: self.local_port,
            guest_port: self.guest_port,
        }
    }

    /// Close the host client with a reset (`SO_LINGER` 0) so a connection the
    /// guest never accepted reads as refused rather than as an empty response.
    fn reset_host(&mut self) {
        if self.host_fd >= 0 {
            let linger = libc::linger {
                l_onoff: 1,
                l_linger: 0,
            };
            unsafe {
                libc::setsockopt(
                    self.host_fd,
                    libc::SOL_SOCKET,
                    libc::SO_LINGER,
                    (&linger as *const libc::linger).cast(),
                    std::mem::size_of::<libc::linger>() as libc::socklen_t,
                );
            }
        }
        self.close_fd();
    }

    #[inline]
    fn is_fresh(&self) -> bool {
        self.bytes_relayed < FRESH_BYTE_THRESHOLD
    }

    /// Both directions finished and every byte acknowledged.
    #[inline]
    fn is_fully_closed(&self) -> bool {
        self.guest_fin
            && self.host_fin_sent
            && self.pending_to_host.is_empty()
            && self.tx_unacked.is_empty()
            && self.snd_una == self.snd_nxt
    }

    #[inline]
    fn rcv_wnd_bytes(&self, max_buf: usize) -> usize {
        max_buf.saturating_sub(self.pending_to_host.len())
    }

    #[inline]
    fn encoded_rcv_wnd(&self, max_buf: usize) -> u16 {
        let bytes = self.rcv_wnd_bytes(max_buf);
        let scaled = bytes >> self.host_ws;
        scaled.min(u16::MAX as usize) as u16
    }

    fn close_fd(&mut self) {
        if self.host_fd >= 0 {
            unsafe {
                libc::close(self.host_fd);
            }
            self.host_fd = -1;
        }
    }
}

impl Drop for TcpFlow {
    fn drop(&mut self) {
        self.close_fd();
    }
}

struct TxQueueShared {
    tx_queue: Option<VirtQueue>,
    kicked: bool,
    worker_parked: bool,
}

struct NetShared {
    cfg: NetConfig,
    kq_fd: Arc<OwnedFd>,
    write_kq_fds: [OwnedFd; 2],
    max_rcv_buf: usize,
    max_pairs: usize,
    active_pairs: AtomicU32,
    mrg_rxbuf: AtomicBool,
    guest_tso4: AtomicBool,
    ip_id: AtomicU32,
    mem: Mutex<Option<Arc<GuestMemory>>>,
    irq: Mutex<Option<IrqLine>>,
    rx_rings: Vec<Mutex<RxRingState>>,
    tx_states: Vec<(Mutex<TxQueueShared>, Condvar)>,
    flows: Vec<Mutex<Option<TcpFlow>>>,
    active_slots: Mutex<HashSet<usize>>,
    next_slot: AtomicU32,
    next_iss: AtomicU32,
    /// Guest address that last accepted each published guest port, and the most
    /// recent such address overall (the first guess for a newly bound port).
    accepted_targets: Mutex<(HashMap<u16, Ipv4Addr>, Ipv4Addr)>,
    metrics: Arc<NetMetrics>,
    paused: AtomicBool,
    shutdown: AtomicBool,
}

impl NetShared {
    fn new_handshake(&self, guest_port: u16, now: Instant) -> SynHandshake {
        let preferred = {
            let g = self.accepted_targets.lock().unwrap();
            g.0.get(&guest_port).copied().unwrap_or(g.1)
        };
        let mut candidates = [self.cfg.guest_ip; MAX_SYN_TARGETS];
        let mut n = 1;
        for &ip in self.cfg.fallback_guest_ips.iter().take(MAX_SYN_TARGETS - 1) {
            candidates[n] = ip;
            n += 1;
        }
        SynHandshake::new(preferred, &candidates[..n], now)
    }

    fn record_accepted_target(&self, guest_port: u16, ip: Ipv4Addr) {
        let mut g = self.accepted_targets.lock().unwrap();
        g.0.insert(guest_port, ip);
        g.1 = ip;
    }

    /// Send a SYN for `flow` to `target` and make it the flow's current address.
    fn send_syn(&self, flow: &mut TcpFlow, target: Ipv4Addr) -> u32 {
        flow.guest_ip = target;
        flow.last_tx = Instant::now();
        let mss = self.cfg.mtu.saturating_sub(40).max(536);
        self.send_tcp(
            Some(flow.slot),
            flow.peer(),
            flow.snd_una,
            0,
            TCP_SYN,
            u16::MAX,
            &[],
            Some(mss),
            true,
            false,
        )
    }

    /// Tear down the flow in `slot` (closing its host socket) and reset the guest side.
    fn abort_flow(&self, slot: usize, mut guard: MutexGuard<'_, Option<TcpFlow>>) -> u32 {
        let Some(flow) = guard.take() else {
            return 0;
        };
        drop(guard);
        self.active_slots.lock().unwrap().remove(&slot);
        self.send_tcp(
            Some(slot),
            flow.peer(),
            flow.snd_nxt,
            flow.rcv_nxt,
            TCP_RST | TCP_ACK,
            0,
            &[],
            None,
            true,
            false,
        )
    }

    /// Drop the flow in `slot` without telling the guest (it already closed or reset).
    fn release_flow(&self, slot: usize, mut guard: MutexGuard<'_, Option<TcpFlow>>) {
        *guard = None;
        drop(guard);
        self.active_slots.lock().unwrap().remove(&slot);
    }

    /// Reset a guest-side segment that belongs to no live connection.
    fn send_stray_rst(&self, slot: usize, peer: FlowPeer, seg_ack: u32) -> u32 {
        self.send_tcp(
            Some(slot),
            peer,
            seg_ack,
            0,
            TCP_RST,
            0,
            &[],
            None,
            true,
            false,
        )
    }

    /// Dedicated fresh-connection RX steering:
    /// - Queue `0` is reserved for ARP, SYN, FIN, RST, fresh requests (`< 64 KiB`), and window-open ACKs.
    /// - Queues `1..(active_pairs)` shard established bulk flow traffic by flow slot (0 cross-queue contention!).
    #[inline]
    fn select_rx_ring(&self, slot: Option<usize>, priority: bool) -> usize {
        let pairs = (self.active_pairs.load(Ordering::Relaxed) as usize).clamp(1, self.max_pairs);
        if pairs <= 1 || priority {
            return 0;
        }
        match slot {
            Some(s) => 1 + (s % (pairs - 1)),
            None => 0,
        }
    }

    #[inline]
    fn raise_rx_irqs(&self, mask: u32) -> bool {
        if mask == 0 {
            return false;
        }
        let pairs = (self.active_pairs.load(Ordering::Relaxed) as usize).clamp(1, self.max_pairs);
        for idx in 0..pairs {
            if (mask & (1u32 << idx)) != 0
                && self.rx_rings[idx].lock().unwrap().raise_irq_if_wanted()
            {
                return true;
            }
        }
        false
    }

    #[allow(clippy::too_many_arguments)]
    fn send_tcp_slices(
        &self,
        slot: Option<usize>,
        peer: FlowPeer,
        seq: u32,
        ack: u32,
        flags: u8,
        window: u16,
        payload_a: &[u8],
        payload_b: &[u8],
        syn_mss: Option<u16>,
        gso_mss: Option<u16>,
        priority: bool,
        raise_now: bool,
    ) -> u32 {
        let payload_len = payload_a.len() + payload_b.len();
        let mut hdr = [0u8; 64];
        let ip_id = self.ip_id.fetch_add(1, Ordering::Relaxed) as u16;
        let is_gso = gso_mss.is_some() && payload_len > 0;
        let hlen = encode_tcp_headers(
            &self.cfg,
            ip_id,
            peer,
            seq,
            ack,
            flags,
            window,
            payload_len,
            syn_mss,
            is_gso,
            &mut hdr,
        );
        let mut vhdr = [0u8; VIRTIO_NET_HDR_LEN];
        if let Some(mss) = gso_mss {
            vhdr[0] = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            vhdr[1] = VIRTIO_NET_HDR_GSO_TCPV4;
            vhdr[2..4].copy_from_slice(&(hlen as u16).to_le_bytes());
            vhdr[4..6].copy_from_slice(&mss.to_le_bytes());
            vhdr[6..8].copy_from_slice(&34u16.to_le_bytes()); // Eth(14) + IPv4(20)
            vhdr[8..10].copy_from_slice(&16u16.to_le_bytes()); // TCP checksum offset
        } else {
            vhdr[0] = VIRTIO_NET_HDR_F_DATA_VALID;
        }
        let ring_idx = self.select_rx_ring(slot, priority);
        let mut rx = self.rx_rings[ring_idx].lock().unwrap();
        let pushed = rx.send_parts_with_vhdr(
            vhdr,
            &hdr[..hlen],
            payload_a,
            payload_b,
            priority,
            &self.metrics,
        );
        if pushed && raise_now {
            let _ = rx.raise_irq_if_wanted();
        }
        if pushed { 1u32 << ring_idx } else { 0 }
    }

    #[allow(clippy::too_many_arguments)]
    fn send_tcp(
        &self,
        slot: Option<usize>,
        peer: FlowPeer,
        seq: u32,
        ack: u32,
        flags: u8,
        window: u16,
        payload: &[u8],
        syn_mss: Option<u16>,
        priority: bool,
        raise_now: bool,
    ) -> u32 {
        self.send_tcp_slices(
            slot,
            peer,
            seq,
            ack,
            flags,
            window,
            payload,
            &[],
            syn_mss,
            None,
            priority,
            raise_now,
        )
    }

    /// Pump any readable bytes from Darwin `host_fd` into the guest RX ring (Host -> Guest).
    /// Returns true if the flow should be aborted/closed.
    fn pump_host_to_guest(
        &self,
        flow: &mut TcpFlow,
        scratch: &mut [u8],
        irq_mask: &mut u32,
        raise_now: bool,
    ) -> bool {
        if flow.state != TcpState::Established {
            return false;
        }
        while flow.host_readable && !flow.host_fin_queued && flow.host_fd >= 0 {
            let avail_buf = MAX_TX_INFLIGHT.saturating_sub(flow.tx_unacked.len());
            if avail_buf == 0 {
                break;
            }
            let cap = avail_buf.min(scratch.len());
            let rc = unsafe { libc::read(flow.host_fd, scratch.as_mut_ptr().cast(), cap) };
            if rc > 0 {
                let n = rc as usize;
                flow.tx_unacked.extend(&scratch[..n]);
                flow.bytes_relayed += n as u64;
                // Under EV_CLEAR (edge-triggered kqueue), NEVER stop just because n < cap:
                // keep looping until EAGAIN/WouldBlock or rc == 0 (EOF) so a combined
                // payload + SHUT_WR edge never drops EOF!
            } else if rc == 0 {
                flow.host_fin_queued = true;
                flow.host_readable = false;
                break;
            } else {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::WouldBlock {
                    flow.host_readable = false;
                    break;
                }
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return true; // Fatal host read error -> RST
            }
        }
        let pushed_mask = self.flush_tx_to_guest(flow, false);
        *irq_mask |= pushed_mask;
        if pushed_mask != 0 && raise_now {
            self.raise_rx_irqs(pushed_mask);
        }
        false
    }

    /// Transmit unsent bytes in `flow.tx_unacked` up to `peer_snd_wnd` directly to guest RX ring.
    /// Zero-copy from `VecDeque::as_slices()`, coalescing up to 60 KiB super-frames when
    /// `VIRTIO_NET_F_GUEST_TSO4` + `VIRTIO_NET_F_MRG_RXBUF` are negotiated.
    fn flush_tx_to_guest(&self, flow: &mut TcpFlow, raise_now: bool) -> u32 {
        let mut pushed_mask = 0u32;
        let is_prio = flow.is_fresh();
        let wnd = flow.encoded_rcv_wnd(self.max_rcv_buf);
        let use_gso =
            self.guest_tso4.load(Ordering::Relaxed) && self.mrg_rxbuf.load(Ordering::Relaxed);
        let max_seg = if use_gso {
            MAX_GUEST_TSO4_PAYLOAD
        } else {
            flow.peer_mss.min(9000)
        };

        while flow.tx_unsent_off < flow.tx_unacked.len() {
            let in_flight = flow.snd_nxt.wrapping_sub(flow.snd_una) as usize;
            let allowed = (flow.snd_wnd as usize).saturating_sub(in_flight);
            if allowed == 0 {
                break;
            }
            let rem = flow.tx_unacked.len() - flow.tx_unsent_off;
            let seg_len = rem.min(allowed).min(max_seg);
            let (s1, s2) = flow.tx_unacked.as_slices();
            let off = flow.tx_unsent_off;
            let (pa, pb): (&[u8], &[u8]) = if off < s1.len() {
                let first = (s1.len() - off).min(seg_len);
                let second = seg_len - first;
                (&s1[off..off + first], &s2[..second])
            } else {
                let off2 = off - s1.len();
                (&s2[off2..off2 + seg_len], &[])
            };

            let is_last_unsent = flow.tx_unsent_off + seg_len >= flow.tx_unacked.len();
            let mut flags = TCP_ACK;
            if is_last_unsent {
                flags |= TCP_PSH;
            }
            let seq = flow.snd_nxt;
            flow.snd_nxt = flow.snd_nxt.wrapping_add(seg_len as u32);
            flow.tx_unsent_off += seg_len;
            flow.last_tx = Instant::now();
            flow.bytes_since_ack = 0;
            flow.last_adv_wnd = flow.rcv_wnd_bytes(self.max_rcv_buf);

            let gso_mss = if use_gso && seg_len > flow.peer_mss {
                Some(flow.peer_mss.min(u16::MAX as usize) as u16)
            } else {
                None
            };

            pushed_mask |= self.send_tcp_slices(
                Some(flow.slot),
                flow.peer(),
                seq,
                flow.rcv_nxt,
                flags,
                wnd,
                pa,
                pb,
                None,
                gso_mss,
                is_prio,
                false,
            );
        }

        // Send FIN once all Host -> Guest bytes have been emitted
        if flow.host_fin_queued
            && !flow.host_fin_sent
            && flow.tx_unsent_off == flow.tx_unacked.len()
        {
            flow.host_fin_sent = true;
            flow.state = TcpState::FinWait;
            flow.fin_time = Some(Instant::now());
            let seq = flow.snd_nxt;
            flow.snd_nxt = flow.snd_nxt.wrapping_add(1);
            flow.last_tx = Instant::now();
            pushed_mask |= self.send_tcp(
                Some(flow.slot),
                flow.peer(),
                seq,
                flow.rcv_nxt,
                TCP_FIN | TCP_ACK,
                wnd,
                &[],
                None,
                true,
                false,
            );
        }

        if pushed_mask != 0 && raise_now {
            self.raise_rx_irqs(pushed_mask);
        }
        pushed_mask
    }

    /// Flush buffered `pending_to_host` bytes to Darwin socket (called from kqueue EVFILT_WRITE).
    /// Returns true if the flow should be aborted/closed.
    fn drain_pending_to_host(
        &self,
        flow: &mut TcpFlow,
        irq_mask: &mut u32,
        raise_now: bool,
    ) -> bool {
        if flow.host_fd < 0 {
            return false;
        }
        let mut drained = 0usize;
        while !flow.pending_to_host.is_empty() && flow.host_writable {
            let (s1, s2) = flow.pending_to_host.as_slices();
            let mut iovs = [
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
            let rc = unsafe { libc::writev(flow.host_fd, iovs.as_mut_ptr(), niov) };
            if rc > 0 {
                let n = rc as usize;
                flow.pending_to_host.drain(..n);
                drained += n;
            } else if rc < 0 {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::WouldBlock {
                    flow.host_writable = false;
                    break;
                }
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return true; // Fatal host write error -> RST
            } else {
                break;
            }
        }

        // Re-arm EV_ONESHOT write readiness if bytes remain buffered after hitting WouldBlock
        if !flow.pending_to_host.is_empty() && !flow.write_ev_armed && flow.host_fd >= 0 {
            kq_ctl(
                self.write_kq_fds[flow.slot & 1].as_raw_fd(),
                flow.host_fd,
                libc::EVFILT_WRITE,
                libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                UDATA_CONN_TAG | flow.slot,
            );
            flow.write_ev_armed = true;
        }

        // If guest already sent FIN and all pending bytes are now written, propagate half-close
        if flow.guest_fin && flow.pending_to_host.is_empty() && flow.host_fd >= 0 {
            unsafe {
                libc::shutdown(flow.host_fd, libc::SHUT_WR);
            }
        }

        // Send priority window-update ACK when buffer opened up substantially (never drop!)
        if drained > 0 {
            let new_wnd = flow.rcv_wnd_bytes(self.max_rcv_buf);
            if new_wnd >= flow.last_adv_wnd + 65536
                || (flow.last_adv_wnd < 65536 && new_wnd >= 65536)
                || flow.pending_to_host.is_empty()
            {
                flow.last_adv_wnd = new_wnd;
                flow.bytes_since_ack = 0;
                let wnd = flow.encoded_rcv_wnd(self.max_rcv_buf);
                // Keep fresh-flow window-open ACKs on RX queue 0; shard bulk window-open ACKs
                // across bulk RX queues 1..N so RX queue 0 stays dedicated to fresh traffic!
                *irq_mask |= self.send_tcp(
                    Some(flow.slot),
                    flow.peer(),
                    flow.snd_nxt,
                    flow.rcv_nxt,
                    TCP_ACK,
                    wnd,
                    &[],
                    None,
                    flow.is_fresh(),
                    raise_now,
                );
            }
        }
        false
    }

    /// Zero-copy Guest->Host TX packet handler called directly from Virtio-Net TX queue!
    /// Returns a bitmask of RX rings that received frames (for batched IRQ delivery).
    fn handle_guest_tx_chain(
        &self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        total_len: usize,
        scratch: &mut [u8],
    ) -> u32 {
        if total_len <= VIRTIO_NET_HDR_LEN + 14 {
            return 0;
        }
        // Copy first <=128 bytes onto stack to parse Virtio + Eth + IPv4 + TCP headers (0 heap allocs!)
        let mut hdr = [0u8; 128];
        let hdr_copy_len = total_len.min(hdr.len());
        {
            let mut copied = 0usize;
            for b in bufs {
                if b.is_write {
                    continue;
                }
                if let Some(s) = mem.read_slice(b.addr, b.len as usize) {
                    let take = s.len().min(hdr_copy_len - copied);
                    hdr[copied..copied + take].copy_from_slice(&s[..take]);
                    copied += take;
                    if copied >= hdr_copy_len {
                        break;
                    }
                }
            }
        }

        let eth = &hdr[VIRTIO_NET_HDR_LEN..hdr_copy_len];
        let ethertype = u16::from_be_bytes([eth[12], eth[13]]);

        // 1. Direct ARP Responder (handles cross-subnet pod mppub0 10.88.x.x -> 10.43.0.1!)
        if ethertype == 0x0806 {
            if let Some(rep) = build_arp_reply_for_request(&self.cfg, eth) {
                let mut rx = self.rx_rings[0].lock().unwrap();
                if rx.send_parts(&rep, &[], true, &self.metrics) {
                    return 1;
                }
            }
            return 0;
        }

        // 2. IPv4 TCP Direct Fast-Path (O(1) slot lookup by dst_port!)
        if ethertype != 0x0800 || eth.len() < 34 || eth[23] != 6 {
            return 0;
        }
        let ihl = ((eth[14] & 0x0f) as usize) * 4;
        let tcp_off = 14 + ihl;
        if eth.len() < tcp_off + 20 {
            return 0;
        }
        let thl = (((eth[tcp_off + 12] >> 4) & 0x0f) as usize) * 4;
        if thl < 20 || eth.len() < tcp_off + thl {
            return 0;
        }

        let guest_port = u16::from_be_bytes([eth[tcp_off], eth[tcp_off + 1]]);
        let local_port = u16::from_be_bytes([eth[tcp_off + 2], eth[tcp_off + 3]]);
        let seg_seq = u32::from_be_bytes(eth[tcp_off + 4..tcp_off + 8].try_into().unwrap());
        let seg_ack = u32::from_be_bytes(eth[tcp_off + 8..tcp_off + 12].try_into().unwrap());
        let flags = eth[tcp_off + 13];
        let seg_wnd = u16::from_be_bytes([eth[tcp_off + 14], eth[tcp_off + 15]]);

        let hdr_total_in_chain = VIRTIO_NET_HDR_LEN + tcp_off + thl;
        let gso_type = hdr[1]; // virtio_net_hdr.gso_type (0 = NONE, 1 = TCPV4)
        let ip_tot_len = u16::from_be_bytes([eth[16], eth[17]]) as usize;
        let raw_payload = total_len.saturating_sub(hdr_total_in_chain);
        let payload_len = if gso_type == 0 && ip_tot_len >= ihl + thl {
            (ip_tot_len - ihl - thl).min(raw_payload)
        } else {
            raw_payload
        };

        let Some(slot_u16) = local_port.checked_sub(EPHEMERAL_BASE) else {
            return 0;
        };
        let slot = slot_u16 as usize;
        if slot >= MAX_SLOTS {
            return 0;
        }

        let src_ip = Ipv4Addr::new(eth[26], eth[27], eth[28], eth[29]);
        let sender = FlowPeer {
            guest_ip: src_ip,
            local_port,
            guest_port,
        };

        let mut guard = self.flows[slot].lock().unwrap();
        let Some(flow) = guard.as_mut() else {
            // Unknown / already-closed flow -> reply RST if not RST
            if (flags & TCP_RST) == 0 && (flags & TCP_ACK) != 0 {
                return self.send_stray_rst(slot, sender, seg_ack);
            }
            return 0;
        };
        if flow.guest_port != guest_port {
            return 0;
        }

        let mut irq_mask = 0u32;

        // A. Handshake: the guest accepts (SYN-ACK) or refuses (RST) on some address.
        if flow.state == TcpState::SynSent {
            if !flow.handshake.is_candidate(src_ip) {
                return 0;
            }
            if (flags & TCP_RST) != 0 {
                // RFC 9293: in SYN-SENT a reset is acceptable only if it acknowledges our SYN.
                if (flags & TCP_ACK) == 0 || seg_ack != flow.snd_nxt {
                    return 0;
                }
                return match flow.handshake.on_refused(src_ip, Instant::now()) {
                    SynAction::Send(target) => self.send_syn(flow, target),
                    SynAction::Wait => 0,
                    SynAction::GiveUp => {
                        flow.reset_host();
                        self.release_flow(slot, guard);
                        self.metrics
                            .published_refused
                            .fetch_add(1, Ordering::Relaxed);
                        0
                    }
                };
            }
            if (flags & (TCP_SYN | TCP_ACK)) == (TCP_SYN | TCP_ACK) && seg_ack == flow.snd_nxt {
                flow.guest_ip = src_ip;
                self.record_accepted_target(flow.guest_port, src_ip);
                let (mss, p_ws, has_ws) = parse_tcp_syn_options(&eth[tcp_off + 20..tcp_off + thl]);
                flow.peer_mss = mss.min((self.cfg.mtu as usize).saturating_sub(40));
                if has_ws {
                    flow.peer_ws = p_ws;
                    flow.host_ws = HOST_WS_SHIFT;
                } else {
                    flow.peer_ws = 0;
                    flow.host_ws = 0;
                }
                flow.snd_una = seg_ack;
                flow.snd_wnd = seg_wnd as u32; // RFC 7323: SYN-ACK window is unscaled
                flow.rcv_nxt = seg_seq.wrapping_add(1);
                flow.state = TcpState::Established;
                flow.last_adv_wnd = flow.rcv_wnd_bytes(self.max_rcv_buf);

                // Immediately try reading waiting HTTP request from host_fd so ACK + GET /id
                // ride in the same burst (zero extra kqueue wakeup on fresh requests!)
                let before_nxt = flow.snd_nxt;
                let fatal = self.pump_host_to_guest(flow, scratch, &mut irq_mask, false);
                if fatal {
                    return irq_mask | self.abort_flow(slot, guard);
                }
                if flow.snd_nxt == before_nxt {
                    // No host payload sent yet -> emit pure ACK to complete 3-way handshake
                    let wnd = flow.encoded_rcv_wnd(self.max_rcv_buf);
                    irq_mask |= self.send_tcp(
                        Some(slot),
                        flow.peer(),
                        flow.snd_nxt,
                        flow.rcv_nxt,
                        TCP_ACK,
                        wnd,
                        &[],
                        None,
                        true,
                        false,
                    );
                }
            }
            return irq_mask;
        }

        // A segment from another candidate address (e.g. a late SYN-ACK to a SYN
        // that was superseded) belongs to no connection: reset its half-open socket.
        if src_ip != flow.guest_ip {
            if (flags & TCP_RST) == 0 {
                return self.send_stray_rst(slot, sender, seg_ack);
            }
            return 0;
        }

        // RST from guest -> tear down immediately
        if (flags & TCP_RST) != 0 {
            self.release_flow(slot, guard);
            return 0;
        }

        // B. Process ACK field (advance snd_una, drain tx_unacked, update peer snd_wnd)
        if (flags & TCP_ACK) != 0 {
            let old_wnd = flow.snd_wnd;
            flow.snd_wnd = (seg_wnd as u32) << flow.peer_ws;
            let acked = seg_ack.wrapping_sub(flow.snd_una) as i32;
            let wnd_opened = flow.snd_wnd > old_wnd;
            if acked > 0 {
                let mut rem = acked as usize;
                let data_acked = rem.min(flow.tx_unacked.len());
                if data_acked > 0 {
                    flow.tx_unacked.drain(..data_acked);
                    flow.tx_unsent_off = flow.tx_unsent_off.saturating_sub(data_acked);
                    rem -= data_acked;
                }
                // FIN acked if rem >= 1 and host_fin_sent
                let _ = rem;
                flow.snd_una = seg_ack;
            }
            if (acked > 0 || wnd_opened)
                && (flow.tx_unsent_off < flow.tx_unacked.len() || flow.host_readable)
            {
                let fatal = self.pump_host_to_guest(flow, scratch, &mut irq_mask, false);
                if fatal {
                    return irq_mask | self.abort_flow(slot, guard);
                }
            }
        }

        // C. Process Guest -> Host Payload (TRUE ZERO-COPY writev() FROM GUEST RAM!)
        let mut send_ack = false;
        let mut arm_write = false;
        let mut abort_flow = false;

        if payload_len > 0 {
            let seq_diff = seg_seq.wrapping_sub(flow.rcv_nxt) as i32;
            if seq_diff > 0 {
                // Out-of-order segment -> emit duplicate ACK so Linux fast-retransmits
                send_ack = true;
            } else {
                let overlap = (-seq_diff) as usize;
                if overlap >= payload_len {
                    // Pure duplicate retransmit -> ACK current rcv_nxt
                    send_ack = true;
                } else {
                    let new_bytes = payload_len - overlap;
                    let skip_total = hdr_total_in_chain + overlap;

                    if flow.pending_to_host.is_empty() && flow.host_fd >= 0 {
                        // ZERO-COPY FAST PATH: build iovec pointing directly into GuestMemory!
                        let mut iovs = [libc::iovec {
                            iov_base: std::ptr::null_mut(),
                            iov_len: 0,
                        }; 32];
                        let mut niov = 0usize;
                        let mut to_skip = skip_total;
                        let mut collected = 0usize;
                        for b in bufs {
                            if b.is_write {
                                continue;
                            }
                            let blen = b.len as usize;
                            if to_skip >= blen {
                                to_skip -= blen;
                                continue;
                            }
                            let Some(s) = mem.read_slice(b.addr, blen) else {
                                break;
                            };
                            let slice = &s[to_skip..];
                            to_skip = 0;
                            let take = slice.len().min(new_bytes - collected);
                            if take > 0 && niov < iovs.len() {
                                iovs[niov] = libc::iovec {
                                    iov_base: slice.as_ptr() as *mut libc::c_void,
                                    iov_len: take,
                                };
                                niov += 1;
                                collected += take;
                                if collected >= new_bytes {
                                    break;
                                }
                            }
                        }

                        let mut written = 0usize;
                        if niov > 0 {
                            loop {
                                let rc = unsafe {
                                    libc::writev(flow.host_fd, iovs.as_ptr(), niov as libc::c_int)
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
                                    flow.host_writable = false;
                                    arm_write = true;
                                    break;
                                }
                                abort_flow = true;
                                break;
                            }
                        }

                        if !abort_flow && written < new_bytes {
                            // Copy ONLY the unwritten remainder into pending_to_host!
                            copy_chain_slice_into(
                                bufs,
                                mem,
                                skip_total + written,
                                new_bytes - written,
                                &mut flow.pending_to_host,
                            );
                            flow.host_writable = false;
                            arm_write = true;
                        }
                    } else if !abort_flow {
                        // Already backpressured -> buffer tail until EVFILT_WRITE drains
                        copy_chain_slice_into(
                            bufs,
                            mem,
                            skip_total,
                            new_bytes,
                            &mut flow.pending_to_host,
                        );
                        arm_write = true;
                    }

                    if !abort_flow {
                        flow.rcv_nxt = flow.rcv_nxt.wrapping_add(new_bytes as u32);
                        flow.bytes_relayed += new_bytes as u64;
                        flow.bytes_since_ack += new_bytes;
                        let rcv_wnd = flow.rcv_wnd_bytes(self.max_rcv_buf);
                        if flow.is_fresh()
                            || flow.bytes_since_ack >= ACK_COALESCE_BYTES
                            || rcv_wnd == 0
                            || ((flags & TCP_PSH) != 0 && payload_len < 8192)
                        {
                            send_ack = true;
                        }
                    }
                }
            }
        }

        if abort_flow {
            return irq_mask | self.abort_flow(slot, guard);
        }

        if arm_write && !flow.write_ev_armed && flow.host_fd >= 0 {
            kq_ctl(
                self.write_kq_fds[slot & 1].as_raw_fd(),
                flow.host_fd,
                libc::EVFILT_WRITE,
                libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
                UDATA_CONN_TAG | slot,
            );
            flow.write_ev_armed = true;
        }

        // D. Process FIN from guest
        if (flags & TCP_FIN) != 0
            && !flow.guest_fin
            && seg_seq.wrapping_add(payload_len as u32) == flow.rcv_nxt
        {
            flow.rcv_nxt = flow.rcv_nxt.wrapping_add(1);
            flow.guest_fin = true;
            send_ack = true;
            if flow.pending_to_host.is_empty() && flow.host_fd >= 0 {
                unsafe {
                    libc::shutdown(flow.host_fd, libc::SHUT_WR);
                }
            }
        }

        if send_ack {
            flow.bytes_since_ack = 0;
            flow.last_adv_wnd = flow.rcv_wnd_bytes(self.max_rcv_buf);
            let wnd = flow.encoded_rcv_wnd(self.max_rcv_buf);
            irq_mask |= self.send_tcp(
                Some(slot),
                flow.peer(),
                flow.snd_nxt,
                flow.rcv_nxt,
                TCP_ACK,
                wnd,
                &[],
                None,
                flow.is_fresh() || (flags & TCP_FIN) != 0,
                false,
            );
        }

        // Clean up fully closed connection
        if flow.guest_fin
            && flow.host_fin_sent
            && flow.pending_to_host.is_empty()
            && flow.tx_unacked.is_empty()
            && flow.snd_una == flow.snd_nxt
        {
            self.release_flow(slot, guard);
        }

        irq_mask
    }
}

#[inline]
pub(crate) fn copy_chain_slice_into(
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

// ============================================================================
// Darwin kqueue I/O Loop (Accept, Host->Guest Read, Backpressure Drain, Timers)
// ============================================================================
struct ListenerEntry {
    host_port: u16,
    guest_port: u16,
    listener: TcpListener,
}

fn run_net_io_loop(shared: Arc<NetShared>, cmd_rx: mpsc::Receiver<BrokerCmd>) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let kq = shared.kq_fd.as_raw_fd();
    let mut listeners: HashMap<u16, ListenerEntry> = HashMap::new();
    let mut listener_by_fd: HashMap<RawFd, u16> = HashMap::new();
    let mut prepared_guests: HashSet<u16> = HashSet::new();

    let mut scratch = vec![0u8; 64 * 1024];
    let mut events = [libc::kevent {
        ident: 0,
        filter: 0,
        flags: 0,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    }; 128];
    let mut last_timer_sweep = Instant::now();

    loop {
        if shared.shutdown.load(Ordering::Relaxed) {
            break;
        }

        // 1. Handle published-port broker control commands
        while !shared.shutdown.load(Ordering::Relaxed) {
            let Ok(cmd) = cmd_rx.try_recv() else { break };
            match cmd {
                BrokerCmd::Prepare { guest_port, reply } => {
                    let ok = !listeners.values().any(|l| l.guest_port == guest_port)
                        && prepared_guests.insert(guest_port);
                    let _ = reply.send(ok);
                }
                BrokerCmd::FinishPrepare { guest_port } => {
                    prepared_guests.remove(&guest_port);
                }
                BrokerCmd::Bind {
                    host_port,
                    guest_port,
                    reply,
                } => match TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, host_port)) {
                    Ok(listener) => {
                        if let Err(error) = listener.set_nonblocking(true) {
                            let _ = reply.send(Err(error.to_string()));
                            continue;
                        }
                        let actual = listener.local_addr().map(|a| a.port()).unwrap_or(host_port);
                        let fd = listener.as_raw_fd();
                        kq_ctl(
                            kq,
                            fd,
                            libc::EVFILT_READ,
                            libc::EV_ADD | libc::EV_ENABLE,
                            UDATA_LISTENER,
                        );
                        listener_by_fd.insert(fd, actual);
                        listeners.insert(
                            actual,
                            ListenerEntry {
                                host_port: actual,
                                guest_port,
                                listener,
                            },
                        );
                        shared
                            .metrics
                            .published_binds
                            .fetch_add(1, Ordering::Relaxed);
                        let _ = reply.send(Ok(actual));
                    }
                    Err(e) => {
                        let _ = reply.send(Err(e.to_string()));
                    }
                },
                BrokerCmd::Release { host_port, reply } => {
                    if let Some(entry) = listeners.remove(&host_port) {
                        let fd = entry.listener.as_raw_fd();
                        listener_by_fd.remove(&fd);
                        kq_ctl(kq, fd, libc::EVFILT_READ, libc::EV_DELETE, 0);
                        // The guest may reuse the port for a listener on another address.
                        shared
                            .accepted_targets
                            .lock()
                            .unwrap()
                            .0
                            .remove(&entry.guest_port);
                    }
                    let slots: Vec<usize> = shared
                        .active_slots
                        .lock()
                        .unwrap()
                        .iter()
                        .copied()
                        .collect();
                    let mut irq_mask = 0u32;
                    for slot in slots {
                        let g = shared.flows[slot].lock().unwrap();
                        if g.as_ref().is_some_and(|flow| flow.host_port == host_port) {
                            irq_mask |= shared.abort_flow(slot, g);
                        }
                    }
                    if irq_mask != 0 {
                        shared.raise_rx_irqs(irq_mask);
                    }
                    let _ = reply.send(());
                }
                BrokerCmd::QueryReleased { guest_port, reply } => {
                    let released = !prepared_guests.contains(&guest_port)
                        && !listeners.values().any(|l| l.guest_port == guest_port);
                    let _ = reply.send(released);
                }
            }
        }

        // 2. Drain any queued RX overflow across active RX rings if guest refilled descriptors
        {
            let pairs =
                (shared.active_pairs.load(Ordering::Relaxed) as usize).clamp(1, shared.max_pairs);
            let mut overflow_mask = 0u32;
            for idx in 0..pairs {
                let mut rx = shared.rx_rings[idx].lock().unwrap();
                if rx.drain_overflow(&shared.metrics) {
                    overflow_mask |= 1u32 << idx;
                }
            }
            if overflow_mask != 0 {
                shared.raise_rx_irqs(overflow_mask);
            }
        }

        // 3. Wait for Darwin kqueue events (5 ms tick while flows active, 50 ms when idle)
        let has_active = !shared.active_slots.lock().unwrap().is_empty();
        let ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: if has_active { 5_000_000 } else { 50_000_000 },
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

        let mut accept_triggered = false;
        let mut ready_slots: Vec<(usize, i16)> = Vec::new();
        if n > 0 {
            for ev in &events[..n as usize] {
                let udata = ev.udata as usize;
                if udata == UDATA_LISTENER {
                    accept_triggered = true;
                } else if (udata & UDATA_CONN_TAG) != 0 {
                    let slot = udata & !UDATA_CONN_TAG;
                    if slot < MAX_SLOTS {
                        ready_slots.push((slot, ev.filter));
                    }
                }
            }
        }

        // 4. Priority lane 1: accept new macOS client connections & emit SYN immediately on RX queue 0!
        if accept_triggered {
            let mut accept_mask = 0u32;
            for entry in listeners.values() {
                while !shared.shutdown.load(Ordering::Relaxed) {
                    match entry.listener.accept() {
                        Ok((stream, _)) => {
                            if stream.set_nonblocking(true).is_err() {
                                continue;
                            }
                            let _ = stream.set_nodelay(true);
                            let cfd = stream.into_raw_fd();
                            let one: libc::c_int = 1;
                            let snd_buf: libc::c_int = std::env::var("MICROPOD_VMM_NET_SNDBUF_KIB")
                                .ok()
                                .and_then(|s| s.parse::<libc::c_int>().ok())
                                .map(|k| k.clamp(64, 6144) * 1024)
                                .unwrap_or(512 * 1024);
                            let rcv_buf: libc::c_int = 2 * 1024 * 1024;
                            unsafe {
                                libc::setsockopt(
                                    cfd,
                                    libc::SOL_SOCKET,
                                    libc::SO_NOSIGPIPE,
                                    (&one as *const libc::c_int).cast(),
                                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                                );
                                libc::setsockopt(
                                    cfd,
                                    libc::SOL_SOCKET,
                                    libc::SO_SNDBUF,
                                    (&snd_buf as *const libc::c_int).cast(),
                                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                                );
                                libc::setsockopt(
                                    cfd,
                                    libc::SOL_SOCKET,
                                    libc::SO_RCVBUF,
                                    (&rcv_buf as *const libc::c_int).cast(),
                                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                                );
                            }

                            // Find an unused O(1) slot
                            let mut chosen: Option<usize> = None;
                            for _ in 0..MAX_SLOTS {
                                let cand = (shared.next_slot.fetch_add(1, Ordering::Relaxed)
                                    as usize)
                                    % MAX_SLOTS;
                                let mut g = shared.flows[cand].lock().unwrap();
                                if g.is_none() {
                                    let iss = shared.next_iss.fetch_add(65537, Ordering::Relaxed);
                                    *g = Some(TcpFlow::new(
                                        cand,
                                        entry.host_port,
                                        entry.guest_port,
                                        cfd,
                                        iss,
                                        shared.cfg.mtu,
                                        shared.new_handshake(entry.guest_port, Instant::now()),
                                    ));
                                    chosen = Some(cand);
                                    break;
                                }
                            }

                            let Some(slot) = chosen else {
                                unsafe {
                                    libc::close(cfd);
                                }
                                continue;
                            };

                            shared.active_slots.lock().unwrap().insert(slot);
                            kq_ctl(
                                kq,
                                cfd,
                                libc::EVFILT_READ,
                                libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                                UDATA_CONN_TAG | slot,
                            );
                            if let Some(flow) = shared.flows[slot].lock().unwrap().as_mut() {
                                let target = flow.handshake.target();
                                accept_mask |= shared.send_syn(flow, target);
                            }
                            shared
                                .metrics
                                .published_conns
                                .fetch_add(1, Ordering::Relaxed);
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => break,
                    }
                }
            }
            if accept_mask != 0 {
                shared.raise_rx_irqs(accept_mask);
            }
        }

        // 5. Handle readable/writable events on active connections:
        //    Priority lane 2: EVFILT_READ (fresh HTTP requests!) ALWAYS runs and raises IRQ
        //    BEFORE EVFILT_WRITE (bulk backpressure drains) so fresh latency stays ultra-low!
        if !ready_slots.is_empty() {
            let mut ready_reads: Vec<usize> = Vec::new();
            let mut ready_writes: Vec<usize> = Vec::new();
            for (slot, filter) in ready_slots {
                if filter == libc::EVFILT_READ {
                    ready_reads.push(slot);
                } else if filter == libc::EVFILT_WRITE {
                    ready_writes.push(slot);
                }
            }

            if !ready_reads.is_empty() {
                let mut read_mask = 0u32;
                for slot in ready_reads {
                    let mut g = shared.flows[slot].lock().unwrap();
                    let Some(flow) = g.as_mut() else {
                        continue;
                    };
                    flow.host_readable = true;
                    let abort =
                        shared.pump_host_to_guest(flow, &mut scratch, &mut read_mask, false);
                    if abort {
                        read_mask |= shared.abort_flow(slot, g);
                    } else if flow.is_fully_closed() {
                        shared.release_flow(slot, g);
                    }
                }
                if read_mask != 0 {
                    shared.raise_rx_irqs(read_mask);
                }
            }

            if !ready_writes.is_empty() {
                let mut write_mask = 0u32;
                for slot in ready_writes {
                    let mut g = shared.flows[slot].lock().unwrap();
                    let Some(flow) = g.as_mut() else {
                        continue;
                    };
                    flow.host_writable = true;
                    let abort = shared.drain_pending_to_host(flow, &mut write_mask, false);
                    if abort {
                        write_mask |= shared.abort_flow(slot, g);
                    } else if flow.is_fully_closed() {
                        shared.release_flow(slot, g);
                    }
                }
                if write_mask != 0 {
                    shared.raise_rx_irqs(write_mask);
                }
            }
        }

        // 6. Periodic timer (5ms while active): SYN/data retransmit & self-healing window updates
        if last_timer_sweep.elapsed() >= Duration::from_millis(5) {
            last_timer_sweep = Instant::now();
            let slots: Vec<usize> = shared
                .active_slots
                .lock()
                .unwrap()
                .iter()
                .copied()
                .collect();
            let mut timer_mask = 0u32;
            for slot in slots {
                let mut g = shared.flows[slot].lock().unwrap();
                let Some(flow) = g.as_mut() else {
                    drop(g);
                    shared.active_slots.lock().unwrap().remove(&slot);
                    continue;
                };
                if flow.state == TcpState::SynSent {
                    match flow.handshake.on_timer(Instant::now(), flow.last_tx) {
                        SynAction::Send(target) => timer_mask |= shared.send_syn(flow, target),
                        SynAction::Wait => {}
                        SynAction::GiveUp => {
                            flow.reset_host();
                            shared.release_flow(slot, g);
                            shared
                                .metrics
                                .published_refused
                                .fetch_add(1, Ordering::Relaxed);
                        }
                    }
                } else if !flow.tx_unacked.is_empty()
                    && flow.last_tx.elapsed() >= Duration::from_millis(200)
                {
                    // Retransmit unacked Host -> Guest bytes
                    flow.tx_unsent_off = 0;
                    flow.snd_nxt = flow.snd_una;
                    timer_mask |= shared.flush_tx_to_guest(flow, false);
                } else if flow.state == TcpState::Established {
                    // Self-healing Host->Guest pump if EVFILT_READ left readable bytes buffered
                    if flow.host_readable && flow.tx_unacked.len() < MAX_TX_INFLIGHT {
                        let abort =
                            shared.pump_host_to_guest(flow, &mut scratch, &mut timer_mask, false);
                        if abort {
                            timer_mask |= shared.abort_flow(slot, g);
                            continue;
                        }
                    }
                    // Self-healing backpressure & delayed-ACK safety net (eliminates zero-window stalls)
                    if !flow.pending_to_host.is_empty() {
                        flow.host_writable = true;
                        let abort = shared.drain_pending_to_host(flow, &mut timer_mask, false);
                        if abort {
                            timer_mask |= shared.abort_flow(slot, g);
                            continue;
                        }
                    } else if flow.bytes_since_ack > 0
                        || flow.rcv_wnd_bytes(shared.max_rcv_buf) > flow.last_adv_wnd
                    {
                        flow.bytes_since_ack = 0;
                        flow.last_adv_wnd = flow.rcv_wnd_bytes(shared.max_rcv_buf);
                        let wnd = flow.encoded_rcv_wnd(shared.max_rcv_buf);
                        timer_mask |= shared.send_tcp(
                            Some(slot),
                            flow.peer(),
                            flow.snd_nxt,
                            flow.rcv_nxt,
                            TCP_ACK,
                            wnd,
                            &[],
                            None,
                            flow.is_fresh(),
                            false,
                        );
                    }
                } else if let Some(ft) = flow.fin_time
                    && ft.elapsed() >= Duration::from_secs(2)
                {
                    shared.release_flow(slot, g);
                }
            }
            if timer_mask != 0 {
                shared.raise_rx_irqs(timer_mask);
            }
        }
    }
}

/// Dedicated P-core kqueue worker for `EVFILT_WRITE` bulk backpressure drains,
/// completely decoupled from `run_net_io_loop` (`accept()` / `EVFILT_READ` fresh lane!).
fn run_write_drain_loop(shared: Arc<NetShared>, shard: usize) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let kq = shared.write_kq_fds[shard].as_raw_fd();
    let mut events = [libc::kevent {
        ident: 0,
        filter: 0,
        flags: 0,
        fflags: 0,
        data: 0,
        udata: std::ptr::null_mut(),
    }; 128];

    loop {
        if shared.shutdown.load(Ordering::Relaxed) {
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
        if n <= 0 {
            continue;
        }
        let mut write_mask = 0u32;
        for ev in &events[..n as usize] {
            let udata = ev.udata as usize;
            if (udata & UDATA_CONN_TAG) == 0 {
                continue;
            }
            let slot = udata & !UDATA_CONN_TAG;
            if slot >= MAX_SLOTS {
                continue;
            }
            let mut g = shared.flows[slot].lock().unwrap();
            let Some(flow) = g.as_mut() else {
                continue;
            };
            // EV_ONESHOT automatically disarmed this event on delivery
            flow.write_ev_armed = false;
            flow.host_writable = true;
            if flow.pending_to_host.is_empty() {
                continue;
            }
            let abort = shared.drain_pending_to_host(flow, &mut write_mask, false);
            if abort {
                write_mask |= shared.abort_flow(slot, g);
            } else if flow.is_fully_closed() {
                shared.release_flow(slot, g);
            }
        }
        if write_mask != 0 {
            shared.raise_rx_irqs(write_mask);
        }
    }
}

/// Peek the destination TCP `local_port` from a Virtio-Net TX descriptor chain
/// (used by two-pass priority TX draining so small fresh packets jump ahead of
/// 64 KiB bulk TSO4 frames without ever reordering frames of the same flow).
#[inline]
fn peek_tx_tcp_local_port(bufs: &[DescBuf], mem: &GuestMemory) -> Option<u16> {
    let mut hdr = [0u8; 64];
    let mut copied = 0usize;
    for b in bufs {
        if b.is_write {
            continue;
        }
        if let Some(s) = mem.read_slice(b.addr, b.len as usize) {
            let take = s.len().min(hdr.len() - copied);
            hdr[copied..copied + take].copy_from_slice(&s[..take]);
            copied += take;
            if copied >= hdr.len() {
                break;
            }
        }
    }
    if copied < VIRTIO_NET_HDR_LEN + 38 {
        return None;
    }
    let eth = &hdr[VIRTIO_NET_HDR_LEN..copied];
    if u16::from_be_bytes([eth[12], eth[13]]) != 0x0800 || eth[23] != 6 {
        return None;
    }
    let ihl = ((eth[14] & 0x0f) as usize) * 4;
    let tcp_off = 14 + ihl;
    if eth.len() < tcp_off + 4 {
        return None;
    }
    Some(u16::from_be_bytes([eth[tcp_off + 2], eth[tcp_off + 3]]))
}

/// Dedicated M5 Max P-core host thread draining Linux TX queue `pair_idx` asynchronously
/// with zero-copy `GuestMemory -> writev()`, two-pass fresh-priority scheduling, and
/// Virtio 1.2 `VRING_USED_F_NO_NOTIFY` kick suppression!
/// With `VIRTIO_NET_F_MQ` (`max_pairs = 4`), 4 parallel P-core threads drain TX queues 0..3
/// simultaneously with zero cross-queue mutex contention!
fn run_tx_drain_loop(shared: Arc<NetShared>, pair_idx: usize) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let mut scratch = vec![0u8; 64 * 1024];
    let mut txq_local: Option<VirtQueue> = None;
    type RxBatchItem = (u16, usize, Vec<DescBuf>, Option<u16>, bool);
    let mut batch_buf: Vec<RxBatchItem> = Vec::with_capacity(32);
    let mut bulk_ports = [0u16; 32];

    loop {
        if shared.shutdown.load(Ordering::Relaxed) {
            return;
        }
        let (mem, irq) = (
            shared.mem.lock().unwrap().clone(),
            shared.irq.lock().unwrap().clone(),
        );
        let (Some(mem), Some(irq)) = (mem, irq) else {
            thread::sleep(Duration::from_millis(1));
            continue;
        };

        // Wait for kick or TX queue setup on this queue pair
        {
            let mut st = shared.tx_states[pair_idx].0.lock().unwrap();
            if let (Some(lq), Some(sq)) = (txq_local.as_ref(), st.tx_queue.as_mut()) {
                sq.next_avail = lq.next_avail;
                sq.next_used = lq.next_used;
            }
            st.worker_parked = true;
            shared.tx_states[pair_idx].1.notify_all();
            while (shared.paused.load(Ordering::Acquire) || !st.kicked)
                && !shared.shutdown.load(Ordering::Relaxed)
            {
                let (ns, _) = shared.tx_states[pair_idx]
                    .1
                    .wait_timeout(st, Duration::from_millis(50))
                    .unwrap();
                st = ns;
            }
            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            st.kicked = false;
            st.worker_parked = false;
            if let Some(ref updated) = st.tx_queue {
                match txq_local {
                    Some(ref mut lq) => {
                        if lq.desc_addr != updated.desc_addr
                            || lq.avail_addr != updated.avail_addr
                            || !lq.ready
                        {
                            *lq = updated.clone();
                        } else {
                            lq.ready = updated.ready;
                            lq.size = updated.size;
                        }
                    }
                    None => txq_local = Some(updated.clone()),
                }
            }
        }

        let Some(ref mut txq) = txq_local else {
            continue;
        };
        if !txq.ready {
            continue;
        }

        // Suppress guest MMIO TX kicks while we actively drain & adaptive-poll this TX ring!
        txq.set_no_notify(&mem, true);
        let mut last_activity = Instant::now();
        let adaptive_spin = Duration::from_micros(60);

        loop {
            let mut drained_tx = false;
            let mut rx_irq_mask = 0u32;

            // Pop up to 32 available TX chains so small fresh packets (SYN-ACK, HTTP 200 OK,
            // ARP) jump straight ahead of 64 KiB bulk TSO4 frames without per-flow reordering!
            loop {
                batch_buf.clear();
                let mut n_bulk_ports = 0usize;
                let mut has_jump_candidate = false;

                while batch_buf.len() < 32 {
                    let Some((head, bufs)) = txq.pop(&mem) else {
                        break;
                    };
                    let total: usize = bufs
                        .iter()
                        .filter(|b| !b.is_write)
                        .map(|b| b.len as usize)
                        .sum();
                    let lport = if total > VIRTIO_NET_HDR_LEN + 38 {
                        peek_tx_tcp_local_port(&bufs, &mem)
                    } else {
                        None
                    };
                    let can_jump = if total <= 2048 {
                        match lport {
                            Some(p) => !bulk_ports[..n_bulk_ports].contains(&p),
                            None => true, // ARP or tiny control frame
                        }
                    } else {
                        if let Some(p) = lport
                            && n_bulk_ports < bulk_ports.len()
                            && !bulk_ports[..n_bulk_ports].contains(&p)
                        {
                            bulk_ports[n_bulk_ports] = p;
                            n_bulk_ports += 1;
                        }
                        false
                    };
                    if can_jump && n_bulk_ports > 0 {
                        has_jump_candidate = true;
                    }
                    batch_buf.push((head, total, bufs, lport, can_jump));
                }

                if batch_buf.is_empty() {
                    break;
                }
                drained_tx = true;

                // Pass 1 (only when small fresh packets sit behind bulk): jump fresh packets first!
                if has_jump_candidate {
                    let mut fast_mask = 0u32;
                    for &(head, total, ref bufs, _, can_jump) in &batch_buf {
                        if !can_jump {
                            continue;
                        }
                        if total > VIRTIO_NET_HDR_LEN {
                            shared.metrics.tx_packets.fetch_add(1, Ordering::Relaxed);
                            shared
                                .metrics
                                .tx_bytes
                                .fetch_add((total - VIRTIO_NET_HDR_LEN) as u64, Ordering::Relaxed);
                            fast_mask |=
                                shared.handle_guest_tx_chain(bufs, &mem, total, &mut scratch);
                        }
                        txq.push_used(&mem, head, 0);
                    }
                    if fast_mask != 0 {
                        shared.raise_rx_irqs(fast_mask);
                    }
                }

                // Pass 2: drain remaining packets (all packets if no jump needed, else bulk)
                for &(head, total, ref bufs, _, can_jump) in &batch_buf {
                    if has_jump_candidate && can_jump {
                        continue;
                    }
                    if total > VIRTIO_NET_HDR_LEN {
                        shared.metrics.tx_packets.fetch_add(1, Ordering::Relaxed);
                        shared
                            .metrics
                            .tx_bytes
                            .fetch_add((total - VIRTIO_NET_HDR_LEN) as u64, Ordering::Relaxed);
                        rx_irq_mask |=
                            shared.handle_guest_tx_chain(bufs, &mem, total, &mut scratch);
                    }
                    txq.push_used(&mem, head, 0);
                }

                if rx_irq_mask != 0 {
                    shared.raise_rx_irqs(rx_irq_mask);
                    rx_irq_mask = 0;
                }
            }

            if drained_tx {
                // Drain any overflow on our corresponding RX ring before checking IRQ
                {
                    let mut rx = shared.rx_rings[pair_idx].lock().unwrap();
                    if rx.drain_overflow(&shared.metrics) {
                        rx_irq_mask |= 1u32 << pair_idx;
                    }
                }
                let raised = shared.raise_rx_irqs(rx_irq_mask);
                if !raised && txq.guest_wants_irq(&mem) {
                    irq.raise_used_buffer();
                }
                last_activity = Instant::now();
                continue;
            }

            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            if shared.paused.load(Ordering::Acquire) {
                txq.set_no_notify(&mem, false);
                break;
            }
            if last_activity.elapsed() < adaptive_spin {
                std::hint::spin_loop();
                continue;
            }

            // Re-enable guest MMIO kicks and double-check avail ring (race-free Virtio 1.2 protocol)
            txq.set_no_notify(&mem, false);
            if txq.has_avail(&mem) {
                txq.set_no_notify(&mem, true);
                last_activity = Instant::now();
                continue;
            }
            break;
        }
    }
}

/// Virtio-Net (Device ID 1) backend with multi-queue (`VIRTIO_NET_F_MQ`) zero-copy O(1)
/// direct TCP published-port engine and `VIRTIO_NET_F_GUEST_TSO4` + `MRG_RXBUF`.
pub struct VirtioNetBridge {
    shared: Arc<NetShared>,
    broker: Option<PortBrokerHandle>,
    worker_handles: Vec<thread::JoinHandle<()>>,
    cmd_rx: Option<mpsc::Receiver<BrokerCmd>>,
}

impl VirtioNetBridge {
    pub fn new(cfg: NetConfig, metrics: Arc<NetMetrics>) -> std::io::Result<Self> {
        let kq_fd = Arc::new(create_wake_queue(WAKE_IDENT)?);
        let write_kq_fds = [
            create_wake_queue(WAKE_IDENT)?,
            create_wake_queue(WAKE_IDENT)?,
        ];

        let max_rcv_buf: usize = std::env::var("MICROPOD_VMM_NET_BUF_KIB")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .map(|k| k.clamp(64, 4096) * 1024)
            .unwrap_or(DEFAULT_HOST_RCV_WND);

        let max_pairs: usize = std::env::var("MICROPOD_VMM_NET_QUEUES")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .map(|q| q.clamp(1, MAX_VQ_PAIRS))
            .unwrap_or(MAX_VQ_PAIRS);

        let (cmd_tx, cmd_rx) = mpsc::channel();
        let broker = if cfg.enable_port_broker {
            Some(PortBrokerHandle {
                cmd_tx,
                kq_fd: kq_fd.clone(),
            })
        } else {
            None
        };

        let mut flows = Vec::with_capacity(MAX_SLOTS);
        for _ in 0..MAX_SLOTS {
            flows.push(Mutex::new(None));
        }

        let mut rx_rings = Vec::with_capacity(max_pairs);
        let mut tx_states = Vec::with_capacity(max_pairs);
        for _ in 0..max_pairs {
            rx_rings.push(Mutex::new(RxRingState::new()));
            tx_states.push((
                Mutex::new(TxQueueShared {
                    tx_queue: None,
                    kicked: false,
                    worker_parked: true,
                }),
                Condvar::new(),
            ));
        }

        let accepted_targets = Mutex::new((HashMap::new(), cfg.guest_ip));
        let shared = Arc::new(NetShared {
            cfg,
            kq_fd,
            write_kq_fds,
            max_rcv_buf,
            max_pairs,
            active_pairs: AtomicU32::new(1),
            mrg_rxbuf: AtomicBool::new(false),
            guest_tso4: AtomicBool::new(false),
            ip_id: AtomicU32::new(1),
            mem: Mutex::new(None),
            irq: Mutex::new(None),
            rx_rings,
            tx_states,
            flows,
            active_slots: Mutex::new(HashSet::with_capacity(64)),
            next_slot: AtomicU32::new(0),
            next_iss: AtomicU32::new(0x1020_3040),
            accepted_targets,
            metrics,
            paused: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
        });

        Ok(Self {
            shared,
            broker,
            worker_handles: Vec::new(),
            cmd_rx: Some(cmd_rx),
        })
    }

    pub fn port_broker(&self) -> Option<PortBrokerHandle> {
        self.broker.clone()
    }

    fn ctrl_vq_idx(&self) -> usize {
        self.shared.max_pairs * 2
    }

    fn ensure_io_started(&mut self) {
        if !self.worker_handles.is_empty() {
            return;
        }
        if let Some(cmd_rx) = self.cmd_rx.take() {
            let shared = self.shared.clone();
            let name = format!("vmm-net-{}", shared.cfg.host_ip);
            self.worker_handles.push(
                thread::Builder::new()
                    .name(name)
                    .spawn(move || run_net_io_loop(shared, cmd_rx))
                    .expect("spawn vmm-net io thread"),
            );

            for shard in 0..2 {
                let shared_w = self.shared.clone();
                let w_name = format!("vmm-net-wr-{}-{}", shared_w.cfg.host_ip, shard);
                self.worker_handles.push(
                    thread::Builder::new()
                        .name(w_name)
                        .spawn(move || run_write_drain_loop(shared_w, shard))
                        .expect("spawn vmm-net write drainer thread"),
                );
            }

            for pair_idx in 0..self.shared.max_pairs {
                let shared_tx = self.shared.clone();
                let tx_name = format!("vmm-net-tx-{}-{}", shared_tx.cfg.host_ip, pair_idx);
                self.worker_handles.push(
                    thread::Builder::new()
                        .name(tx_name)
                        .spawn(move || run_tx_drain_loop(shared_tx, pair_idx))
                        .expect("spawn vmm-net tx drainer thread"),
                );
            }
        }
    }

    fn process_ctrl_cmd(&self, req: &[u8]) -> u8 {
        if req.len() < 2 {
            return VIRTIO_NET_ERR;
        }
        let class = req[0];
        let cmd = req[1];
        let data = &req[2..];
        match (class, cmd) {
            (VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET) => {
                if data.len() < 2 {
                    return VIRTIO_NET_ERR;
                }
                let pairs = u16::from_le_bytes([data[0], data[1]]) as usize;
                if pairs >= 1 && pairs <= self.shared.max_pairs {
                    self.shared
                        .active_pairs
                        .store(pairs as u32, Ordering::Release);
                    VIRTIO_NET_OK
                } else {
                    VIRTIO_NET_ERR
                }
            }
            (VIRTIO_NET_CTRL_RX, _) | (VIRTIO_NET_CTRL_MAC, _) | (VIRTIO_NET_CTRL_VLAN, _) => {
                VIRTIO_NET_OK
            }
            _ => VIRTIO_NET_ERR,
        }
    }
}

impl VirtioBackend for VirtioNetBridge {
    fn device_id(&self) -> u32 {
        1
    }
    fn features(&self) -> u64 {
        let enable_guest_tso4 = std::env::var("MICROPOD_VMM_NET_GUEST_TSO4")
            .map(|v| v != "0")
            .unwrap_or(true);
        let mut feats = VIRTIO_NET_F_CSUM
            | VIRTIO_NET_F_GUEST_CSUM
            | VIRTIO_NET_F_HOST_TSO4
            | VIRTIO_NET_F_MRG_RXBUF
            | VIRTIO_NET_F_MAC
            | VIRTIO_NET_F_STATUS
            | VIRTIO_NET_F_MTU
            | VIRTIO_NET_F_CTRL_VQ;
        if enable_guest_tso4 {
            feats |= VIRTIO_NET_F_GUEST_TSO4;
        }
        if self.shared.max_pairs > 1 {
            feats |= VIRTIO_NET_F_MQ;
        }
        feats
    }
    fn num_queues(&self) -> usize {
        self.shared.max_pairs * 2 + 1 // 0..2*N-1 = RX/TX pairs, 2*N = Control VQ
    }
    fn queue_max_size(&self, q: usize) -> u16 {
        if q == self.ctrl_vq_idx() {
            64
        } else if q % 2 == 1 {
            // Bounded TX ring prevents multi-MiB virtqueue FIFO bufferbloat so Linux fq
            // keeps fresh SYN-ACK/HTTP packets in high-priority band 0!
            std::env::var("MICROPOD_VMM_NET_TX_QSIZE")
                .ok()
                .and_then(|s| s.parse::<u16>().ok())
                .filter(|&v| v.is_power_of_two() && (64..=1024).contains(&v))
                .unwrap_or(512)
        } else {
            1024
        }
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 12];
        cfg[0..6].copy_from_slice(&self.shared.cfg.guest_mac);
        cfg[6..8].copy_from_slice(&1u16.to_le_bytes()); // VIRTIO_NET_S_LINK_UP
        cfg[8..10].copy_from_slice(&(self.shared.max_pairs as u16).to_le_bytes()); // max_virtqueue_pairs
        cfg[10..12].copy_from_slice(&self.shared.cfg.mtu.to_le_bytes());
        let start = offset as usize;
        for (i, b) in data.iter_mut().enumerate() {
            *b = cfg.get(start + i).copied().unwrap_or(0);
        }
    }
    fn attach(&mut self, mem: Arc<GuestMemory>, irq: IrqLine) {
        *self.shared.mem.lock().unwrap() = Some(mem.clone());
        *self.shared.irq.lock().unwrap() = Some(irq.clone());
        for rx_m in &self.shared.rx_rings {
            let mut rx = rx_m.lock().unwrap();
            rx.mem = Some(mem.clone());
            rx.irq = Some(irq.clone());
        }
    }
    fn set_features(&mut self, features: u64) {
        let mrg = (features & VIRTIO_NET_F_MRG_RXBUF) != 0;
        let tso4 = (features & VIRTIO_NET_F_GUEST_TSO4) != 0;
        self.shared.mrg_rxbuf.store(mrg, Ordering::Release);
        self.shared.guest_tso4.store(tso4, Ordering::Release);
        for rx_m in &self.shared.rx_rings {
            rx_m.lock().unwrap().mrg_rxbuf = mrg;
        }
    }
    fn queue_ready(&mut self, q_idx: usize, q: &VirtQueue) {
        let ctrl_idx = self.ctrl_vq_idx();
        if q_idx >= ctrl_idx {
            return;
        }
        let pair = q_idx / 2;
        if q_idx.is_multiple_of(2) {
            self.shared.rx_rings[pair].lock().unwrap().rx_queue = Some(q.clone());
            self.ensure_io_started();
            trigger_kq_wake(self.shared.kq_fd.as_raw_fd());
        } else {
            let mut st = self.shared.tx_states[pair].0.lock().unwrap();
            st.tx_queue = Some(q.clone());
            st.kicked = true;
            self.shared.tx_states[pair].1.notify_one();
            drop(st);
            self.ensure_io_started();
        }
    }
    fn reset(&mut self) {
        self.shared.active_pairs.store(1, Ordering::Release);
        self.shared.mrg_rxbuf.store(false, Ordering::Release);
        self.shared.guest_tso4.store(false, Ordering::Release);
        for rx_m in &self.shared.rx_rings {
            let mut rx = rx_m.lock().unwrap();
            rx.rx_queue = None;
            rx.mrg_rxbuf = false;
            rx.overflow_prio.clear();
            rx.overflow_norm.clear();
        }
        for (mu, _) in &self.shared.tx_states {
            let mut st = mu.lock().unwrap();
            st.tx_queue = None;
            st.kicked = false;
        }
    }
    fn snapshot_pause(&mut self, queues: &mut [VirtQueue], mem: &GuestMemory) -> Vec<u8> {
        self.shared.paused.store(true, Ordering::Release);
        for pair in 0..self.shared.max_pairs {
            self.shared.tx_states[pair].1.notify_all();
            let mut st = self.shared.tx_states[pair].0.lock().unwrap();
            if !self.worker_handles.is_empty() {
                while !st.worker_parked {
                    st = self.shared.tx_states[pair].1.wait(st).unwrap();
                }
            }
            let tx_idx = pair * 2 + 1;
            if let Some(ref sq) = st.tx_queue {
                queues[tx_idx].next_avail = sq.next_avail;
                queues[tx_idx].next_used = sq.next_used;
                if queues[tx_idx].ready {
                    queues[tx_idx].set_no_notify(mem, false);
                }
            }
            let rx_idx = pair * 2;
            let rx = self.shared.rx_rings[pair].lock().unwrap();
            if let Some(ref rxq) = rx.rx_queue {
                queues[rx_idx].next_avail = rxq.next_avail;
                queues[rx_idx].next_used = rxq.next_used;
            }
        }
        self.shared
            .active_pairs
            .load(Ordering::Acquire)
            .to_le_bytes()
            .to_vec()
    }
    fn snapshot_resume(&mut self) {
        self.shared.paused.store(false, Ordering::Release);
        for (mu, cv) in &self.shared.tx_states {
            mu.lock().unwrap().kicked = true;
            cv.notify_all();
        }
    }
    fn snapshot_restore(&mut self, blob: &[u8], queues: &[VirtQueue]) {
        if blob.len() >= 4 {
            let pairs = u32::from_le_bytes(blob[0..4].try_into().unwrap())
                .clamp(1, self.shared.max_pairs as u32);
            self.shared.active_pairs.store(pairs, Ordering::Release);
        }
        let ctrl_idx = self.ctrl_vq_idx();
        for (q_idx, q) in queues.iter().enumerate().take(ctrl_idx) {
            if q.ready {
                self.queue_ready(q_idx, q);
            }
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool {
        let ctrl_idx = self.ctrl_vq_idx();
        if q_idx == ctrl_idx {
            let q = &mut queues[ctrl_idx];
            let mut used_any = false;
            while let Some((head, bufs)) = q.pop(mem) {
                let req = collect_readable(&bufs, mem);
                let ack = self.process_ctrl_cmd(&req);
                let written = scatter_writable(&bufs, mem, &[ack]);
                q.push_used(mem, head, written);
                used_any = true;
            }
            return used_any && q.guest_wants_irq(mem);
        }
        let pair = q_idx / 2;
        if pair >= self.shared.max_pairs {
            return false;
        }
        if q_idx.is_multiple_of(2) {
            let mut rx = self.shared.rx_rings[pair].lock().unwrap();
            if let Some(ref mut rxq) = rx.rx_queue {
                rxq.ready = queues[q_idx].ready;
                rxq.size = queues[q_idx].size;
                rxq.desc_addr = queues[q_idx].desc_addr;
                rxq.avail_addr = queues[q_idx].avail_addr;
                rxq.used_addr = queues[q_idx].used_addr;
            } else {
                rx.rx_queue = Some(queues[q_idx].clone());
            }
            let pushed = rx.drain_overflow(&self.shared.metrics);
            let want_irq = pushed && rx.guest_wants_irq();
            drop(rx);
            return want_irq;
        }
        // Non-blocking <150ns wakeup of dedicated M5 Max P-core TX drainer thread `pair`!
        let mut st = self.shared.tx_states[pair].0.lock().unwrap();
        if st.tx_queue.is_none() {
            st.tx_queue = Some(queues[q_idx].clone());
        }
        st.kicked = true;
        self.shared.tx_states[pair].1.notify_one();
        false
    }
}

impl Drop for VirtioNetBridge {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        trigger_kq_wake(self.shared.kq_fd.as_raw_fd());
        for wkq in &self.shared.write_kq_fds {
            trigger_kq_wake(wkq.as_raw_fd());
        }
        for (mu, cv) in &self.shared.tx_states {
            let _g = mu.lock().unwrap_or_else(|poison| poison.into_inner());
            cv.notify_all();
        }
        for h in self.worker_handles.drain(..) {
            let _ = h.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipv4_checksum_validates_rfc1071() {
        // RFC 1071 / standard IPv4 header example
        let mut hdr = [
            0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00, 0xc0, 0xa8,
            0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7,
        ];
        let c = ipv4_checksum(&hdr);
        assert_eq!(c, 0xb861);
        hdr[10..12].copy_from_slice(&c.to_be_bytes());
        assert_eq!(ipv4_checksum(&hdr), 0);
    }

    #[test]
    fn tcp_options_parse_mss_and_window_scale() {
        let opts = [2, 4, 0x23, 0x00, 1, 3, 3, 9]; // MSS=8960, NOP, WS=9
        let (mss, ws, has_ws) = parse_tcp_syn_options(&opts);
        assert_eq!(mss, 8960);
        assert_eq!(ws, 9);
        assert!(has_ws);
    }

    #[test]
    fn arp_responder_answers_cross_subnet_pod_macvlan_requests() {
        let cfg = NetConfig::published_link(9000);
        let pod_mac = [0x02, 0x42, 0xac, 0x11, 0x00, 0x09];
        let pod_ip = [10, 88, 0, 15];
        let mut req = vec![0u8; 42];
        req[0..6].copy_from_slice(&[0xff; 6]);
        req[6..12].copy_from_slice(&pod_mac);
        req[12..14].copy_from_slice(&0x0806u16.to_be_bytes());
        req[14..16].copy_from_slice(&1u16.to_be_bytes());
        req[16..18].copy_from_slice(&0x0800u16.to_be_bytes());
        req[18] = 6;
        req[19] = 4;
        req[20..22].copy_from_slice(&1u16.to_be_bytes());
        req[22..28].copy_from_slice(&pod_mac);
        req[28..32].copy_from_slice(&pod_ip);
        req[38..42].copy_from_slice(&cfg.host_ip.octets());

        let rep = build_arp_reply_for_request(&cfg, &req).expect("must answer cross-subnet ARP");
        assert_eq!(&rep[0..6], &pod_mac);
        assert_eq!(&rep[6..12], &cfg.host_mac);
        assert_eq!(u16::from_be_bytes([rep[20], rep[21]]), 2);
        assert_eq!(&rep[22..28], &cfg.host_mac);
        assert_eq!(&rep[28..32], &cfg.host_ip.octets());
        assert_eq!(&rep[32..38], &pod_mac);
        assert_eq!(&rep[38..42], &pod_ip);
    }

    #[test]
    fn port_broker_protocol_prepare_bind_revoke_and_query() {
        let bridge = VirtioNetBridge::new(
            NetConfig::published_link(9000),
            Arc::new(NetMetrics::default()),
        )
        .unwrap();
        let broker = bridge.port_broker().unwrap();
        let mut b = bridge;
        b.ensure_io_started();

        let (mut guest, host) = UnixStream::pair().unwrap();
        let h = broker.vsock_handler();
        let t = thread::spawn(move || h(host));

        // 1. Prepare guest port 8080 -> expect 0x50
        guest.write_all(&[0x1f, 0x90, 0x00, 0x01]).unwrap();
        let mut ack = [0u8; 1];
        guest.read_exact(&mut ack).unwrap();
        assert_eq!(ack[0], 0x50);

        // 2. Bind ephemeral host port 0 -> expect non-zero selected port
        guest.write_all(&[0x00, 0x00]).unwrap();
        let mut port_buf = [0u8; 2];
        guest.read_exact(&mut port_buf).unwrap();
        let selected = u16::from_be_bytes(port_buf);
        assert!(selected > 0);

        // 3. Query while active -> expect 0x00
        let (mut q1, q1_h) = UnixStream::pair().unwrap();
        let h2 = broker.vsock_handler();
        let qt1 = thread::spawn(move || h2(q1_h));
        q1.write_all(&[0x1f, 0x90, 0x00, 0x00]).unwrap();
        let mut qrep = [0u8; 1];
        q1.read_exact(&mut qrep).unwrap();
        assert_eq!(qrep[0], 0x00);
        qt1.join().unwrap();

        // 4. Revoke -> expect 0x52
        guest.write_all(&[0x52]).unwrap();
        guest.read_exact(&mut ack).unwrap();
        assert_eq!(ack[0], 0x52);
        drop(guest);
        t.join().unwrap();

        // 5. Query after revoke -> expect 0x52
        let (mut q2, q2_h) = UnixStream::pair().unwrap();
        let h3 = broker.vsock_handler();
        let qt2 = thread::spawn(move || h3(q2_h));
        q2.write_all(&[0x1f, 0x90, 0x00, 0x00]).unwrap();
        q2.read_exact(&mut qrep).unwrap();
        assert_eq!(qrep[0], 0x52);
        qt2.join().unwrap();
    }

    const LINK_IP: Ipv4Addr = Ipv4Addr::new(10, 43, 0, 2);
    const ETH0_IP: Ipv4Addr = Ipv4Addr::new(10, 42, 0, 2);

    #[test]
    fn syn_handshake_tries_every_address_then_backs_off_until_the_deadline() {
        let t0 = Instant::now();
        let mut hs = SynHandshake::new(LINK_IP, &[LINK_IP, ETH0_IP], t0);
        assert_eq!(hs.target(), LINK_IP);
        assert!(hs.is_candidate(ETH0_IP));
        assert!(!hs.is_candidate(Ipv4Addr::new(10, 88, 0, 2)));

        // The link address refuses: offer the same SYN to eth0 at once.
        assert_eq!(hs.on_refused(LINK_IP, t0), SynAction::Send(ETH0_IP));
        // A late reset from the superseded address changes nothing.
        assert_eq!(hs.on_refused(LINK_IP, t0), SynAction::Wait);
        // Both refused: nothing listens yet, so wait out the backoff.
        assert_eq!(hs.on_refused(ETH0_IP, t0), SynAction::Wait);
        assert_eq!(hs.on_timer(t0, t0), SynAction::Wait);
        let retry = t0 + SYN_REFUSED_BACKOFF_MIN;
        assert_eq!(hs.on_timer(retry, t0), SynAction::Send(LINK_IP));

        // Keep refusing: the backoff doubles up to its cap, then the deadline ends it.
        let mut now = retry;
        let mut rounds = 0;
        loop {
            assert_eq!(hs.on_refused(LINK_IP, now), SynAction::Send(ETH0_IP));
            match hs.on_refused(ETH0_IP, now) {
                SynAction::GiveUp => break,
                SynAction::Wait => {}
                other => panic!("unexpected {other:?}"),
            }
            let at = hs.retry_at.expect("a retry is scheduled");
            assert!(at - now <= SYN_REFUSED_BACKOFF_MAX);
            now = at;
            assert_eq!(hs.on_timer(now, now), SynAction::Send(LINK_IP));
            rounds += 1;
            assert!(rounds < 100, "handshake never gave up");
        }
        assert!(now + SYN_REFUSED_BACKOFF_MAX >= t0 + SYN_HANDSHAKE_TIMEOUT);
        assert_eq!(
            hs.on_timer(t0 + SYN_HANDSHAKE_TIMEOUT, now),
            SynAction::GiveUp
        );
    }

    #[test]
    fn syn_handshake_retransmits_an_unanswered_syn_to_the_next_address() {
        let t0 = Instant::now();
        let mut hs = SynHandshake::new(ETH0_IP, &[LINK_IP, ETH0_IP], t0);
        assert_eq!(hs.target(), ETH0_IP, "the learned address goes first");
        assert_eq!(hs.on_timer(t0 + SYN_RTO / 2, t0), SynAction::Wait);
        assert_eq!(hs.on_timer(t0 + SYN_RTO, t0), SynAction::Send(LINK_IP));
        let single = SynHandshake::new(LINK_IP, &[LINK_IP], t0);
        assert_eq!(single.count, 1);
    }

    fn published_bridge() -> VirtioNetBridge {
        VirtioNetBridge::new(
            NetConfig::published_link(1500).with_fallback_guest_ip(ETH0_IP),
            Arc::new(NetMetrics::default()),
        )
        .unwrap()
    }

    /// A guest -> host TCP segment as the guest driver hands it to the TX queue.
    fn guest_segment(
        src: Ipv4Addr,
        sport: u16,
        dport: u16,
        seq: u32,
        ack: u32,
        flags: u8,
    ) -> Vec<u8> {
        let cfg = NetConfig::published_link(1500);
        let mut f = vec![0u8; VIRTIO_NET_HDR_LEN];
        f.extend_from_slice(&cfg.host_mac);
        f.extend_from_slice(&cfg.guest_mac);
        f.extend_from_slice(&0x0800u16.to_be_bytes());
        let mut ip = [0u8; 20];
        ip[0] = 0x45;
        ip[2..4].copy_from_slice(&40u16.to_be_bytes());
        ip[8] = 64;
        ip[9] = 6;
        ip[12..16].copy_from_slice(&src.octets());
        ip[16..20].copy_from_slice(&cfg.host_ip.octets());
        f.extend_from_slice(&ip);
        let mut tcp = [0u8; 20];
        tcp[0..2].copy_from_slice(&sport.to_be_bytes());
        tcp[2..4].copy_from_slice(&dport.to_be_bytes());
        tcp[4..8].copy_from_slice(&seq.to_be_bytes());
        tcp[8..12].copy_from_slice(&ack.to_be_bytes());
        tcp[12] = 5 << 4;
        tcp[13] = flags;
        tcp[14..16].copy_from_slice(&65535u16.to_be_bytes());
        f.extend_from_slice(&tcp);
        f
    }

    /// (destination IP, TCP flags) of every frame queued for the guest so far.
    fn take_frames_to_guest(bridge: &VirtioNetBridge) -> Vec<(Ipv4Addr, u8)> {
        let mut rx = bridge.shared.rx_rings[0].lock().unwrap();
        let rx = &mut *rx;
        rx.overflow_prio
            .drain(..)
            .chain(rx.overflow_norm.drain(..))
            .map(|f| {
                let d = &f.data;
                (Ipv4Addr::new(d[30], d[31], d[32], d[33]), d[47])
            })
            .collect()
    }

    #[test]
    fn published_handshake_learns_the_guest_address_that_accepts() {
        let bridge = published_bridge();
        let shared = &bridge.shared;
        let mut backing = vec![0u8; 4096];
        let ram_base = 0x4000_0000u64;
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), ram_base, backing.len()) };
        let mut scratch = vec![0u8; 4096];
        let mut deliver = |segment: Vec<u8>| {
            mem.write_slice(ram_base, segment.len())
                .unwrap()
                .copy_from_slice(&segment);
            let bufs = [DescBuf {
                addr: ram_base,
                len: segment.len() as u32,
                is_write: false,
            }];
            shared.handle_guest_tx_chain(&bufs, &mem, segment.len(), &mut scratch);
        };

        let (client, host_end) = UnixStream::pair().unwrap();
        host_end.set_nonblocking(true).unwrap();
        let guest_port = 38759;
        let iss = 1000;
        let handshake = shared.new_handshake(guest_port, Instant::now());
        let mut flow = TcpFlow::new(
            0,
            18080,
            guest_port,
            host_end.into_raw_fd(),
            iss,
            1500,
            handshake,
        );
        let lport = flow.local_port;
        shared.send_syn(&mut flow, LINK_IP);
        *shared.flows[0].lock().unwrap() = Some(flow);
        shared.active_slots.lock().unwrap().insert(0);
        assert_eq!(take_frames_to_guest(&bridge), vec![(LINK_IP, TCP_SYN)]);

        // A reset that does not acknowledge our SYN is not a refusal.
        deliver(guest_segment(
            LINK_IP,
            guest_port,
            lport,
            0,
            iss + 7,
            TCP_RST | TCP_ACK,
        ));
        assert!(take_frames_to_guest(&bridge).is_empty());
        // The engine's relay is not on the link address: retry on eth0's.
        deliver(guest_segment(
            LINK_IP,
            guest_port,
            lport,
            0,
            iss + 1,
            TCP_RST | TCP_ACK,
        ));
        assert_eq!(take_frames_to_guest(&bridge), vec![(ETH0_IP, TCP_SYN)]);

        deliver(guest_segment(
            ETH0_IP,
            guest_port,
            lport,
            5000,
            iss + 1,
            TCP_SYN | TCP_ACK,
        ));
        assert_eq!(take_frames_to_guest(&bridge), vec![(ETH0_IP, TCP_ACK)]);
        {
            let g = shared.flows[0].lock().unwrap();
            let flow = g.as_ref().unwrap();
            assert_eq!(flow.state, TcpState::Established);
            assert_eq!(flow.guest_ip, ETH0_IP);
            assert_eq!(flow.rcv_nxt, 5001);
        }

        // A late SYN-ACK from the other address is reset, not mixed into the flow.
        deliver(guest_segment(
            LINK_IP,
            guest_port,
            lport,
            9000,
            iss + 1,
            TCP_SYN | TCP_ACK,
        ));
        assert_eq!(take_frames_to_guest(&bridge), vec![(LINK_IP, TCP_RST)]);
        assert_eq!(
            shared.flows[0].lock().unwrap().as_ref().unwrap().rcv_nxt,
            5001
        );

        // The next connection to this port goes straight to the address that answered.
        assert_eq!(
            shared.new_handshake(guest_port, Instant::now()).target(),
            ETH0_IP
        );
        drop(client);
    }

    #[test]
    fn published_handshake_resets_the_client_when_no_address_accepts() {
        let bridge = published_bridge();
        let shared = &bridge.shared;
        let (client, host_end) = UnixStream::pair().unwrap();
        host_end.set_nonblocking(true).unwrap();
        let start = Instant::now() - SYN_HANDSHAKE_TIMEOUT;
        let handshake = shared.new_handshake(8080, start);
        let mut flow = TcpFlow::new(3, 18081, 8080, host_end.into_raw_fd(), 77, 1500, handshake);
        assert_eq!(
            flow.handshake.on_timer(Instant::now(), flow.last_tx),
            SynAction::GiveUp
        );
        flow.reset_host();
        assert_eq!(flow.host_fd, -1);
        let mut buf = [0u8; 1];
        let mut client = client;
        assert_eq!(
            client.read(&mut buf).unwrap_or(0),
            0,
            "client sees the close"
        );
    }

    #[test]
    fn ctrl_vq_negotiates_mq_pairs_and_rx_sharding() {
        let bridge = VirtioNetBridge::new(
            NetConfig::published_link(9000),
            Arc::new(NetMetrics::default()),
        )
        .unwrap();
        assert_eq!(bridge.shared.active_pairs.load(Ordering::Relaxed), 1);
        assert_eq!(bridge.num_queues(), MAX_VQ_PAIRS * 2 + 1);
        assert_ne!(bridge.features() & VIRTIO_NET_F_MQ, 0);
        assert_ne!(bridge.features() & VIRTIO_NET_F_CTRL_VQ, 0);
        assert_ne!(bridge.features() & VIRTIO_NET_F_MRG_RXBUF, 0);
        assert_ne!(bridge.features() & VIRTIO_NET_F_GUEST_TSO4, 0);

        // Before MQ activation, all traffic routes to RX queue 0
        assert_eq!(bridge.shared.select_rx_ring(Some(5), false), 0);

        // Activate 4 queue pairs via Control VQ command (class=4, cmd=0, pairs=4)
        let cmd = [VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, 4, 0];
        assert_eq!(bridge.process_ctrl_cmd(&cmd), VIRTIO_NET_OK);
        assert_eq!(bridge.shared.active_pairs.load(Ordering::Relaxed), 4);

        // Reject out-of-range pairs (0 or 8)
        assert_eq!(
            bridge.process_ctrl_cmd(&[VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, 0, 0]),
            VIRTIO_NET_ERR
        );
        assert_eq!(
            bridge.process_ctrl_cmd(&[VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, 8, 0]),
            VIRTIO_NET_ERR
        );

        // Fresh/priority traffic always hits dedicated RX queue 0; bulk shards across 1..3
        assert_eq!(bridge.shared.select_rx_ring(Some(0), true), 0);
        assert_eq!(bridge.shared.select_rx_ring(Some(7), true), 0);
        assert_eq!(bridge.shared.select_rx_ring(Some(0), false), 1);
        assert_eq!(bridge.shared.select_rx_ring(Some(1), false), 2);
        assert_eq!(bridge.shared.select_rx_ring(Some(2), false), 3);
        assert_eq!(bridge.shared.select_rx_ring(Some(3), false), 1);
    }

    #[test]
    fn mrg_rxbuf_chains_large_gso_frame_atomically() {
        // Set up a tiny in-memory VirtQueue with 4 writable 512-byte RX descriptors
        let mut backing = vec![0u8; 64 * 1024];
        let ram_base = 0x4000_0000u64;
        let mem =
            Arc::new(unsafe { GuestMemory::new(backing.as_mut_ptr(), ram_base, backing.len()) });

        let desc_addr = ram_base + 0x1000;
        let avail_addr = ram_base + 0x2000;
        let used_addr = ram_base + 0x3000;
        let buf_base = ram_base + 0x4000;
        let qsize = 8u16;

        for i in 0..4u16 {
            let d = desc_addr + (i as u64) * 16;
            mem.write_u32(d, (buf_base + (i as u64) * 512) as u32)
                .unwrap();
            mem.write_u32(d + 4, ((buf_base + (i as u64) * 512) >> 32) as u32)
                .unwrap();
            mem.write_u32(d + 8, 512).unwrap();
            mem.write_u16(d + 12, 2).unwrap(); // VIRTQ_DESC_F_WRITE
            mem.write_u16(d + 14, 0).unwrap();
            mem.write_u16(avail_addr + 4 + (i as u64) * 2, i).unwrap();
        }
        mem.write_u16_release(avail_addr + 2, 4).unwrap();

        let mut rxq = VirtQueue::new(qsize);
        rxq.size = qsize;
        rxq.ready = true;
        rxq.desc_addr = desc_addr;
        rxq.avail_addr = avail_addr;
        rxq.used_addr = used_addr;

        let mut ring = RxRingState::new();
        ring.mem = Some(mem.clone());
        ring.rx_queue = Some(rxq);
        ring.mrg_rxbuf = true;

        let metrics = NetMetrics::default();
        let hdr = [0xAAu8; 54];
        let payload = vec![0x55u8; 1200]; // 12 + 54 + 1200 = 1266 bytes -> needs 3 x 512B descriptors!
        let mut vhdr = [0u8; VIRTIO_NET_HDR_LEN];
        vhdr[0] = VIRTIO_NET_HDR_F_NEEDS_CSUM;
        vhdr[1] = VIRTIO_NET_HDR_GSO_TCPV4;

        assert!(ring.send_parts_with_vhdr(vhdr, &hdr, &payload, &[], false, &metrics));
        // used->idx should atomically advance by 3
        assert_eq!(mem.read_u16_acquire(used_addr + 2).unwrap(), 3);
        // First buffer must contain num_buffers == 3 in vhdr[10..12]
        let first_buf = mem.read_slice(buf_base, 512).unwrap();
        assert_eq!(u16::from_le_bytes([first_buf[10], first_buf[11]]), 3);
        assert_eq!(first_buf[0], VIRTIO_NET_HDR_F_NEEDS_CSUM);
        assert_eq!(first_buf[1], VIRTIO_NET_HDR_GSO_TCPV4);
        assert_eq!(first_buf[12], 0xAA);
        // Third buffer has remaining 1266 - 1024 = 242 bytes
        let used2_len = mem.read_u32(used_addr + 4 + 2 * 8 + 4).unwrap();
        assert_eq!(used2_len, 242);

        // Now try a 1024-byte frame with only 1 descriptor (512B) remaining -> must roll back atomically!
        let big = vec![0x77u8; 1000];
        assert!(!ring.send_parts_with_vhdr(vhdr, &hdr, &big, &[], false, &metrics));
        assert_eq!(ring.rx_queue.as_ref().unwrap().next_avail, 3); // Rolled back!
        assert_eq!(ring.overflow_norm.len(), 1);
    }
}
