//! Live pull & push telemetry + on-demand OpenTelemetry tracing for `micropod-vmm`:
//! - Zero metric files on disk; every sample is read live from atomic counters & `proc_pid_rusage`.
//! - Zero hot-path tracing overhead when disabled (single relaxed `AtomicBool` check).
//! - Serves HTTP/1.1 over an owner-only (`0600`) Unix socket (`--telemetry-socket`) and/or optional
//!   TCP listener (`--prometheus-listen`):
//!   - `GET  /metrics`          → Prometheus / OpenMetrics text exposition (`micropod_vmm_*`)
//!   - `GET  /v1/metrics`       → OpenTelemetry OTLP/JSON (`ExportMetricsServiceRequest`)
//!   - `GET  /v1/traces`        → OpenTelemetry OTLP/JSON (`ExportTraceServiceRequest`)
//!   - `GET  /v1/tracing/status`→ Live on-demand tracing status JSON
//!   - `POST /v1/tracing/enable`→ Dynamically enable tracing on a live VM without restart
//!   - `POST /v1/tracing/disable`→ Dynamically disable tracing on a live VM without restart
//!   - `POST /v1/tracing/clear` → Clear buffered spans in memory
//!   - `GET  /healthz`          → Live structured JSON health & counters
//! - Optional OTLP/HTTP push exporters:
//!   - `--otlp-endpoint http://host:port/v1/metrics` (`resourceMetrics` on interval)
//!   - `--otlp-traces-endpoint http://host:port/v1/traces` (`resourceSpans` on demand)

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use vmm_net::NetMetrics;
use vmm_virtio::virtiofs::FsMetrics;
use vmm_virtio::{
    BLK_FLUSH_SYNC_USEC_BOUNDS, BLK_REQUEST_BYTES_BOUNDS, BalloonMetrics, BlkMetrics,
};

use crate::ctrl::GuestControl;
use crate::{host_phys_footprint_bytes, snapshot};

const MAX_BUFFERED_SPANS: usize = 512;
const OTLP_REQUEST_TIMEOUT: Duration = Duration::from_secs(2);
const OTLP_FINAL_FLUSH_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Debug, Clone)]
pub struct TelemetryConfig {
    pub socket_path: Option<PathBuf>,
    pub prometheus_listen: Option<String>,
    pub otlp_endpoint: Option<String>,
    pub otlp_interval_secs: u64,
    pub tracing_enabled: bool,
    pub traces_endpoint: Option<String>,
    pub slow_op_threshold_ms: u64,
    pub service_name: String,
    pub worker_id: Option<String>,
}

impl Default for TelemetryConfig {
    fn default() -> Self {
        Self {
            socket_path: None,
            prometheus_listen: None,
            otlp_endpoint: None,
            otlp_interval_secs: 10,
            tracing_enabled: false,
            traces_endpoint: None,
            slow_op_threshold_ms: 5,
            service_name: "micropod-vmm".into(),
            worker_id: None,
        }
    }
}

#[inline]
pub fn now_unix_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64)
}

#[derive(Debug, Clone)]
pub struct TraceSpan {
    pub trace_id: String,
    pub span_id: String,
    pub parent_span_id: Option<String>,
    pub name: String,
    pub start_unix_ns: u64,
    pub end_unix_ns: u64,
    pub attributes: Vec<(String, String)>,
    pub status_ok: bool,
}

/// On-demand, zero-overhead-when-disabled OTLP span recorder with live runtime toggle.
pub struct Tracer {
    enabled: AtomicBool,
    slow_op_threshold_ms: AtomicU64,
    trace_id: String,
    span_seq: AtomicU64,
    ring: Mutex<VecDeque<TraceSpan>>,
    pending_export: Mutex<Vec<TraceSpan>>,
    total_recorded: AtomicU64,
    total_exported: AtomicU64,
}

impl Tracer {
    pub fn new(enabled: bool, slow_op_threshold_ms: u64) -> Self {
        let now = now_unix_ns();
        let pid = std::process::id() as u64;
        // Deterministic-length W3C 128-bit trace ID (32 lowercase hex chars, guaranteed non-zero)
        let hi = now ^ (pid.wrapping_mul(0x9e37_79b9_7f4a_7c15)) | 1;
        let lo = now
            .rotate_left(17)
            .wrapping_add(pid.wrapping_mul(0xbf58_476d_1ce4_e5b9))
            | 1;
        let trace_id = format!("{hi:016x}{lo:016x}");
        Self {
            enabled: AtomicBool::new(enabled),
            slow_op_threshold_ms: AtomicU64::new(slow_op_threshold_ms),
            trace_id,
            span_seq: AtomicU64::new(1),
            ring: Mutex::new(VecDeque::with_capacity(64)),
            pending_export: Mutex::new(Vec::new()),
            total_recorded: AtomicU64::new(0),
            total_exported: AtomicU64::new(0),
        }
    }

    #[inline]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    pub fn set_enabled(&self, on: bool) {
        self.enabled.store(on, Ordering::SeqCst);
    }

    pub fn slow_op_threshold_ms(&self) -> u64 {
        self.slow_op_threshold_ms.load(Ordering::Relaxed)
    }

    pub fn trace_id(&self) -> &str {
        &self.trace_id
    }

    fn next_span_id(&self) -> String {
        let seq = self.span_seq.fetch_add(1, Ordering::Relaxed);
        let mixed = seq.wrapping_mul(0x9e37_79b9_7f4a_7c15)
            ^ (std::process::id() as u64).rotate_left(32)
            | 1;
        format!("{mixed:016x}")
    }

    /// Start an RAII span guard. When tracing is disabled, performs only a single relaxed atomic
    /// load and returns `None` with zero heap allocations.
    #[inline]
    pub fn start_span(
        self: &Arc<Self>,
        name: &'static str,
        parent_span_id: Option<String>,
    ) -> Option<SpanGuard> {
        if !self.is_enabled() {
            return None;
        }
        Some(SpanGuard {
            tracer: self.clone(),
            span_id: self.next_span_id(),
            parent_span_id,
            name: name.to_string(),
            start_unix_ns: now_unix_ns(),
            attributes: Vec::new(),
            status_ok: true,
        })
    }

    pub fn record_span(
        &self,
        name: &str,
        parent_span_id: Option<&str>,
        start_unix_ns: u64,
        end_unix_ns: u64,
        attributes: Vec<(String, String)>,
        status_ok: bool,
    ) {
        if !self.is_enabled() {
            return;
        }
        let span = TraceSpan {
            trace_id: self.trace_id.clone(),
            span_id: self.next_span_id(),
            parent_span_id: parent_span_id.map(ToString::to_string),
            name: name.to_string(),
            start_unix_ns,
            end_unix_ns: end_unix_ns.max(start_unix_ns),
            attributes,
            status_ok,
        };
        self.push_span(span);
    }

    fn push_span(&self, span: TraceSpan) {
        self.total_recorded.fetch_add(1, Ordering::Relaxed);
        if let Ok(mut ring) = self.ring.lock() {
            if ring.len() >= MAX_BUFFERED_SPANS {
                ring.pop_front();
            }
            ring.push_back(span.clone());
        }
        if let Ok(mut pending) = self.pending_export.lock() {
            if pending.len() >= MAX_BUFFERED_SPANS {
                pending.remove(0);
            }
            pending.push(span);
        }
    }

    pub fn recent_spans(&self) -> Vec<TraceSpan> {
        self.ring
            .lock()
            .map(|r| r.iter().cloned().collect())
            .unwrap_or_default()
    }

    pub fn drain_pending(&self) -> Vec<TraceSpan> {
        self.pending_export
            .lock()
            .map(|mut p| std::mem::take(&mut *p))
            .unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut r) = self.ring.lock() {
            r.clear();
        }
        if let Ok(mut p) = self.pending_export.lock() {
            p.clear();
        }
    }

    pub fn recorded_count(&self) -> u64 {
        self.total_recorded.load(Ordering::Relaxed)
    }

    pub fn exported_count(&self) -> u64 {
        self.total_exported.load(Ordering::Relaxed)
    }

    pub fn note_exported(&self, n: u64) {
        self.total_exported.fetch_add(n, Ordering::Relaxed);
    }
}

pub struct SpanGuard {
    tracer: Arc<Tracer>,
    span_id: String,
    parent_span_id: Option<String>,
    name: String,
    start_unix_ns: u64,
    attributes: Vec<(String, String)>,
    status_ok: bool,
}

impl SpanGuard {
    pub fn span_id(&self) -> String {
        self.span_id.clone()
    }

