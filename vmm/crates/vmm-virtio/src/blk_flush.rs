//! How a block device puts a guest's flush on the host disk (`--disk-flush`).
//!
//! The guest's ext4 journal orders its writes with flushes: a commit block is
//! written only after a flush (REQ_PREFLUSH) and is itself followed by one
//! (the FUA the device does not offer). Those flushes are what the shared
//! caches' crash fence and guest init's clean-stop record rely on. On macOS
//! fsync(2) only hands the data to the drive, whose cache may persist it in
//! any order or not at all when the power goes, so after a host crash or a
//! power loss the journal could hold a commit whose blocks never arrived.
//! F_BARRIERFSYNC adds a barrier the drive honours (Apple SSDs implement it):
//! everything written before it persists before anything written after it,
//! which is what a journal needs, at a fraction of F_FULLFSYNC's cost.

use std::io;
use std::os::fd::RawFd;
use std::str::FromStr;
use std::sync::atomic::{AtomicU8, Ordering};

/// The host sync a device runs for a guest's VIRTIO_BLK_T_FLUSH and for its
/// own flushes (snapshot pause, exit).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DiskFlush {
    /// `fcntl(F_BARRIERFSYNC)`: fsync, then a write barrier on the drive.
    /// Writes before a flush reach stable storage before any write after it,
    /// so the guest's journal survives a host crash or power loss in order;
    /// the last flushes before a power loss may be lost.
    #[default]
    Barrier,
    /// `fcntl(F_FULLFSYNC)`: fsync, then the drive empties its cache: ordered
    /// and durable when the flush completes. Several times the cost.
    Full,
    /// `fsync(2)`: the data reaches the drive, not necessarily its stable
    /// storage, in no guaranteed order. Survives the VMM's own crash only.
    Fsync,
}

impl DiskFlush {
    /// The spellings `--disk-flush` accepts.
    pub const CHOICES: &'static str = "barrier|full|fsync";

    pub fn name(self) -> &'static str {
        match self {
            DiskFlush::Barrier => "barrier",
            DiskFlush::Full => "full",
            DiskFlush::Fsync => "fsync",
        }
    }

    /// The sync used instead when the disk's filesystem does not support
    /// this one (network and other non-APFS/HFS filesystems refuse the
    /// fcntls): a barrier becomes a full sync, which also orders, and a full
    /// sync becomes fsync, the only one left.
    fn fallback(self) -> Option<DiskFlush> {
        match self {
            DiskFlush::Barrier => Some(DiskFlush::Full),
            DiskFlush::Full => Some(DiskFlush::Fsync),
            DiskFlush::Fsync => None,
        }
    }

    fn from_u8(v: u8) -> DiskFlush {
        match v {
            0 => DiskFlush::Barrier,
            1 => DiskFlush::Full,
            _ => DiskFlush::Fsync,
        }
    }

    fn to_u8(self) -> u8 {
        match self {
            DiskFlush::Barrier => 0,
            DiskFlush::Full => 1,
            DiskFlush::Fsync => 2,
        }
    }
}

impl FromStr for DiskFlush {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "barrier" => Ok(DiskFlush::Barrier),
            "full" => Ok(DiskFlush::Full),
            "fsync" => Ok(DiskFlush::Fsync),
            _ => Err(format!(
                "invalid disk flush mode {s:?} (want {})",
                DiskFlush::CHOICES
            )),
        }
    }
}

/// One host sync of `fd` in `mode`.
pub(crate) type SyncFn = fn(RawFd, DiskFlush) -> io::Result<()>;

/// A device's flush mode. It steps down to the next mode (`fallback`) the
/// first time the disk's filesystem reports the current one unsupported and
/// stays there, so an unsupported fcntl is tried once, not on every flush.
pub(crate) struct FlushPolicy {
    mode: AtomicU8,
    sync: SyncFn,
}

impl FlushPolicy {
    pub(crate) fn new(mode: DiskFlush) -> Self {
        Self::with_sync(mode, host_sync)
    }

    pub(crate) fn with_sync(mode: DiskFlush, sync: SyncFn) -> Self {
        Self {
            mode: AtomicU8::new(mode.to_u8()),
            sync,
        }
    }

    /// The mode the next flush starts with.
    pub(crate) fn mode(&self) -> DiskFlush {
        DiskFlush::from_u8(self.mode.load(Ordering::Relaxed))
    }

    /// Sync `fd`. An unsupported mode is replaced by its fallback for this
    /// and every later flush; any other error fails this flush (the guest
    /// sees VIRTIO_BLK_S_IOERR) and keeps the mode.
    pub(crate) fn flush(&self, fd: RawFd) -> io::Result<()> {
        let mut mode = self.mode();
        loop {
            match (self.sync)(fd, mode) {
                Ok(()) => return Ok(()),
                Err(e) if unsupported(&e) => {
                    let Some(next) = mode.fallback() else {
                        return Err(e);
                    };
                    eprintln!(
                        "[micropod-vmm] disk flush {}: not supported by this disk's filesystem ({e}); using {}",
                        mode.name(),
                        next.name()
                    );
                    self.mode.store(next.to_u8(), Ordering::Relaxed);
                    mode = next;
                }
                Err(e) => return Err(e),
            }
        }
    }
}

/// The errors a filesystem answers a sync fcntl it does not implement with
/// (SMB and NFS: ENOTSUP; others EINVAL or ENOTTY).
fn unsupported(e: &io::Error) -> bool {
    e.raw_os_error().is_some_and(|errno| {
        [
            libc::ENOTSUP,
            libc::EOPNOTSUPP,
            libc::EINVAL,
            libc::ENOTTY,
            libc::ENOSYS,
        ]
        .contains(&errno)
    })
}

