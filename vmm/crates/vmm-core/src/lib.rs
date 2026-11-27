//! Core Apple Silicon Hypervisor.framework VMM runtime:
//! - 16 KiB Stage-2 IPA granule (`HV_IPA_GRANULE_16KB`)
//! - Hardware ARM GICv3 (`hv_gic_create`) + SMP PSCI 1.0
//! - PL011 UART console with boot milestone tracking
//! - Virtio-MMIO v2 bus: RNG, Blk, Balloon (MADV_FREE), Virtio-FS (FUSE),
//!   Virtio-Vsock (Unix socket mux + port broker), and dual smoltcp Virtio-Net.

use std::collections::{HashMap, VecDeque};
use std::ffi::CString;
use std::io::{self, Write};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use hvf_sys::*;
use vmm_fdt::{CacheTopology, VirtioMmioDesc, VmFdtConfig, build_arm64_fdt};
use vmm_net::{NetConfig, NetMetrics, VirtioNetBridge};
use vmm_virtio::virtiofs::{FsMetrics, VirtioFs};
use vmm_virtio::vsock::{ExposeListener, HostServiceHandler, VirtioVsock, VsockExposeSpec};
use vmm_virtio::{
    BalloonMetrics, BlkMetrics, GuestMemory, VirtioBalloon, VirtioBlk, VirtioMmioDevice, VirtioRng,
};

mod boot_clock;
mod ctrl;
mod disk;
pub mod exit;
pub mod snapshot;
pub mod telemetry;

pub use ctrl::{DEFAULT_SHUTDOWN_TIMEOUT_SECS, VSOCK_PORT_CTRL};
pub use snapshot::{Pl011Snapshot, VcpuSnapshot, VmSnapshot};
pub use telemetry::TelemetryConfig;
pub use vmm_virtio::DiskFlush;

pub const RAM_BASE: u64 = 0x4000_0000;
pub const UART_BASE: u64 = 0x0900_0000;
pub const UART_SIZE: u64 = 0x1000;
pub const UART_INTID: u32 = 33; // SPI 1
pub const VIRTIO_MMIO_BASE: u64 = 0x0a00_0000;
pub const VIRTIO_MMIO_STRIDE: u64 = 0x200;
pub const VIRTIO_SPI_BASE_INTID: u32 = 48; // SPI 16+
pub const VSOCK_PORT_BROKER: u32 = 2378;

const PSCI_VERSION: u32 = 0x8400_0000;
const PSCI_CPU_OFF: u32 = 0x8400_0002;
const PSCI_CPU_ON_32: u32 = 0x8400_0003;
const PSCI_CPU_ON_64: u32 = 0xc400_0003;
const PSCI_AFFINITY_INFO_32: u32 = 0x8400_0004;
const PSCI_AFFINITY_INFO_64: u32 = 0xc400_0004;
const PSCI_SYSTEM_OFF: u32 = 0x8400_0008;
const PSCI_SYSTEM_RESET: u32 = 0x8400_0009;
const PSCI_FEATURES: u32 = 0x8400_000a;
const SMCCC_VERSION: u32 = 0x8000_0000;
const SMCCC_ARCH_FEATURES: u32 = 0x8000_0001;
const PSCI_RET_NOT_SUPPORTED: u64 = (-1i64) as u64;

static SIGNAL_SHUTDOWN: AtomicBool = AtomicBool::new(false);
static SIGNAL_COUNT: AtomicU32 = AtomicU32::new(0);

extern "C" fn handle_term_signal(_sig: libc::c_int) {
    SIGNAL_COUNT.fetch_add(1, Ordering::SeqCst);
    SIGNAL_SHUTDOWN.store(true, Ordering::SeqCst);
}

unsafe extern "C" {
    fn sysctlbyname(
        name: *const std::ffi::c_char,
        oldp: *mut std::ffi::c_void,
        oldlenp: *mut usize,
        newp: *mut std::ffi::c_void,
        newlen: usize,
    ) -> i32;
    fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut std::ffi::c_void) -> i32;
    fn getpid() -> i32;
}

fn sysctl_u64(name: &str) -> Option<u64> {
    let cname = CString::new(name).ok()?;
    let mut val: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    let rc = unsafe {
        sysctlbyname(
            cname.as_ptr(),
            (&mut val as *mut u64).cast(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if rc == 0 { Some(val) } else { None }
}

/// Raise this process's open-file limit to as many descriptors as macOS lets
/// one process hold (launchd starts processes with 256). Every guest file a
/// share has open, every vsock and published-port connection is one; each
/// share then takes at most a quarter of the limit. Never lowers it. Returns
/// the limit now in force.
pub fn raise_open_file_limit() -> Option<u64> {
    let mut rl = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) } != 0 {
        return None;
    }
    let per_proc = sysctl_u64("kern.maxfilesperproc").unwrap_or(rl.rlim_cur);
    let target = rl.rlim_max.min(per_proc);
    if rl.rlim_cur < target {
        let raised = libc::rlimit {
            rlim_cur: target,
            rlim_max: rl.rlim_max,
        };
        if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } == 0 {
            rl.rlim_cur = target;
        }
    }
    Some(rl.rlim_cur.min(per_proc))
}

pub fn host_cache_topology() -> (CacheTopology, u32) {
    let topo = CacheTopology {
        l1i_size: sysctl_u64("hw.perflevel0.l1icachesize").unwrap_or(196608) as u32,
        l1d_size: sysctl_u64("hw.perflevel0.l1dcachesize").unwrap_or(131072) as u32,
        l2_size: sysctl_u64("hw.perflevel0.l2cachesize").unwrap_or(16 * 1024 * 1024) as u32,
        line_size: sysctl_u64("hw.cachelinesize").unwrap_or(128) as u32,
    };
    let freq = sysctl_u64("hw.tbfrequency").unwrap_or(24_000_000) as u32;
    (topo, freq)
}

#[repr(C)]
struct RusageInfoV4 {
    ri_uuid: [u8; 16],
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
    ri_cpu_time_qos_default: u64,
    ri_cpu_time_qos_maintenance: u64,
    ri_cpu_time_qos_background: u64,
    ri_cpu_time_qos_utility: u64,
    ri_cpu_time_qos_legacy: u64,
    ri_cpu_time_qos_user_initiated: u64,
    ri_cpu_time_qos_user_interactive: u64,
    ri_billed_system_time: u64,
    ri_serviced_system_time: u64,
    ri_logical_writes: u64,
    ri_lifetime_max_phys_footprint: u64,
    ri_instructions: u64,
    ri_cycles: u64,
    ri_billed_energy: u64,
    ri_serviced_energy: u64,
    ri_interval_max_phys_footprint: u64,
    ri_runnable_time: u64,
}

pub fn host_phys_footprint_bytes() -> (u64, u64) {
    let mut ri = unsafe { std::mem::zeroed::<RusageInfoV4>() };
    let rc = unsafe { proc_pid_rusage(getpid(), 4, (&mut ri as *mut RusageInfoV4).cast()) };
    if rc == 0 {
        (ri.ri_phys_footprint, ri.ri_lifetime_max_phys_footprint)
    } else {
        (0, 0)
    }
}

/// Longest console line scanned for the guest status marker.
const CONSOLE_LINE_MAX: usize = 512;

struct Pl011 {
    rx: VecDeque<u8>,
    imsc: u32,
    ris: u32,
    cr: u32,
    lcr_h: u32,
    ibrd: u32,
    fbrd: u32,
    echo_stdout: bool,
    console_log: Option<io::BufWriter<std::fs::File>>,
    captured: Vec<u8>,
    line: Vec<u8>,
    /// Latest failure guest init announced, and when it was printed.
    guest_failure: Option<(String, Instant)>,
    t0: Instant,
    boot_start_unix_ns: u64,
    first_tx_ms: Option<f64>,
    init_ms: Option<f64>,
    tracer: Arc<telemetry::Tracer>,
}

impl Pl011 {
    fn new(
        t0: Instant,
        boot_start_unix_ns: u64,
        echo_stdout: bool,
        console_log: Option<std::fs::File>,
        tracer: Arc<telemetry::Tracer>,
    ) -> Self {
        Self {
            rx: VecDeque::new(),
            imsc: 0,
            ris: 0x20,
            cr: 0x0301,
            lcr_h: 0,
            ibrd: 0,
            fbrd: 0,
            echo_stdout,
            console_log: console_log.map(io::BufWriter::new),
            captured: Vec::with_capacity(64 * 1024),
            line: Vec::with_capacity(CONSOLE_LINE_MAX),
            guest_failure: None,
            t0,
            boot_start_unix_ns,
            first_tx_ms: None,
            init_ms: None,
            tracer,
        }
    }

    /// Track console lines over the VM's whole life (the capture buffer is
    /// bounded) so a failure the guest reports late is still seen. The run's
    /// exit code honours it only if the guest resets soon after (see
    /// [`exit::guest_status_window`]).
    fn scan_line(&mut self, b: u8) {
        if b == b'\n' {
            if let Some(status) = exit::parse_guest_status(&self.line) {
                self.guest_failure = Some((status, Instant::now()));
            }
            self.line.clear();
        } else if self.line.len() < CONSOLE_LINE_MAX {
            self.line.push(b);
        }
    }

    fn update_irq(&self) {
        let level = (self.ris & self.imsc) != 0;
        let _ = unsafe { hv_gic_set_spi(UART_INTID, level) };
    }

    fn read(&mut self, offset: u64) -> u64 {
        match offset {
            0x000 => {
                let b = self.rx.pop_front().unwrap_or(0);
                if self.rx.is_empty() {
                    self.ris &= !0x10;
                    self.update_irq();
                }
                b as u64
            }
            0x018 => {
                let mut fr = 1u64 << 7;
                if self.rx.is_empty() {
                    fr |= 1 << 4;
                }
                fr
            }
            0x024 => self.ibrd as u64,
            0x028 => self.fbrd as u64,
            0x02c => self.lcr_h as u64,
            0x030 => self.cr as u64,
            0x038 => self.imsc as u64,
            0x03c => self.ris as u64,
            0x040 => (self.ris & self.imsc) as u64,
            0xfe0 => 0x11,
            0xfe4 => 0x10,
            0xfe8 => 0x14,
            0xfec => 0x00,
            0xff0 => 0x0d,
            0xff4 => 0xf0,
            0xff8 => 0x05,
            0xffc => 0xb1,
            _ => 0,
        }
    }