    pub fn attr(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.attributes.push((key.into(), value.into()));
    }

    pub fn set_error(&mut self, message: impl Into<String>) {
        self.status_ok = false;
        self.attributes
            .push(("error.message".into(), message.into()));
    }
}

impl Drop for SpanGuard {
    fn drop(&mut self) {
        let end = now_unix_ns().max(self.start_unix_ns);
        let span = TraceSpan {
            trace_id: self.tracer.trace_id.clone(),
            span_id: std::mem::take(&mut self.span_id),
            parent_span_id: self.parent_span_id.take(),
            name: std::mem::take(&mut self.name),
            start_unix_ns: self.start_unix_ns,
            end_unix_ns: end,
            attributes: std::mem::take(&mut self.attributes),
            status_ok: self.status_ok,
        };
        self.tracer.push_span(span);
    }
}

pub struct TelemetrySource {
    pub pid: i32,
    pub t0: Instant,
    pub ipa_granule: &'static str,
    pub num_vcpus: u32,
    pub memory_mib: usize,
    pub vcpus_online: Arc<AtomicU32>,
    pub mmio_exits: Arc<AtomicU64>,
    pub wfi_exits: Arc<AtomicU64>,
    pub shutting_down: Arc<AtomicBool>,
    pub guest_ctrl: Arc<GuestControl>,
    pub blk: Arc<BlkMetrics>,
    pub balloon: Arc<BalloonMetrics>,
    pub net: Arc<NetMetrics>,
    pub fs: Arc<FsMetrics>,
    pub tracer: Arc<Tracer>,
    pub traces_endpoint: Option<String>,
    pub service_name: String,
    pub worker_id: Option<String>,
    pub host_os: String,
    /// The guest's disk files, by name ("os", "cache"), for their size and
    /// the host storage they take (read at each sample, off the I/O path).
    pub disks: Vec<(&'static str, std::fs::File)>,
}

/// One guest disk file: its size and the host storage it takes. A sparse
/// file takes only what the guest wrote and has not discarded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskUsage {
    pub name: &'static str,
    pub size_bytes: u64,
    pub allocated_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct TelemetrySnapshot {
    pub pid: i32,
    pub state: &'static str,
    pub uptime_secs: f64,
    pub ipa_granule: &'static str,
    pub num_vcpus: u32,
    pub vcpus_online: u32,
    pub memory_mib: usize,
    pub guest_ctrl_connected: bool,
    pub clock_sync_count: u64,
    pub last_clock_sync_unix_secs: u64,
    pub host_phys_bytes: u64,
    pub host_peak_bytes: u64,
    pub balloon_reclaimed_bytes: u64,
    pub balloon_reclaim_failures: u64,
    pub blk_read_ops: u64,
    pub blk_write_ops: u64,
    pub blk_read_bytes: u64,
    pub blk_write_bytes: u64,
    pub blk_flush_ops: u64,
    pub blk_flush_syncs: u64,
    pub blk_flush_sync_usec: u64,
    pub blk_flush_sync_usec_max: u64,
    pub blk_discard_ops: u64,
    /// Bytes of the disk files the host freed for guest discards.
    pub blk_discarded_bytes: u64,
    pub disks: Vec<DiskUsage>,
    /// Read and write requests by data bytes, per `BLK_REQUEST_BYTES_BOUNDS`
    /// bucket (not cumulative).
    pub blk_read_sizes: [u64; BLK_REQUEST_BYTES_BOUNDS.len() + 1],
    pub blk_write_sizes: [u64; BLK_REQUEST_BYTES_BOUNDS.len() + 1],
    /// Host syncs per `BLK_FLUSH_SYNC_USEC_BOUNDS` bucket (not cumulative).
    pub blk_flush_sync_hist: [u64; BLK_FLUSH_SYNC_USEC_BOUNDS.len() + 1],
    pub fs_requests: u64,
    pub fs_bytes_read: u64,
    pub fs_nodes: u64,
    pub fs_nodes_peak: u64,
    pub fs_open_handles: u64,
    pub fs_keep_cache_hits: u64,
    pub fs_ro_cache_hits: u64,
    pub fs_ro_cache_misses: u64,
    pub fs_notify_events: u64,
    pub fs_notify_epoch_resets: u64,
    pub fs_errors: u64,
    pub net_tx_packets: u64,
    pub net_tx_bytes: u64,
    pub net_rx_packets: u64,
    pub net_rx_bytes: u64,
    pub published_binds: u64,
    pub published_conns: u64,
    pub mmio_exits: u64,
    pub wfi_exits: u64,
    pub timestamp_unix_ns: u64,
}

impl TelemetrySource {
    pub fn sample(&self) -> TelemetrySnapshot {
        let (phys_b, peak_b) = host_phys_footprint_bytes();
        let ch = self.guest_ctrl.health();
        let state = if self.shutting_down.load(Ordering::Relaxed) {
            "shutting_down"
        } else {
            "running"
        };
        let timestamp_unix_ns = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos() as u64);
        TelemetrySnapshot {
            pid: self.pid,
            state,
            uptime_secs: self.t0.elapsed().as_secs_f64(),
            ipa_granule: self.ipa_granule,
            num_vcpus: self.num_vcpus,
            vcpus_online: self.vcpus_online.load(Ordering::Relaxed),
            memory_mib: self.memory_mib,
            guest_ctrl_connected: ch.connected,
            clock_sync_count: ch.clock_sync_count,
            last_clock_sync_unix_secs: ch.last_clock_sync_unix_secs,
            host_phys_bytes: phys_b,
            host_peak_bytes: peak_b,
            balloon_reclaimed_bytes: self.balloon.reclaimed_bytes.load(Ordering::Relaxed),
            balloon_reclaim_failures: self.balloon.reclaim_failures.load(Ordering::Relaxed),
            blk_read_ops: self.blk.read_ops.load(Ordering::Relaxed),
            blk_write_ops: self.blk.write_ops.load(Ordering::Relaxed),
            blk_read_bytes: self.blk.read_bytes.load(Ordering::Relaxed),
            blk_write_bytes: self.blk.write_bytes.load(Ordering::Relaxed),
            blk_flush_ops: self.blk.flush_ops.load(Ordering::Relaxed),
            blk_flush_syncs: self.blk.flush_syncs.load(Ordering::Relaxed),
            blk_flush_sync_usec: self.blk.flush_sync_usec.load(Ordering::Relaxed),
            blk_flush_sync_usec_max: self.blk.flush_sync_usec_max.load(Ordering::Relaxed),
            blk_discard_ops: self.blk.discard_ops.load(Ordering::Relaxed),
            blk_discarded_bytes: self.blk.discarded_bytes.load(Ordering::Relaxed),
            disks: self
                .disks
                .iter()
                .filter_map(|(name, file)| {
                    let md = file.metadata().ok()?;
                    Some(DiskUsage {
                        name,
                        size_bytes: md.len(),
                        allocated_bytes: md.blocks().saturating_mul(512),
                    })
                })
                .collect(),
            blk_read_sizes: self
                .blk
                .read_sizes
                .each_ref()
                .map(|c| c.load(Ordering::Relaxed)),
            blk_write_sizes: self
                .blk
                .write_sizes
                .each_ref()
                .map(|c| c.load(Ordering::Relaxed)),
            blk_flush_sync_hist: self
                .blk
                .flush_sync_hist
                .each_ref()
                .map(|c| c.load(Ordering::Relaxed)),
            fs_requests: self.fs.requests.load(Ordering::Relaxed),
            fs_bytes_read: self.fs.bytes_read.load(Ordering::Relaxed),
            fs_nodes: self.fs.nodes.load(Ordering::Relaxed),
            fs_nodes_peak: self.fs.nodes_peak.load(Ordering::Relaxed),
            fs_open_handles: self.fs.open_handles.load(Ordering::Relaxed),
            fs_keep_cache_hits: self.fs.keep_cache_hits.load(Ordering::Relaxed),
            fs_ro_cache_hits: self.fs.ro_cache_hits.load(Ordering::Relaxed),
            fs_ro_cache_misses: self.fs.ro_cache_misses.load(Ordering::Relaxed),
            fs_notify_events: self.fs.notify_events_pushed.load(Ordering::Relaxed),
            fs_notify_epoch_resets: self.fs.notify_epoch_resets.load(Ordering::Relaxed),
            fs_errors: self.fs.fuse_errors.load(Ordering::Relaxed),
            net_tx_packets: self.net.tx_packets.load(Ordering::Relaxed),
            net_tx_bytes: self.net.tx_bytes.load(Ordering::Relaxed),
            net_rx_packets: self.net.rx_packets.load(Ordering::Relaxed),
            net_rx_bytes: self.net.rx_bytes.load(Ordering::Relaxed),
            published_binds: self.net.published_binds.load(Ordering::Relaxed),
            published_conns: self.net.published_conns.load(Ordering::Relaxed),
            mmio_exits: self.mmio_exits.load(Ordering::Relaxed),
            wfi_exits: self.wfi_exits.load(Ordering::Relaxed),
            timestamp_unix_ns,
        }
    }

