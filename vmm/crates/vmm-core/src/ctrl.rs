//! Host <-> guest control channel over Virtio-Vsock (`VSOCK_PORT_CTRL = 2379`).
//!
//! Provides two production lifecycle primitives with zero idle CPU overhead:
//! 1. **Live wall-clock sync (`CLOCK <unix_ns>\n`)**: pushed immediately when `mp-hvf-init`
//!    connects (including right after `--restore-from` snapshot forks!) and whenever the
//!    host wall clock jumps relative to monotonic time (macOS lid sleep/wake or NTP steps).
//! 2. **Graceful guest shutdown (`POWEROFF\n`)**: pushed on host `SIGTERM`/`SIGINT` so
//!    `mp-hvf-init` stops the worker, calls `sync(2)`, remounts ext4 cleanly, and triggers
//!    `PSCI_SYSTEM_OFF` before any hard `hv_vcpus_exit` fallback.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use vmm_virtio::vsock::HostServiceHandler;

pub const VSOCK_PORT_CTRL: u32 = 2379;
/// Default time the host waits for a requested guest poweroff before forcing a stop.
pub const DEFAULT_SHUTDOWN_TIMEOUT_SECS: u64 = 10;
const MIN_UNIX_SECS: u64 = 1_577_836_800; // 2020-01-01 UTC

struct CtrlInner {
    next_gen: u64,
    active: Option<(u64, UnixStream)>,
    poweroff_requested: bool,
    clock_sync_count: u64,
    last_clock_sync_unix_secs: u64,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CtrlHealth {
    pub connected: bool,
    pub clock_sync_count: u64,
    pub last_clock_sync_unix_secs: u64,
}

pub struct GuestControl {
    inner: Arc<Mutex<CtrlInner>>,
    /// Time the guest may spend stopping after `POWEROFF`, announced on connect.
    shutdown_budget: Duration,
}

/// Guest share of a host shutdown timeout: keep a margin for PSCI and teardown.
pub fn guest_shutdown_budget(host_timeout: Duration) -> Duration {
    host_timeout
        .saturating_sub(Duration::from_secs(1))
        .max(Duration::from_secs(1))
}

/// Convert `SystemTime` to a validated Unix nanosecond timestamp (`>= 2020-01-01 UTC`).
pub fn current_unix_ns(now: SystemTime) -> Option<i64> {
    let elapsed = now.duration_since(UNIX_EPOCH).ok()?;
    if elapsed.as_secs() < MIN_UNIX_SECS {
        return None;
    }
    i64::try_from(elapsed.as_nanos()).ok()
}

/// Returns true if wall-clock elapsed time diverged from monotonic elapsed time by more
/// than `threshold_ns` (for example after macOS lid sleep/wake or a large NTP step).
pub fn clock_jump_exceeds_threshold(
    prev_sys_ns: i64,
    now_sys_ns: i64,
    mono_elapsed_ns: i64,
    threshold_ns: i64,
) -> bool {
    let sys_delta = now_sys_ns.saturating_sub(prev_sys_ns);
    let drift = sys_delta.saturating_sub(mono_elapsed_ns).unsigned_abs();
    drift > threshold_ns.max(0) as u64
}

fn format_clock_cmd(now: SystemTime) -> Option<String> {
    let ns = current_unix_ns(now)?;
    Some(format!("CLOCK {ns}\n"))
}

fn write_cmd(stream: &mut UnixStream, cmd: &str) -> bool {
    stream.write_all(cmd.as_bytes()).is_ok()
}

impl GuestControl {
    pub fn new() -> Self {
        Self::with_shutdown_budget(guest_shutdown_budget(Duration::from_secs(
            DEFAULT_SHUTDOWN_TIMEOUT_SECS,
        )))
    }

    pub fn with_shutdown_budget(shutdown_budget: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(CtrlInner {
                next_gen: 1,
                active: None,
                poweroff_requested: false,
                clock_sync_count: 0,
                last_clock_sync_unix_secs: 0,
            })),
            shutdown_budget,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.inner.lock().unwrap().active.is_some()
    }

    pub fn health(&self) -> CtrlHealth {
        let g = self.inner.lock().unwrap();
        CtrlHealth {
            connected: g.active.is_some(),
            clock_sync_count: g.clock_sync_count,
            last_clock_sync_unix_secs: g.last_clock_sync_unix_secs,
        }
    }

    /// Push a `CLOCK <unix_ns>` update to the connected guest init, if any.
    pub fn send_clock_sync(&self, now: SystemTime) -> bool {
        let Some(cmd) = format_clock_cmd(now) else {
            return false;
        };
        let secs = now.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let mut g = self.inner.lock().unwrap();
        let Some((_, ref mut stream)) = g.active else {
            return false;
        };
        if write_cmd(stream, &cmd) {
            g.clock_sync_count += 1;
            g.last_clock_sync_unix_secs = secs;
            true
        } else {
            g.active = None;
            false
        }
    }

    /// Request a graceful guest poweroff. Returns `true` if `POWEROFF` was delivered
    /// to an active guest control connection (so the caller should wait for `PSCI_SYSTEM_OFF`).
    pub fn request_poweroff(&self) -> bool {
        let mut g = self.inner.lock().unwrap();
        g.poweroff_requested = true;
        let Some((_, ref mut stream)) = g.active else {
            return false;
        };
        if write_cmd(stream, "POWEROFF\n") {
            true
        } else {
            g.active = None;
            false
        }
    }