    fn write(&mut self, offset: u64, val: u64) {
        let v = val as u32;
        match offset {
            0x000 => {
                let b = (v & 0xff) as u8;
                if self.first_tx_ms.is_none() {
                    let ms = self.t0.elapsed().as_secs_f64() * 1000.0;
                    self.first_tx_ms = Some(ms);
                    if self.tracer.is_enabled() {
                        self.tracer.record_span(
                            "vmm.boot.to_first_uart",
                            None,
                            self.boot_start_unix_ns,
                            telemetry::now_unix_ns(),
                            vec![("milestone".into(), "first_uart_tx".into())],
                            true,
                        );
                    }
                }
                if self.echo_stdout {
                    let _ = std::io::stdout().write_all(&[b]);
                    if b == b'\n' {
                        let _ = std::io::stdout().flush();
                    }
                }
                if let Some(log) = self.console_log.as_mut() {
                    let _ = log.write_all(&[b]);
                    if b == b'\n' {
                        let _ = log.flush();
                    }
                }
                self.scan_line(b);
                if self.captured.len() < 256 * 1024 {
                    self.captured.push(b);
                }
                if self.init_ms.is_none() && self.captured.ends_with(b"MICROPOD_VMM_INIT_READY") {
                    let ms = self.t0.elapsed().as_secs_f64() * 1000.0;
                    self.init_ms = Some(ms);
                    if self.tracer.is_enabled() {
                        self.tracer.record_span(
                            "vmm.boot.to_init_ready",
                            None,
                            self.boot_start_unix_ns,
                            telemetry::now_unix_ns(),
                            vec![("milestone".into(), "init_ready".into())],
                            true,
                        );
                    }
                }
                self.ris |= 0x20;
                self.update_irq();
            }
            0x024 => self.ibrd = v,
            0x028 => self.fbrd = v,
            0x02c => self.lcr_h = v,
            0x030 => self.cr = v,
            0x038 => {
                self.imsc = v;
                self.update_irq();
            }
            0x044 => {
                self.ris &= !v;
                self.update_irq();
            }
            _ => {}
        }
    }

    fn snapshot(&self) -> Pl011Snapshot {
        Pl011Snapshot {
            cr: self.cr,
            imsc: self.imsc,
            ris: self.ris,
            lcr_h: self.lcr_h,
            ibrd: self.ibrd,
            fbrd: self.fbrd,
        }
    }

    fn restore(&mut self, s: &Pl011Snapshot) {
        self.cr = s.cr;
        self.imsc = s.imsc;
        self.ris = s.ris;
        self.lcr_h = s.lcr_h;
        self.ibrd = s.ibrd;
        self.fbrd = s.fbrd;
    }
}

struct SecondaryStart {
    entry: u64,
    context_id: u64,
    started: bool,
}

// The watchdog accepts one snapshot trigger per run. These are one-shot
// barriers: any vCPU failure must release its peers instead of stranding them
// in a rendezvous that can no longer reach its original participant count.
struct VcpuBarrier {
    remaining: Mutex<Option<usize>>,
    ready: Condvar,
}

impl VcpuBarrier {
    fn new(count: usize) -> Self {
        Self {
            remaining: Mutex::new(Some(count)),
            ready: Condvar::new(),
        }
    }

    fn wait(&self) -> bool {
        let mut remaining = self.remaining.lock().unwrap();
        let Some(count) = *remaining else {
            return false;
        };
        assert!(count > 0);
        *remaining = Some(count - 1);
        if count == 1 {
            self.ready.notify_all();
            return true;
        }
        self.ready
            .wait_while(remaining, |left| left.is_some_and(|n| n > 0))
            .unwrap()
            .is_some()
    }

    fn cancel(&self) {
        let mut remaining = self
            .remaining
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if remaining.is_some_and(|count| count > 0) {
            *remaining = None;
            self.ready.notify_all();
        }
    }
}

struct SnapshotSync {
    requested: AtomicBool,
    enter_barrier: VcpuBarrier,
    saved_barrier: VcpuBarrier,
    done_barrier: VcpuBarrier,
    vcpu_snaps: Mutex<Vec<Option<VcpuSnapshot>>>,
    out_dir: Option<PathBuf>,
    disk_path: Option<PathBuf>,
    ram_ptr: usize,
    ram_size: usize,
    memory_mib: usize,
    gicd_base: u64,
    gicr_base: u64,
    exit_after_snapshot: bool,
    last_error: Mutex<Option<String>>,
}

struct SharedState {
    uart: Mutex<Pl011>,
    virtio: Vec<Mutex<VirtioMmioDevice>>,
    shutdown: AtomicBool,
    shutting_down: Arc<AtomicBool>,
    exit_reason: Mutex<String>,
    /// The `--parent-pid` supervisor disappeared during the run.
    parent_lost: AtomicBool,
    vcpu_handles: Mutex<Vec<hv_vcpu_t>>,
    vcpus_online: Arc<AtomicU32>,
    mmio_exits: Arc<AtomicU64>,
    wfi_exits: Arc<AtomicU64>,
    secondary_starts: Vec<(Mutex<SecondaryStart>, Condvar)>,
    startup: VcpuBarrier,
    restored: VcpuBarrier,
    tracer: Arc<telemetry::Tracer>,
    snap: SnapshotSync,
    /// The guest physical address just past its RAM.
    ram_end: u64,
}

impl SharedState {
    fn abort_vcpus(&self, reason: &str) {
        self.request_shutdown(reason);
        for phase in [
            &self.startup,
            &self.restored,
            &self.snap.saved_barrier,
            &self.snap.done_barrier,
        ] {
            phase.cancel();
        }
    }

    fn request_shutdown(&self, reason: &str) {
        {
            let mut exit_reason = self
                .exit_reason
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            if !self.shutdown.swap(true, Ordering::SeqCst) {
                *exit_reason = reason.to_string();
            }
        }
        // If some CPUs have already stopped, no one can complete a pending
        // snapshot entry. A snapshot with all CPUs present can still finish.
        self.snap.enter_barrier.cancel();
        for (mu, cv) in &self.secondary_starts {
            let _g = mu.lock().unwrap_or_else(|poison| poison.into_inner());
            cv.notify_all();
        }
        let handles = self
            .vcpu_handles
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if !handles.is_empty() {
            let _ = unsafe { hv_vcpus_exit(handles.as_ptr(), handles.len() as u32) };
        }
    }
}

#[derive(Debug, Clone)]
pub struct ShareSpec {
    pub tag: String,
    pub host_path: PathBuf,
    pub read_only: bool,
}

/// The host sync each disk runs for a guest flush.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiskFlushModes {
    /// `--disk` (`/dev/vda`).
    pub os_disk: DiskFlush,
    /// `--cache-disk` (`/dev/vdb`).
    pub cache_disk: DiskFlush,
}

impl VmConfig {
    /// `--disk-flush` for both disks, the OS disk's `--disk-flush-os` when set.
    pub fn flush_modes(&self) -> DiskFlushModes {
        DiskFlushModes {
            os_disk: self.os_disk_flush.unwrap_or(self.disk_flush),
            cache_disk: self.disk_flush,
        }
    }
}