    pub fn render_prometheus(&self) -> String {
        let s = self.sample();
        let up = if s.state == "running" { 1 } else { 0 };
        let ctrl_up = if s.guest_ctrl_connected { 1 } else { 0 };
        let mut out = String::with_capacity(2048);
        out.push_str("# HELP micropod_vmm_up 1 when the Apple Silicon HVF VMM is running.\n");
        out.push_str("# TYPE micropod_vmm_up gauge\n");
        out.push_str(&format!(
            "micropod_vmm_up{{granule=\"{}\",state=\"{}\"}} {up}\n",
            s.ipa_granule, s.state
        ));
        out.push_str("# HELP micropod_vmm_uptime_seconds Elapsed wall seconds since VMM start.\n");
        out.push_str("# TYPE micropod_vmm_uptime_seconds gauge\n");
        out.push_str(&format!(
            "micropod_vmm_uptime_seconds {:.3}\n",
            s.uptime_secs
        ));
        out.push_str("# HELP micropod_vmm_vcpus_configured Configured virtual CPUs.\n");
        out.push_str("# TYPE micropod_vmm_vcpus_configured gauge\n");
        out.push_str(&format!("micropod_vmm_vcpus_configured {}\n", s.num_vcpus));
        out.push_str("# HELP micropod_vmm_vcpus_online Online virtual CPUs.\n");
        out.push_str("# TYPE micropod_vmm_vcpus_online gauge\n");
        out.push_str(&format!("micropod_vmm_vcpus_online {}\n", s.vcpus_online));
        out.push_str(
            "# HELP micropod_vmm_memory_configured_bytes Configured guest RAM in bytes.\n",
        );
        out.push_str("# TYPE micropod_vmm_memory_configured_bytes gauge\n");
        out.push_str(&format!(
            "micropod_vmm_memory_configured_bytes {}\n",
            (s.memory_mib as u64) * 1024 * 1024
        ));
        out.push_str("# HELP micropod_vmm_guest_ctrl_connected 1 when vsock port 2379 control channel is connected.\n");
        out.push_str("# TYPE micropod_vmm_guest_ctrl_connected gauge\n");
        out.push_str(&format!("micropod_vmm_guest_ctrl_connected {ctrl_up}\n"));
        out.push_str("# HELP micropod_vmm_clock_sync_total Host-to-guest UTC clock sync pushes.\n");
        out.push_str("# TYPE micropod_vmm_clock_sync_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_clock_sync_total {}\n",
            s.clock_sync_count
        ));
        out.push_str("# HELP micropod_vmm_host_phys_footprint_bytes Current macOS physical footprint in bytes.\n");
        out.push_str("# TYPE micropod_vmm_host_phys_footprint_bytes gauge\n");
        out.push_str(&format!(
            "micropod_vmm_host_phys_footprint_bytes {}\n",
            s.host_phys_bytes
        ));
        out.push_str("# HELP micropod_vmm_host_peak_footprint_bytes Peak macOS physical footprint in bytes.\n");
        out.push_str("# TYPE micropod_vmm_host_peak_footprint_bytes gauge\n");
        out.push_str(&format!(
            "micropod_vmm_host_peak_footprint_bytes {}\n",
            s.host_peak_bytes
        ));
        out.push_str("# HELP micropod_vmm_balloon_reclaimed_bytes Bytes of guest RAM the guest reported free and the host freed.\n");
        out.push_str("# TYPE micropod_vmm_balloon_reclaimed_bytes counter\n");
        out.push_str(&format!(
            "micropod_vmm_balloon_reclaimed_bytes {}\n",
            s.balloon_reclaimed_bytes
        ));
        out.push_str("# HELP micropod_vmm_balloon_reclaim_failures_total Reported free ranges the host could not free (left as they were).\n");
        out.push_str("# TYPE micropod_vmm_balloon_reclaim_failures_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_balloon_reclaim_failures_total {}\n",
            s.balloon_reclaim_failures
        ));
        out.push_str("# HELP micropod_vmm_blk_ops_total Virtio-Blk I/O operations.\n");
        out.push_str("# TYPE micropod_vmm_blk_ops_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_blk_ops_total{{op=\"read\"}} {}\n",
            s.blk_read_ops
        ));
        out.push_str(&format!(
            "micropod_vmm_blk_ops_total{{op=\"write\"}} {}\n",
            s.blk_write_ops
        ));
        out.push_str("# HELP micropod_vmm_blk_bytes_total Virtio-Blk bytes transferred.\n");
        out.push_str("# TYPE micropod_vmm_blk_bytes_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_blk_bytes_total{{op=\"read\"}} {}\n",
            s.blk_read_bytes
        ));
        out.push_str(&format!(
            "micropod_vmm_blk_bytes_total{{op=\"write\"}} {}\n",
            s.blk_write_bytes
        ));
        out.push_str(&format!(
            "micropod_vmm_blk_ops_total{{op=\"flush\"}} {}\n",
            s.blk_flush_ops
        ));
        out.push_str(&format!(
            "micropod_vmm_blk_ops_total{{op=\"discard\"}} {}\nmicropod_vmm_blk_bytes_total{{op=\"discard\"}} {}\n",
            s.blk_discard_ops, s.blk_discarded_bytes
        ));
        for (name, help, value) in [
            (
                "micropod_vmm_disk_size_bytes",
                "Size of a guest disk's file on the host.",
                (|d: &DiskUsage| d.size_bytes) as fn(&DiskUsage) -> u64,
            ),
            (
                "micropod_vmm_disk_allocated_bytes",
                "Host storage a guest disk's file takes: what the guest wrote and has not discarded (trimmed).",
                |d: &DiskUsage| d.allocated_bytes,
            ),
        ] {
            out.push_str(&format!("# HELP {name} {help}\n# TYPE {name} gauge\n"));
            for d in &s.disks {
                out.push_str(&format!("{name}{{disk=\"{}\"}} {}\n", d.name, value(d)));
            }
        }
        for (name, help, kind, value) in [
            (
                "micropod_vmm_blk_flush_syncs_total",
                "Host syncs run for guest flushes (one answers every flush queued with it).",
                "counter",
                s.blk_flush_syncs,
            ),
            (
                "micropod_vmm_blk_flush_sync_microseconds_total",
                "Time the host syncs for guest flushes took.",
                "counter",
                s.blk_flush_sync_usec,
            ),
            (
                "micropod_vmm_blk_flush_sync_microseconds_max",
                "The longest host sync for a guest flush.",
                "gauge",
                s.blk_flush_sync_usec_max,
            ),
        ] {
            out.push_str(&format!(
                "# HELP {name} {help}\n# TYPE {name} {kind}\n{name} {value}\n"
            ));
        }
        out.push_str(
            "# HELP micropod_vmm_blk_request_bytes Virtio-Blk read and write requests by data bytes.\n",
        );
        out.push_str("# TYPE micropod_vmm_blk_request_bytes histogram\n");
        for (op, sizes, sum) in [
            ("read", &s.blk_read_sizes, s.blk_read_bytes),
            ("write", &s.blk_write_sizes, s.blk_write_bytes),
        ] {
            render_histogram(
                &mut out,
                "micropod_vmm_blk_request_bytes",
                &format!("op=\"{op}\","),
                &BLK_REQUEST_BYTES_BOUNDS,
                sizes,
                sum,
            );
        }
        out.push_str(
            "# HELP micropod_vmm_blk_flush_sync_duration_microseconds Host syncs for guest flushes by duration.\n",
        );
        out.push_str("# TYPE micropod_vmm_blk_flush_sync_duration_microseconds histogram\n");
        render_histogram(
            &mut out,
            "micropod_vmm_blk_flush_sync_duration_microseconds",
            "",
            &BLK_FLUSH_SYNC_USEC_BOUNDS,
            &s.blk_flush_sync_hist,
            s.blk_flush_sync_usec,
        );
        out.push_str(
            "# HELP micropod_vmm_virtiofs_requests_total Virtio-FS FUSE requests handled.\n",
        );
        out.push_str("# TYPE micropod_vmm_virtiofs_requests_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_virtiofs_requests_total {}\n",
            s.fs_requests
        ));
        out.push_str("# HELP micropod_vmm_virtiofs_read_bytes_total Virtio-FS bytes read.\n");
        out.push_str("# TYPE micropod_vmm_virtiofs_read_bytes_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_virtiofs_read_bytes_total {}\n",
            s.fs_bytes_read
        ));
        for (name, help, value) in [
            (
                "micropod_vmm_virtiofs_nodes",
                "Virtio-FS nodes the shares hold (files the guest references).",
                s.fs_nodes,
            ),
            (
                "micropod_vmm_virtiofs_nodes_peak",
                "Most Virtio-FS nodes held at once.",
                s.fs_nodes_peak,
            ),
            (
                "micropod_vmm_virtiofs_open_handles",
                "Virtio-FS open file and directory handles.",
                s.fs_open_handles,
            ),
        ] {
            out.push_str(&format!(
                "# HELP {name} {help}\n# TYPE {name} gauge\n{name} {value}\n"
            ));
        }
        for (name, help, value) in [
            (
                "micropod_vmm_virtiofs_keep_cache_hits_total",
                "Virtio-FS FUSE_OPEN replies preserving Linux page cache via FOPEN_KEEP_CACHE.",
                s.fs_keep_cache_hits,
            ),
            (
                "micropod_vmm_virtiofs_ro_cache_hits_total",
                "Virtio-FS pooled read-only handle cache hits on writable workspaces.",
                s.fs_ro_cache_hits,
            ),
            (
                "micropod_vmm_virtiofs_ro_cache_misses_total",
                "Virtio-FS pooled read-only handle cache misses on writable workspaces.",
                s.fs_ro_cache_misses,
            ),
            (
                "micropod_vmm_virtiofs_notify_events_total",
                "Virtio-FS host-to-guest invalidation notifications pushed on vq 1.",
                s.fs_notify_events,
            ),
            (
                "micropod_vmm_virtiofs_notify_epoch_resets_total",
                "Virtio-FS FUSE_NOTIFY_INC_EPOCH resets (overflow, rescan, or snapshot restore).",
                s.fs_notify_epoch_resets,
            ),
            (
                "micropod_vmm_virtiofs_errors_total",
                "Non-routine Virtio-FS host error replies (excludes ENOENT, ENOSYS, ENODATA).",
                s.fs_errors,
            ),
        ] {
            out.push_str(&format!(
                "# HELP {name} {help}\n# TYPE {name} counter\n{name} {value}\n"
            ));
        }
        out.push_str("# HELP micropod_vmm_net_packets_total Virtio-Net packets processed.\n");
        out.push_str("# TYPE micropod_vmm_net_packets_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_net_packets_total{{dir=\"tx\"}} {}\n",
            s.net_tx_packets
        ));
        out.push_str(&format!(
            "micropod_vmm_net_packets_total{{dir=\"rx\"}} {}\n",
            s.net_rx_packets
        ));
        out.push_str("# HELP micropod_vmm_net_bytes_total Virtio-Net bytes processed.\n");
        out.push_str("# TYPE micropod_vmm_net_bytes_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_net_bytes_total{{dir=\"tx\"}} {}\n",
            s.net_tx_bytes
        ));
        out.push_str(&format!(
            "micropod_vmm_net_bytes_total{{dir=\"rx\"}} {}\n",
            s.net_rx_bytes
        ));
        out.push_str("# HELP micropod_vmm_published_binds_total Published loopback port binds.\n");
        out.push_str("# TYPE micropod_vmm_published_binds_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_published_binds_total {}\n",
            s.published_binds
        ));
        out.push_str(
            "# HELP micropod_vmm_published_conns_total Published TCP connections served.\n",
        );
        out.push_str("# TYPE micropod_vmm_published_conns_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_published_conns_total {}\n",
            s.published_conns
        ));
        out.push_str("# HELP micropod_vmm_vcpu_exits_total Hypervisor vCPU exits.\n");
        out.push_str("# TYPE micropod_vmm_vcpu_exits_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_vcpu_exits_total{{reason=\"mmio\"}} {}\n",
            s.mmio_exits
        ));
        out.push_str(&format!(
            "micropod_vmm_vcpu_exits_total{{reason=\"wfi\"}} {}\n",
            s.wfi_exits
        ));
        out.push_str(
            "# HELP micropod_vmm_tracing_enabled 1 when on-demand VMM tracing is active.\n",
        );
        out.push_str("# TYPE micropod_vmm_tracing_enabled gauge\n");
        out.push_str(&format!(
            "micropod_vmm_tracing_enabled {}\n",
            if self.tracer.is_enabled() { 1 } else { 0 }
        ));
        out.push_str(
            "# HELP micropod_vmm_trace_spans_recorded_total Total VMM trace spans recorded.\n",
        );
        out.push_str("# TYPE micropod_vmm_trace_spans_recorded_total counter\n");
        out.push_str(&format!(
            "micropod_vmm_trace_spans_recorded_total {}\n",
            self.tracer.recorded_count()
        ));
        out
    }

    pub fn render_health_json(&self) -> String {
        let s = self.sample();
        format!(
            "{{\"pid\":{},\"state\":\"{}\",\"uptime_ms\":{:.1},\"ipa_granule\":\"{}\",\
             \"num_vcpus\":{},\"vcpus_online\":{},\"memory_mib\":{},\
             \"guest_ctrl_connected\":{},\"clock_sync_count\":{},\"last_clock_sync_unix_secs\":{},\
             \"host_phys_footprint_mib\":{:.2},\"host_peak_footprint_mib\":{:.2},\
             \"balloon_reclaimed_mib\":{:.2},\
             \"blk_read_ops\":{},\"blk_write_ops\":{},\"blk_read_bytes\":{},\"blk_write_bytes\":{},\
             \"fs_requests\":{},\"fs_bytes_read\":{},\
             \"fs_nodes\":{},\"fs_nodes_peak\":{},\"fs_open_handles\":{},\
             \"fs_keep_cache_hits\":{},\"fs_ro_cache_hits\":{},\"fs_ro_cache_misses\":{},\
             \"fs_notify_events\":{},\"fs_notify_epoch_resets\":{},\"fs_errors\":{},\
             \"net_tx_packets\":{},\"net_tx_bytes\":{},\"net_rx_packets\":{},\"net_rx_bytes\":{},\
             \"published_binds\":{},\"published_conns\":{},\
             \"mmio_exits\":{},\"wfi_exits\":{},\"tracing_enabled\":{},\"sampled_unix_secs\":{}}}\n",
            s.pid,
            s.state,
            s.uptime_secs * 1000.0,
            s.ipa_granule,
            s.num_vcpus,
            s.vcpus_online,
            s.memory_mib,
            s.guest_ctrl_connected,
            s.clock_sync_count,
            s.last_clock_sync_unix_secs,
            (s.host_phys_bytes as f64) / (1024.0 * 1024.0),
            (s.host_peak_bytes as f64) / (1024.0 * 1024.0),
            (s.balloon_reclaimed_bytes as f64) / (1024.0 * 1024.0),
            s.blk_read_ops,
            s.blk_write_ops,
            s.blk_read_bytes,
            s.blk_write_bytes,
            s.fs_requests,
            s.fs_bytes_read,
            s.fs_nodes,
            s.fs_nodes_peak,
            s.fs_open_handles,
            s.fs_keep_cache_hits,
            s.fs_ro_cache_hits,
            s.fs_ro_cache_misses,
            s.fs_notify_events,
            s.fs_notify_epoch_resets,
            s.fs_errors,
            s.net_tx_packets,
            s.net_tx_bytes,
            s.net_rx_packets,
            s.net_rx_bytes,
            s.published_binds,
            s.published_conns,
            s.mmio_exits,
            s.wfi_exits,
            self.tracer.is_enabled(),
            s.timestamp_unix_ns / 1_000_000_000,
        )
    }

    fn resource_attributes_json(&self) -> String {
        let mut attrs = vec![
            format!(
                "{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                json_escape(&self.service_name)
            ),
            "{\"key\":\"host.arch\",\"value\":{\"stringValue\":\"arm64\"}}".to_string(),
            format!(
                "{{\"key\":\"os.build_id\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                json_escape(&self.host_os)
            ),
            format!(
                "{{\"key\":\"micropod.vmm.ipa_granule\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                self.ipa_granule
            ),
        ];
        if let Some(ref wid) = self.worker_id {
            attrs.push(format!(
                "{{\"key\":\"micropod.worker.id\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                json_escape(wid)
            ));
        }
        attrs.join(",")
    }

    pub fn render_tracing_status_json(&self) -> String {
        let buffered = self.tracer.recent_spans().len();
        let ep = self
            .traces_endpoint
            .as_ref()
            .map_or("null".to_string(), |u| format!("\"{}\"", json_escape(u)));
        format!(
            "{{\"enabled\":{},\"trace_id\":\"{}\",\"recorded_spans\":{},\"buffered_spans\":{},\"exported_spans\":{},\"slow_op_threshold_ms\":{},\"traces_endpoint\":{}}}\n",
            self.tracer.is_enabled(),
            self.tracer.trace_id(),
            self.tracer.recorded_count(),
            buffered,
            self.tracer.exported_count(),
            self.tracer.slow_op_threshold_ms(),
            ep,
        )
    }

    /// Render a spec-compliant OpenTelemetry OTLP/JSON `ExportTraceServiceRequest` for `spans`.
    pub fn render_otlp_traces_json_for(&self, spans: &[TraceSpan]) -> String {
        let rendered: Vec<String> = spans
            .iter()
            .map(|sp| {
                let mut fields = vec![
                    format!("\"traceId\":\"{}\"", sp.trace_id),
                    format!("\"spanId\":\"{}\"", sp.span_id),
                    format!("\"name\":\"{}\"", json_escape(&sp.name)),
                    "\"kind\":1".to_string(),
                    format!("\"startTimeUnixNano\":\"{}\"", sp.start_unix_ns),
                    format!("\"endTimeUnixNano\":\"{}\"", sp.end_unix_ns),
                ];
                if let Some(ref parent) = sp.parent_span_id {
                    fields.push(format!("\"parentSpanId\":\"{parent}\""));
                }
                if !sp.attributes.is_empty() {
                    let attrs: Vec<String> = sp
                        .attributes
                        .iter()
                        .map(|(k, v)| {
                            format!(
                                "{{\"key\":\"{}\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                                json_escape(k),
                                json_escape(v)
                            )
                        })
                        .collect();
                    fields.push(format!("\"attributes\":[{}]", attrs.join(",")));
                }
                let code = if sp.status_ok { 1 } else { 2 };
                fields.push(format!("\"status\":{{\"code\":{code}}}"));
                format!("{{{}}}", fields.join(","))
            })
            .collect();
        format!(
            "{{\"resourceSpans\":[{{\"resource\":{{\"attributes\":[{}]}},\"scopeSpans\":[{{\"scope\":{{\"name\":\"micropod.vmm\",\"version\":\"1.0.0\"}},\"spans\":[{}]}}]}}]}}\n",
            self.resource_attributes_json(),
            rendered.join(",")
        )
    }

    pub fn render_otlp_traces_json(&self) -> String {
        let spans = self.tracer.recent_spans();
        self.render_otlp_traces_json_for(&spans)
    }

    /// Render a spec-compliant OpenTelemetry OTLP/JSON `ExportMetricsServiceRequest`.
    pub fn render_otlp_json(&self) -> String {
        let s = self.sample();
        let ts = s.timestamp_unix_ns.to_string();
        let gauge_int = |name: &str, unit: &str, val: i64| -> String {
            format!(
                "{{\"name\":\"{name}\",\"unit\":\"{unit}\",\"gauge\":{{\"dataPoints\":[{{\"timeUnixNano\":\"{ts}\",\"asInt\":\"{val}\"}}]}}}}"
            )
        };
        let gauge_double = |name: &str, unit: &str, val: f64| -> String {
            format!(
                "{{\"name\":\"{name}\",\"unit\":\"{unit}\",\"gauge\":{{\"dataPoints\":[{{\"timeUnixNano\":\"{ts}\",\"asDouble\":{val:.3}}}]}}}}"
            )
        };
        let sum_int = |name: &str, unit: &str, val: u64| -> String {
            format!(
                "{{\"name\":\"{name}\",\"unit\":\"{unit}\",\"sum\":{{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[{{\"timeUnixNano\":\"{ts}\",\"asInt\":\"{val}\"}}]}}}}"
            )
        };

        let metrics = [
            gauge_int(
                "micropod.vmm.up",
                "1",
                if s.state == "running" { 1 } else { 0 },
            ),
            gauge_double("micropod.vmm.uptime", "s", s.uptime_secs),
            gauge_int("micropod.vmm.vcpus.online", "{cpu}", s.vcpus_online as i64),
            gauge_int(
                "micropod.vmm.guest_ctrl.connected",
                "1",
                if s.guest_ctrl_connected { 1 } else { 0 },
            ),
            gauge_int(
                "micropod.vmm.host.phys_footprint",
                "By",
                s.host_phys_bytes as i64,
            ),
            gauge_int(
                "micropod.vmm.host.peak_footprint",
                "By",
                s.host_peak_bytes as i64,
            ),
            sum_int("micropod.vmm.clock.syncs", "{sync}", s.clock_sync_count),
            sum_int(
                "micropod.vmm.balloon.reclaimed",
                "By",
                s.balloon_reclaimed_bytes,
            ),
            sum_int("micropod.vmm.blk.read_ops", "{op}", s.blk_read_ops),
            sum_int("micropod.vmm.blk.write_ops", "{op}", s.blk_write_ops),
            sum_int("micropod.vmm.virtiofs.requests", "{request}", s.fs_requests),
            sum_int(
                "micropod.vmm.virtiofs.keep_cache_hits",
                "{hit}",
                s.fs_keep_cache_hits,
            ),
            sum_int(
                "micropod.vmm.virtiofs.ro_cache_hits",
                "{hit}",
                s.fs_ro_cache_hits,
            ),
            sum_int(
                "micropod.vmm.virtiofs.notify_events",
                "{event}",
                s.fs_notify_events,
            ),
            sum_int("micropod.vmm.virtiofs.errors", "{error}", s.fs_errors),
            gauge_int("micropod.vmm.virtiofs.nodes", "{node}", s.fs_nodes as i64),
            gauge_int(
                "micropod.vmm.virtiofs.open_handles",
                "{handle}",
                s.fs_open_handles as i64,
            ),
            sum_int("micropod.vmm.net.tx_bytes", "By", s.net_tx_bytes),
            sum_int("micropod.vmm.net.rx_bytes", "By", s.net_rx_bytes),
            sum_int(
                "micropod.vmm.published.conns",
                "{connection}",
                s.published_conns,
            ),
        ]
        .join(",");

        format!(
            "{{\"resourceMetrics\":[{{\"resource\":{{\"attributes\":[{}]}},\"scopeMetrics\":[{{\"scope\":{{\"name\":\"micropod.vmm\",\"version\":\"1.0.0\"}},\"metrics\":[{}]}}]}}]}}\n",
            self.resource_attributes_json(),
            metrics
        )
    }
}