    /// Build the `VirtioVsock` host service handler for `VSOCK_PORT_CTRL`.
    pub fn vsock_handler(&self) -> HostServiceHandler {
        let inner = self.inner.clone();
        let budget_cmd = format!("SHUTDOWN_BUDGET {}\n", self.shutdown_budget.as_millis());
        Arc::new(move |mut stream: UnixStream| {
            if stream
                .set_write_timeout(Some(Duration::from_millis(500)))
                .is_err()
            {
                return;
            }
            let _ = stream.set_read_timeout(None);

            // Sync guest wall clock immediately on connect (cold boot or snapshot restore).
            let now_sys = SystemTime::now();
            let now_secs = now_sys
                .duration_since(UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let mut synced_initial = false;
            if let Some(cmd) = format_clock_cmd(now_sys) {
                if !write_cmd(&mut stream, &cmd) {
                    return;
                }
                synced_initial = true;
            }
            // Older guests ignore the unknown command and keep their fixed timings.
            if !write_cmd(&mut stream, &budget_cmd) {
                return;
            }

            let Ok(mut writer) = stream.try_clone() else {
                return;
            };
            if writer
                .set_write_timeout(Some(Duration::from_millis(500)))
                .is_err()
            {
                return;
            }

            let my_gen = {
                let mut g = inner.lock().unwrap();
                let conn_gen = g.next_gen;
                g.next_gen = g.next_gen.wrapping_add(1).max(1);
                if synced_initial {
                    g.clock_sync_count += 1;
                    g.last_clock_sync_unix_secs = now_secs;
                }
                if g.poweroff_requested {
                    let _ = write_cmd(&mut writer, "POWEROFF\n");
                }
                g.active = Some((conn_gen, writer));
                conn_gen
            };

            // Park at 0% CPU until the guest closes or resets the control stream.
            let mut buf = [0u8; 256];
            loop {
                match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }

            let mut g = inner.lock().unwrap();
            if g.active
                .as_ref()
                .is_some_and(|(conn_gen, _)| *conn_gen == my_gen)
            {
                g.active = None;
            }
        })
    }
}

impl Default for GuestControl {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::thread;

    #[test]
    fn guest_control_sends_initial_clock_resync_and_poweroff() {
        let ctrl = GuestControl::new();
        assert!(!ctrl.is_connected());
        assert!(!ctrl.request_poweroff());

        // Reset via a fresh GuestControl to test connected flow
        let ctrl = GuestControl::new();
        let handler = ctrl.vsock_handler();
        let (host_end, guest_end) = UnixStream::pair().unwrap();
        let _ = guest_end.set_read_timeout(Some(Duration::from_secs(2)));
        let t = thread::spawn(move || handler(host_end));

        let mut reader = BufReader::new(guest_end);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert!(
            line.starts_with("CLOCK "),
            "expected initial CLOCK, got {line:?}"
        );
        let ns: i64 = line.trim().strip_prefix("CLOCK ").unwrap().parse().unwrap();
        assert!(ns >= (MIN_UNIX_SECS as i64) * 1_000_000_000);
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line, "SHUTDOWN_BUDGET 9000\n");

        // Wait briefly for handler to register active stream
        for _ in 0..50 {
            if ctrl.is_connected() {
                break;
            }
            thread::sleep(Duration::from_millis(2));
        }
        assert!(ctrl.is_connected());

        let t_sync = UNIX_EPOCH + Duration::new(1_800_000_000, 987_654_321);
        assert!(ctrl.send_clock_sync(t_sync));
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line, "CLOCK 1800000000987654321\n");

        assert!(ctrl.request_poweroff());
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert_eq!(line, "POWEROFF\n");

        drop(reader);
        t.join().unwrap();
        assert!(!ctrl.is_connected());
    }

    #[test]
    fn guest_control_delivers_pending_poweroff_on_connect() {
        let ctrl = GuestControl::with_shutdown_budget(Duration::from_millis(2500));
        assert!(!ctrl.request_poweroff());

        let handler = ctrl.vsock_handler();
        let (host_end, guest_end) = UnixStream::pair().unwrap();
        let _ = guest_end.set_read_timeout(Some(Duration::from_secs(2)));
        let t = thread::spawn(move || handler(host_end));

        let mut reader = BufReader::new(guest_end);
        let mut lines = [String::new(), String::new(), String::new()];
        for line in &mut lines {
            reader.read_line(line).unwrap();
        }
        assert!(lines[0].starts_with("CLOCK "));
        assert_eq!(lines[1], "SHUTDOWN_BUDGET 2500\n");
        assert_eq!(lines[2], "POWEROFF\n");

        drop(reader);
        t.join().unwrap();
    }

    #[test]
    fn guest_shutdown_budget_keeps_a_margin_for_the_host() {
        assert_eq!(
            guest_shutdown_budget(Duration::from_secs(10)),
            Duration::from_secs(9)
        );
        assert_eq!(
            guest_shutdown_budget(Duration::from_secs(1)),
            Duration::from_secs(1)
        );
        assert_eq!(
            guest_shutdown_budget(Duration::ZERO),
            Duration::from_secs(1)
        );
    }

    #[test]
    fn clock_jump_detector_catches_sleep_wake_and_ntp_steps() {
        let base = 1_770_000_000_000_000_000i64;
        let threshold = 500_000_000i64; // 500 ms
        // Normal 1s tick with 2ms jitter -> no sync needed
        assert!(!clock_jump_exceeds_threshold(
            base,
            base + 1_002_000_000,
            1_000_000_000,
            threshold
        ));
        // Mac lid sleep for 2 hours (wall jumps +7200s, monotonic advances 1s) -> sync!
        assert!(clock_jump_exceeds_threshold(
            base,
            base + 7_201_000_000_000,
            1_000_000_000,
            threshold
        ));
        // NTP backward step of 5 seconds -> sync!
        assert!(clock_jump_exceeds_threshold(
            base,
            base - 4_000_000_000,
            1_000_000_000,
            threshold
        ));
    }
}