#[cfg(target_vendor = "apple")]
fn host_sync(fd: RawFd, mode: DiskFlush) -> io::Result<()> {
    loop {
        let rc = unsafe {
            match mode {
                DiskFlush::Barrier => libc::fcntl(fd, libc::F_BARRIERFSYNC),
                DiskFlush::Full => libc::fcntl(fd, libc::F_FULLFSYNC),
                DiskFlush::Fsync => libc::fsync(fd),
            }
        };
        if rc != -1 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.kind() != io::ErrorKind::Interrupted {
            return Err(err);
        }
    }
}

/// Elsewhere fsync(2) itself flushes the drive's cache; there is no cheaper
/// ordering-only sync, so every mode is fsync.
#[cfg(not(target_vendor = "apple"))]
fn host_sync(fd: RawFd, _mode: DiskFlush) -> io::Result<()> {
    loop {
        if unsafe { libc::fsync(fd) } != -1 {
            return Ok(());
        }
        let err = io::Error::last_os_error();
        if err.kind() != io::ErrorKind::Interrupted {
            return Err(err);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static CALLS: Mutex<Vec<(RawFd, DiskFlush)>> = Mutex::new(Vec::new());
    static GUARD: Mutex<()> = Mutex::new(());

    fn recorded() -> Vec<DiskFlush> {
        CALLS.lock().unwrap().drain(..).map(|(_, m)| m).collect()
    }

    #[test]
    fn modes_parse_and_default_to_barrier() {
        assert_eq!(DiskFlush::default(), DiskFlush::Barrier);
        for mode in [DiskFlush::Barrier, DiskFlush::Full, DiskFlush::Fsync] {
            assert_eq!(mode.name().parse::<DiskFlush>(), Ok(mode));
            assert_eq!(DiskFlush::from_u8(mode.to_u8()), mode);
        }
        for bad in ["", "Barrier", "fullfsync", "none", "barrier "] {
            assert!(bad.parse::<DiskFlush>().is_err(), "{bad:?}");
        }
    }

    #[test]
    fn an_unsupported_sync_steps_down_once_and_for_good() {
        let _g = GUARD.lock().unwrap();
        recorded();
        // The filesystem supports only fsync: barrier -> full -> fsync, then
        // every later flush goes straight to fsync.
        fn only_fsync(fd: RawFd, mode: DiskFlush) -> io::Result<()> {
            CALLS.lock().unwrap().push((fd, mode));
            match mode {
                DiskFlush::Fsync => Ok(()),
                DiskFlush::Barrier => Err(io::Error::from_raw_os_error(libc::ENOTSUP)),
                DiskFlush::Full => Err(io::Error::from_raw_os_error(libc::EINVAL)),
            }
        }
        let p = FlushPolicy::with_sync(DiskFlush::Barrier, only_fsync);
        p.flush(7).unwrap();
        assert_eq!(
            recorded(),
            [DiskFlush::Barrier, DiskFlush::Full, DiskFlush::Fsync]
        );
        assert_eq!(p.mode(), DiskFlush::Fsync);
        p.flush(7).unwrap();
        assert_eq!(recorded(), [DiskFlush::Fsync]);

        // Full sync is supported: a barrier steps down to it, not past it.
        fn no_barrier(fd: RawFd, mode: DiskFlush) -> io::Result<()> {
            CALLS.lock().unwrap().push((fd, mode));
            match mode {
                DiskFlush::Barrier => Err(io::Error::from_raw_os_error(libc::ENOTTY)),
                _ => Ok(()),
            }
        }
        let p = FlushPolicy::with_sync(DiskFlush::Barrier, no_barrier);
        p.flush(7).unwrap();
        p.flush(7).unwrap();
        assert_eq!(
            recorded(),
            [DiskFlush::Barrier, DiskFlush::Full, DiskFlush::Full]
        );
    }

    #[test]
    fn a_failed_sync_fails_the_flush_and_keeps_the_mode() {
        let _g = GUARD.lock().unwrap();
        recorded();
        fn eio(fd: RawFd, mode: DiskFlush) -> io::Result<()> {
            CALLS.lock().unwrap().push((fd, mode));
            Err(io::Error::from_raw_os_error(libc::EIO))
        }
        let p = FlushPolicy::with_sync(DiskFlush::Barrier, eio);
        assert_eq!(p.flush(7).unwrap_err().raw_os_error(), Some(libc::EIO));
        assert_eq!(recorded(), [DiskFlush::Barrier]);
        assert_eq!(p.mode(), DiskFlush::Barrier);

        // Nothing is left to step down to from fsync.
        fn unsupported_everywhere(fd: RawFd, mode: DiskFlush) -> io::Result<()> {
            CALLS.lock().unwrap().push((fd, mode));
            Err(io::Error::from_raw_os_error(libc::ENOTSUP))
        }
        let p = FlushPolicy::with_sync(DiskFlush::Fsync, unsupported_everywhere);
        assert!(p.flush(7).is_err());
        assert_eq!(recorded(), [DiskFlush::Fsync]);
    }

    /// The real syscalls on the test's own APFS temp directory: every mode is
    /// supported there, so none steps down.
    #[test]
    fn every_mode_syncs_an_apfs_file() {
        use std::os::fd::AsRawFd;
        let path = std::env::temp_dir().join(format!("mp-blk-flush-{}.img", std::process::id()));
        let f = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let _ = std::fs::remove_file(&path);
        for mode in [DiskFlush::Barrier, DiskFlush::Full, DiskFlush::Fsync] {
            let p = FlushPolicy::new(mode);
            p.flush(f.as_raw_fd()).unwrap();
            assert_eq!(p.mode(), mode);
        }
    }
}