/// Appends one Prometheus histogram series: cumulative `_bucket` lines for
/// `bounds` and `+Inf`, then `_sum` and `_count`. `counts` holds one count per
/// bucket (not cumulative), the last for values above every bound; `labels`
/// is empty or ends in a comma.
fn render_histogram(
    out: &mut String,
    name: &str,
    labels: &str,
    bounds: &[u64],
    counts: &[u64],
    sum: u64,
) {
    let mut cumulative = 0u64;
    for (i, count) in counts.iter().enumerate() {
        cumulative += count;
        let le = bounds
            .get(i)
            .map_or_else(|| "+Inf".to_string(), u64::to_string);
        out.push_str(&format!(
            "{name}_bucket{{{labels}le=\"{le}\"}} {cumulative}\n"
        ));
    }
    let labels = labels.trim_end_matches(',');
    let labels = if labels.is_empty() {
        String::new()
    } else {
        format!("{{{labels}}}")
    };
    out.push_str(&format!(
        "{name}_sum{labels} {sum}\n{name}_count{labels} {cumulative}\n"
    ));
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

fn handle_http_conn<S: Read + Write>(mut stream: S, source: &TelemetrySource) {
    let mut buf = [0u8; 2048];
    let Ok(n) = stream.read(&mut buf) else {
        return;
    };
    if n == 0 {
        return;
    }
    let req = String::from_utf8_lossy(&buf[..n]);
    let first_line = req.lines().next().unwrap_or("");
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("GET");
    let path = parts.next().unwrap_or("/").split('?').next().unwrap_or("/");

    let (status, ctype, body) = match (method, path) {
        ("GET", "/metrics") => (
            "200 OK",
            "text/plain; version=0.0.4; charset=utf-8",
            source.render_prometheus(),
        ),
        ("GET", "/healthz" | "/health") => {
            ("200 OK", "application/json", source.render_health_json())
        }
        ("GET", "/v1/metrics") => ("200 OK", "application/json", source.render_otlp_json()),
        ("GET", "/v1/traces") => (
            "200 OK",
            "application/json",
            source.render_otlp_traces_json(),
        ),
        ("GET", "/v1/tracing/status") => (
            "200 OK",
            "application/json",
            source.render_tracing_status_json(),
        ),
        ("POST", "/v1/tracing/enable") => {
            source.tracer.set_enabled(true);
            let now = now_unix_ns();
            source.tracer.record_span(
                "vmm.tracing.enabled",
                None,
                now,
                now,
                vec![("trigger".into(), "runtime_toggle".into())],
                true,
            );
            (
                "200 OK",
                "application/json",
                source.render_tracing_status_json(),
            )
        }
        ("POST", "/v1/tracing/disable") => {
            source.tracer.set_enabled(false);
            (
                "200 OK",
                "application/json",
                source.render_tracing_status_json(),
            )
        }
        ("POST", "/v1/tracing/clear") => {
            source.tracer.clear();
            (
                "200 OK",
                "application/json",
                source.render_tracing_status_json(),
            )
        }
        _ => (
            "404 Not Found",
            "text/plain; charset=utf-8",
            "not found\n".into(),
        ),
    };
    let resp = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
}

/// Parse an `http://host:port/path` OTLP endpoint into `(host:port, path)`.
pub fn parse_http_endpoint(url: &str) -> Option<(String, String)> {
    parse_http_endpoint_with_default(url, "/v1/metrics")
}

pub fn parse_http_endpoint_with_default(url: &str, default_path: &str) -> Option<(String, String)> {
    let rest = url.strip_prefix("http://")?;
    let (authority, path) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, default_path),
    };
    if authority.is_empty() {
        return None;
    }
    let host_port = if authority.contains(':') {
        authority.to_string()
    } else {
        format!("{authority}:80")
    };
    Some((host_port, path.to_string()))
}