pub struct VmConfig {
    pub kernel_path: PathBuf,
    pub initrd_path: Option<PathBuf>,
    pub disk_path: Option<PathBuf>,
    pub disk_read_only: bool,
    /// Optional second Virtio-Blk disk (`/dev/vdb`) mounted by guest init at
    /// `/var/lib/micropod/caches` so persistent dependency & BuildKit caches
    /// survive `disk.ext4` OS upgrades.
    pub cache_disk_path: Option<PathBuf>,
    /// The host sync both disks run for a guest flush (`--disk-flush`).
    pub disk_flush: DiskFlush,
    /// The OS disk's own (`--disk-flush-os`), overriding `disk_flush` for it
    /// alone: the cache disk keeps `disk_flush`.
    pub os_disk_flush: Option<DiskFlush>,
    pub num_vcpus: u32,
    pub memory_mib: usize,
    pub cmdline: String,
    pub enable_balloon: bool,
    pub enable_net: bool,
    pub enable_published_net: bool,
    pub published_mtu: u16,
    /// Opt-in host loopback TCP ports reachable from the guest at `10.42.0.1:<port>`.
    pub allow_host_ports: Vec<u16>,
    pub enable_vsock: bool,
    pub vsock_exposes: Vec<VsockExposeSpec>,
    pub shares: Vec<ShareSpec>,
    pub echo_console: bool,
    pub timeout_secs: u64,
    pub snapshot_trigger: Option<PathBuf>,
    pub snapshot_out: Option<PathBuf>,
    pub snapshot_and_exit: bool,
    pub restore_from: Option<PathBuf>,
    pub telemetry: TelemetryConfig,
    /// After SIGTERM/SIGINT, how long to wait for the guest to power off before
    /// forcing the stop (the guest is told its share when it connects).
    pub shutdown_timeout_secs: u64,
    /// Append the guest console (kernel, init and engine output) to this file.
    pub console_log: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct VmRunReport {
    pub exit_reason: String,
    /// Failure the guest reported before it stopped (`engine-exited ...`, `init-failed ...`).
    pub guest_failure: Option<String>,
    /// The `--parent-pid` supervisor exited during the run (exit code 7).
    pub parent_exited: bool,
    pub ipa_granule: &'static str,
    pub num_vcpus: u32,
    pub vcpus_started: u32,
    pub memory_mib: usize,
    pub boot_to_first_uart_ms: Option<f64>,
    pub boot_to_init_ms: Option<f64>,
    pub total_wall_ms: f64,
    pub mmio_exits: u64,
    pub wfi_exits: u64,
    pub blk_read_ops: u64,
    pub blk_write_ops: u64,
    pub blk_read_bytes: u64,
    pub blk_write_bytes: u64,
    pub balloon_kicks: u64,
    pub balloon_ranges: u64,
    pub balloon_reclaimed_bytes: u64,
    pub net_tx_packets: u64,
    pub net_tx_bytes: u64,
    pub net_rx_packets: u64,
    pub net_rx_bytes: u64,
    pub published_binds: u64,
    pub published_conns: u64,
    pub published_refused: u64,
    pub fs_requests: u64,
    pub fs_bytes_read: u64,
    /// Most Virtio-FS nodes all shares held at once.
    pub fs_nodes_peak: u64,
    pub workspace_kicks: u64,
    pub workspace_used_batches: u64,
    pub workspace_irq_requests: u64,
    pub host_phys_footprint_mib: f64,
    pub host_peak_footprint_mib: f64,
    pub console_output: String,
}

impl VmRunReport {
    /// Process exit code for this run (see [`exit`]).
    pub fn exit_code(&self) -> i32 {
        if self.parent_exited {
            return exit::EXIT_PARENT_EXITED;
        }
        exit::exit_code(&self.exit_reason, self.guest_failure.as_deref())
    }
}

fn align_up(v: u64, align: u64) -> u64 {
    (v + align - 1) & !(align - 1)
}

fn checked_ram_size(memory_mib: usize) -> Result<usize, String> {
    if memory_mib == 0 {
        return Err("memory_mib must be greater than zero".into());
    }
    memory_mib
        .checked_mul(1024 * 1024)
        .ok_or_else(|| "memory_mib overflows the host address size".into())
}

pub fn run_vm(cfg: VmConfig) -> Result<VmRunReport, String> {
    run_vm_with_parent(cfg, None)
}

fn verify_expected_parent(expected_parent_pid: Option<libc::pid_t>) -> Result<(), String> {
    let Some(expected) = expected_parent_pid else {
        return Ok(());
    };
    if expected <= 1 {
        return Err("expected parent PID must be greater than 1".into());
    }
    // The kernel updates the parent when it reparents an orphaned process.
    let actual = unsafe { libc::getppid() };
    if actual != expected {
        return Err(format!("expected parent PID {expected}, found {actual}"));
    }
    Ok(())
}

/// Run a VM whose lifetime may be tied to its direct supervisor process.
pub fn run_vm_with_parent(
    cfg: VmConfig,
    expected_parent_pid: Option<libc::pid_t>,
) -> Result<VmRunReport, String> {
    verify_expected_parent(expected_parent_pid)?;
    SIGNAL_SHUTDOWN.store(false, Ordering::SeqCst);
    SIGNAL_COUNT.store(0, Ordering::SeqCst);
    unsafe {
        libc::signal(
            libc::SIGTERM,
            handle_term_signal as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            handle_term_signal as *const () as libc::sighandler_t,
        );
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }

    let t0 = Instant::now();
    let boot_start_unix_ns = telemetry::now_unix_ns();
    let tracer = Arc::new(telemetry::Tracer::new(
        cfg.telemetry.tracing_enabled,
        cfg.telemetry.slow_op_threshold_ms,
    ));
    let mut setup_span = tracer.start_span(
        if cfg.restore_from.is_some() {
            "vmm.restore.setup"
        } else {
            "vmm.boot.setup"
        },
        None,
    );
    let setup_parent = setup_span.as_ref().map(|s| s.span_id());
    let restore_snap: Option<(PathBuf, VmSnapshot)> = match &cfg.restore_from {
        Some(dir) => {
            let _sp = tracer.start_span("vmm.restore.validate", setup_parent.clone());
            let snap = VmSnapshot::read_from(&dir.join("vmstate.bin"))?;
            let host_os = snapshot::host_os_build_id();
            if !snap.host_os_version.is_empty()
                && snap.host_os_version != host_os
                && std::env::var("MICROPOD_VMM_ALLOW_CROSS_OS_SNAPSHOT").as_deref() != Ok("1")
            {
                return Err(format!(
                    "snapshot host OS build mismatch (snapshot={}, host={}); regenerate snapshot",
                    snap.host_os_version, host_os
                ));
            }
            let expected_ram = checked_ram_size(snap.memory_mib)?;
            let ram_meta = std::fs::metadata(dir.join("ram.bin"))
                .map_err(|e| format!("stat snapshot ram.bin: {e}"))?;
            if ram_meta.len() as usize != expected_ram {
                return Err(format!(
                    "snapshot RAM size mismatch: ram.bin={} expected={}",
                    ram_meta.len(),
                    expected_ram
                ));
            }
            Some((dir.clone(), snap))
        }
        None => None,
    };

    let num_vcpus = restore_snap
        .as_ref()
        .map_or(cfg.num_vcpus, |(_, s)| s.num_vcpus);
    let memory_mib = restore_snap
        .as_ref()
        .map_or(cfg.memory_mib, |(_, s)| s.memory_mib);
    if num_vcpus == 0 {
        return Err("num_vcpus must be greater than zero".into());
    }
    let ram_size = checked_ram_size(memory_mib)?;

    let (kernel_bytes, text_offset, image_size, initrd_bytes) = if restore_snap.is_none() {
        let _sp = tracer.start_span("vmm.boot.read_images", setup_parent.clone());
        let kb = std::fs::read(&cfg.kernel_path).map_err(|e| format!("read kernel: {e}"))?;
        if kb.len() < 64 {
            return Err("kernel Image too small".into());
        }
        let magic = u32::from_le_bytes(kb[56..60].try_into().unwrap());
        if magic != 0x644d_5241 {
            return Err(format!("invalid ARM64 Image magic {magic:#x}"));
        }
        let toff = u64::from_le_bytes(kb[8..16].try_into().unwrap());
        let isz = u64::from_le_bytes(kb[16..24].try_into().unwrap()).max(kb.len() as u64);
        let ib = match &cfg.initrd_path {
            Some(p) => Some(std::fs::read(p).map_err(|e| format!("read initrd: {e}"))?),
            None => None,
        };
        (kb, toff, isz, ib)
    } else {
        (Vec::new(), 0, 0, None)
    };

    verify_expected_parent(expected_parent_pid)?;

    // In restore mode, if `--disk <target>` does not yet exist and the snapshot holds `disk.ext4`,
    // instantly APFS CoW-clone `<snap>/disk.ext4` -> `<target>` before opening and locking it!
    if let (Some((snap_dir, _)), Some(disk_path)) = (&restore_snap, cfg.disk_path.as_deref())
        && !disk_path.exists()
    {
        let snap_disk = snap_dir.join("disk.ext4");
        if snap_disk.exists() {
            let _sp = tracer.start_span("vmm.restore.cow_disk_clone", setup_parent.clone());
            snapshot::clone_file_apfs(&snap_disk, disk_path)?;
        }
    }

    // Keep the locked file alive through VM teardown. The block device's
    // duplicate also retains the lock until its I/O worker releases the file.
    let disk = cfg
        .disk_path
        .as_deref()
        .map(|path| {
            disk::open(path, cfg.disk_read_only).map_err(|e| match e.kind() {
                io::ErrorKind::WouldBlock if !cfg.disk_read_only => {
                    format!("disk {} is locked by another writer", path.display())
                }
                _ => format!("open disk {}: {e}", path.display()),
            })
        })
        .transpose()?;
    let cache_disk = cfg
        .cache_disk_path
        .as_deref()
        .map(|path| {
            disk::open(path, false).map_err(|e| match e.kind() {
                io::ErrorKind::WouldBlock => {
                    format!("cache disk {} is locked by another writer", path.display())
                }
                _ => format!("open cache disk {}: {e}", path.display()),
            })
        })
        .transpose()?;

    // Bind every exposed host socket before the guest exists: an unusable path
    // (too long, occupied by a live listener, or not a socket) fails startup.
    let vsock_listeners = cfg
        .vsock_exposes
        .iter()
        .map(ExposeListener::bind)
        .collect::<Result<Vec<_>, _>>()?;
    let console_log = cfg
        .console_log
        .as_deref()
        .map(|path| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .map_err(|e| format!("open --console-log {}: {e}", path.display()))
        })
        .transpose()?;
    let shutdown_timeout = Duration::from_secs(cfg.shutdown_timeout_secs);
    let shutdown_wait = ctrl::host_shutdown_wait(shutdown_timeout);

    // 1. Create VM with 16 KiB Stage-2 IPA granule (macOS 26+)
    let vm_cfg = unsafe { hv_vm_config_create() };
    if vm_cfg.is_null() {
        return Err("hv_vm_config_create returned null".into());
    }
    let mut ipa_granule = "default";
    let g_rc =
        unsafe { hv_vm_config_set_ipa_granule(vm_cfg, hv_ipa_granule_t::HV_IPA_GRANULE_16KB) };
    if g_rc == HV_SUCCESS {
        ipa_granule = "16KiB";
    }
    let create_res = check(unsafe { hv_vm_create(vm_cfg) }, "hv_vm_create");
    unsafe { os_release(vm_cfg) };
    create_res.map_err(|e| e.to_string())?;

