//! Zero-`vmnet`, zero-TCC outbound egress gateway for `eth0` (`10.42.0.2/24 -> 10.42.0.1`).
//!
//! Translates guest IPv4 packets directly into host Darwin sockets over `kqueue`:
//! - ARP (`10.42.0.1`): immediate reply with host gateway MAC.
//! - ICMP Echo (`10.42.0.1` + external unprivileged `SOCK_DGRAM / IPPROTO_ICMP`).
//! - UDP + DNS proxy (`10.42.0.1:53` -> host `/etc/resolv.conf` resolver, fallback `1.1.1.1`).
//! - Outbound TCP: non-blocking `connect()` + zero-copy `GuestMemory -> libc::writev()`
//!   + `VIRTIO_NET_F_HOST_TSO4` + strict host-loopback/link-local isolation.

use std::collections::{HashMap, VecDeque};
use std::net::Ipv4Addr;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use vmm_virtio::{DescBuf, GuestMemory, IrqLine, VirtQueue, VirtioBackend};

use crate::{
    HOST_WS_SHIFT, NetConfig, NetMetrics, RxRingState, TCP_ACK, TCP_FIN, TCP_PSH, TCP_RST, TCP_SYN,
    VIRTIO_NET_F_CSUM, VIRTIO_NET_F_GUEST_CSUM, VIRTIO_NET_F_HOST_TSO4, VIRTIO_NET_F_MAC,
    VIRTIO_NET_F_MTU, VIRTIO_NET_F_STATUS, VIRTIO_NET_HDR_LEN, build_arp_reply_for_request,
    copy_chain_slice_into, create_wake_queue, ipv4_checksum, kq_ctl, parse_tcp_syn_options,
    trigger_kq_event, trigger_kq_wake,
};

const EGRESS_WAKE_IDENT: usize = 0x4d50_4547; // "MPEG"
const UDATA_TCP_TAG: usize = 0x1000_0000;
const UDATA_UDP_TAG: usize = 0x2000_0000;
const UDATA_ICMP_TAG: usize = 0x3000_0000;

const EGRESS_MAX_TCP_FLOWS: usize = 2048;
const EGRESS_MAX_UDP_FLOWS: usize = 512;
const EGRESS_MAX_ICMP_FLOWS: usize = 64;
const EGRESS_RCV_WND: usize = 256 * 1024;
const EGRESS_TX_INFLIGHT: usize = 256 * 1024;
const EGRESS_ACK_COALESCE: usize = 32 * 1024;

/// Security guard: reject outbound guest connections targeting host loopback,
/// link-local, unspecified, broadcast, or multicast IPv4 addresses.
#[inline]
pub fn is_blocked_egress_ip(ip: Ipv4Addr) -> bool {
    ip.is_loopback()
        || ip.is_unspecified()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
}

/// Parse valid upstream IPv4 DNS servers from `/etc/resolv.conf` contents, deduplicating
/// while preserving order and excluding host-loopback, unspecified, link-local, broadcast,
/// and multicast addresses.
pub fn parse_resolv_conf_dns(contents: &str) -> Vec<Ipv4Addr> {
    let mut servers = Vec::new();
    for line in contents.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("nameserver")
            && let Some(tok) = rest.split_whitespace().next()
            && let Ok(ip) = tok.parse::<Ipv4Addr>()
            && !is_blocked_egress_ip(ip)
            && !servers.contains(&ip)
        {
            servers.push(ip);
        }
    }
    servers
}

fn read_env_dns_override() -> Option<Vec<Ipv4Addr>> {
    let val = std::env::var("MICROPOD_VMM_DNS_IPV4").ok()?;
    let mut out = Vec::new();
    for part in val.split(',') {
        if let Ok(ip) = part.trim().parse::<Ipv4Addr>()
            && !ip.is_unspecified()
            && !out.contains(&ip)
        {
            out.push(ip);
        }
    }
    if out.is_empty() { None } else { Some(out) }
}

/// Discover usable host upstream IPv4 DNS servers (from `MICROPOD_VMM_DNS_IPV4` or `/etc/resolv.conf`).
pub fn discover_upstream_dns_list() -> Vec<Ipv4Addr> {
    if let Some(list) = read_env_dns_override() {
        return list;
    }
    if let Ok(contents) = std::fs::read_to_string("/etc/resolv.conf") {
        let mut servers = parse_resolv_conf_dns(&contents);
        if !servers.is_empty() {
            if servers.len() == 1 && servers[0] != Ipv4Addr::new(1, 1, 1, 1) {
                servers.push(Ipv4Addr::new(1, 1, 1, 1));
            }
            return servers;
        }
    }
    vec![Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(8, 8, 8, 8)]
}

/// Discover a usable host upstream IPv4 DNS server (from `MICROPOD_VMM_DNS_IPV4` or `/etc/resolv.conf`).
pub fn discover_upstream_dns() -> Ipv4Addr {
    discover_upstream_dns_list()[0]
}

struct DnsResolverState {
    servers: Vec<Ipv4Addr>,
    active_idx: usize,
    last_check: Instant,
    last_mtime: Option<SystemTime>,
    env_override: bool,
}

impl DnsResolverState {
    fn new() -> Self {
        let env_list = read_env_dns_override();
        let env_override = env_list.is_some();
        let last_mtime = if env_override {
            None
        } else {
            std::fs::metadata("/etc/resolv.conf")
                .ok()
                .and_then(|m| m.modified().ok())
        };
        let servers = env_list.unwrap_or_else(discover_upstream_dns_list);
        Self {
            servers,
            active_idx: 0,
            last_check: Instant::now(),
            last_mtime,
            env_override,
        }
    }

    fn current(&mut self) -> Ipv4Addr {
        if !self.env_override && self.last_check.elapsed() >= Duration::from_secs(2) {
            self.refresh_if_changed();
        }
        self.servers[self.active_idx % self.servers.len()]
    }

    fn refresh_if_changed(&mut self) {
        self.last_check = Instant::now();
        if self.env_override {
            return;
        }
        let mtime = std::fs::metadata("/etc/resolv.conf")
            .ok()
            .and_then(|m| m.modified().ok());
        if mtime.is_some() && mtime == self.last_mtime {
            return;
        }
        self.last_mtime = mtime;
        let fresh = discover_upstream_dns_list();
        if fresh != self.servers {
            self.servers = fresh;
            self.active_idx = 0;
        }
    }

    fn force_refresh(&mut self) {
        self.last_mtime = None;
        self.refresh_if_changed();
        self.active_idx = 0;
    }

    fn rotate_failover(&mut self) {
        if self.servers.len() > 1 {
            self.active_idx = (self.active_idx + 1) % self.servers.len();
        }
    }
}