fn time_remaining(deadline: Instant) -> io::Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(io::ErrorKind::TimedOut.into());
    }
    Ok(remaining)
}

struct OtlpDestination {
    authority: String,
    path: String,
    lookup: Option<mpsc::Receiver<io::Result<SocketAddr>>>,
}

impl OtlpDestination {
    fn new(endpoint: &str, default_path: &str) -> Option<Self> {
        let (authority, path) = parse_http_endpoint_with_default(endpoint, default_path)?;
        Some(Self {
            authority,
            path,
            lookup: None,
        })
    }

    fn resolve_until(&mut self, deadline: Instant) -> io::Result<SocketAddr> {
        if let Ok(address) = self.authority.parse() {
            return Ok(address);
        }
        if self.lookup.is_none() {
            // getaddrinfo cannot be cancelled. Keep at most one outstanding lookup per
            // destination, and give it only the hostname and the reply channel.
            let authority = self.authority.clone();
            let (send, receive) = mpsc::sync_channel(1);
            thread::Builder::new()
                .name("vmm-telemetry-dns".into())
                .spawn(move || {
                    let address = authority.to_socket_addrs().and_then(|mut addresses| {
                        addresses
                            .next()
                            .ok_or_else(|| io::ErrorKind::AddrNotAvailable.into())
                    });
                    let _ = send.send(address);
                })?;
            self.lookup = Some(receive);
        }
        let result = self
            .lookup
            .as_ref()
            .unwrap()
            .recv_timeout(time_remaining(deadline)?);
        match result {
            Err(mpsc::RecvTimeoutError::Timeout) => Err(io::ErrorKind::TimedOut.into()),
            other => {
                self.lookup = None;
                other.map_err(|_| io::Error::from(io::ErrorKind::ConnectionAborted))?
            }
        }
    }