    let mut ram_ptr: *mut std::ffi::c_void = ptr::null_mut();
    let mut _ram_mmap_file: Option<std::fs::File> = None;
    let run_res = (|| -> Result<VmRunReport, String> {
        // 2. Configure and create Apple Hardware GICv3 BEFORE creating vCPUs
        let mut gicd_size: usize = 0;
        let mut gicd_align: usize = 0;
        let mut gicr_region_size: usize = 0;
        let mut gicr_align: usize = 0;
        check(
            unsafe { hv_gic_get_distributor_size(&mut gicd_size) },
            "gic dist size",
        )
        .map_err(|e| e.to_string())?;
        check(
            unsafe { hv_gic_get_distributor_base_alignment(&mut gicd_align) },
            "gic dist align",
        )
        .map_err(|e| e.to_string())?;
        check(
            unsafe { hv_gic_get_redistributor_region_size(&mut gicr_region_size) },
            "gic redist size",
        )
        .map_err(|e| e.to_string())?;
        check(
            unsafe { hv_gic_get_redistributor_base_alignment(&mut gicr_align) },
            "gic redist align",
        )
        .map_err(|e| e.to_string())?;

        let (gicd_base, gicr_base) = if let Some((_, ref snap)) = restore_snap {
            (snap.gicd_base, snap.gicr_base)
        } else {
            let db = align_up(0x1000_0000, gicd_align.max(0x10000) as u64);
            let rb = align_up(db + gicd_size as u64, gicr_align.max(0x20000) as u64);
            (db, rb)
        };
        if gicr_base + (gicr_region_size as u64) > RAM_BASE {
            return Err(format!(
                "GIC redistributor region ({:#x} + {:#x}) overlaps RAM ({:#x})",
                gicr_base, gicr_region_size, RAM_BASE
            ));
        }

        let gic_cfg = unsafe { hv_gic_config_create() };
        if gic_cfg.is_null() {
            return Err("hv_gic_config_create returned null".into());
        }
        let gic_res = (|| {
            check(
                unsafe { hv_gic_config_set_distributor_base(gic_cfg, gicd_base) },
                "gic set dist base",
            )?;
            check(
                unsafe { hv_gic_config_set_redistributor_base(gic_cfg, gicr_base) },
                "gic set redist base",
            )?;
            check(unsafe { hv_gic_create(gic_cfg) }, "hv_gic_create")
        })();
        unsafe { os_release(gic_cfg) };
        gic_res.map_err(|e| e.to_string())?;

        let mut vtimer_intid: u32 = 27;
        let mut ptimer_intid: u32 = 30;
        let _ = unsafe {
            hv_gic_get_intid(
                hv_gic_intid_t::HV_GIC_INT_EL1_VIRTUAL_TIMER,
                &mut vtimer_intid,
            )
        };
        let _ = unsafe {
            hv_gic_get_intid(
                hv_gic_intid_t::HV_GIC_INT_EL1_PHYSICAL_TIMER,
                &mut ptimer_intid,
            )
        };

        // 3. Allocate or APFS-CoW MAP_PRIVATE guest RAM
        {
            let _sp = tracer.start_span(
                if restore_snap.is_some() {
                    "vmm.restore.cow_ram_map"
                } else {
                    "vmm.boot.ram_alloc"
                },
                setup_parent.clone(),
            );
            if let Some((ref snap_dir, _)) = restore_snap {
                let (ptr, f) = snapshot::map_cow_ram(&snap_dir.join("ram.bin"), ram_size)?;
                ram_ptr = ptr;
                _ram_mmap_file = Some(f);
            } else {
                // Plain anonymous memory, not hv_vm_allocate: the balloon
                // gives reported free pages back by mapping fresh ones over
                // them (GuestMemory::reclaim), and macOS frees neither the
                // pages nor their footprint for hv_vm_allocate memory
                // (madvise is ignored on it; pages replaced under it stay
                // charged).
                ram_ptr = unsafe {
                    libc::mmap(
                        ptr::null_mut(),
                        ram_size,
                        libc::PROT_READ | libc::PROT_WRITE,
                        libc::MAP_PRIVATE | libc::MAP_ANON,
                        -1,
                        0,
                    )
                };
                if ram_ptr == libc::MAP_FAILED {
                    ram_ptr = ptr::null_mut();
                    return Err(format!(
                        "allocate {ram_size} bytes of guest RAM: {}",
                        std::io::Error::last_os_error()
                    ));
                }
            }
            check(
                unsafe { hv_vm_map(ram_ptr, RAM_BASE, ram_size, HV_MEMORY_RWX) },
                "hv_vm_map",
            )
            .map_err(|e| e.to_string())?;
        }

        let mem = Arc::new(unsafe { GuestMemory::new_guest_ram(ram_ptr.cast(), RAM_BASE, ram_size) });

        // 4. Cold-boot only: load kernel Image + optional initrd
        let (kernel_ipa, initrd_range, mut next_ipa) = if restore_snap.is_none() {
            let _sp = tracer.start_span("vmm.boot.kernel_load", setup_parent.clone());
            let kipa = RAM_BASE + text_offset;
            {
                let dst = mem
                    .write_slice(kipa, kernel_bytes.len())
                    .ok_or("kernel exceeds guest RAM")?;
                dst.copy_from_slice(&kernel_bytes);
            }
            let mut nipa = align_up(kipa + image_size + (4 << 20), 16 * 1024);
            let ir = if let Some(ref rd) = initrd_bytes {
                let start = nipa;
                let end = start + rd.len() as u64;
                let dst = mem
                    .write_slice(start, rd.len())
                    .ok_or("initrd exceeds guest RAM")?;
                dst.copy_from_slice(rd);
                nipa = align_up(end + (1 << 20), 2 << 20);
                Some((start, end))
            } else {
                nipa = align_up(nipa, 2 << 20);
                None
            };
            (kipa, ir, nipa)
        } else {
            (0, None, 0)
        };

        // 5. Attach Virtio-MMIO v2 devices
        let virtio_span = tracer.start_span(
            if restore_snap.is_some() {
                "vmm.restore.virtio_attach"
            } else {
                "vmm.boot.virtio_attach"
            },
            setup_parent.clone(),
        );
        let blk_metrics = Arc::new(BlkMetrics::default());
        let balloon_metrics = Arc::new(BalloonMetrics::default());
        let net_metrics = Arc::new(NetMetrics::default());
        let fs_metrics = Arc::new(FsMetrics::default());

        let mut virtio_devs: Vec<Mutex<VirtioMmioDevice>> = Vec::new();
        let mut virtio_descs: Vec<VirtioMmioDesc> = Vec::new();
        let mut push_dev = |backend: Box<dyn vmm_virtio::VirtioBackend>| {
            let slot = virtio_devs.len() as u64;
            let base = VIRTIO_MMIO_BASE + slot * VIRTIO_MMIO_STRIDE;
            let intid = VIRTIO_SPI_BASE_INTID + slot as u32;
            virtio_devs.push(Mutex::new(VirtioMmioDevice::new(
                intid,
                mem.clone(),
                backend,
            )));
            virtio_descs.push(VirtioMmioDesc {
                base,
                size: VIRTIO_MMIO_STRIDE,
                spi: intid - 32,
            });
        };

        push_dev(Box::new(VirtioRng));
        let flush = cfg.flush_modes();
        if disk.is_some() && flush.os_disk != cfg.disk_flush {
            eprintln!(
                "[micropod-vmm] disk flush: OS disk {}, cache disk {} (--disk-flush-os)",
                flush.os_disk.name(),
                flush.cache_disk.name()
            );
        }
        if let Some(disk) = &disk {
            let file = disk
                .try_clone()
                .map_err(|e| format!("duplicate disk descriptor: {e}"))?;
            let blk = VirtioBlk::new(file, cfg.disk_read_only, blk_metrics.clone(), flush.os_disk)
                .map_err(|e| format!("init virtio-blk: {e}"))?;
            push_dev(Box::new(blk));
        }
        if let Some(cache_disk) = &cache_disk {
            let file = cache_disk
                .try_clone()
                .map_err(|e| format!("duplicate cache disk descriptor: {e}"))?;
            let blk = VirtioBlk::new(file, false, blk_metrics.clone(), flush.cache_disk)
                .map_err(|e| format!("init cache virtio-blk: {e}"))?;
            push_dev(Box::new(blk));
        }
        if cfg.enable_balloon {
            push_dev(Box::new(VirtioBalloon::new(balloon_metrics.clone())));
        }

        let mut vsock_services: HashMap<u32, HostServiceHandler> = HashMap::new();
        // Linux probes virtio-mmio DT nodes in order:
        // eth0 = primary egress (10.42.0.2/24), eth1 = dedicated published-port link (10.43.0.2/24)
        if cfg.enable_net {
            let egress_cfg =
                NetConfig::primary_egress().with_host_loopback_ports(cfg.allow_host_ports.clone());
            let net0 = vmm_net::VirtioNetEgress::new(egress_cfg, net_metrics.clone())
                .map_err(|e| format!("init eth0 virtio-net egress: {e}"))?;
            push_dev(Box::new(net0));
        }
        if cfg.enable_published_net {
            let mut link = NetConfig::published_link(cfg.published_mtu);
            if cfg.enable_net {
                // Engines that predate the dedicated link bind their port relay to eth0.
                link = link.with_fallback_guest_ip(NetConfig::primary_egress().guest_ip);
            }
            let net1 = VirtioNetBridge::new(link, net_metrics.clone())
                .map_err(|e| format!("init eth1 virtio-net: {e}"))?;
            if let Some(broker) = net1.port_broker() {
                vsock_services.insert(VSOCK_PORT_BROKER, broker.vsock_handler());
            }
            push_dev(Box::new(net1));
        }
        for share in &cfg.shares {
            let vfs = VirtioFs::new(
                &share.tag,
                share.host_path.clone(),
                share.read_only,
                fs_metrics.clone(),
            )
            .map_err(|e| format!("init virtiofs {}: {e}", share.tag))?;
            push_dev(Box::new(vfs));
        }
        let guest_ctrl = Arc::new(ctrl::GuestControl::with_shutdown_budget(
            ctrl::guest_shutdown_budget(shutdown_timeout),
        ));
        if cfg.enable_vsock || !vsock_listeners.is_empty() || !vsock_services.is_empty() {
            vsock_services.insert(VSOCK_PORT_CTRL, guest_ctrl.vsock_handler());
            let vsock = VirtioVsock::new(vsock_listeners, vsock_services);
            push_dev(Box::new(vsock));
        }

        drop(virtio_span);

        let fdt_ipa = if let Some((_, ref snap)) = restore_snap {
            if virtio_devs.len() != snap.devices.len() {
                return Err(format!(
                    "virtio device count mismatch on restore: cli={} snapshot={}",
                    virtio_devs.len(),
                    snap.devices.len()
                ));
            }
            for (slot, (dev, dsnap)) in virtio_devs.iter().zip(snap.devices.iter()).enumerate() {
                let actual_id = dev.lock().unwrap().device_id();
                if actual_id != dsnap.device_id {
                    return Err(format!(
                        "virtio slot {slot} device mismatch on restore: cli device_id={actual_id} snapshot device_id={}",
                        dsnap.device_id
                    ));
                }
            }
            0u64
        } else {
            let (cache_topo, timer_freq_hz) = host_cache_topology();
            let dtb = build_arm64_fdt(&VmFdtConfig {
                num_vcpus,
                ram_base: RAM_BASE,
                ram_size: ram_size as u64,
                gicd_base,
                gicd_size: gicd_size as u64,
                gicr_base,
                gicr_size: gicr_region_size as u64,
                uart_base: UART_BASE,
                uart_size: UART_SIZE,
                uart_spi: UART_INTID - 32,
                vtimer_ppi: vtimer_intid - 16,
                ptimer_ppi: ptimer_intid - 16,
                timer_freq_hz,
                cmdline: boot_clock::cmdline(&cfg.cmdline, std::time::SystemTime::now())?,
                initrd: initrd_range,
                cache: cache_topo,
                virtio_mmio: virtio_descs,
            });
            let fipa = next_ipa;
            next_ipa += dtb.len() as u64;
            let _ = next_ipa;
            {
                let dst = mem
                    .write_slice(fipa, dtb.len())
                    .ok_or("FDT exceeds guest RAM")?;
                dst.copy_from_slice(&dtb);
            }
            fipa
        };

        // Setup is complete before the guest starts; keeping the guard any longer
        // would incorrectly stretch boot/restore setup spans across the VM lifetime.
        if let Some(ref mut sp) = setup_span {
            sp.attr("vcpus", num_vcpus.to_string());
            sp.attr("memory_mib", memory_mib.to_string());
            sp.attr("ipa_granule", ipa_granule);
        }
        drop(setup_span);

        // 6. Launch all vCPU threads behind a startup barrier so GICv3 topology is final
        let is_restore = restore_snap.is_some();
        let mut pl011 = Pl011::new(
            t0,
            boot_start_unix_ns,
            cfg.echo_console,
            console_log,
            tracer.clone(),
        );
        if let Some((_, ref snap)) = restore_snap {
            pl011.restore(&snap.pl011);
        }

        let mut secondary_starts = Vec::with_capacity(num_vcpus as usize);
        for _ in 0..num_vcpus {
            secondary_starts.push((
                Mutex::new(SecondaryStart {
                    entry: 0,
                    context_id: 0,
                    started: is_restore,
                }),
                Condvar::new(),
            ));
        }
        let shared = Arc::new(SharedState {
            uart: Mutex::new(pl011),
            virtio: virtio_devs,
            shutdown: AtomicBool::new(false),
            shutting_down: Arc::new(AtomicBool::new(false)),
            exit_reason: Mutex::new("unknown".into()),
            parent_lost: AtomicBool::new(false),
            vcpu_handles: Mutex::new(Vec::with_capacity(num_vcpus as usize)),
            vcpus_online: Arc::new(AtomicU32::new(if is_restore { num_vcpus } else { 1 })),
            mmio_exits: Arc::new(AtomicU64::new(0)),
            wfi_exits: Arc::new(AtomicU64::new(0)),
            secondary_starts,
            startup: VcpuBarrier::new(num_vcpus as usize),
            restored: VcpuBarrier::new(num_vcpus as usize),
            tracer: tracer.clone(),
            snap: SnapshotSync {
                requested: AtomicBool::new(false),
                enter_barrier: VcpuBarrier::new(num_vcpus as usize),
                saved_barrier: VcpuBarrier::new(num_vcpus as usize),
                done_barrier: VcpuBarrier::new(num_vcpus as usize),
                vcpu_snaps: Mutex::new(vec![None; num_vcpus as usize]),
                out_dir: cfg.snapshot_out.clone(),
                disk_path: cfg.disk_path.clone(),
                ram_ptr: ram_ptr as usize,
                ram_size,
                memory_mib,
                gicd_base,
                gicr_base,
                exit_after_snapshot: cfg.snapshot_and_exit,
                last_error: Mutex::new(None),
            },
            ram_end: RAM_BASE + ram_size as u64,
        });

        let mut threads = Vec::with_capacity(num_vcpus as usize);

        // Start live Prometheus / OTLP / healthz telemetry server (zero metric files on disk)
        let telemetry_source = Arc::new(telemetry::TelemetrySource {
            pid: unsafe { getpid() },
            t0,
            ipa_granule,
            num_vcpus,
            memory_mib,
            vcpus_online: shared.vcpus_online.clone(),
            mmio_exits: shared.mmio_exits.clone(),
            wfi_exits: shared.wfi_exits.clone(),
            shutting_down: shared.shutting_down.clone(),
            guest_ctrl: guest_ctrl.clone(),
            blk: blk_metrics.clone(),
            balloon: balloon_metrics.clone(),
            net: net_metrics.clone(),
            fs: fs_metrics.clone(),
            service_name: cfg.telemetry.service_name.clone(),
            worker_id: cfg.telemetry.worker_id.clone(),
            host_os: telemetry::TelemetryServer::make_host_os(),
            tracer: tracer.clone(),
            traces_endpoint: cfg.telemetry.traces_endpoint.clone(),
        });
        let telemetry_server = telemetry::TelemetryServer::start(&cfg.telemetry, telemetry_source)?;

        // Watch for signals, deadlines, snapshot trigger, lid-sleep clock jumps, and supervisor loss.
        let wd_shared = shared.clone();
        let wd_ctrl = guest_ctrl.clone();
        let timeout_secs = cfg.timeout_secs;
        let snap_trigger = cfg.snapshot_trigger.clone();
        let has_snap_out = cfg.snapshot_out.is_some();
        let watchdog = thread::Builder::new()
            .spawn(move || {
                let deadline = if timeout_secs > 0 {
                    Some(Instant::now() + Duration::from_secs(timeout_secs))
                } else {
                    None
                };
                let mut snap_fired = false;
                let mut graceful_deadline: Option<Instant> = None;
                let mut parent_lost = false;
                // A forced stop is reported as what started the shutdown.
                let forced = |parent_lost: bool| {
                    if parent_lost {
                        "parent-exited"
                    } else {
                        "signal"
                    }
                };
                let mut last_clock_check = Instant::now();
                let mut last_clock_sync = Instant::now();
                let mut last_sys_ns = ctrl::current_unix_ns(std::time::SystemTime::now());
                loop {
                    if wd_shared.shutdown.load(Ordering::Relaxed) {
                        return;
                    }
                    if SIGNAL_SHUTDOWN.load(Ordering::Relaxed) {
                        wd_shared.shutting_down.store(true, Ordering::Relaxed);
                        if SIGNAL_COUNT.load(Ordering::Relaxed) >= 2 {
                            wd_shared.request_shutdown(forced(parent_lost));
                            return;
                        }
                        if graceful_deadline.is_none() {
                            if !wd_ctrl.request_poweroff() {
                                wd_shared.request_shutdown(forced(parent_lost));
                                return;
                            }
                            graceful_deadline = Some(Instant::now() + shutdown_wait);
                        }
                    }
                    // The supervisor is gone: stop the guest the same orderly way
                    // (engine stop, sync, read-only remount) within the same budget.
                    if !parent_lost && verify_expected_parent(expected_parent_pid).is_err() {
                        parent_lost = true;
                        wd_shared.parent_lost.store(true, Ordering::SeqCst);
                        wd_shared.shutting_down.store(true, Ordering::Relaxed);
                        eprintln!(
                            "[micropod-vmm] supervisor exited; powering the guest off (up to {}s)",
                            shutdown_wait.as_secs()
                        );
                        if graceful_deadline.is_none() {
                            if !wd_ctrl.request_poweroff() {
                                wd_shared.request_shutdown("parent-exited");
                                return;
                            }
                            graceful_deadline = Some(Instant::now() + shutdown_wait);
                        }
                    }
                    if let Some(gd) = graceful_deadline
                        && Instant::now() >= gd
                    {
                        wd_shared.request_shutdown(forced(parent_lost));
                        return;
                    }
                    let check_elapsed = last_clock_check.elapsed();
                    if check_elapsed >= Duration::from_secs(1) {
                        let now_sys = std::time::SystemTime::now();
                        let now_sys_ns = ctrl::current_unix_ns(now_sys);
                        let jumped = match (last_sys_ns, now_sys_ns) {
                            (Some(prev), Some(curr)) => ctrl::clock_jump_exceeds_threshold(
                                prev,
                                curr,
                                check_elapsed.as_nanos() as i64,
                                500_000_000,
                            ),
                            _ => false,
                        };
                        if (jumped || last_clock_sync.elapsed() >= Duration::from_secs(60))
                            && wd_ctrl.is_connected()
                        {
                            let mut sp = wd_shared.tracer.start_span("vmm.clock.sync", None);
                            if wd_ctrl.send_clock_sync(now_sys) {
                                if let Some(ref mut g) = sp {
                                    g.attr("reason", if jumped { "jump" } else { "periodic" });
                                }
                                last_clock_sync = Instant::now();
                            }
                        }
                        last_sys_ns = now_sys_ns;
                        last_clock_check = Instant::now();
                    }
                    if !snap_fired
                        && has_snap_out
                        && let Some(ref trig) = snap_trigger
                        && trig.exists()
                        && wd_shared.vcpus_online.load(Ordering::Acquire) == num_vcpus
                    {
                        let _ = std::fs::remove_file(trig);
                        snap_fired = true;
                        wd_shared.snap.requested.store(true, Ordering::Release);
                        let handles = wd_shared.vcpu_handles.lock().unwrap();
                        if !handles.is_empty() {
                            let _ =
                                unsafe { hv_vcpus_exit(handles.as_ptr(), handles.len() as u32) };
                        }
                    }
                    if let Some(d) = deadline
                        && Instant::now() >= d
                    {
                        wd_shared.request_shutdown("timeout");
                        return;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
            })
            .map_err(|error| format!("spawn watchdog: {error}"))?;

        struct WatchdogGuard {
            shared: Arc<SharedState>,
            handle: Option<thread::JoinHandle<()>>,
        }
        impl Drop for WatchdogGuard {
            fn drop(&mut self) {
                self.shared.shutdown.store(true, Ordering::SeqCst);
                if let Some(h) = self.handle.take() {
                    let _ = h.join();
                }
            }
        }
        let watchdog_guard = WatchdogGuard {
            shared: shared.clone(),
            handle: Some(watchdog),
        };

        let restore_mach_now = unsafe { mach_absolute_time() };
        let restore_snap_arc = restore_snap.map(|(_, s)| Arc::new(s));

        let mut vcpu_error = None;
        for cpu_id in 0..num_vcpus {
            let shared_c = shared.clone();
            let rsnap_c = restore_snap_arc.clone();
            let launched = thread::Builder::new().spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_vcpu_thread(
                        cpu_id,
                        num_vcpus,
                        kernel_ipa,
                        fdt_ipa,
                        &shared_c,
                        rsnap_c,
                        restore_mach_now,
                    )
                }))
                .unwrap_or_else(|_| Err("thread panicked".to_string()));
                result.map_err(|error| {
                    shared_c.abort_vcpus("vcpu_error");
                    format!("vCPU {cpu_id}: {error}")
                })
            });
            match launched {
                Ok(handle) => threads.push(handle),
                Err(error) => {
                    shared.abort_vcpus("vcpu_spawn_error");
                    vcpu_error = Some(format!("spawn vCPU {cpu_id}: {error}"));
                    break;
                }
            }
        }

        for h in threads {
            let result = h
                .join()
                .unwrap_or_else(|_| Err("vCPU thread panicked".to_string()));
            if let Err(error) = result {
                shared.abort_vcpus("vcpu_error");
                vcpu_error.get_or_insert(error);
            }
        }
        // Join watchdog, record final session span, stop telemetry server (which flushes pending
        // traces cleanly), and drop all Virtio devices BEFORE hv_vm_destroy() releases guest RAM!
        drop(watchdog_guard);
        if tracer.is_enabled() {
            let reason = shared.exit_reason.lock().unwrap().clone();
            tracer.record_span(
                "vmm.session",
                None,
                boot_start_unix_ns,
                telemetry::now_unix_ns(),
                vec![
                    ("exit_reason".into(), reason),
                    (
                        "mode".into(),
                        if is_restore {
                            "restore".into()
                        } else {
                            "cold_boot".into()
                        },
                    ),
                    ("vcpus".into(), num_vcpus.to_string()),
                    ("memory_mib".into(), memory_mib.to_string()),
                ],
                vcpu_error.is_none(),
            );
        }
        drop(telemetry_server);
        if let Some(error) = vcpu_error {
            return Err(error);
        }
        if let Some(err) = shared.snap.last_error.lock().unwrap().take() {
            return Err(err);
        }

        let total_wall_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let (phys_b, peak_b) = host_phys_footprint_bytes();
        let exit_reason = shared.exit_reason.lock().unwrap().clone();
        let vcpus_started = shared.vcpus_online.load(Ordering::Relaxed);
        let mmio_exits = shared.mmio_exits.load(Ordering::Relaxed);
        let wfi_exits = shared.wfi_exits.load(Ordering::Relaxed);
        let status_window = exit::guest_status_window(shutdown_timeout);
        let (boot_to_first_uart_ms, boot_to_init_ms, console_output, guest_failure) = {
            let mut uart = shared.uart.lock().unwrap();
            if let Some(log) = uart.console_log.as_mut() {
                let _ = log.flush();
            }
            // Only a reset shortly after the marker is the failure it announced.
            let guest_failure = uart
                .guest_failure
                .as_ref()
                .filter(|(_, seen)| exit_reason == "reboot" && seen.elapsed() <= status_window)
                .map(|(status, _)| status.clone());
            (
                uart.first_tx_ms,
                uart.init_ms,
                String::from_utf8_lossy(&uart.captured).into_owned(),
                guest_failure,
            )
        };
        let parent_exited = shared.parent_lost.load(Ordering::SeqCst);
        drop(shared);
        drop(mem);
        Ok(VmRunReport {
            exit_reason,
            guest_failure,
            parent_exited,
            ipa_granule,
            num_vcpus,
            vcpus_started,
            memory_mib,
            boot_to_first_uart_ms,
            boot_to_init_ms,
            total_wall_ms,
            mmio_exits,
            wfi_exits,
            blk_read_ops: blk_metrics.read_ops.load(Ordering::Relaxed),
            blk_write_ops: blk_metrics.write_ops.load(Ordering::Relaxed),
            blk_read_bytes: blk_metrics.read_bytes.load(Ordering::Relaxed),
            blk_write_bytes: blk_metrics.write_bytes.load(Ordering::Relaxed),
            balloon_kicks: balloon_metrics.report_kicks.load(Ordering::Relaxed),
            balloon_ranges: balloon_metrics.reported_ranges.load(Ordering::Relaxed),
            balloon_reclaimed_bytes: balloon_metrics.reclaimed_bytes.load(Ordering::Relaxed),
            net_tx_packets: net_metrics.tx_packets.load(Ordering::Relaxed),
            net_tx_bytes: net_metrics.tx_bytes.load(Ordering::Relaxed),
            net_rx_packets: net_metrics.rx_packets.load(Ordering::Relaxed),
            net_rx_bytes: net_metrics.rx_bytes.load(Ordering::Relaxed),
            published_binds: net_metrics.published_binds.load(Ordering::Relaxed),
            published_conns: net_metrics.published_conns.load(Ordering::Relaxed),
            published_refused: net_metrics.published_refused.load(Ordering::Relaxed),
            fs_requests: fs_metrics.requests.load(Ordering::Relaxed),
            fs_bytes_read: fs_metrics.bytes_read.load(Ordering::Relaxed),
            fs_nodes_peak: fs_metrics.nodes_peak.load(Ordering::Relaxed),
            workspace_kicks: fs_metrics.workspace_kicks.load(Ordering::Relaxed),
            workspace_used_batches: fs_metrics.workspace_used_batches.load(Ordering::Relaxed),
            workspace_irq_requests: fs_metrics.workspace_irq_requests.load(Ordering::Relaxed),
            host_phys_footprint_mib: (phys_b as f64) / (1024.0 * 1024.0),
            host_peak_footprint_mib: (peak_b as f64) / (1024.0 * 1024.0),
            console_output,
        })
    })();

    let _ = unsafe { hv_vm_destroy() };
    if !ram_ptr.is_null() {
        let _ = unsafe { libc::munmap(ram_ptr, ram_size) };
    }
    run_res
}