#[inline]
fn internet_checksum(mut sum: u32, data: &[u8]) -> u16 {
    let mut i = 0;
    while i + 1 < data.len() {
        sum += u16::from_be_bytes([data[i], data[i + 1]]) as u32;
        i += 2;
    }
    if i < data.len() {
        sum += (data[i] as u32) << 8;
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

#[inline]
fn udp_checksum(src: Ipv4Addr, dst: Ipv4Addr, udp_hdr: &[u8; 8], payload: &[u8]) -> u16 {
    let s = src.octets();
    let d = dst.octets();
    let udp_len = (8 + payload.len()) as u32;
    let mut sum: u32 = 0;
    sum += u16::from_be_bytes([s[0], s[1]]) as u32;
    sum += u16::from_be_bytes([s[2], s[3]]) as u32;
    sum += u16::from_be_bytes([d[0], d[1]]) as u32;
    sum += u16::from_be_bytes([d[2], d[3]]) as u32;
    sum += 17u32; // IPPROTO_UDP
    sum += udp_len;
    for chunk in udp_hdr.as_chunks::<2>().0 {
        sum += u16::from_be_bytes([chunk[0], chunk[1]]) as u32;
    }
    let c = internet_checksum(sum, payload);
    if c == 0 { 0xffff } else { c }
}

#[inline]
#[allow(clippy::too_many_arguments)]
fn encode_egress_tcp_headers(
    cfg: &NetConfig,
    ip_id: u16,
    src_ip: Ipv4Addr,
    src_port: u16,
    dst_ip: Ipv4Addr,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    payload_len: usize,
    syn_mss: Option<u16>,
    hdr_buf: &mut [u8; 64],
) -> usize {
    let tcp_len = if syn_mss.is_some() { 28 } else { 20 };
    let ip_tot_len = (20 + tcp_len + payload_len) as u16;

    hdr_buf[0..6].copy_from_slice(&cfg.guest_mac);
    hdr_buf[6..12].copy_from_slice(&cfg.host_mac);
    hdr_buf[12..14].copy_from_slice(&0x0800u16.to_be_bytes());

    hdr_buf[14] = 0x45;
    hdr_buf[15] = 0x00;
    hdr_buf[16..18].copy_from_slice(&ip_tot_len.to_be_bytes());
    hdr_buf[18..20].copy_from_slice(&ip_id.to_be_bytes());
    hdr_buf[20..22].copy_from_slice(&0x4000u16.to_be_bytes());
    hdr_buf[22] = 64;
    hdr_buf[23] = 6;
    hdr_buf[24..26].copy_from_slice(&0u16.to_be_bytes());
    hdr_buf[26..30].copy_from_slice(&src_ip.octets());
    hdr_buf[30..34].copy_from_slice(&dst_ip.octets());
    let csum = ipv4_checksum(&hdr_buf[14..34]);
    hdr_buf[24..26].copy_from_slice(&csum.to_be_bytes());

    hdr_buf[34..36].copy_from_slice(&src_port.to_be_bytes());
    hdr_buf[36..38].copy_from_slice(&dst_port.to_be_bytes());
    hdr_buf[38..42].copy_from_slice(&seq.to_be_bytes());
    hdr_buf[42..46].copy_from_slice(&ack.to_be_bytes());
    hdr_buf[46] = ((tcp_len / 4) as u8) << 4;
    hdr_buf[47] = flags;
    hdr_buf[48..50].copy_from_slice(&window.to_be_bytes());
    hdr_buf[50..52].copy_from_slice(&0u16.to_be_bytes()); // VIRTIO_NET_HDR_F_DATA_VALID offload
    hdr_buf[52..54].copy_from_slice(&0u16.to_be_bytes());

    if let Some(mss) = syn_mss {
        hdr_buf[54] = 2;
        hdr_buf[55] = 4;
        hdr_buf[56..58].copy_from_slice(&mss.to_be_bytes());
        hdr_buf[58] = 1;
        hdr_buf[59] = 3;
        hdr_buf[60] = 3;
        hdr_buf[61] = HOST_WS_SHIFT;
    }

    14 + 20 + tcp_len
}

#[allow(clippy::too_many_arguments)]
fn encode_egress_udp_headers(
    cfg: &NetConfig,
    ip_id: u16,
    src_ip: Ipv4Addr,
    src_port: u16,
    dst_ip: Ipv4Addr,
    dst_port: u16,
    payload: &[u8],
    hdr_buf: &mut [u8; 42],
) -> usize {
    let udp_len = (8 + payload.len()) as u16;
    let ip_tot_len = 20 + udp_len;

    hdr_buf[0..6].copy_from_slice(&cfg.guest_mac);
    hdr_buf[6..12].copy_from_slice(&cfg.host_mac);
    hdr_buf[12..14].copy_from_slice(&0x0800u16.to_be_bytes());

    hdr_buf[14] = 0x45;
    hdr_buf[15] = 0x00;
    hdr_buf[16..18].copy_from_slice(&ip_tot_len.to_be_bytes());
    hdr_buf[18..20].copy_from_slice(&ip_id.to_be_bytes());
    hdr_buf[20..22].copy_from_slice(&0x4000u16.to_be_bytes());
    hdr_buf[22] = 64;
    hdr_buf[23] = 17;
    hdr_buf[24..26].copy_from_slice(&0u16.to_be_bytes());
    hdr_buf[26..30].copy_from_slice(&src_ip.octets());
    hdr_buf[30..34].copy_from_slice(&dst_ip.octets());
    let csum = ipv4_checksum(&hdr_buf[14..34]);
    hdr_buf[24..26].copy_from_slice(&csum.to_be_bytes());

    let mut uhdr = [0u8; 8];
    uhdr[0..2].copy_from_slice(&src_port.to_be_bytes());
    uhdr[2..4].copy_from_slice(&dst_port.to_be_bytes());
    uhdr[4..6].copy_from_slice(&udp_len.to_be_bytes());
    uhdr[6..8].copy_from_slice(&0u16.to_be_bytes());
    let ucsum = udp_checksum(src_ip, dst_ip, &uhdr, payload);
    uhdr[6..8].copy_from_slice(&ucsum.to_be_bytes());
    hdr_buf[34..42].copy_from_slice(&uhdr);
    42
}

fn encode_egress_icmp_frame(
    cfg: &NetConfig,
    ip_id: u16,
    src_ip: Ipv4Addr,
    dst_ip: Ipv4Addr,
    icmp_payload: &[u8],
) -> Vec<u8> {
    let ip_tot_len = (20 + icmp_payload.len()) as u16;
    let mut frame = Vec::with_capacity(14 + ip_tot_len as usize);
    frame.extend_from_slice(&cfg.guest_mac);
    frame.extend_from_slice(&cfg.host_mac);
    frame.extend_from_slice(&0x0800u16.to_be_bytes());

    let mut ip = [0u8; 20];
    ip[0] = 0x45;
    ip[2..4].copy_from_slice(&ip_tot_len.to_be_bytes());
    ip[4..6].copy_from_slice(&ip_id.to_be_bytes());
    ip[6..8].copy_from_slice(&0x4000u16.to_be_bytes());
    ip[8] = 64;
    ip[9] = 1; // ICMP
    ip[12..16].copy_from_slice(&src_ip.octets());
    ip[16..20].copy_from_slice(&dst_ip.octets());
    let csum = ipv4_checksum(&ip);
    ip[10..12].copy_from_slice(&csum.to_be_bytes());
    frame.extend_from_slice(&ip);
    frame.extend_from_slice(icmp_payload);
    frame
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct TcpFlowKey {
    guest_ip: Ipv4Addr,
    guest_port: u16,
    remote_ip: Ipv4Addr,
    remote_port: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EgressTcpState {
    Connecting,
    SynRcvd,
    Established,
    FinWait,
}

struct EgressTcpFlow {
    id: usize,
    key: TcpFlowKey,
    fd: RawFd,
    state: EgressTcpState,
    snd_una: u32,
    snd_nxt: u32,
    snd_wnd: u32,
    peer_mss: usize,
    peer_ws: u8,
    host_ws: u8,
    rcv_nxt: u32,
    last_adv_wnd: usize,
    bytes_since_ack: usize,
    pending_to_host: VecDeque<u8>,
    tx_unacked: VecDeque<u8>,
    tx_unsent_off: usize,
    host_readable: bool,
    host_writable: bool,
    write_ev_armed: bool,
    host_fin_queued: bool,
    host_fin_sent: bool,
    guest_fin: bool,
    created: Instant,
    last_activity: Instant,
    last_tx: Instant,
    fin_time: Option<Instant>,
}

impl EgressTcpFlow {
    fn rcv_wnd_bytes(&self) -> usize {
        EGRESS_RCV_WND.saturating_sub(self.pending_to_host.len())
    }

    fn encoded_rcv_wnd(&self) -> u16 {
        let scaled = self.rcv_wnd_bytes() >> self.host_ws;
        scaled.min(u16::MAX as usize) as u16
    }

    fn close_fd(&mut self) {
        if self.fd >= 0 {
            unsafe { libc::close(self.fd) };
            self.fd = -1;
        }
    }
}

impl Drop for EgressTcpFlow {
    fn drop(&mut self) {
        self.close_fd();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct UdpFlowKey {
    guest_ip: Ipv4Addr,
    guest_port: u16,
    remote_ip: Ipv4Addr,
    remote_port: u16,
}

struct EgressUdpFlow {
    key: UdpFlowKey,
    target_ip: Ipv4Addr,
    fd: RawFd,
    got_reply: bool,
    failover_noted: bool,
    last_activity: Instant,
}

impl Drop for EgressUdpFlow {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe { libc::close(self.fd) };
            self.fd = -1;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct IcmpFlowKey {
    guest_ip: Ipv4Addr,
    remote_ip: Ipv4Addr,
    icmp_id: u16,
}

struct EgressIcmpFlow {
    key: IcmpFlowKey,
    fd: RawFd,
    last_activity: Instant,
}

impl Drop for EgressIcmpFlow {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe { libc::close(self.fd) };
            self.fd = -1;
        }
    }
}

struct EgressTable {
    tcp_by_id: HashMap<usize, EgressTcpFlow>,
    tcp_by_key: HashMap<TcpFlowKey, usize>,
    udp_by_id: HashMap<usize, EgressUdpFlow>,
    udp_by_key: HashMap<UdpFlowKey, usize>,
    icmp_by_id: HashMap<usize, EgressIcmpFlow>,
    icmp_by_key: HashMap<IcmpFlowKey, usize>,
    next_id: usize,
}

impl EgressTable {
    fn new() -> Self {
        Self {
            tcp_by_id: HashMap::with_capacity(64),
            tcp_by_key: HashMap::with_capacity(64),
            udp_by_id: HashMap::with_capacity(32),
            udp_by_key: HashMap::with_capacity(32),
            icmp_by_id: HashMap::with_capacity(8),
            icmp_by_key: HashMap::with_capacity(8),
            next_id: 1,
        }
    }

    fn alloc_id(&mut self) -> usize {
        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        id
    }

    fn remove_tcp(&mut self, id: usize) {
        if let Some(f) = self.tcp_by_id.remove(&id) {
            self.tcp_by_key.remove(&f.key);
        }
    }

    fn remove_udp(&mut self, id: usize) {
        if let Some(f) = self.udp_by_id.remove(&id) {
            self.udp_by_key.remove(&f.key);
        }
    }

    fn remove_icmp(&mut self, id: usize) {
        if let Some(f) = self.icmp_by_id.remove(&id) {
            self.icmp_by_key.remove(&f.key);
        }
    }
}

struct EgressShared {
    cfg: NetConfig,
    dns: Mutex<DnsResolverState>,
    kq_fd: OwnedFd,
    rx: Mutex<RxRingState>,
    table: Mutex<EgressTable>,
    next_iss: AtomicU32,
    metrics: Arc<NetMetrics>,
    shutdown: AtomicBool,
}

impl EgressShared {
    #[inline]
    fn upstream_dns(&self) -> Ipv4Addr {
        self.dns.lock().unwrap().current()
    }
    #[allow(clippy::too_many_arguments)]
    fn send_tcp(
        &self,
        key: TcpFlowKey,
        seq: u32,
        ack: u32,
        flags: u8,
        window: u16,
        payload: &[u8],
        syn_mss: Option<u16>,
        priority: bool,
    ) -> bool {
        let mut hdr = [0u8; 64];
        let mut rx = self.rx.lock().unwrap();
        let ip_id = rx.next_ip_id();
        let hlen = encode_egress_tcp_headers(
            &self.cfg,
            ip_id,
            key.remote_ip,
            key.remote_port,
            key.guest_ip,
            key.guest_port,
            seq,
            ack,
            flags,
            window,
            payload.len(),
            syn_mss,
            &mut hdr,
        );
        rx.send_parts(&hdr[..hlen], payload, priority, &self.metrics)
    }

    fn send_udp(&self, key: UdpFlowKey, payload: &[u8]) -> bool {
        let mut hdr = [0u8; 42];
        let mut rx = self.rx.lock().unwrap();
        let ip_id = rx.next_ip_id();
        let hlen = encode_egress_udp_headers(
            &self.cfg,
            ip_id,
            key.remote_ip,
            key.remote_port,
            key.guest_ip,
            key.guest_port,
            payload,
            &mut hdr,
        );
        rx.send_parts(&hdr[..hlen], payload, true, &self.metrics)
    }

    fn flush_tcp_to_guest(&self, flow: &mut EgressTcpFlow) -> bool {
        let mut any = false;
        let wnd = flow.encoded_rcv_wnd();
        let mut seg_buf = [0u8; 1500];

        while flow.tx_unsent_off < flow.tx_unacked.len() {
            let in_flight = flow.snd_nxt.wrapping_sub(flow.snd_una) as usize;
            let allowed = (flow.snd_wnd as usize).saturating_sub(in_flight);
            if allowed == 0 {
                break;
            }
            let rem = flow.tx_unacked.len() - flow.tx_unsent_off;
            let seg_len = rem.min(allowed).min(flow.peer_mss).min(seg_buf.len());
            if seg_len == 0 {
                break;
            }
            let (s1, s2) = flow.tx_unacked.as_slices();
            let off = flow.tx_unsent_off;
            if off < s1.len() {
                let first = (s1.len() - off).min(seg_len);
                seg_buf[..first].copy_from_slice(&s1[off..off + first]);
                if first < seg_len {
                    seg_buf[first..seg_len].copy_from_slice(&s2[..seg_len - first]);
                }
            } else {
                let off2 = off - s1.len();
                seg_buf[..seg_len].copy_from_slice(&s2[off2..off2 + seg_len]);
            }

            let is_last = flow.tx_unsent_off + seg_len >= flow.tx_unacked.len();
            let flags = TCP_ACK | if is_last { TCP_PSH } else { 0 };
            let seq = flow.snd_nxt;
            flow.snd_nxt = flow.snd_nxt.wrapping_add(seg_len as u32);
            flow.tx_unsent_off += seg_len;
            flow.last_tx = Instant::now();
            flow.last_activity = flow.last_tx;
            flow.bytes_since_ack = 0;
            flow.last_adv_wnd = flow.rcv_wnd_bytes();

            any |= self.send_tcp(
                flow.key,
                seq,
                flow.rcv_nxt,
                flags,
                wnd,
                &seg_buf[..seg_len],
                None,
                false,
            );
        }

        if flow.host_fin_queued
            && !flow.host_fin_sent
            && flow.tx_unsent_off == flow.tx_unacked.len()
        {
            flow.host_fin_sent = true;
            flow.state = EgressTcpState::FinWait;
            flow.fin_time = Some(Instant::now());
            let seq = flow.snd_nxt;
            flow.snd_nxt = flow.snd_nxt.wrapping_add(1);
            flow.last_tx = Instant::now();
            any |= self.send_tcp(
                flow.key,
                seq,
                flow.rcv_nxt,
                TCP_FIN | TCP_ACK,
                wnd,
                &[],
                None,
                true,
            );
        }
        any
    }

    fn pump_tcp_from_host(&self, flow: &mut EgressTcpFlow, scratch: &mut [u8]) -> (bool, bool) {
        if flow.state != EgressTcpState::Established {
            return (false, false);
        }
        let mut abort = false;
        while flow.host_readable && !flow.host_fin_queued && flow.fd >= 0 {
            let avail = EGRESS_TX_INFLIGHT.saturating_sub(flow.tx_unacked.len());
            if avail == 0 {
                break;
            }
            let cap = avail.min(scratch.len());
            let rc = unsafe { libc::read(flow.fd, scratch.as_mut_ptr().cast(), cap) };
            if rc > 0 {
                let n = rc as usize;
                flow.tx_unacked.extend(&scratch[..n]);
                flow.last_activity = Instant::now();
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
                abort = true;
                break;
            }
        }
        let pushed = self.flush_tcp_to_guest(flow);
        (pushed, abort)
    }

    fn drain_pending_to_host(&self, flow: &mut EgressTcpFlow) -> (bool, bool) {
        if flow.fd < 0 {
            return (false, false);
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
            let rc = unsafe { libc::writev(flow.fd, iovs.as_mut_ptr(), niov) };
            if rc > 0 {
                let n = rc as usize;
                flow.pending_to_host.drain(..n);
                drained += n;
                flow.last_activity = Instant::now();
            } else if rc < 0 {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::WouldBlock {
                    flow.host_writable = false;
                    break;
                }
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return (false, true);
            } else {
                break;
            }
        }

        if flow.pending_to_host.is_empty() && flow.write_ev_armed {
            kq_ctl(
                self.kq_fd.as_raw_fd(),
                flow.fd,
                libc::EVFILT_WRITE,
                libc::EV_DISABLE,
                UDATA_TCP_TAG | flow.id,
            );
            flow.write_ev_armed = false;
        }
        if flow.guest_fin && flow.pending_to_host.is_empty() && flow.fd >= 0 {
            unsafe { libc::shutdown(flow.fd, libc::SHUT_WR) };
        }

        let mut pushed = false;
        if drained > 0 {
            let new_wnd = flow.rcv_wnd_bytes();
            if new_wnd >= flow.last_adv_wnd + 32768 || flow.pending_to_host.is_empty() {
                flow.last_adv_wnd = new_wnd;
                flow.bytes_since_ack = 0;
                pushed = self.send_tcp(
                    flow.key,
                    flow.snd_nxt,
                    flow.rcv_nxt,
                    TCP_ACK,
                    flow.encoded_rcv_wnd(),
                    &[],
                    None,
                    true,
                );
            }
        }
        (pushed, false)
    }

    fn handle_tx_chain(
        &self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        total_len: usize,
        scratch: &mut [u8],
    ) -> bool {
        if total_len <= VIRTIO_NET_HDR_LEN + 14 {
            return false;
        }
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

        // 1. ARP responder for 10.42.0.1
        if ethertype == 0x0806 {
            if let Some(rep) = build_arp_reply_for_request(&self.cfg, eth) {
                let mut rx = self.rx.lock().unwrap();
                return rx.send_parts(&rep, &[], true, &self.metrics);
            }
            return false;
        }

        if ethertype != 0x0800 || eth.len() < 34 {
            return false;
        }
        let ihl = ((eth[14] & 0x0f) as usize) * 4;
        if ihl < 20 || eth.len() < 14 + ihl {
            return false;
        }
        let ip_tot_len = u16::from_be_bytes([eth[16], eth[17]]) as usize;
        let proto = eth[23];
        let src_ip = Ipv4Addr::new(eth[26], eth[27], eth[28], eth[29]);
        let dst_ip = Ipv4Addr::new(eth[30], eth[31], eth[32], eth[33]);
        let l4_off = 14 + ihl;

        match proto {
            6 => self.handle_tcp_tx(
                bufs, mem, total_len, &hdr, eth, l4_off, ihl, ip_tot_len, src_ip, dst_ip, scratch,
            ),
            17 => self.handle_udp_tx(
                bufs, mem, total_len, l4_off, ihl, ip_tot_len, src_ip, dst_ip,
            ),
            1 => self.handle_icmp_tx(
                bufs, mem, total_len, l4_off, ihl, ip_tot_len, src_ip, dst_ip,
            ),
            _ => false,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn handle_tcp_tx(
        &self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        total_len: usize,
        hdr: &[u8; 128],
        eth: &[u8],
        tcp_off: usize,
        ihl: usize,
        ip_tot_len: usize,
        src_ip: Ipv4Addr,
        dst_ip: Ipv4Addr,
        scratch: &mut [u8],
    ) -> bool {
        if eth.len() < tcp_off + 20 {
            return false;
        }
        let thl = (((eth[tcp_off + 12] >> 4) & 0x0f) as usize) * 4;
        if thl < 20 || eth.len() < tcp_off + thl {
            return false;
        }
        let guest_port = u16::from_be_bytes([eth[tcp_off], eth[tcp_off + 1]]);
        let remote_port = u16::from_be_bytes([eth[tcp_off + 2], eth[tcp_off + 3]]);
        let seg_seq = u32::from_be_bytes(eth[tcp_off + 4..tcp_off + 8].try_into().unwrap());
        let seg_ack = u32::from_be_bytes(eth[tcp_off + 8..tcp_off + 12].try_into().unwrap());
        let flags = eth[tcp_off + 13];
        let seg_wnd = u16::from_be_bytes([eth[tcp_off + 14], eth[tcp_off + 15]]);

        let hdr_total_in_chain = VIRTIO_NET_HDR_LEN + tcp_off + thl;
        let gso_type = hdr[1];
        let raw_payload = total_len.saturating_sub(hdr_total_in_chain);
        let payload_len = if gso_type == 0 && ip_tot_len >= ihl + thl {
            (ip_tot_len - ihl - thl).min(raw_payload)
        } else {
            raw_payload
        };

        let key = TcpFlowKey {
            guest_ip: src_ip,
            guest_port,
            remote_ip: dst_ip,
            remote_port,
        };

        // New outbound TCP connection (SYN without ACK)
        if (flags & (TCP_SYN | TCP_ACK)) == TCP_SYN {
            let connect_ip = if dst_ip == self.cfg.host_ip && remote_port == 53 {
                self.upstream_dns()
            } else if dst_ip == self.cfg.host_ip || is_blocked_egress_ip(dst_ip) {
                return self.send_tcp(
                    key,
                    0,
                    seg_seq.wrapping_add(1),
                    TCP_RST | TCP_ACK,
                    0,
                    &[],
                    None,
                    true,
                );
            } else {
                dst_ip
            };

            let mut table = self.table.lock().unwrap();
            if let Some(&existing_id) = table.tcp_by_key.get(&key) {
                // Retransmitted SYN while Connecting/SynRcvd
                if let Some(f) = table.tcp_by_id.get(&existing_id) {
                    if f.state == EgressTcpState::SynRcvd {
                        let mss = self.cfg.mtu.saturating_sub(40).max(536);
                        let (sn, rn, wnd) = (f.snd_una, f.rcv_nxt, f.encoded_rcv_wnd());
                        drop(table);
                        return self.send_tcp(
                            key,
                            sn,
                            rn,
                            TCP_SYN | TCP_ACK,
                            wnd,
                            &[],
                            Some(mss),
                            true,
                        );
                    }
                    return false;
                }
            }
            if table.tcp_by_id.len() >= EGRESS_MAX_TCP_FLOWS {
                drop(table);
                return self.send_tcp(
                    key,
                    0,
                    seg_seq.wrapping_add(1),
                    TCP_RST | TCP_ACK,
                    0,
                    &[],
                    None,
                    true,
                );
            }

            let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) };
            if fd < 0 {
                drop(table);
                return self.send_tcp(
                    key,
                    0,
                    seg_seq.wrapping_add(1),
                    TCP_RST | TCP_ACK,
                    0,
                    &[],
                    None,
                    true,
                );
            }
            unsafe {
                let fl = libc::fcntl(fd, libc::F_GETFL, 0);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                let one: libc::c_int = 1;
                let buf_sz: libc::c_int = 256 * 1024;
                libc::setsockopt(
                    fd,
                    libc::IPPROTO_TCP,
                    libc::TCP_NODELAY,
                    (&one as *const libc::c_int).cast(),
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    (&one as *const libc::c_int).cast(),
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_SNDBUF,
                    (&buf_sz as *const libc::c_int).cast(),
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_RCVBUF,
                    (&buf_sz as *const libc::c_int).cast(),
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
            }

            let sin = libc::sockaddr_in {
                sin_len: std::mem::size_of::<libc::sockaddr_in>() as u8,
                sin_family: libc::AF_INET as libc::sa_family_t,
                sin_port: remote_port.to_be(),
                sin_addr: libc::in_addr {
                    s_addr: u32::from_ne_bytes(connect_ip.octets()),
                },
                sin_zero: [0; 8],
            };
            let rc = unsafe {
                libc::connect(
                    fd,
                    (&sin as *const libc::sockaddr_in).cast(),
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            };
            let connected_now = if rc == 0 {
                true
            } else {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EINPROGRESS) {
                    false
                } else {
                    unsafe { libc::close(fd) };
                    drop(table);
                    return self.send_tcp(
                        key,
                        0,
                        seg_seq.wrapping_add(1),
                        TCP_RST | TCP_ACK,
                        0,
                        &[],
                        None,
                        true,
                    );
                }
            };

            let (mss, p_ws, has_ws) = parse_tcp_syn_options(&eth[tcp_off + 20..tcp_off + thl]);
            let id = table.alloc_id();
            let iss = self.next_iss.fetch_add(65537, Ordering::Relaxed);
            let now = Instant::now();
            let host_ws = if has_ws { HOST_WS_SHIFT } else { 0 };
            let peer_ws = if has_ws { p_ws } else { 0 };
            let state = if connected_now {
                EgressTcpState::SynRcvd
            } else {
                EgressTcpState::Connecting
            };
            let flow = EgressTcpFlow {
                id,
                key,
                fd,
                state,
                snd_una: iss,
                snd_nxt: iss.wrapping_add(1),
                snd_wnd: seg_wnd as u32,
                peer_mss: mss.min((self.cfg.mtu as usize).saturating_sub(40)).max(536),
                peer_ws,
                host_ws,
                rcv_nxt: seg_seq.wrapping_add(1),
                last_adv_wnd: EGRESS_RCV_WND,
                bytes_since_ack: 0,
                pending_to_host: VecDeque::new(),
                tx_unacked: VecDeque::new(),
                tx_unsent_off: 0,
                host_readable: false,
                host_writable: connected_now,
                write_ev_armed: !connected_now,
                host_fin_queued: false,
                host_fin_sent: false,
                guest_fin: false,
                created: now,
                last_activity: now,
                last_tx: now,
                fin_time: None,
            };
            let wnd = flow.encoded_rcv_wnd();
            table.tcp_by_key.insert(key, id);
            table.tcp_by_id.insert(id, flow);
            if connected_now {
                kq_ctl(
                    self.kq_fd.as_raw_fd(),
                    fd,
                    libc::EVFILT_READ,
                    libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                    UDATA_TCP_TAG | id,
                );
                drop(table);
                let adv_mss = self.cfg.mtu.saturating_sub(40).max(536);
                return self.send_tcp(
                    key,
                    iss,
                    seg_seq.wrapping_add(1),
                    TCP_SYN | TCP_ACK,
                    wnd,
                    &[],
                    Some(adv_mss),
                    true,
                );
            } else {
                kq_ctl(
                    self.kq_fd.as_raw_fd(),
                    fd,
                    libc::EVFILT_WRITE,
                    libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                    UDATA_TCP_TAG | id,
                );
                return false;
            }
        }

        let mut table = self.table.lock().unwrap();
        let Some(&id) = table.tcp_by_key.get(&key) else {
            drop(table);
            if (flags & TCP_RST) == 0 && (flags & TCP_ACK) != 0 {
                return self.send_tcp(key, seg_ack, 0, TCP_RST, 0, &[], None, true);
            }
            return false;
        };

        if (flags & TCP_RST) != 0 {
            table.remove_tcp(id);
            return false;
        }

        let Some(flow) = table.tcp_by_id.get_mut(&id) else {
            return false;
        };
        flow.last_activity = Instant::now();
        let mut need_irq = false;

        if flow.state == EgressTcpState::SynRcvd
            && (flags & TCP_ACK) != 0
            && seg_ack == flow.snd_nxt
        {
            flow.snd_una = seg_ack;
            flow.snd_wnd = (seg_wnd as u32) << flow.peer_ws;
            flow.state = EgressTcpState::Established;
            flow.host_readable = true;
            let (p, abort) = self.pump_tcp_from_host(flow, scratch);
            need_irq |= p;
            if abort {
                let (k, sn, rn) = (flow.key, flow.snd_nxt, flow.rcv_nxt);
                table.remove_tcp(id);
                drop(table);
                return self.send_tcp(k, sn, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
            }
        } else if (flags & TCP_ACK) != 0 && flow.state != EgressTcpState::Connecting {
            flow.snd_wnd = (seg_wnd as u32) << flow.peer_ws;
            let acked = seg_ack.wrapping_sub(flow.snd_una) as i32;
            if acked > 0 {
                let data_acked = (acked as usize).min(flow.tx_unacked.len());
                if data_acked > 0 {
                    flow.tx_unacked.drain(..data_acked);
                    flow.tx_unsent_off = flow.tx_unsent_off.saturating_sub(data_acked);
                }
                flow.snd_una = seg_ack;
                if flow.tx_unsent_off < flow.tx_unacked.len() || flow.host_readable {
                    let (p, abort) = self.pump_tcp_from_host(flow, scratch);
                    need_irq |= p;
                    if abort {
                        let (k, sn, rn) = (flow.key, flow.snd_nxt, flow.rcv_nxt);
                        table.remove_tcp(id);
                        drop(table);
                        return self.send_tcp(k, sn, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
                    }
                }
            }
        }

        let mut send_ack = false;
        let mut arm_write = false;
        let mut abort = false;

        if payload_len > 0 && flow.state == EgressTcpState::Established {
            let seq_diff = seg_seq.wrapping_sub(flow.rcv_nxt) as i32;
            if seq_diff > 0 {
                send_ack = true;
            } else {
                let overlap = (-seq_diff) as usize;
                if overlap >= payload_len {
                    send_ack = true;
                } else {
                    let new_bytes = payload_len - overlap;
                    let skip_total = hdr_total_in_chain + overlap;
                    if flow.pending_to_host.is_empty() && flow.fd >= 0 {
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
                                    libc::writev(flow.fd, iovs.as_ptr(), niov as libc::c_int)
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
                                abort = true;
                                break;
                            }
                        }
                        if !abort && written < new_bytes {
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
                    } else if !abort {
                        copy_chain_slice_into(
                            bufs,
                            mem,
                            skip_total,
                            new_bytes,
                            &mut flow.pending_to_host,
                        );
                        arm_write = true;
                    }
                    if !abort {
                        flow.rcv_nxt = flow.rcv_nxt.wrapping_add(new_bytes as u32);
                        flow.bytes_since_ack += new_bytes;
                        if flow.bytes_since_ack >= EGRESS_ACK_COALESCE
                            || flow.rcv_wnd_bytes() == 0
                            || (flags & TCP_PSH) != 0
                        {
                            send_ack = true;
                        }
                    }
                }
            }
        }

        if abort {
            let (k, sn, rn) = (flow.key, flow.snd_nxt, flow.rcv_nxt);
            table.remove_tcp(id);
            drop(table);
            return self.send_tcp(k, sn, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
        }

        if arm_write && !flow.write_ev_armed && flow.fd >= 0 {
            kq_ctl(
                self.kq_fd.as_raw_fd(),
                flow.fd,
                libc::EVFILT_WRITE,
                libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                UDATA_TCP_TAG | id,
            );
            flow.write_ev_armed = true;
        }

        if (flags & TCP_FIN) != 0
            && !flow.guest_fin
            && seg_seq.wrapping_add(payload_len as u32) == flow.rcv_nxt
        {
            flow.rcv_nxt = flow.rcv_nxt.wrapping_add(1);
            flow.guest_fin = true;
            send_ack = true;
            if flow.pending_to_host.is_empty() && flow.fd >= 0 {
                unsafe { libc::shutdown(flow.fd, libc::SHUT_WR) };
            }
        }

        if send_ack {
            flow.bytes_since_ack = 0;
            flow.last_adv_wnd = flow.rcv_wnd_bytes();
            need_irq |= self.send_tcp(
                flow.key,
                flow.snd_nxt,
                flow.rcv_nxt,
                TCP_ACK,
                flow.encoded_rcv_wnd(),
                &[],
                None,
                true,
            );
        }

        if flow.guest_fin
            && flow.host_fin_sent
            && flow.pending_to_host.is_empty()
            && flow.tx_unacked.is_empty()
            && flow.snd_una == flow.snd_nxt
        {
            table.remove_tcp(id);
        }

        need_irq
    }

    #[allow(clippy::too_many_arguments)]
    fn handle_udp_tx(
        &self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        total_len: usize,
        udp_off: usize,
        ihl: usize,
        ip_tot_len: usize,
        src_ip: Ipv4Addr,
        dst_ip: Ipv4Addr,
    ) -> bool {
        let mut raw = Vec::with_capacity(total_len.saturating_sub(VIRTIO_NET_HDR_LEN));
        let mut skip = VIRTIO_NET_HDR_LEN;
        for b in bufs {
            if b.is_write {
                continue;
            }
            let blen = b.len as usize;
            if skip >= blen {
                skip -= blen;
                continue;
            }
            if let Some(s) = mem.read_slice(b.addr, blen) {
                raw.extend_from_slice(&s[skip..]);
                skip = 0;
            }
        }
        if raw.len() < udp_off + 8 || ip_tot_len < ihl + 8 {
            return false;
        }
        let guest_port = u16::from_be_bytes([raw[udp_off], raw[udp_off + 1]]);
        let remote_port = u16::from_be_bytes([raw[udp_off + 2], raw[udp_off + 3]]);
        let udp_len = u16::from_be_bytes([raw[udp_off + 4], raw[udp_off + 5]]) as usize;
        if udp_len < 8 || raw.len() < udp_off + udp_len {
            return false;
        }
        let payload = &raw[udp_off + 8..udp_off + udp_len];

        let target_ip = if dst_ip == self.cfg.host_ip && remote_port == 53 {
            self.upstream_dns()
        } else if dst_ip == self.cfg.host_ip || is_blocked_egress_ip(dst_ip) {
            return false;
        } else {
            dst_ip
        };

        let key = UdpFlowKey {
            guest_ip: src_ip,
            guest_port,
            remote_ip: dst_ip,
            remote_port,
        };

        let mut table = self.table.lock().unwrap();
        let existing_fd = if let Some(&id) = table.udp_by_key.get(&key) {
            let stale_target = table
                .udp_by_id
                .get(&id)
                .is_some_and(|f| f.target_ip != target_ip);
            if stale_target {
                table.remove_udp(id);
                None
            } else if let Some(f) = table.udp_by_id.get_mut(&id) {
                f.last_activity = Instant::now();
                Some(f.fd)
            } else {
                None
            }
        } else {
            None
        };
        let fd = if let Some(fd) = existing_fd {
            fd
        } else {
            if table.udp_by_id.len() >= EGRESS_MAX_UDP_FLOWS {
                // Evict oldest UDP NAT entry
                if let Some((&oldest_id, _)) =
                    table.udp_by_id.iter().min_by_key(|(_, f)| f.last_activity)
                {
                    table.remove_udp(oldest_id);
                }
            }
            let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
            if fd < 0 {
                return false;
            }
            unsafe {
                let fl = libc::fcntl(fd, libc::F_GETFL, 0);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
            }
            let sin = libc::sockaddr_in {
                sin_len: std::mem::size_of::<libc::sockaddr_in>() as u8,
                sin_family: libc::AF_INET as libc::sa_family_t,
                sin_port: remote_port.to_be(),
                sin_addr: libc::in_addr {
                    s_addr: u32::from_ne_bytes(target_ip.octets()),
                },
                sin_zero: [0; 8],
            };
            if unsafe {
                libc::connect(
                    fd,
                    (&sin as *const libc::sockaddr_in).cast(),
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            } < 0
            {
                unsafe { libc::close(fd) };
                return false;
            }
            let id = table.alloc_id();
            kq_ctl(
                self.kq_fd.as_raw_fd(),
                fd,
                libc::EVFILT_READ,
                libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                UDATA_UDP_TAG | id,
            );
            table.udp_by_key.insert(key, id);
            table.udp_by_id.insert(
                id,
                EgressUdpFlow {
                    key,
                    target_ip,
                    fd,
                    got_reply: false,
                    failover_noted: false,
                    last_activity: Instant::now(),
                },
            );
            fd
        };

        let _ = unsafe { libc::send(fd, payload.as_ptr().cast(), payload.len(), 0) };
        false
    }

    #[allow(clippy::too_many_arguments)]
    fn handle_icmp_tx(
        &self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        total_len: usize,
        icmp_off: usize,
        ihl: usize,
        ip_tot_len: usize,
        src_ip: Ipv4Addr,
        dst_ip: Ipv4Addr,
    ) -> bool {
        let mut raw = Vec::with_capacity(total_len.saturating_sub(VIRTIO_NET_HDR_LEN));
        let mut skip = VIRTIO_NET_HDR_LEN;
        for b in bufs {
            if b.is_write {
                continue;
            }
            let blen = b.len as usize;
            if skip >= blen {
                skip -= blen;
                continue;
            }
            if let Some(s) = mem.read_slice(b.addr, blen) {
                raw.extend_from_slice(&s[skip..]);
                skip = 0;
            }
        }
        let icmp_len = ip_tot_len.saturating_sub(ihl);
        if icmp_len < 8 || raw.len() < icmp_off + icmp_len {
            return false;
        }
        let icmp = &raw[icmp_off..icmp_off + icmp_len];
        if icmp[0] != 8 {
            return false; // Only handle ICMP Echo Request
        }

        // Gateway self-ping: instant local echo reply
        if dst_ip == self.cfg.host_ip {
            let mut reply = icmp.to_vec();
            reply[0] = 0; // Echo Reply
            reply[2] = 0;
            reply[3] = 0;
            let csum = internet_checksum(0, &reply);
            reply[2..4].copy_from_slice(&csum.to_be_bytes());
            let mut rx = self.rx.lock().unwrap();
            let ip_id = rx.next_ip_id();
            let frame = encode_egress_icmp_frame(&self.cfg, ip_id, dst_ip, src_ip, &reply);
            return rx.send_parts(&frame, &[], true, &self.metrics);
        }

        if is_blocked_egress_ip(dst_ip) {
            return false;
        }

        let icmp_id = u16::from_be_bytes([icmp[4], icmp[5]]);
        let key = IcmpFlowKey {
            guest_ip: src_ip,
            remote_ip: dst_ip,
            icmp_id,
        };
        let mut table = self.table.lock().unwrap();
        let fd = if let Some(&id) = table.icmp_by_key.get(&key) {
            if let Some(f) = table.icmp_by_id.get_mut(&id) {
                f.last_activity = Instant::now();
                f.fd
            } else {
                return false;
            }
        } else {
            if table.icmp_by_id.len() >= EGRESS_MAX_ICMP_FLOWS
                && let Some((&oldest_id, _)) =
                    table.icmp_by_id.iter().min_by_key(|(_, f)| f.last_activity)
            {
                table.remove_icmp(oldest_id);
            }
            // macOS supports unprivileged SOCK_DGRAM / IPPROTO_ICMP echo sockets!
            let fd = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, libc::IPPROTO_ICMP) };
            if fd < 0 {
                return false;
            }
            unsafe {
                let fl = libc::fcntl(fd, libc::F_GETFL, 0);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
            }
            let sin = libc::sockaddr_in {
                sin_len: std::mem::size_of::<libc::sockaddr_in>() as u8,
                sin_family: libc::AF_INET as libc::sa_family_t,
                sin_port: 0,
                sin_addr: libc::in_addr {
                    s_addr: u32::from_ne_bytes(dst_ip.octets()),
                },
                sin_zero: [0; 8],
            };
            if unsafe {
                libc::connect(
                    fd,
                    (&sin as *const libc::sockaddr_in).cast(),
                    std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
                )
            } < 0
            {
                unsafe { libc::close(fd) };
                return false;
            }
            let id = table.alloc_id();
            kq_ctl(
                self.kq_fd.as_raw_fd(),
                fd,
                libc::EVFILT_READ,
                libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                UDATA_ICMP_TAG | id,
            );
            table.icmp_by_key.insert(key, id);
            table.icmp_by_id.insert(
                id,
                EgressIcmpFlow {
                    key,
                    fd,
                    last_activity: Instant::now(),
                },
            );
            fd
        };
        let _ = unsafe { libc::send(fd, icmp.as_ptr().cast(), icmp.len(), 0) };
        false
    }
}

fn run_egress_io_loop(shared: Arc<EgressShared>) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let kq = shared.kq_fd.as_raw_fd();
    let mut scratch = vec![0u8; 64 * 1024];
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
        if shared.shutdown.load(Ordering::Relaxed) {
            break;
        }
        {
            let mut rx = shared.rx.lock().unwrap();
            if rx.drain_overflow(&shared.metrics) {
                rx.raise_irq();
            }
        }

        let ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 25_000_000,
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

        let mut need_irq = false;
        if n > 0 {
            let mut table = shared.table.lock().unwrap();
            for ev in &events[..n as usize] {
                let udata = ev.udata as usize;
                let tag = udata & 0xf000_0000;
                let id = udata & 0x0fff_ffff;
                if tag == UDATA_TCP_TAG {
                    let Some(flow) = table.tcp_by_id.get_mut(&id) else {
                        continue;
                    };
                    if flow.state == EgressTcpState::Connecting && ev.filter == libc::EVFILT_WRITE {
                        let mut so_err: libc::c_int = 0;
                        let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
                        let grc = unsafe {
                            libc::getsockopt(
                                flow.fd,
                                libc::SOL_SOCKET,
                                libc::SO_ERROR,
                                (&mut so_err as *mut libc::c_int).cast(),
                                &mut len,
                            )
                        };
                        if grc == 0 && so_err == 0 {
                            flow.state = EgressTcpState::SynRcvd;
                            flow.host_writable = true;
                            flow.write_ev_armed = false;
                            flow.last_tx = Instant::now();
                            flow.last_activity = flow.last_tx;
                            kq_ctl(kq, flow.fd, libc::EVFILT_WRITE, libc::EV_DISABLE, udata);
                            kq_ctl(
                                kq,
                                flow.fd,
                                libc::EVFILT_READ,
                                libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR,
                                udata,
                            );
                            let adv_mss = shared.cfg.mtu.saturating_sub(40).max(536);
                            need_irq |= shared.send_tcp(
                                flow.key,
                                flow.snd_una,
                                flow.rcv_nxt,
                                TCP_SYN | TCP_ACK,
                                flow.encoded_rcv_wnd(),
                                &[],
                                Some(adv_mss),
                                true,
                            );
                        } else {
                            let (k, rn) = (flow.key, flow.rcv_nxt);
                            table.remove_tcp(id);
                            need_irq |=
                                shared.send_tcp(k, 0, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
                        }
                        continue;
                    }

                    let mut abort = false;
                    if ev.filter == libc::EVFILT_READ {
                        flow.host_readable = true;
                        let (p, a) = shared.pump_tcp_from_host(flow, &mut scratch);
                        need_irq |= p;
                        abort |= a;
                    } else if ev.filter == libc::EVFILT_WRITE {
                        flow.host_writable = true;
                        let (p, a) = shared.drain_pending_to_host(flow);
                        need_irq |= p;
                        abort |= a;
                    }
                    if abort {
                        let (k, sn, rn) = (flow.key, flow.snd_nxt, flow.rcv_nxt);
                        table.remove_tcp(id);
                        need_irq |=
                            shared.send_tcp(k, sn, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
                    } else if flow.guest_fin
                        && flow.host_fin_sent
                        && flow.pending_to_host.is_empty()
                        && flow.tx_unacked.is_empty()
                        && flow.snd_una == flow.snd_nxt
                    {
                        table.remove_tcp(id);
                    }
                } else if tag == UDATA_UDP_TAG {
                    let Some(flow) = table.udp_by_id.get_mut(&id) else {
                        continue;
                    };
                    loop {
                        let rc =
                            unsafe { libc::recv(flow.fd, scratch.as_mut_ptr().cast(), 1472, 0) };
                        if rc > 0 {
                            flow.got_reply = true;
                            flow.last_activity = Instant::now();
                            need_irq |= shared.send_udp(flow.key, &scratch[..rc as usize]);
                        } else {
                            break;
                        }
                    }
                } else if tag == UDATA_ICMP_TAG {
                    let Some(flow) = table.icmp_by_id.get_mut(&id) else {
                        continue;
                    };
                    loop {
                        let rc =
                            unsafe { libc::recv(flow.fd, scratch.as_mut_ptr().cast(), 1480, 0) };
                        if rc >= 8 {
                            flow.last_activity = Instant::now();
                            // Darwin SOCK_DGRAM/IPPROTO_ICMP returns the IPv4 header + ICMP payload
                            let pkt = &scratch[..rc as usize];
                            let icmp_slice = if (pkt[0] >> 4) == 4 {
                                let ihl = ((pkt[0] & 0x0f) as usize) * 4;
                                if pkt.len() > ihl + 8 {
                                    &pkt[ihl..]
                                } else {
                                    pkt
                                }
                            } else {
                                pkt
                            };
                            let mut reply = icmp_slice.to_vec();
                            // Restore guest's original ICMP echo ID & recompute checksum
                            reply[4..6].copy_from_slice(&flow.key.icmp_id.to_be_bytes());
                            reply[2] = 0;
                            reply[3] = 0;
                            let csum = internet_checksum(0, &reply);
                            reply[2..4].copy_from_slice(&csum.to_be_bytes());
                            let mut rx = shared.rx.lock().unwrap();
                            let ip_id = rx.next_ip_id();
                            let frame = encode_egress_icmp_frame(
                                &shared.cfg,
                                ip_id,
                                flow.key.remote_ip,
                                flow.key.guest_ip,
                                &reply,
                            );
                            need_irq |= rx.send_parts(&frame, &[], true, &shared.metrics);
                        } else {
                            break;
                        }
                    }
                }
            }
        }

        // Periodic timer sweep: TCP retransmits, connect timeouts, UDP/ICMP NAT GC
        if last_sweep.elapsed() >= Duration::from_millis(50) {
            last_sweep = Instant::now();
            let mut table = shared.table.lock().unwrap();
            let mut dead_tcp = Vec::new();
            for (&id, flow) in table.tcp_by_id.iter_mut() {
                if flow.state == EgressTcpState::Connecting
                    && flow.created.elapsed() >= Duration::from_secs(15)
                {
                    dead_tcp.push((id, Some((flow.key, 0, flow.rcv_nxt))));
                } else if flow.state == EgressTcpState::SynRcvd
                    && flow.last_tx.elapsed() >= Duration::from_millis(500)
                {
                    if flow.created.elapsed() >= Duration::from_secs(10) {
                        dead_tcp.push((id, None));
                    } else {
                        flow.last_tx = Instant::now();
                        let mss = shared.cfg.mtu.saturating_sub(40).max(536);
                        need_irq |= shared.send_tcp(
                            flow.key,
                            flow.snd_una,
                            flow.rcv_nxt,
                            TCP_SYN | TCP_ACK,
                            flow.encoded_rcv_wnd(),
                            &[],
                            Some(mss),
                            true,
                        );
                    }
                } else if !flow.tx_unacked.is_empty()
                    && flow.last_tx.elapsed() >= Duration::from_millis(250)
                {
                    flow.tx_unsent_off = 0;
                    flow.snd_nxt = flow.snd_una;
                    need_irq |= shared.flush_tcp_to_guest(flow);
                } else if let Some(ft) = flow.fin_time {
                    if ft.elapsed() >= Duration::from_secs(2) {
                        dead_tcp.push((id, None));
                    }
                } else if flow.last_activity.elapsed() >= Duration::from_secs(300) {
                    dead_tcp.push((id, None));
                }
            }
            for (id, rst) in dead_tcp {
                table.remove_tcp(id);
                if let Some((k, sn, rn)) = rst {
                    need_irq |= shared.send_tcp(k, sn, rn, TCP_RST | TCP_ACK, 0, &[], None, true);
                }
            }

            let mut dns_timed_out = false;
            let mut dead_udp = Vec::new();
            for (&id, f) in table.udp_by_id.iter_mut() {
                let elapsed = f.last_activity.elapsed();
                if f.key.remote_ip == shared.cfg.host_ip && f.key.remote_port == 53 {
                    if f.got_reply && elapsed >= Duration::from_secs(5) {
                        dead_udp.push(id);
                    } else if !f.got_reply && elapsed >= Duration::from_secs(3) {
                        if !f.failover_noted {
                            f.failover_noted = true;
                            dns_timed_out = true;
                        }
                        if elapsed >= Duration::from_secs(10) {
                            dead_udp.push(id);
                        }
                    }
                } else if elapsed >= Duration::from_secs(45) {
                    dead_udp.push(id);
                }
            }
            if dns_timed_out {
                shared.dns.lock().unwrap().rotate_failover();
            }
            for id in dead_udp {
                table.remove_udp(id);
            }
            let dead_icmp: Vec<usize> = table
                .icmp_by_id
                .iter()
                .filter(|(_, f)| f.last_activity.elapsed() >= Duration::from_secs(15))
                .map(|(&id, _)| id)
                .collect();
            for id in dead_icmp {
                table.remove_icmp(id);
            }
        }

        if need_irq {
            shared.rx.lock().unwrap().raise_irq();
        }
    }
}

/// Virtio-Net (Device ID 1) outbound egress gateway (`eth0`, zero `vmnet`, zero TCC).
pub struct VirtioNetEgress {
    shared: Arc<EgressShared>,
    io_handle: Option<thread::JoinHandle<()>>,
    tx_scratch: Vec<u8>,
}

impl VirtioNetEgress {
    pub fn new(cfg: NetConfig, metrics: Arc<NetMetrics>) -> std::io::Result<Self> {
        let kq_fd = create_wake_queue(EGRESS_WAKE_IDENT)?;

        let shared = Arc::new(EgressShared {
            cfg,
            dns: Mutex::new(DnsResolverState::new()),
            kq_fd,
            rx: Mutex::new(RxRingState::new()),
            table: Mutex::new(EgressTable::new()),
            next_iss: AtomicU32::new(0x4200_1000),
            metrics,
            shutdown: AtomicBool::new(false),
        });
        Ok(Self {
            shared,
            io_handle: None,
            tx_scratch: vec![0u8; 16 * 1024],
        })
    }

    fn ensure_io_started(&mut self) {
        if self.io_handle.is_some() {
            return;
        }
        let shared = self.shared.clone();
        let handle = thread::Builder::new()
            .name("vmm-net-egress".into())
            .spawn(move || run_egress_io_loop(shared))
            .expect("spawn vmm-net-egress thread");
        self.io_handle = Some(handle);
    }
}

impl VirtioBackend for VirtioNetEgress {
    fn device_id(&self) -> u32 {
        1
    }
    fn features(&self) -> u64 {
        VIRTIO_NET_F_CSUM
            | VIRTIO_NET_F_GUEST_CSUM
            | VIRTIO_NET_F_HOST_TSO4
            | VIRTIO_NET_F_MAC
            | VIRTIO_NET_F_STATUS
            | VIRTIO_NET_F_MTU
    }
    fn num_queues(&self) -> usize {
        2
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        512
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 12];
        cfg[0..6].copy_from_slice(&self.shared.cfg.guest_mac);
        cfg[6..8].copy_from_slice(&1u16.to_le_bytes());
        cfg[8..10].copy_from_slice(&1u16.to_le_bytes());
        cfg[10..12].copy_from_slice(&self.shared.cfg.mtu.to_le_bytes());
        let start = offset as usize;
        for (i, b) in data.iter_mut().enumerate() {
            *b = cfg.get(start + i).copied().unwrap_or(0);
        }
    }
    fn attach(&mut self, mem: Arc<GuestMemory>, irq: IrqLine) {
        let mut rx = self.shared.rx.lock().unwrap();
        rx.mem = Some(mem);
        rx.irq = Some(irq);
    }
    fn queue_ready(&mut self, q_idx: usize, q: &VirtQueue) {
        if q_idx == 0 {
            self.shared.rx.lock().unwrap().rx_queue = Some(q.clone());
            self.ensure_io_started();
            trigger_kq_wake(self.shared.kq_fd.as_raw_fd());
        }
    }
    fn reset(&mut self) {
        let mut rx = self.shared.rx.lock().unwrap();
        rx.rx_queue = None;
        rx.overflow_prio.clear();
        rx.overflow_norm.clear();
    }
    fn snapshot_pause(&mut self, queues: &mut [VirtQueue], _mem: &GuestMemory) -> Vec<u8> {
        let rx = self.shared.rx.lock().unwrap();
        if let Some(ref rxq) = rx.rx_queue {
            queues[0].next_avail = rxq.next_avail;
            queues[0].next_used = rxq.next_used;
        }
        Vec::new()
    }
    fn snapshot_restore(&mut self, _blob: &[u8], queues: &[VirtQueue]) {
        // Re-read host /etc/resolv.conf immediately so forks restored on a new Wi-Fi/VPN work.
        self.shared.dns.lock().unwrap().force_refresh();
        if let Some(rxq) = queues.first()
            && rxq.ready
        {
            self.queue_ready(0, rxq);
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool {
        if q_idx == 0 {
            let mut rx = self.shared.rx.lock().unwrap();
            if let Some(ref mut rxq) = rx.rx_queue {
                rxq.ready = queues[0].ready;
                rxq.size = queues[0].size;
                rxq.desc_addr = queues[0].desc_addr;
                rxq.avail_addr = queues[0].avail_addr;
                rxq.used_addr = queues[0].used_addr;
            } else {
                rx.rx_queue = Some(queues[0].clone());
            }
            let pushed = rx.drain_overflow(&self.shared.metrics);
            return pushed && rx.rx_queue.as_ref().is_some_and(|q| q.guest_wants_irq(mem));
        }
        if q_idx == 1 {
            self.ensure_io_started();
            let q = &mut queues[1];
            let mut used_tx = false;
            let mut need_rx_irq = false;
            while let Some((head, bufs)) = q.pop(mem) {
                let total: usize = bufs
                    .iter()
                    .filter(|b| !b.is_write)
                    .map(|b| b.len as usize)
                    .sum();
                if total > VIRTIO_NET_HDR_LEN {
                    self.shared
                        .metrics
                        .tx_packets
                        .fetch_add(1, Ordering::Relaxed);
                    self.shared
                        .metrics
                        .tx_bytes
                        .fetch_add((total - VIRTIO_NET_HDR_LEN) as u64, Ordering::Relaxed);
                    need_rx_irq |=
                        self.shared
                            .handle_tx_chain(&bufs, mem, total, &mut self.tx_scratch);
                }
                q.push_used(mem, head, 0);
                used_tx = true;
            }
            if need_rx_irq {
                self.shared.rx.lock().unwrap().raise_irq();
            }
            return used_tx && q.guest_wants_irq(mem);
        }
        false
    }
}

impl Drop for VirtioNetEgress {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        trigger_kq_event(self.shared.kq_fd.as_raw_fd(), EGRESS_WAKE_IDENT);
        if let Some(h) = self.io_handle.take() {
            let _ = h.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn egress_retirement_wake_notifies_its_kqueue() {
        let kq = create_wake_queue(EGRESS_WAKE_IDENT).unwrap();
        trigger_kq_event(kq.as_raw_fd(), EGRESS_WAKE_IDENT);
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        let timeout = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        let ready =
            unsafe { libc::kevent(kq.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, &timeout) };
        assert_eq!(ready, 1);
        let identifier = event.ident;
        assert_eq!(identifier, EGRESS_WAKE_IDENT);
        assert_eq!(event.filter, libc::EVFILT_USER);
    }

    #[test]
    fn egress_blocks_loopback_and_link_local() {
        assert!(is_blocked_egress_ip(Ipv4Addr::new(127, 0, 0, 1)));
        assert!(is_blocked_egress_ip(Ipv4Addr::new(127, 1, 2, 3)));
        assert!(is_blocked_egress_ip(Ipv4Addr::new(0, 0, 0, 0)));
        assert!(is_blocked_egress_ip(Ipv4Addr::new(169, 254, 169, 254)));
        assert!(is_blocked_egress_ip(Ipv4Addr::new(224, 0, 0, 1)));
        assert!(is_blocked_egress_ip(Ipv4Addr::new(255, 255, 255, 255)));
        assert!(!is_blocked_egress_ip(Ipv4Addr::new(1, 1, 1, 1)));
        assert!(!is_blocked_egress_ip(Ipv4Addr::new(8, 8, 8, 8)));
        assert!(!is_blocked_egress_ip(Ipv4Addr::new(192, 168, 1, 1)));
    }

    #[test]
    fn egress_udp_checksum_validates() {
        let cfg = NetConfig::primary_egress();
        let payload = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00";
        let mut hdr = [0u8; 42];
        let hlen = encode_egress_udp_headers(
            &cfg,
            42,
            Ipv4Addr::new(10, 42, 0, 1),
            53,
            Ipv4Addr::new(10, 42, 0, 2),
            54321,
            payload,
            &mut hdr,
        );
        assert_eq!(hlen, 42);
        assert_eq!(ipv4_checksum(&hdr[14..34]), 0);
        // Verify UDP checksum over pseudo-header + header + payload == 0 (or 0xffff complement)
        let mut check_sum: u32 = 0;
        let s = Ipv4Addr::new(10, 42, 0, 1).octets();
        let d = Ipv4Addr::new(10, 42, 0, 2).octets();
        check_sum += u16::from_be_bytes([s[0], s[1]]) as u32;
        check_sum += u16::from_be_bytes([s[2], s[3]]) as u32;
        check_sum += u16::from_be_bytes([d[0], d[1]]) as u32;
        check_sum += u16::from_be_bytes([d[2], d[3]]) as u32;
        check_sum += 17 + (8 + payload.len()) as u32;
        for c in hdr[34..42].as_chunks::<2>().0 {
            check_sum += u16::from_be_bytes([c[0], c[1]]) as u32;
        }
        assert_eq!(internet_checksum(check_sum, payload), 0);
    }

    #[test]
    fn egress_dns_discovery_returns_valid_ipv4() {
        let dns = discover_upstream_dns();
        assert!(!dns.is_unspecified());
    }

    #[test]
    fn egress_parse_resolv_conf_filters_and_deduplicates() {
        let sample = "\
# Generated by macOS configd
search corp.local
nameserver 127.0.0.1
nameserver ::1
nameserver 169.254.169.254
nameserver 10.0.0.53
nameserver 1.1.1.1
nameserver 10.0.0.53
nameserver 224.0.0.251
";
        let list = parse_resolv_conf_dns(sample);
        assert_eq!(
            list,
            vec![Ipv4Addr::new(10, 0, 0, 53), Ipv4Addr::new(1, 1, 1, 1)]
        );
    }

    #[test]
    fn egress_dns_failover_rotates_cleanly() {
        let mut st = DnsResolverState {
            servers: vec![Ipv4Addr::new(10, 0, 0, 53), Ipv4Addr::new(1, 1, 1, 1)],
            active_idx: 0,
            last_check: Instant::now(),
            last_mtime: None,
            env_override: true,
        };
        assert_eq!(st.current(), Ipv4Addr::new(10, 0, 0, 53));
        st.rotate_failover();
        assert_eq!(st.current(), Ipv4Addr::new(1, 1, 1, 1));
        st.rotate_failover();
        assert_eq!(st.current(), Ipv4Addr::new(10, 0, 0, 53));
    }
}