    fn push(&mut self, payload: &str, timeout: Duration) -> io::Result<bool> {
        let deadline = Instant::now() + timeout;
        let address = self.resolve_until(deadline)?;
        let mut stream = TcpStream::connect_timeout(&address, time_remaining(deadline)?)?;
        let request = format!(
            "POST {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
            self.path,
            self.authority,
            payload.len()
        );
        let mut unsent = request.as_bytes();
        while !unsent.is_empty() {
            stream.set_write_timeout(Some(time_remaining(deadline)?))?;
            match stream.write(unsent) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(written) => unsent = &unsent[written..],
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }

        let mut response = [0u8; 256];
        loop {
            stream.set_read_timeout(Some(time_remaining(deadline)?))?;
            match stream.read(&mut response) {
                Ok(n) => {
                    let status = std::str::from_utf8(&response[..n])
                        .ok()
                        .and_then(|text| text.split_ascii_whitespace().nth(1));
                    return Ok(matches!(status, Some("200" | "202" | "204")));
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    }
}

struct TelemetrySocket {
    path: PathBuf,
    identity: (u64, u64),
}

impl TelemetrySocket {
    fn bind(path: &Path) -> io::Result<(UnixListener, Self)> {
        let listener = match UnixListener::bind(path) {
            Ok(listener) => listener,
            Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
                let Some(identity) = Self::identity(path)? else {
                    return Err(error);
                };
                let existing = Self {
                    path: path.to_path_buf(),
                    identity,
                };
                if !unix_socket_refuses_connections(path)? {
                    return Err(error);
                }
                existing.unlink_if_same()?;
                UnixListener::bind(path)?
            }
            Err(error) => return Err(error),
        };
        let identity = Self::identity(path)?.ok_or_else(|| {
            io::Error::new(io::ErrorKind::AddrNotAvailable, "bound socket path changed")
        })?;
        Ok((
            listener,
            Self {
                path: path.to_path_buf(),
                identity,
            },
        ))
    }

    fn identity(path: &Path) -> io::Result<Option<(u64, u64)>> {
        match std::fs::symlink_metadata(path) {
            Ok(meta) if meta.file_type().is_socket() => Ok(Some((meta.dev(), meta.ino()))),
            Ok(_) => Ok(None),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn unlink_if_same(&self) -> io::Result<()> {
        if Self::identity(&self.path)? == Some(self.identity) {
            std::fs::remove_file(&self.path)?;
        }
        Ok(())
    }
}

fn unix_socket_refuses_connections(path: &Path) -> io::Result<bool> {
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let len = std::mem::size_of_val(&address) as libc::socklen_t;
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    address.sun_len = len as u8;
    for (dst, &byte) in address.sun_path.iter_mut().zip(bytes) {
        *dst = byte as libc::c_char;
    }
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let socket = unsafe { OwnedFd::from_raw_fd(raw) };
    let fd = socket.as_raw_fd();
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0
        || unsafe { libc::fcntl(fd, libc::F_SETFL, libc::O_NONBLOCK) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    let connected = unsafe { libc::connect(fd, (&raw const address).cast(), len) };
    Ok(connected < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ECONNREFUSED))
}

pub struct TelemetryServer {
    stop: Arc<AtomicBool>,
    socket: Option<TelemetrySocket>,
    handles: Vec<thread::JoinHandle<()>>,
}

impl TelemetryServer {
    pub fn start(cfg: &TelemetryConfig, source: Arc<TelemetrySource>) -> Result<Self, String> {
        let mut server = Self {
            stop: Arc::new(AtomicBool::new(false)),
            socket: None,
            handles: Vec::new(),
        };

        if let Some(ref sock_path) = cfg.socket_path {
            if let Some(parent) = sock_path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let (listener, socket) = TelemetrySocket::bind(sock_path)
                .map_err(|e| format!("bind telemetry socket {}: {e}", sock_path.display()))?;
            server.socket = Some(socket);
            std::fs::set_permissions(sock_path, PermissionsExt::from_mode(0o600))
                .map_err(|e| format!("set telemetry socket permissions: {e}"))?;
            listener
                .set_nonblocking(true)
                .map_err(|e| format!("telemetry socket nonblocking: {e}"))?;
            let stop_c = server.stop.clone();
            let src_c = source.clone();
            server.handles.push(
                thread::Builder::new()
                    .name("vmm-telemetry-unix".into())
                    .spawn(move || {
                        while !stop_c.load(Ordering::Relaxed) {
                            match listener.accept() {
                                Ok((stream, _)) => {
                                    if stream.set_nonblocking(false).is_ok()
                                        && stream
                                            .set_read_timeout(Some(Duration::from_secs(2)))
                                            .is_ok()
                                        && stream
                                            .set_write_timeout(Some(Duration::from_secs(2)))
                                            .is_ok()
                                    {
                                        handle_http_conn(stream, &src_c);
                                    }
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                    thread::sleep(Duration::from_millis(20));
                                }
                                Err(_) => break,
                            }
                        }
                    })
                    .map_err(|e| format!("spawn Unix telemetry listener: {e}"))?,
            );
        }

        if let Some(ref listen_addr) = cfg.prometheus_listen {
            let addr: SocketAddr = listen_addr
                .parse()
                .map_err(|e| format!("invalid --prometheus-listen {listen_addr}: {e}"))?;
            let listener = TcpListener::bind(addr)
                .map_err(|e| format!("bind --prometheus-listen {addr}: {e}"))?;
            listener
                .set_nonblocking(true)
                .map_err(|e| format!("prometheus listener nonblocking: {e}"))?;
            let stop_c = server.stop.clone();
            let src_c = source.clone();
            server.handles.push(
                thread::Builder::new()
                    .name("vmm-telemetry-http".into())
                    .spawn(move || {
                        while !stop_c.load(Ordering::Relaxed) {
                            match listener.accept() {
                                Ok((stream, _)) => {
                                    if stream.set_nonblocking(false).is_ok()
                                        && stream
                                            .set_read_timeout(Some(Duration::from_secs(2)))
                                            .is_ok()
                                        && stream
                                            .set_write_timeout(Some(Duration::from_secs(2)))
                                            .is_ok()
                                    {
                                        handle_http_conn(stream, &src_c);
                                    }
                                }
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                    thread::sleep(Duration::from_millis(20));
                                }
                                Err(_) => break,
                            }
                        }
                    })
                    .map_err(|e| format!("spawn TCP telemetry listener: {e}"))?,
            );
        }

        if let Some(ref endpoint) = cfg.otlp_endpoint {
            let mut destination =
                OtlpDestination::new(endpoint, "/v1/metrics").ok_or_else(|| {
                    format!(
                        "invalid --otlp-endpoint (expected http://host:port/v1/metrics): {endpoint}"
                    )
                })?;
            let interval = Duration::from_secs(cfg.otlp_interval_secs.max(1));
            let stop_c = server.stop.clone();
            let src_c = source.clone();
            server.handles.push(
                thread::Builder::new()
                    .name("vmm-telemetry-otlp".into())
                    .spawn(move || {
                        // Push an initial export shortly after boot, then every `interval`.
                        let mut next_push = Instant::now() + Duration::from_millis(250);
                        while !stop_c.load(Ordering::Relaxed) {
                            if Instant::now() >= next_push {
                                let payload = src_c.render_otlp_json();
                                let _ = destination.push(&payload, OTLP_REQUEST_TIMEOUT);
                                next_push = Instant::now() + interval;
                            }
                            thread::sleep(Duration::from_millis(50));
                        }
                    })
                    .map_err(|e| format!("spawn metrics exporter: {e}"))?,
            );
        }

        if let Some(ref endpoint) = cfg.traces_endpoint {
            let mut destination = OtlpDestination::new(endpoint, "/v1/traces").ok_or_else(|| {
                format!(
                    "invalid --otlp-traces-endpoint (expected http://host:port/v1/traces): {endpoint}"
                )
            })?;
            let stop_c = server.stop.clone();
            let src_c = source.clone();
            server.handles.push(
                thread::Builder::new()
                    .name("vmm-telemetry-traces".into())
                    .spawn(move || {
                        let mut flush = |timeout| {
                            let batch = src_c.tracer.drain_pending();
                            if !batch.is_empty() {
                                let count = batch.len() as u64;
                                let payload = src_c.render_otlp_traces_json_for(&batch);
                                if destination.push(&payload, timeout).unwrap_or(false) {
                                    src_c.tracer.note_exported(count);
                                }
                            }
                        };
                        while !stop_c.load(Ordering::Relaxed) {
                            flush(OTLP_REQUEST_TIMEOUT);
                            thread::sleep(Duration::from_millis(200));
                        }
                        // Try to send the remaining spans within the shutdown budget.
                        flush(OTLP_FINAL_FLUSH_TIMEOUT);
                    })
                    .map_err(|e| format!("spawn trace exporter: {e}"))?,
            );
        }

        Ok(server)
    }

    pub fn make_host_os() -> String {
        snapshot::host_os_build_id()
    }
}

impl Drop for TelemetryServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for h in self.handles.drain(..) {
            let _ = h.join();
        }
        if let Some(ref socket) = self.socket {
            let _ = socket.unlink_if_same();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn dummy_source(tracer: Arc<Tracer>, traces_endpoint: Option<String>) -> Arc<TelemetrySource> {
        // A sparse 1 GiB disk file with 64 KiB written.
        let path = std::env::temp_dir().join(format!("mp-tel-disk-{}.img", std::process::id()));
        let disk = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let _ = std::fs::remove_file(&path);
        disk.set_len(1 << 30).unwrap();
        std::os::unix::fs::FileExt::write_all_at(&disk, &[1u8; 64 << 10], 0).unwrap();
        disk.sync_all().unwrap();
        let disks = vec![("os", disk)];
        let blk = Arc::new(BlkMetrics::default());
        blk.read_ops.store(42, Ordering::Relaxed);
        blk.read_sizes[0].store(40, Ordering::Relaxed);
        blk.read_sizes[1].store(2, Ordering::Relaxed);
        blk.flush_sync_hist[1].store(5, Ordering::Relaxed);
        blk.flush_sync_usec.store(400, Ordering::Relaxed);
        blk.discard_ops.store(3, Ordering::Relaxed);
        blk.discarded_bytes.store(8192, Ordering::Relaxed);
        let fs = Arc::new(FsMetrics::default());
        fs.requests.store(99, Ordering::Relaxed);
        fs.nodes.store(7, Ordering::Relaxed);
        fs.nodes_peak.store(11, Ordering::Relaxed);
        Arc::new(TelemetrySource {
            pid: 1234,
            t0: Instant::now(),
            ipa_granule: "16KiB",
            num_vcpus: 4,
            memory_mib: 4096,
            vcpus_online: Arc::new(AtomicU32::new(4)),
            mmio_exits: Arc::new(AtomicU64::new(100)),
            wfi_exits: Arc::new(AtomicU64::new(50)),
            shutting_down: Arc::new(AtomicBool::new(false)),
            guest_ctrl: Arc::new(GuestControl::new()),
            blk,
            balloon: Arc::new(BalloonMetrics::default()),
            net: Arc::new(NetMetrics::default()),
            fs,
            tracer,
            traces_endpoint,
            service_name: "micropod-vmm".into(),
            worker_id: Some("worker-test-1".into()),
            host_os: "25F".into(),
            disks,
        })
    }

    fn unix_http(sock: &std::path::Path, req: &str) -> String {
        let mut u = UnixStream::connect(sock).unwrap();
        u.write_all(req.as_bytes()).unwrap();
        let mut resp = String::new();
        u.read_to_string(&mut resp).unwrap();
        resp
    }

    fn test_socket(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("mp-tel-{name}-{}.sock", std::process::id()))
    }

    #[test]
    fn partial_start_retires_listener_and_its_socket() {
        let path = test_socket("rollback");
        let cfg = TelemetryConfig {
            socket_path: Some(path.clone()),
            prometheus_listen: Some("invalid".into()),
            ..TelemetryConfig::default()
        };
        let source = dummy_source(Arc::new(Tracer::new(false, 5)), None);
        let listener_source = Arc::downgrade(&source);
        let error = TelemetryServer::start(&cfg, source).err().unwrap();
        assert!(error.starts_with("invalid --prometheus-listen"));
        assert!(listener_source.upgrade().is_none());
        assert!(!path.exists());
    }

    #[test]
    fn start_preserves_regular_files_and_live_sockets_but_recovers_stale_sockets() {
        let path = test_socket("existing");
        let cfg = TelemetryConfig {
            socket_path: Some(path.clone()),
            ..TelemetryConfig::default()
        };
        let source = dummy_source(Arc::new(Tracer::new(false, 5)), None);
        let mut existing = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        existing.write_all(b"keep").unwrap();
        drop(existing);
        assert!(TelemetryServer::start(&cfg, source.clone()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"keep");
        std::fs::remove_file(&path).unwrap();

        let listener = UnixListener::bind(&path).unwrap();
        let live_identity = TelemetrySocket::identity(&path).unwrap();
        assert!(TelemetryServer::start(&cfg, source.clone()).is_err());
        assert_eq!(TelemetrySocket::identity(&path).unwrap(), live_identity);
        assert!(UnixStream::connect(&path).is_ok());
        drop(listener);

        let recovered = TelemetryServer::start(&cfg, source).unwrap();
        assert!(UnixStream::connect(&path).is_ok());
        drop(recovered);
        assert!(!path.exists());
    }

    #[test]
    fn retirement_preserves_a_replacement_socket() {
        let path = test_socket("replacement");
        let cfg = TelemetryConfig {
            socket_path: Some(path.clone()),
            ..TelemetryConfig::default()
        };
        let source = dummy_source(Arc::new(Tracer::new(false, 5)), None);
        let server = TelemetryServer::start(&cfg, source).unwrap();
        std::fs::remove_file(&path).unwrap();
        let replacement = UnixListener::bind(&path).unwrap();
        drop(server);
        assert!(UnixStream::connect(&path).is_ok());
        drop(replacement);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn pending_dns_respects_deadline_and_does_not_start_another_lookup() {
        let mut target = OtlpDestination::new("http://lookup.test:4318", "/v1/metrics").unwrap();
        let (complete_lookup, pending) = mpsc::sync_channel(1);
        target.lookup = Some(pending);
        let start = Instant::now();
        let error = target
            .resolve_until(start + Duration::from_millis(30))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));

        let address = "127.0.0.1:4318".parse().unwrap();
        complete_lookup.send(Ok(address)).unwrap();
        assert_eq!(
            target
                .resolve_until(Instant::now() + Duration::from_secs(1))
                .unwrap(),
            address
        );
        assert!(target.lookup.is_none());
    }

    #[test]
    fn otlp_request_releases_unresponsive_loopback_collector_within_budget() {
        let collector = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", collector.local_addr().unwrap());
        let mut target = OtlpDestination::new(&endpoint, "/v1/metrics").unwrap();
        let start = Instant::now();
        let error = target.push("{}", Duration::from_millis(50)).unwrap_err();
        assert!(matches!(
            error.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ));
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn telemetry_renders_valid_prometheus_health_and_otlp_and_pushes_over_http() {
        let tracer = Arc::new(Tracer::new(false, 5));
        // Off by default -> zero-cost start_span returns None
        assert!(tracer.start_span("ignored", None).is_none());

        let collector = TcpListener::bind("127.0.0.1:0").unwrap();
        let col_addr = collector.local_addr().unwrap();
        let received = Arc::new(Mutex::new(Vec::<String>::new()));
        let rec_c = received.clone();
        let col_thread = thread::spawn(move || {
            // Expect at least 2 POSTs: /v1/metrics and /v1/traces
            for _ in 0..2 {
                if let Ok((mut s, _)) = collector.accept() {
                    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut buf = vec![0u8; 16384];
                    if let Ok(n) = s.read(&mut buf) {
                        rec_c
                            .lock()
                            .unwrap()
                            .push(String::from_utf8_lossy(&buf[..n]).into_owned());
                    }
                    let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
                }
            }
        });

        let traces_ep = format!("http://{col_addr}/v1/traces");
        let src = dummy_source(tracer.clone(), Some(traces_ep.clone()));
        let prom = src.render_prometheus();
        assert!(prom.contains("# TYPE micropod_vmm_up gauge"));
        assert!(prom.contains("micropod_vmm_blk_ops_total{op=\"read\"} 42"));
        assert!(prom.contains("# TYPE micropod_vmm_blk_request_bytes histogram\n"));
        assert!(
            prom.contains("micropod_vmm_blk_request_bytes_bucket{op=\"read\",le=\"4096\"} 40\n")
        );
        assert!(
            prom.contains("micropod_vmm_blk_request_bytes_bucket{op=\"read\",le=\"16384\"} 42\n")
        );
        assert!(
            prom.contains("micropod_vmm_blk_request_bytes_bucket{op=\"read\",le=\"+Inf\"} 42\n")
        );
        assert!(prom.contains("micropod_vmm_blk_request_bytes_count{op=\"read\"} 42\n"));
        assert!(prom.contains("micropod_vmm_blk_request_bytes_sum{op=\"write\"} 0\n"));
        assert!(
            prom.contains(
                "micropod_vmm_blk_flush_sync_duration_microseconds_bucket{le=\"50\"} 0\n"
            )
        );
        assert!(
            prom.contains(
                "micropod_vmm_blk_flush_sync_duration_microseconds_bucket{le=\"100\"} 5\n"
            )
        );
        assert!(
            prom.contains(
                "micropod_vmm_blk_flush_sync_duration_microseconds_bucket{le=\"+Inf\"} 5\n"
            )
        );
        assert!(prom.contains("micropod_vmm_blk_flush_sync_duration_microseconds_sum 400\n"));
        assert!(prom.contains("micropod_vmm_blk_ops_total{op=\"discard\"} 3\n"));
        assert!(prom.contains("micropod_vmm_blk_bytes_total{op=\"discard\"} 8192\n"));
        assert!(prom.contains("micropod_vmm_disk_size_bytes{disk=\"os\"} 1073741824\n"));
        let allocated: u64 = prom
            .lines()
            .find_map(|l| l.strip_prefix("micropod_vmm_disk_allocated_bytes{disk=\"os\"} "))
            .expect("allocated bytes of the os disk")
            .parse()
            .unwrap();
        assert!(
            ((64 << 10)..(1 << 30)).contains(&allocated),
            "a sparse disk's allocation {allocated} is what was written"
        );
        assert!(prom.contains("micropod_vmm_virtiofs_requests_total 99"));
        assert!(
            prom.contains(
                "# TYPE micropod_vmm_virtiofs_nodes gauge\nmicropod_vmm_virtiofs_nodes 7\n"
            )
        );
        assert!(prom.contains("micropod_vmm_virtiofs_nodes_peak 11\n"));
        assert!(prom.contains("micropod_vmm_tracing_enabled 0"));

        let health = src.render_health_json();
        assert!(health.contains("\"state\":\"running\""));
        assert!(health.contains("\"blk_read_ops\":42"));
        assert!(health.contains("\"fs_nodes\":7,\"fs_nodes_peak\":11,\"fs_open_handles\":0,"));
        assert!(health.contains("\"tracing_enabled\":false"));

        let otlp = src.render_otlp_json();
        assert!(otlp.contains("\"resourceMetrics\""));
        assert!(otlp.contains("\"micropod.vmm.blk.read_ops\""));
        assert!(otlp.contains("\"worker-test-1\""));

        let sock = std::env::temp_dir().join(format!("mp-tel-test-{}.sock", std::process::id()));
        let cfg = TelemetryConfig {
            socket_path: Some(sock.clone()),
            prometheus_listen: None,
            otlp_endpoint: Some(format!("http://{col_addr}/v1/metrics")),
            otlp_interval_secs: 1,
            tracing_enabled: false,
            traces_endpoint: Some(traces_ep),
            slow_op_threshold_ms: 5,
            service_name: "micropod-vmm".into(),
            worker_id: Some("worker-test-1".into()),
        };
        let srv = TelemetryServer::start(&cfg, src).unwrap();

        // Scrape /metrics over Unix socket
        let resp = unix_http(&sock, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(
            resp.contains("200 OK") && resp.contains("micropod_vmm_virtiofs_requests_total 99")
        );

        // Dynamically enable tracing on the live server with zero restart!
        let en = unix_http(
            &sock,
            "POST /v1/tracing/enable HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
        );
        assert!(
            en.contains("200 OK") && en.contains("\"enabled\":true"),
            "{en}"
        );
        {
            let mut g = tracer.start_span("vmm.test.op", None).unwrap();
            g.attr("stage", "unit");
        }
        let tr = unix_http(&sock, "GET /v1/traces HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert!(
            tr.contains("200 OK")
                && tr.contains("\"resourceSpans\"")
                && tr.contains("\"vmm.test.op\"")
                && tr.contains("\"stage\""),
            "{tr}"
        );

        // Disable dynamically again
        let dis = unix_http(
            &sock,
            "POST /v1/tracing/disable HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
        );
        assert!(dis.contains("\"enabled\":false"), "{dis}");
        assert!(tracer.start_span("ignored_after_disable", None).is_none());

        col_thread.join().unwrap();
        let batches = received.lock().unwrap().clone();
        assert!(
            batches
                .iter()
                .any(|b| b.contains("POST /v1/metrics") && b.contains("\"resourceMetrics\"")),
            "missing metrics push: {batches:?}"
        );
        assert!(
            batches.iter().any(|b| b.contains("POST /v1/traces")
                && b.contains("\"resourceSpans\"")
                && b.contains("\"vmm.test.op\"")),
            "missing traces push: {batches:?}"
        );

        drop(srv);
        assert!(!sock.exists(), "telemetry socket should clean up on Drop");
    }
}