fn handle_vcpu_snapshot(cpu_id: u32, vcpu: hv_vcpu_t, shared: &SharedState) -> Result<(), String> {
    if !shared.snap.enter_barrier.wait() {
        return Ok(());
    }
    let vcpu_res = snapshot::save_vcpu_state(vcpu, cpu_id);
    match vcpu_res {
        Ok(vs) => {
            shared.snap.vcpu_snaps.lock().unwrap()[cpu_id as usize] = Some(vs);
        }
        Err(e) => {
            *shared.snap.last_error.lock().unwrap() = Some(e);
        }
    }
    if !shared.snap.saved_barrier.wait() {
        return Ok(());
    }

    if cpu_id == 0 {
        let save_t0 = Instant::now();
        let mut snap_span = shared.tracer.start_span("vmm.snapshot.save", None);
        let snap_parent = snap_span.as_ref().map(|s| s.span_id());
        let res = (|| -> Result<(), String> {
            if let Some(err) = shared.snap.last_error.lock().unwrap().clone() {
                return Err(err);
            }
            let out_dir = shared
                .snap
                .out_dir
                .as_ref()
                .ok_or("snapshot requested without --snapshot-out")?;
            std::fs::create_dir_all(out_dir)
                .map_err(|e| format!("create snapshot dir {}: {e}", out_dir.display()))?;

            let devices: Vec<_> = {
                let _sp = shared
                    .tracer
                    .start_span("vmm.snapshot.virtio_pause", snap_parent.clone());
                shared
                    .virtio
                    .iter()
                    .map(|d| d.lock().unwrap().snapshot_pause())
                    .collect()
            };
            let gic_state = {
                let _sp = shared
                    .tracer
                    .start_span("vmm.snapshot.gic_save", snap_parent.clone());
                snapshot::save_gic_state()?
            };
            let pl011 = shared.uart.lock().unwrap().snapshot();
            let vcpus: Vec<VcpuSnapshot> = shared
                .snap
                .vcpu_snaps
                .lock()
                .unwrap()
                .iter_mut()
                .map(|opt| {
                    opt.take()
                        .ok_or_else(|| "missing vcpu snapshot".to_string())
                })
                .collect::<Result<Vec<_>, _>>()?;

            let ram_written = {
                let mut sp = shared
                    .tracer
                    .start_span("vmm.snapshot.sparse_ram_write", snap_parent.clone());
                let written = unsafe {
                    snapshot::write_sparse_ram(
                        shared.snap.ram_ptr as *const u8,
                        shared.snap.ram_size,
                        &out_dir.join("ram.bin"),
                    )
                }?;
                if let Some(ref mut g) = sp {
                    g.attr("ram_written_bytes", written.to_string());
                }
                written
            };

            if let Some(ref disk_path) = shared.snap.disk_path {
                let _sp = shared
                    .tracer
                    .start_span("vmm.snapshot.cow_disk_clone", snap_parent.clone());
                snapshot::clone_file_apfs(disk_path, &out_dir.join("disk.ext4"))?;
            }

            let created_unix_secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let vm_snap = VmSnapshot {
                host_os_version: snapshot::host_os_build_id(),
                created_unix_secs,
                memory_mib: shared.snap.memory_mib,
                num_vcpus: vcpus.len() as u32,
                gicd_base: shared.snap.gicd_base,
                gicr_base: shared.snap.gicr_base,
                pl011,
                gic_state,
                vcpus,
                devices,
            };
            {
                let _sp = shared
                    .tracer
                    .start_span("vmm.snapshot.vmstate_write", snap_parent.clone());
                vm_snap.write_atomic(&out_dir.join("vmstate.bin"))?;
            }

            let snap_ms = save_t0.elapsed().as_secs_f64() * 1000.0;
            if let Some(ref mut g) = snap_span {
                g.attr("ram_written_bytes", ram_written.to_string());
                g.attr("num_vcpus", vm_snap.num_vcpus.to_string());
            }
            let ready_meta = format!(
                "{{\"snapshot_ms\":{:.2},\"ram_written_bytes\":{},\"ram_total_bytes\":{},\"num_vcpus\":{},\"memory_mib\":{}}}\n",
                snap_ms, ram_written, shared.snap.ram_size, vm_snap.num_vcpus, vm_snap.memory_mib,
            );
            let ready_tmp = out_dir.join("READY.tmp");
            std::fs::write(&ready_tmp, ready_meta).map_err(|e| format!("write READY.tmp: {e}"))?;
            std::fs::rename(&ready_tmp, out_dir.join("READY"))
                .map_err(|e| format!("rename READY: {e}"))?;
            Ok(())
        })();

        if let Err(ref e) = res
            && let Some(ref mut g) = snap_span
        {
            g.set_error(e.clone());
        }
        drop(snap_span);

        shared.snap.requested.store(false, Ordering::Release);
        if let Err(e) = res {
            *shared.snap.last_error.lock().unwrap() = Some(e);
            shared.request_shutdown("snapshot_error");
        } else if shared.snap.exit_after_snapshot {
            shared.request_shutdown("snapshot_done");
        } else {
            for d in &shared.virtio {
                d.lock().unwrap().snapshot_resume();
            }
        }
    }

    let _ = shared.snap.done_barrier.wait();
    Ok(())
}

struct VcpuRegistration<'a> {
    handle: hv_vcpu_t,
    active: &'a Mutex<Vec<hv_vcpu_t>>,
}

impl Drop for VcpuRegistration<'_> {
    fn drop(&mut self) {
        // Unregister and destroy on the owning thread while excluding
        // concurrent hv_vcpus_exit calls with a handle to this vCPU.
        let mut handles = self
            .active
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        handles.retain(|active| *active != self.handle);
        let _ = unsafe { hv_vcpu_destroy(self.handle) };
    }
}

fn run_vcpu_thread(
    cpu_id: u32,
    num_vcpus: u32,
    kernel_ipa: u64,
    fdt_ipa: u64,
    shared: &SharedState,
    restore_snap: Option<Arc<VmSnapshot>>,
    restore_mach_now: u64,
) -> Result<(), String> {
    // Pin vCPU threads to Apple Silicon P-cores via macOS User-Interactive QoS
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let mut vcpu: hv_vcpu_t = 0;
    let mut exit_ptr: *const hv_vcpu_exit_t = ptr::null();
    let vcfg = unsafe { hv_vcpu_config_create() };
    let rc = unsafe { hv_vcpu_create(&mut vcpu, &mut exit_ptr, vcfg) };
    if !vcfg.is_null() {
        unsafe { os_release(vcfg) };
    }
    check(rc, "hv_vcpu_create").map_err(|e| e.to_string())?;
    let _registration = VcpuRegistration {
        handle: vcpu,
        active: &shared.vcpu_handles,
    };
    shared.vcpu_handles.lock().unwrap().push(vcpu);

    let mpidr = 0x8000_0000u64 | (cpu_id as u64);
    check(
        unsafe { hv_vcpu_set_sys_reg(vcpu, hv_sys_reg_t::HV_SYS_REG_MPIDR_EL1, mpidr) },
        "set MPIDR_EL1",
    )
    .map_err(|e| e.to_string())?;

    if let Some(ref snap) = restore_snap {
        let vsnap = snap
            .vcpus
            .iter()
            .find(|v| v.cpu_id == cpu_id)
            .ok_or_else(|| format!("snapshot missing state for vCPU {cpu_id}"))?;
        snapshot::restore_vcpu_state(vcpu, vsnap, restore_mach_now)?;
        if !shared.startup.wait() {
            return Ok(());
        }
        if cpu_id == 0 {
            let mut sp = shared.tracer.start_span("vmm.restore.gic_and_virtio", None);
            let restore_res = snapshot::restore_gic_state(&snap.gic_state).and_then(|()| {
                // Start Virtio backends & bind host sockets ONLY AFTER `hv_gic_set_state`,
                // guaranteeing no early host-side SPI can be overwritten by GIC state restore!
                for (dev, dsnap) in shared.virtio.iter().zip(snap.devices.iter()) {
                    dev.lock().unwrap().snapshot_restore(dsnap)?;
                }
                Ok(())
            });
            if let Err(e) = restore_res {
                if let Some(ref mut g) = sp {
                    g.set_error(e.clone());
                }
                *shared.snap.last_error.lock().unwrap() = Some(e);
                shared.request_shutdown("gic_restore_error");
            }
            drop(sp);
        }
        if !shared.restored.wait() {
            return Ok(());
        }
    } else if !shared.startup.wait() {
        return Ok(());
    }

    (|| -> Result<(), String> {
        if restore_snap.is_none() {
            let (entry_pc, x0) = if cpu_id == 0 {
                (kernel_ipa, fdt_ipa)
            } else {
                let (mu, cv) = &shared.secondary_starts[cpu_id as usize];
                let mut st = mu.lock().unwrap();
                while !st.started && !shared.shutdown.load(Ordering::SeqCst) {
                    st = cv.wait(st).unwrap();
                }
                if shared.shutdown.load(Ordering::SeqCst) {
                    return Ok(());
                }
                (st.entry, st.context_id)
            };

            unsafe {
                check(
                    hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_CPSR, 0x3c5),
                    "set CPSR",
                )?;
                check(
                    hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_PC, entry_pc),
                    "set PC",
                )?;
                check(hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_X0, x0), "set X0")?;
                check(hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_X1, 0), "set X1")?;
                check(hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_X2, 0), "set X2")?;
                check(hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_X3, 0), "set X3")?;
            }
        }

        loop {
            if shared.shutdown.load(Ordering::Relaxed) {
                break;
            }
            if shared.snap.requested.load(Ordering::Acquire) {
                handle_vcpu_snapshot(cpu_id, vcpu, shared)?;
                if shared.shutdown.load(Ordering::Relaxed) {
                    break;
                }
                continue;
            }
            check(unsafe { hv_vcpu_run(vcpu) }, "hv_vcpu_run").map_err(|e| e.to_string())?;
            let exit = unsafe { *exit_ptr };
            match exit.reason {
                hv_exit_reason_t::HV_EXIT_REASON_CANCELED => {
                    if shared.shutdown.load(Ordering::Relaxed) {
                        break;
                    }
                    if shared.snap.requested.load(Ordering::Acquire) {
                        handle_vcpu_snapshot(cpu_id, vcpu, shared)?;
                        if shared.shutdown.load(Ordering::Relaxed) {
                            break;
                        }
                    }
                }
                hv_exit_reason_t::HV_EXIT_REASON_VTIMER_ACTIVATED => {
                    let _ = unsafe { hv_vcpu_set_vtimer_mask(vcpu, false) };
                }
                hv_exit_reason_t::HV_EXIT_REASON_EXCEPTION => {
                    let esr = exit.exception.syndrome;
                    let ec = (esr >> 26) & 0x3f;
                    match ec {
                        0x01 => {
                            shared.wfi_exits.fetch_add(1, Ordering::Relaxed);
                            advance_pc(vcpu)?;
                        }
                        0x16 | 0x17 => {
                            handle_psci(vcpu, ec, num_vcpus, shared)?;
                            if shared.shutdown.load(Ordering::Relaxed) {
                                break;
                            }
                        }
                        0x24 if (RAM_BASE..shared.ram_end)
                            .contains(&exit.exception.physical_address) =>
                        {
                            // The guest touched RAM while the balloon had it
                            // out of the stage-2 mapping for a moment
                            // (GuestMemory::reclaim): run the access again.
                            std::thread::yield_now();
                        }
                        0x24 => {
                            shared.mmio_exits.fetch_add(1, Ordering::Relaxed);
                            handle_mmio(vcpu, esr, exit.exception.physical_address, shared)?;
                        }
                        0x18 => {
                            let is_read = (esr & 1) != 0;
                            let rt = ((esr >> 5) & 0x1f) as u32;
                            if is_read && let Some(reg) = hv_reg_t::gpr(rt) {
                                let _ = unsafe { hv_vcpu_set_reg(vcpu, reg, 0) };
                            }
                            advance_pc(vcpu)?;
                        }
                        _ => {
                            let mut pc = 0u64;
                            let _ = unsafe { hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_PC, &mut pc) };
                            shared.request_shutdown(&format!(
                                "unhandled_ec_{ec:#x}_esr_{esr:#x}_pc_{pc:#x}"
                            ));
                            break;
                        }
                    }
                }
                hv_exit_reason_t::HV_EXIT_REASON_UNKNOWN => {
                    shared.request_shutdown("unknown_exit");
                    break;
                }
            }
        }
        Ok(())
    })()
}

#[inline]
fn advance_pc(vcpu: hv_vcpu_t) -> Result<(), String> {
    let mut pc = 0u64;
    check(
        unsafe { hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_PC, &mut pc) },
        "get PC",
    )
    .map_err(|e| e.to_string())?;
    check(
        unsafe { hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_PC, pc + 4) },
        "set PC",
    )
    .map_err(|e| e.to_string())
}

fn handle_psci(
    vcpu: hv_vcpu_t,
    ec: u64,
    num_vcpus: u32,
    shared: &SharedState,
) -> Result<(), String> {
    let mut x0 = 0u64;
    let mut x1 = 0u64;
    let mut x2 = 0u64;
    let mut x3 = 0u64;
    unsafe {
        let _ = hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_X0, &mut x0);
        let _ = hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_X1, &mut x1);
        let _ = hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_X2, &mut x2);
        let _ = hv_vcpu_get_reg(vcpu, hv_reg_t::HV_REG_X3, &mut x3);
    }
    let fn_id = x0 as u32;
    let ret: u64 = match fn_id {
        PSCI_VERSION => 0x0001_0000,
        SMCCC_VERSION => 0x0001_0001,
        SMCCC_ARCH_FEATURES => match x1 as u32 {
            SMCCC_VERSION => 0,
            _ => PSCI_RET_NOT_SUPPORTED,
        },
        PSCI_FEATURES => match x1 as u32 {
            PSCI_VERSION
            | PSCI_CPU_OFF
            | PSCI_CPU_ON_32
            | PSCI_CPU_ON_64
            | PSCI_AFFINITY_INFO_32
            | PSCI_AFFINITY_INFO_64
            | PSCI_SYSTEM_OFF
            | PSCI_SYSTEM_RESET
            | PSCI_FEATURES => 0,
            _ => PSCI_RET_NOT_SUPPORTED,
        },
        PSCI_CPU_ON_32 | PSCI_CPU_ON_64 => {
            let target = (x1 & 0xff) as u32;
            if target > 0 && target < num_vcpus {
                let (mu, cv) = &shared.secondary_starts[target as usize];
                let mut st = mu.lock().unwrap();
                if st.started {
                    (-4i64) as u64
                } else {
                    st.entry = x2;
                    st.context_id = x3;
                    st.started = true;
                    shared.vcpus_online.fetch_add(1, Ordering::Relaxed);
                    cv.notify_all();
                    0
                }
            } else {
                (-2i64) as u64
            }
        }
        PSCI_AFFINITY_INFO_32 | PSCI_AFFINITY_INFO_64 => {
            let target = (x1 & 0xff) as u32;
            if target == 0 {
                0
            } else if target < num_vcpus {
                let st = shared.secondary_starts[target as usize].0.lock().unwrap();
                if st.started { 0 } else { 1 }
            } else {
                (-2i64) as u64
            }
        }
        PSCI_SYSTEM_OFF => {
            shared.request_shutdown("poweroff");
            0
        }
        PSCI_SYSTEM_RESET => {
            shared.request_shutdown("reboot");
            0
        }
        PSCI_CPU_OFF => {
            shared.request_shutdown("cpu_off");
            0
        }
        _ => PSCI_RET_NOT_SUPPORTED,
    };
    let _ = unsafe { hv_vcpu_set_reg(vcpu, hv_reg_t::HV_REG_X0, ret) };
    if ec == 0x17 {
        advance_pc(vcpu)?;
    }
    Ok(())
}

fn handle_mmio(vcpu: hv_vcpu_t, esr: u64, ipa: u64, shared: &SharedState) -> Result<(), String> {
    let isv = ((esr >> 24) & 1) != 0;
    if !isv {
        return advance_pc(vcpu);
    }
    let sas = ((esr >> 22) & 3) as usize;
    let size = 1usize << sas;
    let sse = ((esr >> 21) & 1) != 0;
    let srt = ((esr >> 16) & 0x1f) as u32;
    let sf = ((esr >> 15) & 1) != 0;
    let is_write = ((esr >> 6) & 1) != 0;

    if is_write {
        let mut val = 0u64;
        if let Some(reg) = hv_reg_t::gpr(srt) {
            let _ = unsafe { hv_vcpu_get_reg(vcpu, reg, &mut val) };
        }
        if (UART_BASE..UART_BASE + UART_SIZE).contains(&ipa) {
            shared.uart.lock().unwrap().write(ipa - UART_BASE, val);
        } else if ipa >= VIRTIO_MMIO_BASE {
            let rel = ipa - VIRTIO_MMIO_BASE;
            let slot = (rel / VIRTIO_MMIO_STRIDE) as usize;
            let off = rel % VIRTIO_MMIO_STRIDE;
            if let Some(dev) = shared.virtio.get(slot) {
                dev.lock().unwrap().mmio_write(off, size, val);
            }
        }
    } else {
        let mut val = if (UART_BASE..UART_BASE + UART_SIZE).contains(&ipa) {
            shared.uart.lock().unwrap().read(ipa - UART_BASE)
        } else if ipa >= VIRTIO_MMIO_BASE {
            let rel = ipa - VIRTIO_MMIO_BASE;
            let slot = (rel / VIRTIO_MMIO_STRIDE) as usize;
            let off = rel % VIRTIO_MMIO_STRIDE;
            shared
                .virtio
                .get(slot)
                .map_or(0, |d| d.lock().unwrap().mmio_read(off, size))
        } else {
            0
        };
        if sse {
            val = match size {
                1 => (val as i8) as i64 as u64,
                2 => (val as i16) as i64 as u64,
                4 => (val as i32) as i64 as u64,
                _ => val,
            };
            if !sf {
                val &= 0xffff_ffff;
            }
        }
        if let Some(reg) = hv_reg_t::gpr(srt) {
            let _ = unsafe { hv_vcpu_set_reg(vcpu, reg, val) };
        }
    }
    advance_pc(vcpu)
}

#[cfg(test)]
mod vcpu_lifecycle_tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn vcpu_start_failure_releases_a_peer_and_late_arrivals() {
        let barrier = Arc::new(VcpuBarrier::new(4));
        let peer = barrier.clone();
        let (send, result) = mpsc::channel();
        let waiter = thread::spawn(move || send.send(peer.wait()).unwrap());
        let deadline = Instant::now() + Duration::from_secs(2);
        while *barrier.remaining.lock().unwrap() == Some(4) {
            assert!(Instant::now() < deadline, "peer did not enter the barrier");
            thread::yield_now();
        }
        barrier.cancel();
        assert!(!result.recv_timeout(Duration::from_secs(1)).unwrap());
        waiter.join().unwrap();
        assert!(!barrier.wait());
    }

    #[test]
    fn memory_size_validation_rejects_zero_and_overflow() {
        assert!(checked_ram_size(0).is_err());
        assert!(checked_ram_size(usize::MAX / (1024 * 1024) + 1).is_err());
        assert_eq!(checked_ram_size(512).unwrap(), 512 * 1024 * 1024);
    }

    fn flush_config(disk_flush: DiskFlush, os_disk_flush: Option<DiskFlush>) -> VmConfig {
        VmConfig {
            kernel_path: PathBuf::new(),
            initrd_path: None,
            disk_path: None,
            disk_read_only: false,
            cache_disk_path: None,
            disk_flush,
            os_disk_flush,
            num_vcpus: 1,
            memory_mib: 512,
            cmdline: String::new(),
            timeout_secs: 0,
            echo_console: false,
            enable_balloon: false,
            enable_net: false,
            enable_published_net: false,
            published_mtu: 1500,
            allow_host_ports: Vec::new(),
            enable_vsock: false,
            vsock_exposes: Vec::new(),
            shares: Vec::new(),
            snapshot_trigger: None,
            snapshot_out: None,
            snapshot_and_exit: false,
            restore_from: None,
            telemetry: TelemetryConfig::default(),
            shutdown_timeout_secs: DEFAULT_SHUTDOWN_TIMEOUT_SECS,
            console_log: None,
        }
    }

    #[test]
    fn os_disk_flush_overrides_only_the_os_disk() {
        // Unchanged by default: barrier on both.
        let both = flush_config(DiskFlush::default(), None).flush_modes();
        assert_eq!(
            both,
            DiskFlushModes {
                os_disk: DiskFlush::Barrier,
                cache_disk: DiskFlush::Barrier
            }
        );
        // --disk-flush still sets both.
        let fsync = flush_config(DiskFlush::Fsync, None).flush_modes();
        assert_eq!(
            (fsync.os_disk, fsync.cache_disk),
            (DiskFlush::Fsync, DiskFlush::Fsync)
        );
        // --disk-flush-os moves the OS disk alone; the cache disk keeps its ordering.
        let os = flush_config(DiskFlush::Barrier, Some(DiskFlush::Fsync)).flush_modes();
        assert_eq!(
            (os.os_disk, os.cache_disk),
            (DiskFlush::Fsync, DiskFlush::Barrier)
        );
        let os = flush_config(DiskFlush::Full, Some(DiskFlush::Barrier)).flush_modes();
        assert_eq!(
            (os.os_disk, os.cache_disk),
            (DiskFlush::Barrier, DiskFlush::Full)
        );
    }

    #[test]
    fn invalid_boot_dimensions_are_rejected_before_reading_images() {
        for (num_vcpus, memory_mib, expected) in [
            (0, 512, "num_vcpus must be greater than zero"),
            (1, 0, "memory_mib must be greater than zero"),
            (1, usize::MAX, "memory_mib overflows the host address size"),
        ] {
            let config = VmConfig {
                kernel_path: PathBuf::new(),
                initrd_path: None,
                disk_path: None,
                disk_read_only: false,
                cache_disk_path: None,
                disk_flush: DiskFlush::default(),
                os_disk_flush: None,
                num_vcpus,
                memory_mib,
                cmdline: String::new(),
                timeout_secs: 0,
                echo_console: false,
                enable_balloon: false,
                enable_net: false,
                enable_published_net: false,
                published_mtu: 1500,
                allow_host_ports: Vec::new(),
                enable_vsock: false,
                vsock_exposes: Vec::new(),
                shares: Vec::new(),
                snapshot_trigger: None,
                snapshot_out: None,
                snapshot_and_exit: false,
                restore_from: None,
                telemetry: TelemetryConfig::default(),
                shutdown_timeout_secs: DEFAULT_SHUTDOWN_TIMEOUT_SECS,
                console_log: None,
            };
            assert_eq!(run_vm(config).err().as_deref(), Some(expected));
        }
    }

    #[test]
    fn completed_rendezvous_releases_all_participants() {
        let barrier = Arc::new(VcpuBarrier::new(2));
        let peer = barrier.clone();
        let waiter = thread::spawn(move || peer.wait());
        assert!(barrier.wait());
        barrier.cancel();
        assert!(waiter.join().unwrap());
    }
}
