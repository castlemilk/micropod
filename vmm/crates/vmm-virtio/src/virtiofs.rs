//! Virtio-FS (Device ID 26) FUSE 7.31+ host directory share device.
//! Mounts macOS host directories directly inside Linux via `mount -t virtiofs <tag> <dst>`.
//!
//! Containment: the guest is untrusted, and a writable share is often the
//! user's home directory. A node is an entry name in a parent node, never a
//! host path. Every host access is a single-entry `*at` call (`AT_SYMLINK_NOFOLLOW`
//! or `O_NOFOLLOW`) on a directory descriptor opened from the share root through
//! the node's entry names with `O_NOFOLLOW_ANY` (one entry at a time with
//! `O_NOFOLLOW` elsewhere), and checked against the host (dev, ino) the node is
//! bound to. Names are single components other than `.` and `..`. A symlink the
//! guest plants therefore never redirects a request, a renamed directory takes
//! its subtree with it, and a node whose directory cannot be reached that way
//! (or that the host moved out of the share) fails with ESTALE instead of being
//! looked up by path.
//!
//! One host entry has one node however the guest spells its name (case and
//! Unicode normalisation on the Mac's default volume); guest ownership belongs
//! to the host file, so every name of it agrees (see [`GuestAttr`]). Host opens
//! never block (a FIFO is refused, not waited on), and what a guest can make
//! the VMM hold is bounded: nodes it forgets are freed, and nodes, owner pins,
//! open handles, listings, read-only caches and request sizes have limits.
//!
//! Phase B5 optimizations:
//! - Inline synchronous VirtQueue dispatch on `QueueNotify` (eliminates cross-thread
//!   `Condvar` + HVF `WFI` sleep/wake latency on synchronous FUSE RPCs!).
//! - Per-directory `O_DIRECTORY` `dirfd` cache + `*at` syscalls (`fstatat`, `openat`,
//!   `mkdirat`, `unlinkat`, `renameat`, `symlinkat`, `linkat`) avoiding full-path APFS walks.
//! - Darwin `getattrlistbulk(2)` single-syscall bulk directory + metadata listing for
//!   `FUSE_READDIRPLUS` / `FUSE_READDIR`.
//! - Zero-copy `preadv`/`pwritev` directly into/from `GuestMemory` descriptors + reusable
//!   response scratch buffer (zero heap allocations on hot paths).

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::io::ErrorKind;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use crate::{DescBuf, GuestMemory, IrqLine, VirtQueue, VirtioBackend, scatter_writable};

// FUSE opcodes (Linux include/uapi/linux/fuse.h)
const FUSE_LOOKUP: u32 = 1;
const FUSE_FORGET: u32 = 2;
const FUSE_GETATTR: u32 = 3;
const FUSE_SETATTR: u32 = 4;
const FUSE_READLINK: u32 = 5;
const FUSE_SYMLINK: u32 = 6;
const FUSE_MKDIR: u32 = 9;
const FUSE_UNLINK: u32 = 10;
const FUSE_RMDIR: u32 = 11;
const FUSE_RENAME: u32 = 12;
const FUSE_LINK: u32 = 13;
const FUSE_OPEN: u32 = 14;
const FUSE_READ: u32 = 15;
const FUSE_WRITE: u32 = 16;
const FUSE_STATFS: u32 = 17;
const FUSE_RELEASE: u32 = 18;
const FUSE_FSYNC: u32 = 20;
const FUSE_GETXATTR: u32 = 22;
const FUSE_LISTXATTR: u32 = 23;
const FUSE_FLUSH: u32 = 25;
const FUSE_INIT: u32 = 26;
const FUSE_OPENDIR: u32 = 27;
const FUSE_READDIR: u32 = 28;
const FUSE_RELEASEDIR: u32 = 29;
const FUSE_FSYNCDIR: u32 = 30;
const FUSE_ACCESS: u32 = 34;
const FUSE_CREATE: u32 = 35;
const FUSE_DESTROY: u32 = 38;
const FUSE_BATCH_FORGET: u32 = 42;
const FUSE_READDIRPLUS: u32 = 44;
const FUSE_RENAME2: u32 = 45;
const FUSE_LSEEK: u32 = 46;
const FUSE_STATX: u32 = 52;

const FUSE_ASYNC_READ: u32 = 1 << 0;
const FUSE_ATOMIC_O_TRUNC: u32 = 1 << 3;
const FUSE_BIG_WRITES: u32 = 1 << 5;
const FUSE_AUTO_INVAL_DATA: u32 = 1 << 12;
const FUSE_DO_READDIRPLUS: u32 = 1 << 13;
const FUSE_NO_OPEN_SUPPORT: u32 = 1 << 17;
const FUSE_PARALLEL_DIROPS: u32 = 1 << 18;
const FUSE_MAX_PAGES: u32 = 1 << 22;
const FUSE_CACHE_SYMLINKS: u32 = 1 << 23;
const FUSE_INIT_EXT: u32 = 1 << 30;
const FUSE_DIRECT_IO_ALLOW_MMAP_FLAGS2: u32 = 1 << (36 - 32);
const FUSE_DIRECT_IO_MMAP_MINOR: u32 = 39;

// FUSE open_flags (Linux include/uapi/linux/fuse.h)
const FOPEN_DIRECT_IO: u32 = 1 << 0;
const FOPEN_KEEP_CACHE: u32 = 1 << 1;
const FOPEN_CACHE_DIR: u32 = 1 << 3;
const FOPEN_NOFLUSH: u32 = 1 << 5;
const FUSE_FSYNC_FDATASYNC: u32 = 1;

const FATTR_MODE: u32 = 1 << 0;
const FATTR_UID: u32 = 1 << 1;
const FATTR_GID: u32 = 1 << 2;
const FATTR_SIZE: u32 = 1 << 3;
const FATTR_ATIME: u32 = 1 << 4;
const FATTR_MTIME: u32 = 1 << 5;
const FATTR_FH: u32 = 1 << 6;
const FATTR_ATIME_NOW: u32 = 1 << 7;
const FATTR_MTIME_NOW: u32 = 1 << 8;

const FUSE_ROOT_ID: u64 = 1;

// Linux errno values (arm64 generic)
const LINUX_EPERM: i32 = 1;
const LINUX_ENOENT: i32 = 2;
const LINUX_EINTR: i32 = 4;
const LINUX_EIO: i32 = 5;
const LINUX_ENXIO: i32 = 6;
const LINUX_EBADF: i32 = 9;
const LINUX_EACCES: i32 = 13;
const LINUX_EEXIST: i32 = 17;
const LINUX_ENODEV: i32 = 19;
const LINUX_ENOTDIR: i32 = 20;
const LINUX_EISDIR: i32 = 21;
const LINUX_EINVAL: i32 = 22;
const LINUX_ENFILE: i32 = 23;
const LINUX_EMFILE: i32 = 24;
const LINUX_ENOTTY: i32 = 25;
const LINUX_EFBIG: i32 = 27;
const LINUX_ENOSPC: i32 = 28;
const LINUX_EROFS: i32 = 30;
const LINUX_ENAMETOOLONG: i32 = 36;
const LINUX_ENOSYS: i32 = 38;
const LINUX_ENOTEMPTY: i32 = 39;
const LINUX_ELOOP: i32 = 40;
const LINUX_ENODATA: i32 = 61;
const LINUX_EOPNOTSUPP: i32 = 95;
const LINUX_ETIMEDOUT: i32 = 110;
const LINUX_ESTALE: i32 = 116;
const LINUX_EDQUOT: i32 = 122;
const FUSE_GETATTR_FH: u32 = 1;

/// `fchmodat` flag for the entry itself: Darwin changes a symlink's own mode,
/// other hosts follow it (the guest never sends a mode change for a symlink).
#[cfg(target_vendor = "apple")]
const AT_NOFOLLOW_MODE: i32 = libc::AT_SYMLINK_NOFOLLOW;
#[cfg(not(target_vendor = "apple"))]
const AT_NOFOLLOW_MODE: i32 = 0;

fn check_rc(rc: libc::c_int) -> Result<(), i32> {
    if rc == 0 {
        Ok(())
    } else {
        Err(last_os_errno_linux())
    }
}

const MAX_CACHED_DIR_FDS: usize = 512;

/// Most nodes one share holds. The guest's FORGETs keep the table to what its
/// inode cache references; this bounds a guest kernel that never forgets
/// (a lookup that would bind beyond it fails with ENFILE).
const MAX_NODES: usize = 1 << 20;
/// Most host files guest `chown`s may pin an owner on, per share (beyond it
/// a `chown` that would add one fails with ENOSPC).
const MAX_OWNER_PINS: usize = 1 << 20;
/// Most entries each read-only lookup and attribute cache keeps.
const MAX_RO_CACHE: usize = 16 * 1024;
/// Most open file and directory handles per share (also at most a quarter of
/// the descriptors the process may open; see [`handle_limit`]). Beyond it
/// OPEN, CREATE and OPENDIR fail with ENFILE.
const MAX_OPEN_HANDLES: usize = 16 * 1024;
/// Most open directory handles per share; each holds part of a listing.
const MAX_OPEN_DIRS: usize = 1024;
/// Largest FUSE request accepted: `max_write` plus headers, with room to spare.
const MAX_FUSE_REQUEST: usize = 1024 * 1024 + 4096;
/// Attribute buffer for one `getattrlistbulk` call while a listing streams.
const DIR_CHUNK_BYTES: usize = 16 * 1024;
/// Entries `readdir(3)` reads per refill when `getattrlistbulk` is unavailable.
const DIR_CHUNK_ENTRIES: usize = 128;
/// Entries a directory handle keeps after a reply, for a guest that resumes
/// a little before where the reply ended (its buffer held fewer entries).
const DIR_RETAIN: usize = 128;
/// A cached directory descriptor is checked to still lie inside the share at
/// most this often (the guest's own attribute validity on writable shares).
const DIR_FD_RECHECK_MS: u64 = 20;

// Writable shares may be changed by a host editor while a guest file is open.
// 20ms metadata validity keeps host-edit visibility ~3.5x faster than OrbStack (~91ms)
// and ~40x faster than Apple VZ (~1004ms) while preventing mid-scan dentry thrashing.
const RW_VALIDITY: (u64, u32) = (0, 20_000_000);

/// How long anything a read-only share reports stays valid, in the guest and
/// in this server's read-only caches alike. The guest cannot change such a
/// share, but the host can: it may atomically replace a file (write a
/// temporary file, rename it over the old name), and the guest must see the
/// new file within this long without a remount. A replaced name binds a new
/// node, so the guest never mixes the old file's cached pages with the new
/// file's attributes.
const RO_VALIDITY_MS: u64 = 1000;

/// Entry and attribute validity for a reply built from what the host reported
/// `age_ms` ago, as (seconds, nanoseconds), or None once it has run out: a
/// cached read-only reply only carries what is left of the validity of the
/// host answer it repeats, so caching never extends how long the guest may
/// see a file the host has since replaced.
fn validity_left(validity_ms: u64, age_ms: u64) -> Option<(u64, u32)> {
    let left = validity_ms.checked_sub(age_ms).filter(|&ms| ms > 0)?;
    Some((left / 1000, ((left % 1000) * 1_000_000) as u32))
}

/// Compact POSIX stat snapshot populated from `fstatat`/`fstat`/`getattrlistbulk`.
#[derive(Clone, Copy, Debug)]
struct FuseStat {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    size: u64,
    blocks: u64,
    atime: i64,
    atime_nsec: i64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
    rdev: u64,
}

impl FuseStat {
    fn from_libc(st: &libc::stat) -> Self {
        Self {
            dev: st.st_dev as u64,
            ino: st.st_ino,
            mode: st.st_mode as u32,
            nlink: st.st_nlink as u32,
            size: st.st_size.max(0) as u64,
            blocks: st.st_blocks.max(0) as u64,
            atime: st.st_atime,
            atime_nsec: st.st_atime_nsec,
            mtime: st.st_mtime,
            mtime_nsec: st.st_mtime_nsec,
            ctime: st.st_ctime,
            ctime_nsec: st.st_ctime_nsec,
            rdev: st.st_rdev as u64,
        }
    }

    #[inline]
    fn dtype(&self) -> u32 {
        (self.mode >> 12) & 0xf
    }
}

struct OpenFile {
    nodeid: u64,
    file: Arc<File>,
    /// Host (dev, ino) of the open file.
    identity: (u64, u64),
}

#[derive(Clone)]
struct BulkDirEntry {
    /// The entry's name as the host stores it.
    name: CString,
    stat: FuseStat,
    /// A directory another file system is mounted on: the listing's identity
    /// is the covered directory, not the mounted root a lookup reaches.
    mount_point: bool,
}

struct OpenDir {
    dir_nodeid: u64,
    dir_fd: OwnedFd,
    listing: DirListing,
}

/// One OPENDIR handle's pass over its directory, read from the host a chunk
/// at a time as the guest asks for entries, never held whole: a handle keeps
/// at most a chunk it has not sent plus [`DIR_RETAIN`] entries it has.
/// Offsets are entry indexes within the pass; offset 0, or one before what the
/// handle still holds, starts a new pass.
#[derive(Default)]
struct DirListing {
    /// Index within the pass of `window[0]`.
    base: usize,
    window: VecDeque<BulkDirEntry>,
    /// The pass has read the whole directory.
    eof: bool,
    /// A pass is under way.
    started: bool,
    /// `readdir(3)` stream, used where `getattrlistbulk` is unavailable.
    stream: Option<DirStream>,
}

/// A `readdir(3)` stream over a duplicate of an open directory descriptor.
struct DirStream(NonNull<libc::DIR>);

// SAFETY: the stream is only used under the FsCore mutex, by one thread at a time.
unsafe impl Send for DirStream {}

impl DirStream {
    fn open(dir_fd: RawFd) -> Result<Self, i32> {
        let dup = unsafe { libc::fcntl(dir_fd, libc::F_DUPFD_CLOEXEC, 0) };
        if dup < 0 {
            return Err(last_os_errno_linux());
        }
        match NonNull::new(unsafe { libc::fdopendir(dup) }) {
            Some(dirp) => {
                unsafe { libc::rewinddir(dirp.as_ptr()) };
                Ok(Self(dirp))
            }
            None => {
                let errno = last_os_errno_linux();
                unsafe { libc::close(dup) };
                Err(errno)
            }
        }
    }
}

impl Drop for DirStream {
    fn drop(&mut self) {
        unsafe { libc::closedir(self.0.as_ptr()) };
    }
}

impl DirListing {
    /// Start a new pass at the first entry.
    fn rewind(&mut self, dir_fd: RawFd) {
        self.base = 0;
        self.window.clear();
        self.eof = false;
        self.started = true;
        match &self.stream {
            Some(stream) => unsafe { libc::rewinddir(stream.0.as_ptr()) },
            None => {
                unsafe { libc::lseek(dir_fd, 0, libc::SEEK_SET) };
            }
        }
    }

    /// Read the next chunk of entries into the window (or reach the end).
    fn fill(&mut self, dir_fd: RawFd, buf: &mut Vec<u8>) -> Result<(), i32> {
        #[cfg(target_vendor = "apple")]
        if self.stream.is_none() {
            match darwin_bulk::read_dir_chunk(dir_fd, buf, &mut self.window) {
                Ok(0) => self.eof = true,
                Ok(_) => {}
                // A file system without getattrlistbulk: list it with readdir(3).
                Err(_) if self.base == 0 && self.window.is_empty() => {
                    self.stream = Some(DirStream::open(dir_fd)?);
                }
                Err(e) => return Err(e),
            }
            if self.stream.is_none() {
                return Ok(());
            }
        }
        #[cfg(not(target_vendor = "apple"))]
        let _ = buf;
        if self.stream.is_none() {
            self.stream = Some(DirStream::open(dir_fd)?);
        }
        let dirp = self.stream.as_ref().map(|s| s.0.as_ptr()).unwrap();
        for _ in 0..DIR_CHUNK_ENTRIES {
            let ent = unsafe { libc::readdir(dirp) };
            if ent.is_null() {
                self.eof = true;
                break;
            }
            let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
            if matches!(name.to_bytes(), b"." | b"..") {
                continue;
            }
            if let Ok(stat) = fstatat_cstr(dir_fd, name) {
                self.window.push_back(BulkDirEntry {
                    name: name.to_owned(),
                    stat,
                    mount_point: false,
                });
            }
        }
        Ok(())
    }
}

/// What one share may hold (fields so tests can lower them).
struct Limits {
    nodes: usize,
    pins: usize,
    /// Open file and directory handles together (see [`handle_limit`]).
    handles: usize,
    dirs: usize,
}

impl Limits {
    fn new() -> Self {
        let handles = handle_limit();
        Self {
            nodes: MAX_NODES,
            pins: MAX_OWNER_PINS,
            handles,
            dirs: MAX_OPEN_DIRS.min(handles),
        }
    }
}

/// A cached directory descriptor and when it was last found inside the share.
struct CachedDir {
    fd: Arc<OwnedFd>,
    checked_ms: u64,
}

fn raw_os_err_to_linux(raw: i32) -> i32 {
    match raw {
        libc::EPERM => LINUX_EPERM,
        libc::ENOENT => LINUX_ENOENT,
        libc::EINTR => LINUX_EINTR,
        libc::ENXIO => LINUX_ENXIO,
        libc::EBADF => LINUX_EBADF,
        libc::EACCES => LINUX_EACCES,
        libc::EEXIST => LINUX_EEXIST,
        libc::ENODEV => LINUX_ENODEV,
        libc::ENOTDIR => LINUX_ENOTDIR,
        libc::EISDIR => LINUX_EISDIR,
        libc::EINVAL => LINUX_EINVAL,
        libc::ENFILE => LINUX_ENFILE,
        libc::EMFILE => LINUX_EMFILE,
        libc::ENOTTY => LINUX_ENOTTY,
        libc::EFBIG => LINUX_EFBIG,
        libc::ENOSPC => LINUX_ENOSPC,
        libc::EROFS => LINUX_EROFS,
        libc::ENAMETOOLONG => LINUX_ENAMETOOLONG,
        libc::ENOTEMPTY => LINUX_ENOTEMPTY,
        libc::ELOOP => LINUX_ELOOP,
        libc::ENOSYS => LINUX_ENOSYS,
        libc::ENODATA => LINUX_ENODATA,
        libc::ETIMEDOUT => LINUX_ETIMEDOUT,
        libc::ESTALE => LINUX_ESTALE,
        libc::EDQUOT => LINUX_EDQUOT,
        raw if raw == libc::ENOTSUP || raw == libc::EOPNOTSUPP => LINUX_EOPNOTSUPP,
        _ => LINUX_EIO,
    }
}

fn last_os_errno_linux() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .map(raw_os_err_to_linux)
        .unwrap_or(LINUX_EIO)
}

fn io_err_to_linux(e: &std::io::Error) -> i32 {
    if let Some(raw) = e.raw_os_error() {
        return raw_os_err_to_linux(raw);
    }
    match e.kind() {
        ErrorKind::NotFound => LINUX_ENOENT,
        ErrorKind::PermissionDenied => LINUX_EACCES,
        ErrorKind::AlreadyExists => LINUX_EEXIST,
        ErrorKind::InvalidInput => LINUX_EINVAL,
        _ => LINUX_EIO,
    }
}

fn sync_host_fd(fd: RawFd, data_only: bool) -> Result<(), i32> {
    #[cfg(target_vendor = "apple")]
    let result = {
        // Darwin uses the same full sync for both kinds of explicit request.
        // File providers without a device-barrier operation can still support fsync.
        let _ = data_only;
        if unsafe { libc::fcntl(fd, libc::F_FULLFSYNC) } == 0 {
            return Ok(());
        }
        match last_os_errno_linux() {
            LINUX_EINVAL | LINUX_ENOTTY | LINUX_EOPNOTSUPP | LINUX_ENOSYS => unsafe {
                libc::fsync(fd)
            },
            errno => return Err(errno),
        }
    };
    #[cfg(not(target_vendor = "apple"))]
    let result = unsafe {
        if data_only {
            libc::fdatasync(fd)
        } else {
            libc::fsync(fd)
        }
    };
    if result == 0 {
        Ok(())
    } else {
        Err(last_os_errno_linux())
    }
}

#[cfg(test)]
fn path_to_cstr(p: &Path) -> Result<CString, i32> {
    CString::new(p.as_os_str().as_bytes()).map_err(|_| LINUX_EINVAL)
}

fn name_to_cstr(name: &[u8]) -> Result<CString, i32> {
    if name.is_empty() || name.contains(&b'/') || name.contains(&0) {
        return Err(LINUX_EINVAL);
    }
    CString::new(name).map_err(|_| LINUX_EINVAL)
}

fn fstat_fd(fd: RawFd) -> Result<FuseStat, i32> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } == 0 {
        Ok(FuseStat::from_libc(&st))
    } else {
        Err(last_os_errno_linux())
    }
}

fn fstatat_cstr(dirfd: RawFd, name: &CStr) -> Result<FuseStat, i32> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(dirfd, name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } == 0 {
        Ok(FuseStat::from_libc(&st))
    } else {
        Err(last_os_errno_linux())
    }
}

// ============================================================================
// Darwin getattrlistbulk(2): single-syscall directory listing + full stat metadata
// ============================================================================
#[cfg(target_vendor = "apple")]
mod darwin_bulk {
    use super::*;

    const ATTR_BIT_MAP_COUNT: u16 = 5;
    const ATTR_CMN_NAME: u32 = 0x0000_0001;
    const ATTR_CMN_DEVID: u32 = 0x0000_0002;
    const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
    const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
    const ATTR_CMN_CHGTIME: u32 = 0x0000_0800;
    const ATTR_CMN_ACCTIME: u32 = 0x0000_1000;
    const ATTR_CMN_ACCESSMASK: u32 = 0x0002_0000;
    const ATTR_CMN_FILEID: u32 = 0x0200_0000;
    const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;

    const ATTR_DIR_LINKCOUNT: u32 = 0x0000_0001;
    const ATTR_DIR_MOUNTSTATUS: u32 = 0x0000_0004;
    const DIR_MNTSTATUS_MNTPOINT: u32 = 0x0000_0001;

    const FSOPT_NOFOLLOW: u64 = 0x0000_0001;

    const ATTR_FILE_LINKCOUNT: u32 = 0x0000_0001;
    const ATTR_FILE_TOTALSIZE: u32 = 0x0000_0002;
    const ATTR_FILE_ALLOCSIZE: u32 = 0x0000_0004;
    const ATTR_FILE_DEVTYPE: u32 = 0x0000_0020;

    #[repr(C)]
    struct AttrList {
        bitmapcount: u16,
        reserved: u16,
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct AttributeSet {
        commonattr: u32,
        volattr: u32,
        dirattr: u32,
        fileattr: u32,
        forkattr: u32,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct AttrReference {
        dataoffset: i32,
        length: u32,
    }

    unsafe extern "C" {
        fn getattrlistbulk(
            dirfd: libc::c_int,
            attr_list: *mut AttrList,
            attr_buf: *mut libc::c_void,
            attr_buf_size: libc::size_t,
            options: u64,
        ) -> libc::c_int;
        fn getattrlistat(
            dirfd: libc::c_int,
            path: *const libc::c_char,
            attr_list: *mut AttrList,
            attr_buf: *mut libc::c_void,
            attr_buf_size: libc::size_t,
            options: libc::c_ulong,
        ) -> libc::c_int;
    }

    /// The name in an attribute record whose cursor `cur` is at its
    /// ATTR_CMN_NAME reference, advancing past the reference. The slice
    /// borrows the record's buffer, which the caller keeps alive (`'a`).
    unsafe fn record_name<'a>(cur: &mut *const u8, rec_end: *const u8) -> Option<&'a [u8]> {
        let field_start = *cur;
        let aref = unsafe { read_unaligned_adv::<AttrReference>(cur, rec_end) }?;
        if aref.dataoffset < 0 || aref.length == 0 {
            return None;
        }
        let str_ptr = unsafe { field_start.add(aref.dataoffset as usize) };
        if str_ptr as usize >= rec_end as usize {
            return None;
        }
        let max_len = (rec_end as usize) - (str_ptr as usize);
        let raw_len = (aref.length as usize).min(max_len);
        // SAFETY: within the record; the caller keeps the buffer alive while it uses the name.
        let slice = unsafe { std::slice::from_raw_parts(str_ptr, raw_len) };
        Some(match slice.iter().position(|&b| b == 0) {
            Some(z) => &slice[..z],
            None => slice,
        })
    }

    /// The name the entry `name` of `dirfd` is stored under when it differs
    /// from `name` (in case or Unicode normalisation, on a volume that ignores
    /// both) and the entry is still the file `st` describes.
    pub(super) fn stored_name(dirfd: RawFd, name: &CStr, st: &FuseStat) -> Option<CString> {
        match entry_stored(dirfd, name) {
            Ok((stored, identity)) if identity == (st.dev, st.ino) && stored.as_c_str() != name => {
                Some(stored)
            }
            _ => None,
        }
    }

    /// The name the host stores the entry `name` of `dirfd` under, and the
    /// (dev, ino) it is (not following a symlink).
    pub(super) fn entry_stored(dirfd: RawFd, name: &CStr) -> Result<(CString, (u64, u64)), i32> {
        let mut req = AttrList {
            bitmapcount: ATTR_BIT_MAP_COUNT,
            reserved: 0,
            commonattr: ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_FILEID,
            volattr: 0,
            dirattr: 0,
            fileattr: 0,
            forkattr: 0,
        };
        // A stored name is at most 255 UTF-16 units: 765 bytes of UTF-8.
        let mut buf = [0u8; 1024];
        let rc = unsafe {
            getattrlistat(
                dirfd,
                name.as_ptr(),
                &mut req,
                buf.as_mut_ptr().cast(),
                buf.len(),
                FSOPT_NOFOLLOW as libc::c_ulong,
            )
        };
        if rc != 0 {
            return Err(last_os_errno_linux());
        }
        let len = u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize;
        let end = unsafe { buf.as_ptr().add(len.min(buf.len())) };
        let mut cur = unsafe { buf.as_ptr().add(4) };
        let parsed = (|| {
            let ret = unsafe { read_unaligned_adv::<AttributeSet>(&mut cur, end) }?;
            let want = ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_FILEID;
            if ret.commonattr & want != want {
                return None;
            }
            let stored = unsafe { record_name(&mut cur, end) }?;
            let dev = unsafe { read_unaligned_adv::<i32>(&mut cur, end) }? as u64;
            let ino = unsafe { read_unaligned_adv::<u64>(&mut cur, end) }?;
            Some((CString::new(stored).ok()?, (dev, ino)))
        })();
        parsed.ok_or(LINUX_EIO)
    }

    #[inline]
    fn vtype_to_ifmt(objtype: u32) -> u32 {
        match objtype {
            1 => libc::S_IFREG as u32,  // VREG
            2 => libc::S_IFDIR as u32,  // VDIR
            3 => libc::S_IFBLK as u32,  // VBLK
            4 => libc::S_IFCHR as u32,  // VCHR
            5 => libc::S_IFLNK as u32,  // VLNK
            6 => libc::S_IFSOCK as u32, // VSOCK
            7 => libc::S_IFIFO as u32,  // VFIFO
            _ => libc::S_IFREG as u32,
        }
    }

    #[inline]
    unsafe fn read_unaligned_adv<T: Copy>(cursor: &mut *const u8, end: *const u8) -> Option<T> {
        let sz = std::mem::size_of::<T>();
        if (*cursor as usize).checked_add(sz)? > end as usize {
            return None;
        }
        let val = unsafe { std::ptr::read_unaligned((*cursor).cast::<T>()) };
        *cursor = unsafe { (*cursor).add(sz) };
        Some(val)
    }

    /// Every entry of a directory, from its first (tests compare the parser
    /// with `lstat`).
    #[cfg(test)]
    pub(super) fn read_dir_bulk(
        dir_fd: RawFd,
        buf: &mut Vec<u8>,
    ) -> Result<Vec<BulkDirEntry>, i32> {
        let _ = unsafe { libc::lseek(dir_fd, 0, libc::SEEK_SET) };
        let mut entries = VecDeque::new();
        while read_dir_chunk(dir_fd, buf, &mut entries)? > 0 {}
        Ok(entries.into())
    }

    /// Read the next entries of a directory from its descriptor's position
    /// (one `getattrlistbulk` call) into `out`; 0 at the end.
    pub(super) fn read_dir_chunk(
        dir_fd: RawFd,
        buf: &mut Vec<u8>,
        out: &mut VecDeque<BulkDirEntry>,
    ) -> Result<usize, i32> {
        if buf.len() < DIR_CHUNK_BYTES {
            buf.resize(DIR_CHUNK_BYTES, 0);
        }
        let mut req = AttrList {
            bitmapcount: ATTR_BIT_MAP_COUNT,
            reserved: 0,
            commonattr: ATTR_CMN_RETURNED_ATTRS
                | ATTR_CMN_NAME
                | ATTR_CMN_DEVID
                | ATTR_CMN_OBJTYPE
                | ATTR_CMN_MODTIME
                | ATTR_CMN_CHGTIME
                | ATTR_CMN_ACCTIME
                | ATTR_CMN_ACCESSMASK
                | ATTR_CMN_FILEID,
            volattr: 0,
            dirattr: ATTR_DIR_LINKCOUNT | ATTR_DIR_MOUNTSTATUS,
            fileattr: ATTR_FILE_LINKCOUNT
                | ATTR_FILE_TOTALSIZE
                | ATTR_FILE_ALLOCSIZE
                | ATTR_FILE_DEVTYPE,
            forkattr: 0,
        };

        let size = DIR_CHUNK_BYTES.min(buf.len());
        let count = unsafe { getattrlistbulk(dir_fd, &mut req, buf.as_mut_ptr().cast(), size, 0) };
        if count < 0 {
            return Err(last_os_errno_linux());
        }
        {
            let entries = out;
            let base_ptr = buf.as_ptr();
            let buf_end = unsafe { base_ptr.add(buf.len()) };
            let mut rec_ptr = base_ptr;
            for _ in 0..count {
                if (rec_ptr as usize) + 4 > buf_end as usize {
                    break;
                }
                let rec_len = unsafe { std::ptr::read_unaligned(rec_ptr.cast::<u32>()) } as usize;
                if rec_len < 4 || (rec_ptr as usize) + rec_len > buf_end as usize {
                    break;
                }
                let rec_end = unsafe { rec_ptr.add(rec_len) };
                let mut cur = unsafe { rec_ptr.add(4) };
                rec_ptr = rec_end;

                let Some(ret) = (unsafe { read_unaligned_adv::<AttributeSet>(&mut cur, rec_end) })
                else {
                    continue;
                };

                let mut name_bytes: Option<CString> = None;
                if ret.commonattr & ATTR_CMN_NAME != 0 {
                    let name = unsafe { record_name(&mut cur, rec_end) };
                    if let Some(trimmed) = name
                        && !trimmed.is_empty()
                        && trimmed != b"."
                        && trimmed != b".."
                    {
                        name_bytes = CString::new(trimmed).ok();
                    }
                }
                let dev = if ret.commonattr & ATTR_CMN_DEVID != 0 {
                    unsafe { read_unaligned_adv::<i32>(&mut cur, rec_end) }.unwrap_or(0) as u64
                } else {
                    0
                };
                let objtype = if ret.commonattr & ATTR_CMN_OBJTYPE != 0 {
                    unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }.unwrap_or(1)
                } else {
                    1
                };
                let mtime = if ret.commonattr & ATTR_CMN_MODTIME != 0 {
                    unsafe { read_unaligned_adv::<libc::timespec>(&mut cur, rec_end) }.unwrap_or(
                        libc::timespec {
                            tv_sec: 0,
                            tv_nsec: 0,
                        },
                    )
                } else {
                    libc::timespec {
                        tv_sec: 0,
                        tv_nsec: 0,
                    }
                };
                let ctime = if ret.commonattr & ATTR_CMN_CHGTIME != 0 {
                    unsafe { read_unaligned_adv::<libc::timespec>(&mut cur, rec_end) }
                        .unwrap_or(mtime)
                } else {
                    mtime
                };
                let atime = if ret.commonattr & ATTR_CMN_ACCTIME != 0 {
                    unsafe { read_unaligned_adv::<libc::timespec>(&mut cur, rec_end) }
                        .unwrap_or(mtime)
                } else {
                    mtime
                };
                let accessmask = if ret.commonattr & ATTR_CMN_ACCESSMASK != 0 {
                    unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }.unwrap_or(0o644)
                } else {
                    0o644
                };
                let ino = if ret.commonattr & ATTR_CMN_FILEID != 0 {
                    unsafe { read_unaligned_adv::<u64>(&mut cur, rec_end) }.unwrap_or(0)
                } else {
                    0
                };

                let mut nlink: u32 = if objtype == 2 { 2 } else { 1 };
                if ret.dirattr & ATTR_DIR_LINKCOUNT != 0
                    && let Some(v) = unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }
                {
                    nlink = v;
                }
                let mount_point = ret.dirattr & ATTR_DIR_MOUNTSTATUS != 0
                    && unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }
                        .is_some_and(|status| status & DIR_MNTSTATUS_MNTPOINT != 0);
                if ret.fileattr & ATTR_FILE_LINKCOUNT != 0
                    && let Some(v) = unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }
                {
                    nlink = v;
                }
                let size = if ret.fileattr & ATTR_FILE_TOTALSIZE != 0 {
                    unsafe { read_unaligned_adv::<i64>(&mut cur, rec_end) }
                        .unwrap_or(0)
                        .max(0) as u64
                } else {
                    0
                };
                let allocsize = if ret.fileattr & ATTR_FILE_ALLOCSIZE != 0 {
                    unsafe { read_unaligned_adv::<i64>(&mut cur, rec_end) }
                        .unwrap_or(0)
                        .max(0) as u64
                } else {
                    0
                };
                let rdev = if ret.fileattr & ATTR_FILE_DEVTYPE != 0 {
                    unsafe { read_unaligned_adv::<u32>(&mut cur, rec_end) }.unwrap_or(0) as u64
                } else {
                    0
                };

                let Some(name) = name_bytes else {
                    continue;
                };
                let mode = vtype_to_ifmt(objtype) | (accessmask & 0o7777);
                entries.push_back(BulkDirEntry {
                    name,
                    mount_point,
                    stat: FuseStat {
                        dev,
                        ino,
                        mode,
                        nlink,
                        size,
                        blocks: allocsize / 512,
                        atime: atime.tv_sec as i64,
                        atime_nsec: atime.tv_nsec as i64,
                        mtime: mtime.tv_sec as i64,
                        mtime_nsec: mtime.tv_nsec as i64,
                        ctime: ctime.tv_sec as i64,
                        ctime_nsec: ctime.tv_nsec as i64,
                        rdev,
                    },
                });
            }
        }
        Ok(count as usize)
    }
}

#[cfg(not(target_vendor = "apple"))]
mod darwin_bulk {
    use super::*;

    /// Names are compared byte for byte elsewhere.
    pub(super) fn stored_name(_dirfd: RawFd, _name: &CStr, _st: &FuseStat) -> Option<CString> {
        None
    }

    pub(super) fn entry_stored(dirfd: RawFd, name: &CStr) -> Result<(CString, (u64, u64)), i32> {
        let st = fstatat_cstr(dirfd, name)?;
        Ok((name.to_owned(), (st.dev, st.ino)))
    }
}

#[derive(Default)]
pub struct FsMetrics {
    pub requests: AtomicU64,
    pub bytes_read: AtomicU64,
    pub bytes_written: AtomicU64,
    /// Nodes all shares hold now, and the most they have held at once.
    pub nodes: AtomicU64,
    pub nodes_peak: AtomicU64,
    /// Open file and directory handles all shares hold now.
    pub open_handles: AtomicU64,
    pub workspace_kicks: AtomicU64,
    pub workspace_used_batches: AtomicU64,
    pub workspace_irq_requests: AtomicU64,
}

/// Deepest directory chain resolved for one node. A chain cannot loop (every
/// node's parent was known before it), but resolution is bounded regardless.
const MAX_NODE_DEPTH: usize = 4096;

/// A relative directory path opened with one `openat(O_NOFOLLOW_ANY)` stays
/// well below Darwin's PATH_MAX; longer chains are walked one entry at a time.
#[cfg(target_vendor = "apple")]
const MAX_ONE_SHOT_REL_PATH: usize = 900;

/// How long a root caller keeps seeing an unclaimed node as owned by the
/// non-root user that last used it: far longer than the guest's 20 ms
/// attribute cache, short enough not to outlive the activity that caused it.
const OWNER_ADOPT_WINDOW: Duration = Duration::from_secs(5);

const S_ISUID: u32 = 0o4000;
const S_ISGID: u32 = 0o2000;

/// Marks the pinned-owner sections of a snapshot blob: by node, by host file.
const SNAPSHOT_OWNERS_TAG: &[u8; 4] = b"OWN1";
const SNAPSHOT_FILE_OWNERS_TAG: &[u8; 4] = b"OWN2";
const SNAPSHOT_DIRECT_IO_MMAP_TAG: &[u8; 4] = b"DIO1";

// renameat2(2) flags the guest may send in FUSE_RENAME2.
const LINUX_RENAME_NOREPLACE: u32 = 1 << 0;
const LINUX_RENAME_EXCHANGE: u32 = 1 << 1;

const DIR_OPEN_FLAGS: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;

/// One node the guest can name: the directory entry it was last seen at and
/// the host file it is bound to. Nodes are addressed by (parent, name), never
/// by a host path, so renaming a directory moves its whole subtree at once and
/// every host access is resolved again from the share root.
///
/// A host entry has one node however the guest spells it: on a volume that
/// ignores case or Unicode normalisation, a node is keyed by the name it was
/// first bound under, and any other spelling of the entry finds it through
/// [`FsCore::kin`] and re-keys it to the name the host stores.
/// Hard links are separate entries, so separate nodes, of one file:
/// they report the same inode number and share its owner (both by host
/// identity). A node lives while the guest references it (`lookups`) or a
/// child is addressed through it.
struct Node {
    parent: u64,
    /// Entry name in `parent` as the host stores it (the root is `.` in itself).
    name: CString,
    /// Host (dev, ino) this node is bound to (None only for the root, and
    /// for a node restored from a snapshot until it is observed again).
    identity: Option<(u64, u64)>,
    /// Entry replies the guest has not forgotten yet (FUSE `nlookup`).
    lookups: u64,
    /// Last non-root caller that saw this node, and when (ms since the share
    /// opened): what a root caller sees as the owner of a floating file.
    recent_user: Option<(u32, u32)>,
    recent_at_ms: u64,
}

impl Node {
    fn new(parent: u64, name: CString, identity: Option<(u64, u64)>) -> Self {
        Self {
            parent,
            name,
            identity,
            lookups: 0,
            recent_user: None,
            recent_at_ms: 0,
        }
    }
}

/// Mode, uid and gid the guest sees for a node.
///
/// Ownership on a writable share belongs to the host file, by (dev, ino), so
/// every name of a file (hard links, other spellings) and every node bound to
/// it agrees. Host uids mean nothing in the guest, so a file no guest `chown`
/// has touched "floats": a non-root caller sees itself as owner and group, so
/// non-root containers can use the Mac's files (as with Docker Desktop), and a
/// root caller, which passes permission checks without owning anything, sees
/// the non-root user that used the node within [`OWNER_ADOPT_WINDOW`], else
/// root. A guest `chown` or `chgrp` pins both fields for every caller: the one
/// it names, and the other at the value the caller saw then. A pin lasts until
/// the guest removes the file's last name (or the share closes). A non-root
/// caller handing a floating file to itself pins nothing. Set-id bits are never
/// honoured on a writable share (see [`guest_mode`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GuestAttr {
    mode: u32,
    uid: u32,
    gid: u32,
    /// Inode number (see [`FsCore::guest_ino`]); the FUSE node ID is separate.
    ino: u64,
}

/// A writable share behaves as if mounted nosuid whatever the guest's mount
/// flags (a container runtime remounting a bind can drop `nosuid`): set-id
/// bits on files are neither reported to the guest nor written to the Mac. On
/// a floating owner they would also grant whoever refreshed the guest's
/// attribute cache last. A directory's set-group-ID bit only steers group
/// inheritance and is left alone.
fn guest_mode(mode: u32, is_dir: bool) -> u32 {
    if is_dir {
        mode & !S_ISUID
    } else {
        mode & !(S_ISUID | S_ISGID)
    }
}

#[inline]
fn mode_is_dir(mode: u32) -> bool {
    mode & (libc::S_IFMT as u32) == libc::S_IFDIR as u32
}

/// A guest-supplied directory entry name: one component, never `.` or `..`.
fn entry_name(name: &[u8]) -> Result<CString, i32> {
    if name == b"." || name == b".." {
        return Err(LINUX_EINVAL);
    }
    name_to_cstr(name)
}

/// Open the directory `name` of `dirfd` without following a symlink: `nofollow`
/// is `O_NOFOLLOW` for one entry or `O_NOFOLLOW_ANY` for a relative path (Darwin
/// rejects the two together; `O_NOFOLLOW_ANY` covers the last component too).
fn open_dir_at(dirfd: RawFd, name: &CStr, nofollow: i32) -> Result<OwnedFd, i32> {
    let fd = unsafe { libc::openat(dirfd, name.as_ptr(), DIR_OPEN_FLAGS | nofollow) };
    if fd >= 0 {
        return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
    }
    let errno = last_os_errno_linux();
    #[cfg(target_vendor = "apple")]
    if errno == LINUX_EACCES {
        // A directory the host user may search but not list (mode -wx) still
        // serves `*at` calls through a search-only descriptor.
        let fd = unsafe {
            libc::openat(
                dirfd,
                name.as_ptr(),
                libc::O_SEARCH | libc::O_CLOEXEC | nofollow,
            )
        };
        if fd >= 0 {
            return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
        }
    }
    Err(errno)
}

/// Open the entry `name` of `dirfd` without following a symlink and without
/// blocking (a FIFO with no peer would otherwise hold the worker forever).
fn open_entry_at(
    dirfd: RawFd,
    name: &CStr,
    flags: i32,
    mode: libc::c_uint,
) -> Result<OwnedFd, i32> {
    let fd = unsafe {
        libc::openat(
            dirfd,
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | libc::O_NOCTTY,
            mode,
        )
    };
    if fd < 0 {
        Err(last_os_errno_linux())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

/// Keep `fd` (opened by [`open_entry_at`] with `flags`, describing `st`) as a
/// host handle only for a regular file or a directory: the guest serves
/// FIFOs, sockets and devices itself and never needs a host handle for one.
/// A regular file drops the O_NONBLOCK it was opened with.
fn host_handle(fd: OwnedFd, st: &FuseStat, flags: i32) -> Result<File, i32> {
    match st.mode & libc::S_IFMT as u32 {
        m if m == libc::S_IFREG as u32 => {
            if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags & libc::O_APPEND) } != 0 {
                return Err(last_os_errno_linux());
            }
            Ok(File::from(fd))
        }
        m if m == libc::S_IFDIR as u32 => Ok(File::from(fd)),
        _ => Err(LINUX_ENXIO),
    }
}

/// Open handles one share may hold: [`MAX_OPEN_HANDLES`], or a quarter of the
/// descriptors this process may open if that is less (the rest serve other
/// shares, the disk, vsock and published-port connections).
fn handle_limit() -> usize {
    let mut rl = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    let mut cur = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) } == 0 {
        rl.rlim_cur
    } else {
        256
    };
    #[cfg(target_vendor = "apple")]
    {
        let mut per_proc: libc::c_int = 0;
        let mut len = std::mem::size_of::<libc::c_int>();
        if unsafe {
            libc::sysctlbyname(
                c"kern.maxfilesperproc".as_ptr(),
                (&mut per_proc as *mut libc::c_int).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        } == 0
            && per_proc > 0
        {
            cur = cur.min(per_proc as libc::rlim_t);
        }
    }
    usize::try_from(cur / 4)
        .unwrap_or(MAX_OPEN_HANDLES)
        .clamp(64, MAX_OPEN_HANDLES)
}

/// The path the host gives an open directory now (`F_GETPATH`).
#[cfg(target_vendor = "apple")]
fn fd_path(fd: RawFd) -> Option<Vec<u8>> {
    let mut buf = [0u8; libc::PATH_MAX as usize];
    if unsafe { libc::fcntl(fd, libc::F_GETPATH, buf.as_mut_ptr()) } != 0 {
        return None;
    }
    let len = buf.iter().position(|&b| b == 0)?;
    Some(buf[..len].to_vec())
}

fn path_within(path: &[u8], root: &[u8]) -> bool {
    path == root
        || (path.starts_with(root) && (root.ends_with(b"/") || path.get(root.len()) == Some(&b'/')))
}

/// Open the directory reached from `base` through `names` (entry names, never
/// `.` or `..`) without following a symlink in any component, so the result
/// is a directory inside the tree `base` heads unless the host moves one of
/// those directories out of it meanwhile ([`FsCore::dir_fd`] checks that).
fn open_dir_beneath(base: RawFd, names: &[&CStr]) -> Result<OwnedFd, i32> {
    #[cfg(target_vendor = "apple")]
    {
        let total: usize = names.iter().map(|n| n.to_bytes().len() + 1).sum();
        if !names.is_empty() && total <= MAX_ONE_SHOT_REL_PATH {
            let mut rel = Vec::with_capacity(total);
            for (i, n) in names.iter().enumerate() {
                if i > 0 {
                    rel.push(b'/');
                }
                rel.extend_from_slice(n.to_bytes());
            }
            let rel = CString::new(rel).map_err(|_| LINUX_EINVAL)?;
            return open_dir_at(base, &rel, libc::O_NOFOLLOW_ANY);
        }
    }
    // One entry at a time: O_NOFOLLOW on a single name never follows a link.
    let mut cur: Option<OwnedFd> = None;
    for n in names {
        let at = cur.as_ref().map_or(base, |fd| fd.as_raw_fd());
        cur = Some(open_dir_at(at, n, libc::O_NOFOLLOW)?);
    }
    cur.ok_or(LINUX_EINVAL)
}

#[cfg(target_vendor = "apple")]
fn host_rename(
    old_dir: RawFd,
    old: &CStr,
    new_dir: RawFd,
    new: &CStr,
    flags: u32,
) -> Result<(), i32> {
    let rc = if flags == 0 {
        unsafe { libc::renameat(old_dir, old.as_ptr(), new_dir, new.as_ptr()) }
    } else {
        let mut darwin = 0;
        if flags & LINUX_RENAME_NOREPLACE != 0 {
            darwin |= libc::RENAME_EXCL;
        }
        if flags & LINUX_RENAME_EXCHANGE != 0 {
            darwin |= libc::RENAME_SWAP;
        }
        unsafe { libc::renameatx_np(old_dir, old.as_ptr(), new_dir, new.as_ptr(), darwin) }
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(last_os_errno_linux())
    }
}

#[cfg(not(target_vendor = "apple"))]
fn host_rename(
    old_dir: RawFd,
    old: &CStr,
    new_dir: RawFd,
    new: &CStr,
    flags: u32,
) -> Result<(), i32> {
    if flags != 0 {
        return Err(LINUX_EINVAL);
    }
    if unsafe { libc::renameat(old_dir, old.as_ptr(), new_dir, new.as_ptr()) } == 0 {
        Ok(())
    } else {
        Err(last_os_errno_linux())
    }
}

/// A read-only LOOKUP answer (the node it bound, or the error) and the
/// `clock_ms` the host gave it at.
type RoLookup = (Result<u64, i32>, u64);

struct FsCore {
    read_only: bool,
    writable_workspace: bool,
    direct_io_requested: bool,
    direct_io_mmap: bool,
    /// The share root, opened once. Every host access is a `*at` call on a
    /// directory reached from here without following symlinks.
    root_fd: Arc<OwnedFd>,
    /// Host device of the share root: inode numbers from it reach the guest
    /// as they are; those of volumes mounted inside the share are folded with
    /// an index into `foreign_devs`.
    root_dev: u64,
    foreign_devs: Vec<u64>,
    /// Where the host says the share root is (`F_GETPATH`); cached directory
    /// descriptors must stay beneath it.
    #[cfg_attr(not(target_vendor = "apple"), allow(dead_code))]
    root_path: Vec<u8>,
    next_nodeid: u64,
    next_fh: u64,
    nodes: HashMap<u64, Node>,
    /// (parent node, stored entry name) -> node.
    children: HashMap<u64, HashMap<CString, u64>>,
    /// (parent node, host identity) -> a node `parent` has for that file, to
    /// find the node of an entry under another spelling, or after the host
    /// renames it (writable shares). `kin_more` holds any further nodes for
    /// the same file in the same directory (other hard links).
    kin: HashMap<(u64, (u64, u64)), u64>,
    kin_more: HashMap<(u64, (u64, u64)), Vec<u64>>,
    /// Open directories by node; a descriptor keeps naming its directory
    /// across renames, so it stays valid until the node goes, unless the host
    /// moves the directory out of the share.
    dir_fds: HashMap<u64, CachedDir>,
    open_files: HashMap<u64, OpenFile>,
    open_dirs: HashMap<u64, OpenDir>,
    limits: Limits,
    /// Guest owner pinned by a guest `chown`, by host (dev, ino) (see [`GuestAttr`]).
    owners: HashMap<(u64, u64), (u32, u32)>,
    // Read-only hot caches (eliminates repeat host lstat/open syscalls on oci-tools!).
    // Lookups and attributes carry the `clock_ms` the host reported them at
    // and are served only for `ro_validity_ms` after it.
    ro_lookup_cache: HashMap<(u64, Vec<u8>), RoLookup>,
    ro_attr_cache: HashMap<u64, (FuseStat, u64)>,
    /// A descriptor of the file each node is bound to, for reads without an
    /// open handle (FUSE_NO_OPEN_SUPPORT). It outlives a node the host
    /// replaced until the guest forgets the node: a guest file still open
    /// on it keeps reading the file it opened.
    ro_file_cache: HashMap<u64, Arc<File>>,
    ro_validity_ms: u64,
    // Reusable scratch buffers (zero heap allocs on hot paths)
    read_buf: Vec<u8>,
    bulk_buf: Vec<u8>,
    resp_buf: Vec<u8>,
    metrics: Arc<FsMetrics>,
    /// Guest uid/gid of the request being handled (from `fuse_in_header`).
    caller: (u32, u32),
    epoch: Instant,
    adopt_window_ms: u64,
}

struct FsQueueState {
    queues: Vec<Option<VirtQueue>>,
    mem: Option<Arc<GuestMemory>>,
    irq: Option<IrqLine>,
    kicked: bool,
    worker_parked: bool,
}

struct FsShared {
    core: Mutex<FsCore>,
    workspace_metrics: Option<Arc<FsMetrics>>,
    state: (Mutex<FsQueueState>, Condvar),
    paused: AtomicBool,
    shutdown: AtomicBool,
}

pub struct VirtioFs {
    tag: [u8; 36],
    tag_name: String,
    request_queues: u16,
    offer_event_idx: bool,
    shared: Arc<FsShared>,
    worker_handle: Option<thread::JoinHandle<()>>,
}

impl VirtioFs {
    pub fn new(
        tag: &str,
        root: PathBuf,
        read_only: bool,
        metrics: Arc<FsMetrics>,
    ) -> std::io::Result<Self> {
        let count = if tag == "workspace" && !read_only {
            std::env::var_os("MICROPOD_VIRTIOFS_WORKSPACE_QUEUES")
        } else {
            None
        };
        let request_queues = match count {
            None => 1,
            Some(value) => value
                .to_str()
                .and_then(|s| s.parse::<u16>().ok())
                .filter(|n| (1..=16).contains(n))
                .ok_or_else(|| {
                    std::io::Error::new(
                        ErrorKind::InvalidInput,
                        "MICROPOD_VIRTIOFS_WORKSPACE_QUEUES must be between 1 and 16",
                    )
                })?,
        };
        let mut device = Self::with_request_queues(tag, root, read_only, metrics, request_queues)?;
        if tag == "workspace" && !read_only {
            device.offer_event_idx =
                match std::env::var_os("MICROPOD_VIRTIOFS_WORKSPACE_EVENT_IDX").as_deref() {
                    None => false,
                    Some(value) if value == "0" => false,
                    Some(value) if value == "1" => true,
                    Some(_) => {
                        return Err(std::io::Error::new(
                            ErrorKind::InvalidInput,
                            "MICROPOD_VIRTIOFS_WORKSPACE_EVENT_IDX must be 0 or 1",
                        ));
                    }
                };
        }
        Ok(device)
    }

    fn with_request_queues(
        tag: &str,
        root: PathBuf,
        read_only: bool,
        metrics: Arc<FsMetrics>,
        request_queues: u16,
    ) -> std::io::Result<Self> {
        let workspace_metrics = (tag == "workspace" && !read_only).then(|| metrics.clone());
        let core = FsCore::new(tag, &root, read_only, metrics)?;
        let mut tag_bytes = [0u8; 36];
        let src = tag.as_bytes();
        let n = src.len().min(36);
        tag_bytes[..n].copy_from_slice(&src[..n]);

        Ok(Self {
            tag: tag_bytes,
            tag_name: tag.to_string(),
            request_queues,
            offer_event_idx: false,
            shared: Arc::new(FsShared {
                core: Mutex::new(core),
                workspace_metrics,
                state: (
                    Mutex::new(FsQueueState {
                        queues: vec![None; 1 + usize::from(request_queues)],
                        mem: None,
                        irq: None,
                        kicked: false,
                        worker_parked: true,
                    }),
                    Condvar::new(),
                ),
                paused: AtomicBool::new(false),
                shutdown: AtomicBool::new(false),
            }),
            worker_handle: None,
        })
    }

    fn ensure_worker_started(&mut self) {
        if self.worker_handle.is_some() {
            return;
        }
        let shared = self.shared.clone();
        let name = format!("vmm-fs-{}", self.tag_name);
        let handle = thread::Builder::new()
            .name(name)
            .spawn(move || run_fs_io_loop(shared))
            .expect("spawn vmm-fs io worker");
        self.worker_handle = Some(handle);
    }

    // Once parked, the worker has rearmed each queue and returned its live
    // cursors. Queue configuration and snapshots can then use the same state.
    fn park_worker(&self) -> MutexGuard<'_, FsQueueState> {
        let (state, wake) = &self.shared.state;
        let mut st = state.lock().unwrap();
        self.shared.paused.store(true, Ordering::Release);
        wake.notify_all();
        while self.worker_handle.is_some() && !st.worker_parked {
            st = wake.wait(st).unwrap();
        }
        st
    }

    fn resume_worker(&self, st: &mut FsQueueState) {
        self.shared.paused.store(false, Ordering::Release);
        st.kicked = true;
        self.shared.state.1.notify_all();
    }

    #[cfg(test)]
    fn handle_fuse(&mut self, req: &[u8]) -> Option<Vec<u8>> {
        let mut core = self.shared.core.lock().unwrap();
        if core.handle_fuse_into(req) {
            Some(core.resp_buf.clone())
        } else {
            None
        }
    }

    #[cfg(test)]
    fn handle_fuse_chain(&mut self, bufs: &[DescBuf], mem: &GuestMemory) -> u32 {
        let mut scratch = Vec::new();
        self.shared
            .core
            .lock()
            .unwrap()
            .handle_fuse_chain(bufs, mem, &mut scratch)
    }
}

impl FsCore {
    fn new(
        tag: &str,
        root: &Path,
        read_only: bool,
        metrics: Arc<FsMetrics>,
    ) -> std::io::Result<Self> {
        let canon = fs::canonicalize(root)?;
        let croot = CString::new(canon.as_os_str().as_bytes())
            .map_err(|_| std::io::Error::from(ErrorKind::InvalidInput))?;
        let fd = unsafe {
            libc::open(
                croot.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let root_fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let root_dev = fstat_fd(root_fd.as_raw_fd())
            .map_err(|_| std::io::Error::last_os_error())?
            .dev;
        #[cfg(target_vendor = "apple")]
        let root_path = fd_path(root_fd.as_raw_fd()).unwrap_or_default();
        #[cfg(not(target_vendor = "apple"))]
        let root_path = canon.as_os_str().as_bytes().to_vec();
        let mut nodes = HashMap::new();
        nodes.insert(FUSE_ROOT_ID, Node::new(FUSE_ROOT_ID, c".".to_owned(), None));
        let now = metrics.nodes.fetch_add(1, Ordering::Relaxed) + 1;
        metrics.nodes_peak.fetch_max(now, Ordering::Relaxed);
        let writable_workspace = tag == "workspace" && !read_only;
        Ok(Self {
            read_only,
            writable_workspace,
            direct_io_requested: writable_workspace
                && std::env::var_os("MICROPOD_VIRTIOFS_LIVE_READ")
                    .is_some_and(|value| value == "1"),
            direct_io_mmap: false,
            root_fd: Arc::new(root_fd),
            root_dev,
            foreign_devs: Vec::new(),
            root_path,
            next_nodeid: 2,
            next_fh: 1,
            nodes,
            children: HashMap::new(),
            kin: HashMap::new(),
            kin_more: HashMap::new(),
            dir_fds: HashMap::new(),
            open_files: HashMap::new(),
            open_dirs: HashMap::new(),
            limits: Limits::new(),
            owners: HashMap::new(),
            ro_lookup_cache: HashMap::new(),
            ro_attr_cache: HashMap::new(),
            ro_file_cache: HashMap::new(),
            ro_validity_ms: RO_VALIDITY_MS,
            read_buf: vec![0u8; 256 * 1024],
            bulk_buf: Vec::new(),
            resp_buf: Vec::with_capacity(4096),
            metrics,
            caller: (0, 0),
            epoch: Instant::now(),
            adopt_window_ms: OWNER_ADOPT_WINDOW.as_millis() as u64,
        })
    }

    fn child_id(&self, parent: u64, name: &CStr) -> Option<u64> {
        self.children.get(&parent)?.get(name).copied()
    }

    fn insert_child(&mut self, parent: u64, name: CString, identity: Option<(u64, u64)>) -> u64 {
        let id = self.next_nodeid;
        self.next_nodeid += 1;
        self.insert_node(id, parent, name, identity);
        id
    }

    fn insert_node(&mut self, id: u64, parent: u64, name: CString, identity: Option<(u64, u64)>) {
        self.children
            .entry(parent)
            .or_default()
            .insert(name.clone(), id);
        if self
            .nodes
            .insert(id, Node::new(parent, name, identity))
            .is_none()
        {
            let now = self.metrics.nodes.fetch_add(1, Ordering::Relaxed) + 1;
            self.metrics.nodes_peak.fetch_max(now, Ordering::Relaxed);
        }
        self.index_kin(id);
    }

    /// Drop node `id` from every table. The caller handles its children.
    fn remove_node(&mut self, id: u64) -> Option<Node> {
        self.unindex_kin(id);
        let node = self.nodes.remove(&id)?;
        self.metrics.nodes.fetch_sub(1, Ordering::Relaxed);
        if let Some(siblings) = self.children.get_mut(&node.parent)
            && siblings.get(node.name.as_c_str()) == Some(&id)
        {
            siblings.remove(node.name.as_c_str());
            if siblings.is_empty() {
                self.children.remove(&node.parent);
            }
        }
        self.dir_fds.remove(&id);
        if self.read_only {
            self.ro_attr_cache.remove(&id);
            let key = (node.parent, node.name.to_bytes().to_vec());
            if self
                .ro_lookup_cache
                .get(&key)
                .is_some_and(|(found, _)| *found == Ok(id))
            {
                self.ro_lookup_cache.remove(&key);
            }
        }
        Some(node)
    }

    /// Forget a node and everything below it: later requests for them get
    /// ESTALE (open handles, and on read-only shares the node's own
    /// descriptor, keep working), and the name can bind afresh.
    fn retire(&mut self, id: u64) {
        let mut stack = vec![id];
        while let Some(id) = stack.pop() {
            if id == FUSE_ROOT_ID {
                continue;
            }
            if self.remove_node(id).is_none() {
                continue;
            }
            if let Some(kids) = self.children.remove(&id) {
                stack.extend(kids.into_values());
            }
        }
    }

    fn retire_child(&mut self, parent: u64, name: &CStr) {
        if let Some(id) = self.child_id(parent, name) {
            self.retire(id);
        }
    }

    /// FUSE_FORGET: the guest dropped `count` references to node `id`.
    fn forget(&mut self, id: u64, count: u64) {
        let Some(node) = self.nodes.get_mut(&id) else {
            // Already retired: the guest is done with the file it read through it.
            self.ro_file_cache.remove(&id);
            return;
        };
        node.lookups = node.lookups.saturating_sub(count);
        self.drop_unreferenced(id);
    }

    /// Remove node `id` once the guest holds no reference to it and no child
    /// is addressed through it, then its parent on the same terms.
    fn drop_unreferenced(&mut self, mut id: u64) {
        while id != FUSE_ROOT_ID {
            let Some(node) = self.nodes.get(&id) else {
                return;
            };
            if node.lookups != 0 || self.children.contains_key(&id) {
                return;
            }
            let parent = node.parent;
            self.remove_node(id);
            self.ro_file_cache.remove(&id);
            id = parent;
        }
    }

    /// FUSE_INIT starts a new session: the guest mounted the share (again).
    /// It references no node or handle of an earlier session, whose FORGETs
    /// and RELEASEs it stopped sending once that session ended, so all of
    /// them go. Owner pins belong to host files and stay.
    fn reset_session(&mut self) {
        let stale: Vec<u64> = self
            .nodes
            .keys()
            .copied()
            .filter(|&id| id != FUSE_ROOT_ID)
            .collect();
        for id in stale {
            self.remove_node(id);
        }
        self.children.clear();
        self.kin.clear();
        self.kin_more.clear();
        self.dir_fds.clear();
        let handles = (self.open_files.len() + self.open_dirs.len()) as u64;
        self.open_files.clear();
        self.open_dirs.clear();
        self.metrics
            .open_handles
            .fetch_sub(handles, Ordering::Relaxed);
        self.ro_lookup_cache.clear();
        self.ro_attr_cache.clear();
        self.ro_file_cache.clear();
        if let Some(root) = self.nodes.get_mut(&FUSE_ROOT_ID) {
            root.lookups = 0;
        }
    }

    /// Count an entry reply for node `id` (the guest now references it once more).
    fn add_lookup(&mut self, id: u64) {
        if let Some(node) = self.nodes.get_mut(&id) {
            node.lookups = node.lookups.saturating_add(1);
        }
    }

    /// The key the entry `name` of directory node `parent` (descriptor `pfd`),
    /// which is the file `st` describes, has among `parent`'s children: `name`
    /// when that is already its node's key or `parent` has no node for the
    /// file yet (it then binds under `name`, with no extra host call), else
    /// the spelling the host stores the entry under, which a node `parent` has
    /// for the file under another spelling, or under its name before a rename
    /// on the host, takes over (see [`Self::adopt_renamed`]). Different
    /// spellings of one entry thus share one node.
    fn child_key<'a>(
        &mut self,
        parent: u64,
        pfd: RawFd,
        name: &'a CStr,
        st: &FuseStat,
    ) -> Cow<'a, CStr> {
        let known = self
            .child_id(parent, name)
            .and_then(|id| self.nodes.get(&id))
            .is_some_and(|n| n.identity.is_none_or(|k| k == (st.dev, st.ino)));
        if self.read_only || known || !self.kin.contains_key(&(parent, (st.dev, st.ino))) {
            return Cow::Borrowed(name);
        }
        let key = darwin_bulk::stored_name(pfd, name, st).map_or(Cow::Borrowed(name), Cow::Owned);
        self.adopt_renamed(parent, pfd, &key, st);
        key
    }

    /// Before binding the stored entry `key` of `parent` to the file `st`
    /// describes: a node `parent` already has for that file under another key
    /// is this entry under the name it had before the host renamed it (its
    /// old key is gone, or now another spelling of `key`), and takes `key`.
    /// A node under a key that is still a separate entry is another hard link.
    fn adopt_renamed(&mut self, parent: u64, pfd: RawFd, key: &CStr, st: &FuseStat) {
        let identity = (st.dev, st.ino);
        if self.read_only || self.child_id(parent, key).is_some() {
            return;
        }
        let k = (parent, identity);
        let Some(&first) = self.kin.get(&k) else {
            return;
        };
        let mut candidates = vec![first];
        if let Some(more) = self.kin_more.get(&k) {
            candidates.extend(more);
        }
        for other in candidates {
            let Some(old) = self.nodes.get(&other).map(|n| n.name.clone()) else {
                continue;
            };
            let same_entry = match darwin_bulk::entry_stored(pfd, &old) {
                Err(LINUX_ENOENT) => true,
                Ok((stored, found)) => found == identity && stored.as_c_str() == key,
                Err(_) => false,
            };
            if !same_entry {
                continue;
            }
            if let Some(siblings) = self.children.get_mut(&parent)
                && siblings.get(old.as_c_str()) == Some(&other)
            {
                siblings.remove(old.as_c_str());
            }
            self.children
                .entry(parent)
                .or_default()
                .insert(key.to_owned(), other);
            if let Some(node) = self.nodes.get_mut(&other) {
                node.name = key.to_owned();
            }
            return;
        }
    }

    /// Record node `id` among `parent`'s nodes for its host file (see [`FsCore::kin`]).
    fn index_kin(&mut self, id: u64) {
        let Some(node) = self.nodes.get(&id) else {
            return;
        };
        let Some(identity) = node.identity else {
            return;
        };
        let k = (node.parent, identity);
        match self.kin.get(&k) {
            None => {
                self.kin.insert(k, id);
            }
            Some(&first) if first == id => {}
            Some(_) => {
                let more = self.kin_more.entry(k).or_default();
                if !more.contains(&id) {
                    more.push(id);
                }
            }
        }
    }

    fn unindex_kin(&mut self, id: u64) {
        let Some(node) = self.nodes.get(&id) else {
            return;
        };
        let Some(identity) = node.identity else {
            return;
        };
        let k = (node.parent, identity);
        if self.kin.get(&k) == Some(&id) {
            match self.kin_more.get_mut(&k).and_then(|more| more.pop()) {
                Some(next) => {
                    self.kin.insert(k, next);
                }
                None => {
                    self.kin.remove(&k);
                }
            }
        } else if let Some(more) = self.kin_more.get_mut(&k) {
            more.retain(|&other| other != id);
        }
        if self.kin_more.get(&k).is_some_and(|more| more.is_empty()) {
            self.kin_more.remove(&k);
        }
    }

    /// The node for the entry `name` of directory node `parent` (descriptor
    /// `pfd`), which is the file `st` describes, binding one if needed. The
    /// caller replies with an entry for it. ENFILE when a node would be
    /// needed beyond [`MAX_NODES`].
    fn bind_entry(
        &mut self,
        parent: u64,
        pfd: RawFd,
        name: &CStr,
        st: &FuseStat,
    ) -> Result<u64, i32> {
        let key = self.child_key(parent, pfd, name, st);
        if self.child_id(parent, &key).is_none() && self.nodes.len() >= self.limits.nodes {
            return Err(LINUX_ENFILE);
        }
        Ok(self.observe_child(parent, &key, st))
    }

    /// Room for another node (checked before an operation creates a host entry).
    fn node_room(&self) -> Result<(), i32> {
        if self.nodes.len() >= self.limits.nodes {
            Err(LINUX_ENFILE)
        } else {
            Ok(())
        }
    }

    /// Bind the entry `name` (the key it is stored under) of `parent` to the
    /// host file `st` describes.
    ///
    /// An editor can atomically replace a pathname. Linux keys its page cache by
    /// FUSE node ID, so the replacement must receive a distinct ID while open
    /// handles to the old inode continue to address their original contents.
    /// The host may do this on a read-only share too (a policy file renamed
    /// into place): reusing the old node would show the old file's pages
    /// under the new file's size.
    fn observe_child(&mut self, parent: u64, name: &CStr, st: &FuseStat) -> u64 {
        let identity = (st.dev, st.ino);
        if let Some(id) = self.child_id(parent, name) {
            if let Some(node) = self.nodes.get_mut(&id) {
                match node.identity {
                    None => {
                        node.identity = Some(identity);
                        self.index_kin(id);
                        return id;
                    }
                    Some(known) if known == identity => return id,
                    Some(_) => {}
                }
            }
            self.retire(id);
        }
        self.insert_child(parent, name.to_owned(), Some(identity))
    }

    /// Move the node at (`old_parent`, `old`) to (`new_parent`, `new`) after a
    /// host rename that replaced the entry `displaced` of `new_parent` (the key
    /// the destination had; `new` itself after a rename to another spelling of
    /// it). Its descendants are addressed through it, so they move too.
    fn move_child(
        &mut self,
        old_parent: u64,
        old: &CStr,
        new_parent: u64,
        new: CString,
        displaced: &CStr,
    ) {
        let moving = self.child_id(old_parent, old);
        // The displaced destination is gone; its open handles stay valid.
        for key in [displaced, new.as_c_str()] {
            if let Some(dst) = self.child_id(new_parent, key)
                && Some(dst) != moving
            {
                self.retire(dst);
            }
        }
        let Some(id) = moving else {
            return;
        };
        self.unindex_kin(id);
        if let Some(siblings) = self.children.get_mut(&old_parent) {
            siblings.remove(old);
            if siblings.is_empty() {
                self.children.remove(&old_parent);
            }
        }
        self.children
            .entry(new_parent)
            .or_default()
            .insert(new.clone(), id);
        if let Some(node) = self.nodes.get_mut(&id) {
            node.parent = new_parent;
            node.name = new;
        }
        self.index_kin(id);
    }

    /// Swap two entries after a host `RENAME_SWAP`.
    fn exchange_children(&mut self, a_parent: u64, a: &CStr, b_parent: u64, b: &CStr) {
        let a_id = self.child_id(a_parent, a);
        let b_id = self.child_id(b_parent, b);
        for id in [a_id, b_id].into_iter().flatten() {
            self.unindex_kin(id);
        }
        for (parent, name) in [(a_parent, a), (b_parent, b)] {
            if let Some(siblings) = self.children.get_mut(&parent) {
                siblings.remove(name);
                if siblings.is_empty() {
                    self.children.remove(&parent);
                }
            }
        }
        for (id, parent, name) in [(a_id, b_parent, b), (b_id, a_parent, a)] {
            let Some(id) = id else {
                continue;
            };
            self.children
                .entry(parent)
                .or_default()
                .insert(name.to_owned(), id);
            if let Some(node) = self.nodes.get_mut(&id) {
                node.parent = parent;
                node.name = name.to_owned();
            }
            self.index_kin(id);
        }
    }

    /// Path of a node relative to the share root, from its entry names.
    fn node_rel_path(&self, id: u64) -> Option<Vec<u8>> {
        let mut names = Vec::new();
        let mut cur = id;
        while cur != FUSE_ROOT_ID {
            let node = self.nodes.get(&cur)?;
            names.push(node.name.to_bytes());
            if names.len() > MAX_NODE_DEPTH {
                return None;
            }
            cur = node.parent;
        }
        let mut rel = Vec::new();
        for name in names.iter().rev() {
            if !rel.is_empty() {
                rel.push(b'/');
            }
            rel.extend_from_slice(name);
        }
        Some(rel)
    }

    fn identity_matches(&self, nodeid: u64, st: &FuseStat) -> bool {
        self.nodes
            .get(&nodeid)
            .and_then(|n| n.identity)
            .is_none_or(|known| known == (st.dev, st.ino))
    }

    fn has_identity(&self, nodeid: u64) -> bool {
        self.nodes
            .get(&nodeid)
            .is_some_and(|n| n.identity.is_some())
    }

    /// A descriptor for the directory node `id`, reached from the share root
    /// through the node's entry names without following any symlink, and
    /// checked against the host directory the node is bound to. Fails with
    /// ESTALE when no such directory exists any more: nothing is ever resolved
    /// through a host path, so a symlink planted in the share cannot redirect it.
    fn dir_fd(&mut self, id: u64) -> Result<Arc<OwnedFd>, i32> {
        if id == FUSE_ROOT_ID {
            return Ok(self.root_fd.clone());
        }
        if let Some(fd) = self.cached_dir(id) {
            return Ok(fd);
        }
        // Walk up to the nearest directory already open, collecting entry names.
        let mut chain = Vec::new();
        let mut cur = id;
        let base = loop {
            if cur == FUSE_ROOT_ID {
                break self.root_fd.clone();
            }
            if let Some(fd) = self.cached_dir(cur) {
                break fd;
            }
            let node = self.nodes.get(&cur).ok_or(LINUX_ESTALE)?;
            chain.push(cur);
            if chain.len() > MAX_NODE_DEPTH {
                return Err(LINUX_ESTALE);
            }
            cur = node.parent;
        };
        let open = |core: &Self| {
            let names: Vec<&CStr> = chain
                .iter()
                .rev()
                .map(|c| core.nodes[c].name.as_c_str())
                .collect();
            open_dir_beneath(base.as_raw_fd(), &names)
        };
        let mut opened = open(self);
        if matches!(opened, Err(LINUX_EMFILE | LINUX_ENFILE)) {
            // Out of descriptors: drop the cache and try once more.
            self.dir_fds.clear();
            opened = open(self);
        }
        let fd = match opened {
            Ok(fd) => fd,
            // The node no longer names a directory reachable without symlinks.
            Err(LINUX_ENOENT | LINUX_ENOTDIR | LINUX_ELOOP) => return Err(LINUX_ESTALE),
            Err(e) => return Err(e),
        };
        if self.has_identity(id) {
            let st = fstat_fd(fd.as_raw_fd())?;
            if !self.identity_matches(id, &st) {
                return Err(LINUX_ESTALE);
            }
        }
        // The host may have moved a directory on the way out of the share
        // while the walk was under way.
        if !self.fd_within_share(fd.as_raw_fd()) {
            return Err(LINUX_ESTALE);
        }
        let fd = Arc::new(fd);
        self.cache_dir(id, fd.clone());
        Ok(fd)
    }

    fn cache_dir(&mut self, id: u64, fd: Arc<OwnedFd>) {
        if self.dir_fds.len() >= MAX_CACHED_DIR_FDS {
            self.dir_fds.clear();
        }
        let checked_ms = self.clock_ms();
        self.dir_fds.insert(id, CachedDir { fd, checked_ms });
    }

    /// The cached descriptor of directory node `id`, unless the host has
    /// moved that directory out of the share since (it is then dropped, and
    /// the node is reached again through its names from the root).
    fn cached_dir(&mut self, id: u64) -> Option<Arc<OwnedFd>> {
        let now = self.clock_ms();
        let cached = self.dir_fds.get(&id)?;
        let fd = cached.fd.clone();
        if now.saturating_sub(cached.checked_ms) < DIR_FD_RECHECK_MS {
            return Some(fd);
        }
        if self.fd_within_share(fd.as_raw_fd()) {
            if let Some(cached) = self.dir_fds.get_mut(&id) {
                cached.checked_ms = now;
            }
            Some(fd)
        } else {
            self.dir_fds.remove(&id);
            None
        }
    }

    /// Whether the directory open at `fd` lies inside the share root now.
    #[cfg(target_vendor = "apple")]
    fn fd_within_share(&mut self, fd: RawFd) -> bool {
        let Some(path) = fd_path(fd) else {
            // Longer than F_GETPATH serves: climb `..` to the root instead.
            return self.fd_within_share_by_parents(fd);
        };
        if path_within(&path, &self.root_path) {
            return true;
        }
        // The root itself may have been renamed: compare with where it is now.
        match fd_path(self.root_fd.as_raw_fd()) {
            Some(root) if root != self.root_path => {
                self.root_path = root;
                path_within(&path, &self.root_path)
            }
            _ => false,
        }
    }

    #[cfg(not(target_vendor = "apple"))]
    fn fd_within_share(&mut self, _fd: RawFd) -> bool {
        true
    }

    /// Whether the root directory is among the ancestors of the directory
    /// open at `fd` (or is it), found by opening `..` repeatedly.
    #[cfg(target_vendor = "apple")]
    fn fd_within_share_by_parents(&self, fd: RawFd) -> bool {
        let Ok(root) = fstat_fd(self.root_fd.as_raw_fd()) else {
            return false;
        };
        let Ok(mut st) = fstat_fd(fd) else {
            return false;
        };
        let mut cur: Option<OwnedFd> = None;
        for _ in 0..MAX_NODE_DEPTH {
            if (st.dev, st.ino) == (root.dev, root.ino) {
                return true;
            }
            let at = cur.as_ref().map_or(fd, |c| c.as_raw_fd());
            let Ok(parent) = open_dir_at(at, c"..", 0) else {
                return false;
            };
            let Ok(pst) = fstat_fd(parent.as_raw_fd()) else {
                return false;
            };
            if (pst.dev, pst.ino) == (st.dev, st.ino) {
                return false; // the file system root
            }
            st = pst;
            cur = Some(parent);
        }
        false
    }

    /// Run `f` with the directory holding node `id` and the node's entry name
    /// (the root is `.` in itself). `f` must operate on that one entry only.
    fn at_leaf<R>(
        &mut self,
        id: u64,
        f: impl FnOnce(RawFd, &CStr) -> Result<R, i32>,
    ) -> Result<R, i32> {
        let parent = self.nodes.get(&id).ok_or(LINUX_ESTALE)?.parent;
        let pfd = self.dir_fd(parent)?;
        let name = &self.nodes.get(&id).ok_or(LINUX_ESTALE)?.name;
        f(pfd.as_raw_fd(), name)
    }

    /// `lstat` of a node, ESTALE if its entry now names a different host file.
    fn stat_node(&mut self, nodeid: u64) -> Result<FuseStat, i32> {
        let st = self.at_leaf(nodeid, fstatat_cstr)?;
        if self.identity_matches(nodeid, &st) {
            Ok(st)
        } else {
            Err(LINUX_ESTALE)
        }
    }

    /// Open a node's host file or directory without following a symlink or
    /// blocking; ESTALE if its entry now names a different host file, ENXIO
    /// for a FIFO, socket or device (see [`host_handle`]).
    fn open_node(&mut self, nodeid: u64, flags: i32) -> Result<(File, FuseStat), i32> {
        let fd = self.at_leaf(nodeid, |dfd, name| open_entry_at(dfd, name, flags, 0))?;
        let st = fstat_fd(fd.as_raw_fd())?;
        if !self.identity_matches(nodeid, &st) {
            return Err(LINUX_ESTALE);
        }
        Ok((host_handle(fd, &st, flags)?, st))
    }

    /// The errno to report for a failed open of a node: a stale positive dentry
    /// must be revalidated, even when the new binding prevents open (such as a
    /// symlink).
    fn open_failure(&mut self, nodeid: u64, errno: i32) -> i32 {
        if errno == LINUX_ESTALE {
            return errno;
        }
        let stale = self.has_identity(nodeid)
            && matches!(
                self.stat_node(nodeid),
                Err(LINUX_ESTALE | LINUX_ENOENT | LINUX_ENOTDIR | LINUX_ELOOP)
            );
        if stale { LINUX_ESTALE } else { errno }
    }

    fn node_stat(&mut self, nodeid: u64, body: &[u8]) -> Result<FuseStat, i32> {
        if !self.read_only
            && body.len() >= 16
            && u32::from_le_bytes(body[..4].try_into().unwrap()) & FUSE_GETATTR_FH != 0
        {
            let fh = u64::from_le_bytes(body[8..16].try_into().unwrap());
            let open = self
                .open_files
                .get(&fh)
                .filter(|open| open.nodeid == nodeid)
                .ok_or(LINUX_EBADF)?;
            return fstat_fd(open.file.as_raw_fd());
        }
        let by_path = self.stat_node(nodeid);
        if matches!(by_path, Err(LINUX_ENOENT | LINUX_ESTALE)) {
            if let Some(open) = self.open_files.values().find(|open| open.nodeid == nodeid) {
                return fstat_fd(open.file.as_raw_fd());
            }
            // A read-only node the host replaced, still read through its descriptor.
            if let Some(file) = self.ro_file_cache.get(&nodeid) {
                return fstat_fd(file.as_raw_fd());
            }
        }
        by_path
    }

    /// The owner a SETATTR naming owner fields (`valid`) leaves on the file
    /// `st` describes: both fields fixed, the one it does not name at the
    /// value this caller saw (see [`GuestAttr`]). None leaves the file as it
    /// is: a non-root caller handing a floating file to itself changes nothing
    /// (it already sees itself as owner) and must not pin it for other users.
    fn owner_after(
        &mut self,
        nodeid: u64,
        st: &FuseStat,
        body: &[u8],
        valid: u32,
    ) -> Result<Option<(u32, u32)>, i32> {
        let current = self.owners.get(&(st.dev, st.ino)).copied();
        let seen = match current {
            Some(pin) => pin,
            None => self.floating_owner(nodeid, false),
        };
        let uid = if valid & FATTR_UID != 0 {
            u32::from_le_bytes(body[76..80].try_into().unwrap())
        } else {
            seen.0
        };
        let gid = if valid & FATTR_GID != 0 {
            u32::from_le_bytes(body[80..84].try_into().unwrap())
        } else {
            seen.1
        };
        if current.is_none() {
            if self.caller.0 != 0 && (uid, gid) == self.caller {
                return Ok(None);
            }
            if self.owners.len() >= self.limits.pins {
                return Err(LINUX_ENOSPC);
            }
        }
        Ok(Some((uid, gid)))
    }

    /// FUSE_SETATTR. Changes apply through the handle the guest names, else
    /// to the node's entry with single-entry `*at` calls that need no access
    /// to its contents and never follow a symlink (only a truncate opens it),
    /// else, for a node already gone (its file unlinked or renamed over while
    /// open: `fchmod` and the like on that descriptor), through a handle open
    /// on it. Owner changes touch nothing on the host.
    fn set_attributes(&mut self, nodeid: u64, body: &[u8], valid: u32) -> Result<FuseStat, i32> {
        let handle = if valid & FATTR_FH != 0 {
            let fh = u64::from_le_bytes(body[8..16].try_into().unwrap());
            let open = self
                .open_files
                .get(&fh)
                .filter(|f| f.nodeid == nodeid)
                .ok_or(LINUX_EBADF)?;
            Some(open.file.clone())
        } else if !self.nodes.contains_key(&nodeid) {
            let open = self
                .open_files
                .values()
                .find(|f| f.nodeid == nodeid)
                .ok_or(LINUX_ESTALE)?;
            Some(open.file.clone())
        } else {
            None
        };
        let st = match &handle {
            Some(file) => fstat_fd(file.as_raw_fd())?,
            // An entry that is gone is a stale node to the guest, which then looks again.
            None => self.stat_node(nodeid).map_err(|e| match e {
                LINUX_ENOENT | LINUX_ENOTDIR | LINUX_ELOOP if self.has_identity(nodeid) => {
                    LINUX_ESTALE
                }
                e => e,
            })?,
        };
        let owner = if self.read_only || valid & (FATTR_UID | FATTR_GID) == 0 {
            None
        } else {
            self.owner_after(nodeid, &st, body, valid)?
        };
        if valid & FATTR_SIZE != 0 {
            let size = u64::from_le_bytes(body[16..24].try_into().unwrap()) as libc::off_t;
            let rc = match &handle {
                Some(file) => unsafe { libc::ftruncate(file.as_raw_fd(), size) },
                None => {
                    let (file, _) = self
                        .open_node(nodeid, libc::O_WRONLY)
                        .map_err(|e| self.open_failure(nodeid, e))?;
                    unsafe { libc::ftruncate(file.as_raw_fd(), size) }
                }
            };
            if rc != 0 {
                return Err(last_os_errno_linux());
            }
        }
        if valid & FATTR_MODE != 0 {
            let mode = u32::from_le_bytes(body[68..72].try_into().unwrap()) & 0o7777;
            let mode = guest_mode(mode, mode_is_dir(st.mode)) as libc::mode_t;
            match &handle {
                Some(file) => check_rc(unsafe { libc::fchmod(file.as_raw_fd(), mode) })?,
                None => self.at_leaf(nodeid, |dfd, name| {
                    check_rc(unsafe { libc::fchmodat(dfd, name.as_ptr(), mode, AT_NOFOLLOW_MODE) })
                })?,
            }
        }
        if valid & (FATTR_ATIME | FATTR_MTIME | FATTR_ATIME_NOW | FATTR_MTIME_NOW) != 0 {
            let time = |set: u32, now: u32, secs_at: usize, nsec_at: usize| {
                if valid & now != 0 {
                    return Ok(libc::timespec {
                        tv_sec: 0,
                        tv_nsec: libc::UTIME_NOW,
                    });
                }
                if valid & set == 0 {
                    return Ok(libc::timespec {
                        tv_sec: 0,
                        tv_nsec: libc::UTIME_OMIT,
                    });
                }
                let secs = i64::from_le_bytes(body[secs_at..secs_at + 8].try_into().unwrap());
                let nsec = u32::from_le_bytes(body[nsec_at..nsec_at + 4].try_into().unwrap());
                if nsec >= 1_000_000_000 {
                    return Err(LINUX_EINVAL);
                }
                Ok(libc::timespec {
                    tv_sec: secs as libc::time_t,
                    tv_nsec: nsec as libc::c_long,
                })
            };
            let times = [
                time(FATTR_ATIME, FATTR_ATIME_NOW, 32, 56)?,
                time(FATTR_MTIME, FATTR_MTIME_NOW, 40, 60)?,
            ];
            match &handle {
                Some(file) => {
                    check_rc(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?
                }
                None => self.at_leaf(nodeid, |dfd, name| {
                    check_rc(unsafe {
                        libc::utimensat(
                            dfd,
                            name.as_ptr(),
                            times.as_ptr(),
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    })
                })?,
            }
        }
        let st = match &handle {
            Some(file) => fstat_fd(file.as_raw_fd())?,
            None if valid
                & (FATTR_SIZE
                    | FATTR_MODE
                    | FATTR_ATIME
                    | FATTR_MTIME
                    | FATTR_ATIME_NOW
                    | FATTR_MTIME_NOW)
                != 0 =>
            {
                self.stat_node(nodeid)?
            }
            None => st,
        };
        if let Some(pin) = owner {
            self.owners.insert((st.dev, st.ino), pin);
        }
        Ok(st)
    }

    /// Forget the owner pinned on a file the guest no longer has a name or an
    /// open handle for (`gone`: its last name was just removed).
    fn release_owner(&mut self, identity: (u64, u64), gone: bool) {
        if gone
            && self.owners.contains_key(&identity)
            && !self.open_files.values().any(|f| f.identity == identity)
        {
            self.owners.remove(&identity);
        }
    }

    fn handles_full(&self) -> bool {
        self.open_files.len() + self.open_dirs.len() >= self.limits.handles
    }

    fn clock_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    /// The owner a floating file reached through node `nodeid` shows the
    /// current caller: a non-root caller itself (noted on the node when
    /// `note`), root the non-root user that used the node within the adoption
    /// window, else root.
    fn floating_owner(&mut self, nodeid: u64, note: bool) -> (u32, u32) {
        let caller = self.caller;
        let now = self.clock_ms();
        let window = self.adopt_window_ms;
        match self.nodes.get_mut(&nodeid) {
            Some(node) if caller.0 != 0 => {
                if note {
                    node.recent_user = Some(caller);
                    node.recent_at_ms = now;
                }
                caller
            }
            Some(node) => match node.recent_user {
                Some(user) if now.saturating_sub(node.recent_at_ms) < window => user,
                _ => (0, 0),
            },
            // A node already gone, reached through an open handle.
            None => caller,
        }
    }

    /// Inode number the guest sees for the host file `st` describes: hard
    /// links share it, as on the host. Files on volumes mounted inside the
    /// share have their device folded into the top byte.
    fn guest_ino(&mut self, st: &FuseStat) -> u64 {
        if st.dev == self.root_dev {
            return st.ino;
        }
        let index = match self.foreign_devs.iter().position(|&d| d == st.dev) {
            Some(i) => i,
            None if self.foreign_devs.len() < 255 => {
                self.foreign_devs.push(st.dev);
                self.foreign_devs.len() - 1
            }
            None => 254,
        };
        st.ino ^ ((index as u64 + 1) << 56)
    }

    /// Mode, owner and inode number the current caller sees for the host file
    /// `st` describes, reached through node `nodeid` (see [`GuestAttr`]).
    /// Read-only shares stay root-owned: the guest and this server cache their
    /// attributes for every caller, so they must not depend on who looked first.
    fn guest_attr(&mut self, nodeid: u64, st: &FuseStat) -> GuestAttr {
        let ino = self.guest_ino(st);
        if self.read_only {
            return GuestAttr {
                mode: st.mode,
                uid: 0,
                gid: 0,
                ino,
            };
        }
        let (uid, gid) = match self.owners.get(&(st.dev, st.ino)) {
            Some(&pin) => pin,
            None => self.floating_owner(nodeid, true),
        };
        GuestAttr {
            mode: guest_mode(st.mode, mode_is_dir(st.mode)),
            uid,
            gid,
            ino,
        }
    }

    fn encode_attr_stat(st: &FuseStat, attr: GuestAttr, out: &mut Vec<u8>) {
        // fuse_attr (88 bytes)
        out.extend_from_slice(&attr.ino.to_le_bytes()); // ino: the host's, so hard links match
        out.extend_from_slice(&st.size.to_le_bytes()); // size
        out.extend_from_slice(&st.blocks.to_le_bytes()); // blocks
        out.extend_from_slice(&(st.atime as u64).to_le_bytes()); // atime
        out.extend_from_slice(&(st.mtime as u64).to_le_bytes()); // mtime
        out.extend_from_slice(&(st.ctime as u64).to_le_bytes()); // ctime
        out.extend_from_slice(&(st.atime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&(st.mtime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&(st.ctime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&attr.mode.to_le_bytes()); // mode (POSIX matches Linux!)
        out.extend_from_slice(&st.nlink.to_le_bytes());
        // Guest-visible owner (see `FsCore::guest_attr`); the host owner is meaningless in the guest.
        out.extend_from_slice(&attr.uid.to_le_bytes()); // uid
        out.extend_from_slice(&attr.gid.to_le_bytes()); // gid
        out.extend_from_slice(&(st.rdev as u32).to_le_bytes());
        out.extend_from_slice(&4096u32.to_le_bytes()); // blksize
        out.extend_from_slice(&0u32.to_le_bytes()); // flags
    }

    fn encode_entry_out_stat(
        nodeid: u64,
        st: &FuseStat,
        (valid_secs, valid_nsecs): (u64, u32),
        attr: GuestAttr,
        out: &mut Vec<u8>,
    ) {
        // fuse_entry_out (128 bytes)
        out.extend_from_slice(&nodeid.to_le_bytes());
        out.extend_from_slice(&1u64.to_le_bytes()); // generation
        out.extend_from_slice(&valid_secs.to_le_bytes()); // entry_valid
        out.extend_from_slice(&valid_secs.to_le_bytes()); // attr_valid
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // entry_valid_nsec
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // attr_valid_nsec
        Self::encode_attr_stat(st, attr, out);
    }

    /// How long the guest may keep an entry or attributes the host just reported.
    fn validity(&self) -> (u64, u32) {
        if self.read_only {
            validity_left(self.ro_validity_ms, 0).unwrap_or((0, 0))
        } else {
            RW_VALIDITY
        }
    }

    /// Reply with a `fuse_entry_out` for node `id`, which the guest then
    /// references once more.
    fn write_entry(&mut self, unique: u64, id: u64, st: &FuseStat) -> bool {
        let valid = self.validity();
        self.write_entry_valid(unique, id, st, valid)
    }

    fn write_entry_valid(
        &mut self,
        unique: u64,
        id: u64,
        st: &FuseStat,
        valid: (u64, u32),
    ) -> bool {
        self.add_lookup(id);
        let attr = self.guest_attr(id, st);
        self.begin_ok(unique);
        Self::encode_entry_out_stat(id, st, valid, attr, &mut self.resp_buf);
        self.finish_ok()
    }

    /// Reply with a `fuse_attr_out` for node `id`.
    fn write_attr(&mut self, unique: u64, id: u64, st: &FuseStat) -> bool {
        let valid = self.validity();
        self.write_attr_valid(unique, id, st, valid)
    }

    fn write_attr_valid(
        &mut self,
        unique: u64,
        id: u64,
        st: &FuseStat,
        (valid_secs, valid_nsecs): (u64, u32),
    ) -> bool {
        let attr = self.guest_attr(id, st);
        self.begin_ok(unique);
        self.resp_buf.extend_from_slice(&valid_secs.to_le_bytes());
        self.resp_buf.extend_from_slice(&valid_nsecs.to_le_bytes());
        self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
        Self::encode_attr_stat(st, attr, &mut self.resp_buf);
        self.finish_ok()
    }

    /// Remember what the host just reported for the entry `name` of read-only
    /// directory node `parent`: the node it binds and that node's
    /// attributes, or the error.
    fn ro_remember_entry(&mut self, parent: u64, name: &[u8], found: Result<(u64, FuseStat), i32>) {
        let now = self.clock_ms();
        if self.ro_lookup_cache.len() >= MAX_RO_CACHE {
            self.ro_lookup_cache.clear();
        }
        self.ro_lookup_cache
            .insert((parent, name.to_vec()), (found.map(|(id, _)| id), now));
        if let Ok((id, st)) = found {
            self.ro_remember_attr(id, st, now);
        }
    }

    fn ro_remember_attr(&mut self, id: u64, st: FuseStat, now: u64) {
        if self.ro_attr_cache.len() >= MAX_RO_CACHE {
            self.ro_attr_cache.clear();
        }
        self.ro_attr_cache.insert(id, (st, now));
    }

    /// Attributes of read-only node `id` the host reported recently enough,
    /// with what is left of their validity.
    fn ro_cached_attr(&mut self, id: u64) -> Option<(FuseStat, (u64, u32))> {
        let &(st, seen) = self.ro_attr_cache.get(&id)?;
        let left = validity_left(self.ro_validity_ms, self.clock_ms().saturating_sub(seen));
        if left.is_none() {
            self.ro_attr_cache.remove(&id);
        }
        Some((st, left?))
    }

    /// Reply to a LOOKUP of `name` in read-only directory node `parent` from
    /// what the host answered recently enough, if it did.
    fn ro_cached_lookup(&mut self, unique: u64, parent: u64, name: &[u8]) -> Option<bool> {
        let key = (parent, name.to_vec());
        let &(found, seen) = self.ro_lookup_cache.get(&key)?;
        let Some(left) = validity_left(self.ro_validity_ms, self.clock_ms().saturating_sub(seen))
        else {
            self.ro_lookup_cache.remove(&key);
            return None;
        };
        match found {
            Ok(id) => {
                let (st, attr_left) = self.ro_cached_attr(id)?;
                Some(self.write_entry_valid(unique, id, &st, left.min(attr_left)))
            }
            Err(e) => Some(self.write_err(unique, e)),
        }
    }

    #[inline]
    fn write_err(&mut self, unique: u64, errno: i32) -> bool {
        self.resp_buf.clear();
        self.resp_buf.extend_from_slice(&16u32.to_le_bytes());
        self.resp_buf.extend_from_slice(&(-errno).to_le_bytes());
        self.resp_buf.extend_from_slice(&unique.to_le_bytes());
        true
    }

    #[inline]
    fn begin_ok(&mut self, unique: u64) {
        self.resp_buf.clear();
        self.resp_buf.extend_from_slice(&0u32.to_le_bytes()); // patched in finish_ok
        self.resp_buf.extend_from_slice(&0i32.to_le_bytes());
        self.resp_buf.extend_from_slice(&unique.to_le_bytes());
    }

    #[inline]
    fn finish_ok(&mut self) -> bool {
        let len = self.resp_buf.len() as u32;
        self.resp_buf[0..4].copy_from_slice(&len.to_le_bytes());
        true
    }

    #[inline]
    fn write_ok_slice(&mut self, unique: u64, body: &[u8]) -> bool {
        self.begin_ok(unique);
        self.resp_buf.extend_from_slice(body);
        self.finish_ok()
    }

    fn parse_cstr(b: &[u8]) -> (&[u8], &[u8]) {
        match b.iter().position(|&c| c == 0) {
            Some(i) => (&b[..i], &b[i + 1..]),
            None => (b, &[]),
        }
    }

    fn linux_open_flags_to_darwin(flags: u32, read_only: bool) -> Result<i32, i32> {
        let acc = flags & 0x3;
        let write = acc == 1 || acc == 2;
        let trunc = (flags & 0o1000) != 0; // Linux O_TRUNC = 01000
        let append = (flags & 0o2000) != 0; // Linux O_APPEND = 02000
        let create = (flags & 0o100) != 0; // Linux O_CREAT = 0100
        let excl = (flags & 0o200) != 0; // Linux O_EXCL = 0200
        if read_only && (write || trunc || create) {
            return Err(LINUX_EROFS);
        }
        let mut out = match acc {
            0 => libc::O_RDONLY,
            1 => libc::O_WRONLY,
            2 => libc::O_RDWR,
            _ => return Err(LINUX_EINVAL),
        };
        if trunc {
            out |= libc::O_TRUNC;
        }
        if append {
            out |= libc::O_APPEND;
        }
        if create {
            out |= libc::O_CREAT;
            if excl {
                out |= libc::O_EXCL;
            }
        }
        Ok(out | libc::O_CLOEXEC)
    }

    /// Resolve the entry `cname` of directory node `parent` for FUSE_LOOKUP.
    fn lookup_entry(&mut self, parent: u64, cname: &CStr) -> Result<(u64, FuseStat), i32> {
        let name = cname.to_bytes();
        if name == b"." || name == b".." {
            let id = if name == b"." || parent == FUSE_ROOT_ID {
                parent
            } else {
                self.nodes.get(&parent).ok_or(LINUX_ESTALE)?.parent
            };
            return self.stat_node(id).map(|st| (id, st));
        }
        if name.is_empty() || name.contains(&b'/') {
            return Err(LINUX_EINVAL);
        }
        let pfd = self.dir_fd(parent)?;
        let st = fstatat_cstr(pfd.as_raw_fd(), cname)?;
        Ok((self.bind_entry(parent, pfd.as_raw_fd(), cname, &st)?, st))
    }

    /// Reply with the entry `name` a MKDIR, SYMLINK or LINK just made in
    /// directory node `parent` (descriptor `pfd`).
    fn write_new_entry(&mut self, unique: u64, parent: u64, pfd: RawFd, name: &CStr) -> bool {
        let bound = fstatat_cstr(pfd, name)
            .and_then(|st| Ok((self.bind_entry(parent, pfd, name, &st)?, st)));
        match bound {
            Ok((id, st)) => self.write_entry(unique, id, &st),
            Err(e) => self.write_err(unique, e),
        }
    }

    /// Keep an open file of node `nodeid` as a new handle.
    fn add_open_file(&mut self, nodeid: u64, file: File, st: &FuseStat) -> u64 {
        let fh = self.next_fh;
        self.next_fh += 1;
        self.open_files.insert(
            fh,
            OpenFile {
                nodeid,
                file: Arc::new(file),
                identity: (st.dev, st.ino),
            },
        );
        self.metrics.open_handles.fetch_add(1, Ordering::Relaxed);
        fh
    }

    fn direct_open_flags(&self, st: &FuseStat) -> u32 {
        if self.direct_io_mmap && st.mode & libc::S_IFMT as u32 == libc::S_IFREG as u32 {
            FOPEN_DIRECT_IO
        } else {
            0
        }
    }

    /// Attributes of an entry a listing of directory node `parent` (open at
    /// `dir_fd`) returned. A mount point, or a directory whose node is bound
    /// to another file than the listing reports, is looked up instead: the
    /// listing names the covered directory, while a lookup (and every later
    /// access through the node) reaches the mounted root.
    fn listed_stat(&self, parent: u64, dir_fd: RawFd, e: &BulkDirEntry) -> FuseStat {
        if mode_is_dir(e.stat.mode) {
            let rebound = self
                .child_id(parent, &e.name)
                .and_then(|id| self.nodes.get(&id)?.identity)
                .is_some_and(|known| known != (e.stat.dev, e.stat.ino));
            if (e.mount_point || rebound)
                && let Ok(st) = fstatat_cstr(dir_fd, &e.name)
            {
                return st;
            }
        }
        e.stat
    }

    /// FUSE_READDIR(PLUS) on open directory handle `fh` from entry `offset`.
    fn read_directory(
        &mut self,
        unique: u64,
        plus: bool,
        fh: u64,
        offset: usize,
        max_size: usize,
    ) -> bool {
        let Some(od) = self.open_dirs.get_mut(&fh) else {
            return self.write_err(unique, LINUX_EBADF);
        };
        let (dir_nodeid, dir_fd) = (od.dir_nodeid, od.dir_fd.as_raw_fd());
        let mut listing = std::mem::take(&mut od.listing);
        let done = self.list_into(
            unique,
            plus,
            dir_nodeid,
            dir_fd,
            &mut listing,
            offset,
            max_size,
        );
        if let Some(od) = self.open_dirs.get_mut(&fh) {
            od.listing = listing;
        }
        done
    }

    #[allow(clippy::too_many_arguments)]
    fn list_into(
        &mut self,
        unique: u64,
        plus: bool,
        dir_nodeid: u64,
        dir_fd: RawFd,
        l: &mut DirListing,
        offset: usize,
        max_size: usize,
    ) -> bool {
        if offset == 0 || !l.started || offset < l.base {
            // A directory the host moved out of the share is not listed.
            if !self.fd_within_share(dir_fd) {
                return self.write_err(unique, LINUX_ESTALE);
            }
            l.rewind(dir_fd);
        }
        // Drop what the guest is past, reading on until `offset` is held.
        loop {
            let past = offset.saturating_sub(l.base).min(l.window.len());
            l.window.drain(..past);
            l.base += past;
            if l.base + l.window.len() > offset || l.eof {
                break;
            }
            if let Err(e) = l.fill(dir_fd, &mut self.bulk_buf) {
                return self.write_err(unique, e);
            }
        }
        // Entries listed under a node already gone are sent without one.
        let live = self.nodes.contains_key(&dir_nodeid);
        let ro = self.read_only;
        let valid = self.validity();
        self.begin_ok(unique);
        let body_start = self.resp_buf.len();
        let mut index = offset.max(l.base);
        loop {
            let k = index - l.base;
            if k >= l.window.len() {
                if l.eof {
                    break;
                }
                match l.fill(dir_fd, &mut self.bulk_buf) {
                    Ok(()) => continue,
                    Err(_) if index > offset => break,
                    Err(e) => return self.write_err(unique, e),
                }
            }
            let e = &l.window[k];
            let name = e.name.to_bytes();
            let raw_ent = (if plus { 128 } else { 0 }) + 24 + name.len();
            if (self.resp_buf.len() - body_start) + ((raw_ent + 7) & !7) > max_size {
                break;
            }
            let st = self.listed_stat(dir_nodeid, dir_fd, e);
            let ino = self.guest_ino(&st);
            if plus {
                if live {
                    // A node the host renamed since takes the listed name.
                    self.adopt_renamed(dir_nodeid, dir_fd, &e.name, &st);
                }
                let id = if live
                    && (self.child_id(dir_nodeid, &e.name).is_some()
                        || self.nodes.len() < self.limits.nodes)
                {
                    Some(self.observe_child(dir_nodeid, &e.name, &st))
                } else {
                    None
                };
                match id {
                    Some(id) => {
                        if ro {
                            self.ro_remember_entry(dir_nodeid, name, Ok((id, st)));
                        }
                        self.add_lookup(id);
                        let attr = self.guest_attr(id, &st);
                        Self::encode_entry_out_stat(id, &st, valid, attr, &mut self.resp_buf);
                    }
                    // Node ID 0: the guest lists the entry without binding it.
                    None => self.resp_buf.extend_from_slice(&[0u8; 128]),
                }
            }
            let dtype = st.dtype();
            self.resp_buf.extend_from_slice(&ino.to_le_bytes());
            self.resp_buf
                .extend_from_slice(&((index + 1) as u64).to_le_bytes());
            self.resp_buf
                .extend_from_slice(&(name.len() as u32).to_le_bytes());
            self.resp_buf.extend_from_slice(&dtype.to_le_bytes());
            self.resp_buf.extend_from_slice(name);
            while !(self.resp_buf.len() - body_start).is_multiple_of(8) {
                self.resp_buf.push(0);
            }
            index += 1;
        }
        // Keep a short tail of what was sent and what was read but not sent.
        let keep_from = (index - l.base).saturating_sub(DIR_RETAIN);
        l.window.drain(..keep_from);
        l.base += keep_from;
        self.finish_ok()
    }

    /// Handle a FUSE request, writing any response into `self.resp_buf` (zero allocs!).
    /// Returns `true` if a response was produced in `self.resp_buf`, `false` for no-reply ops.
    fn handle_fuse_into(&mut self, req: &[u8]) -> bool {
        if req.len() < 40 {
            return false;
        }
        self.metrics.requests.fetch_add(1, Ordering::Relaxed);
        let opcode = u32::from_le_bytes(req[4..8].try_into().unwrap());
        let unique = u64::from_le_bytes(req[8..16].try_into().unwrap());
        let nodeid = u64::from_le_bytes(req[16..24].try_into().unwrap());
        self.caller = (
            u32::from_le_bytes(req[24..28].try_into().unwrap()),
            u32::from_le_bytes(req[28..32].try_into().unwrap()),
        );
        let body = &req[40..];

        match opcode {
            FUSE_INIT => {
                let in_flags = body
                    .get(12..16)
                    .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                    .unwrap_or(0);
                self.reset_session();
                self.direct_io_mmap = false;
                if self.direct_io_requested {
                    let guest_major = body
                        .get(..4)
                        .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                        .unwrap_or(0);
                    let guest_minor = body
                        .get(4..8)
                        .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                        .unwrap_or(0);
                    let guest_flags2 = body
                        .get(16..20)
                        .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                        .unwrap_or(0);
                    self.direct_io_mmap = guest_major == 7
                        && guest_minor >= FUSE_DIRECT_IO_MMAP_MINOR
                        && in_flags & FUSE_INIT_EXT != 0
                        && guest_flags2 & FUSE_DIRECT_IO_ALLOW_MMAP_FLAGS2 != 0;
                    eprintln!(
                        "[virtiofs-workspace] direct_io_mmap={} guest_minor={guest_minor}",
                        self.direct_io_mmap
                    );
                    if !self.direct_io_mmap {
                        return self.write_err(unique, LINUX_EOPNOTSUPP);
                    }
                }
                let (minor, flags2) = if self.direct_io_mmap {
                    (FUSE_DIRECT_IO_MMAP_MINOR, FUSE_DIRECT_IO_ALLOW_MMAP_FLAGS2)
                } else {
                    (31, 0u32)
                };
                self.begin_ok(unique);
                self.resp_buf.extend_from_slice(&7u32.to_le_bytes()); // major
                self.resp_buf.extend_from_slice(&minor.to_le_bytes());
                self.resp_buf
                    .extend_from_slice(&(256 * 1024u32).to_le_bytes()); // max_readahead (256 KiB)
                let mut flags = FUSE_ASYNC_READ
                    | FUSE_BIG_WRITES
                    | FUSE_DO_READDIRPLUS
                    | FUSE_PARALLEL_DIROPS
                    | FUSE_MAX_PAGES
                    | FUSE_CACHE_SYMLINKS;
                if (in_flags & FUSE_ATOMIC_O_TRUNC) != 0 {
                    flags |= FUSE_ATOMIC_O_TRUNC;
                }
                if self.direct_io_mmap {
                    flags |= FUSE_INIT_EXT;
                }
                if self.read_only {
                    // Read-only shares (e.g. oci-tools) skip FUSE_OPEN/FLUSH/RELEASE completely
                    // (Linux sets fc->no_open=1 and FOPEN_KEEP_CACHE automatically) and keep the
                    // guest page cache warm across container execs. That cache is per node, and a
                    // file the host replaces binds a new node (see `observe_child`).
                    flags |= FUSE_NO_OPEN_SUPPORT;
                }
                // Pages cached for a file whose size or mtime changed are dropped when its
                // attributes are refreshed (and a read-only share's directory listings with
                // its mtime): free while nothing changes.
                if (in_flags & FUSE_AUTO_INVAL_DATA) != 0 {
                    flags |= FUSE_AUTO_INVAL_DATA;
                }
                self.resp_buf.extend_from_slice(&flags.to_le_bytes());
                self.resp_buf.extend_from_slice(&64u16.to_le_bytes()); // max_background
                self.resp_buf.extend_from_slice(&48u16.to_le_bytes()); // congestion_threshold
                self.resp_buf
                    .extend_from_slice(&(256 * 1024u32).to_le_bytes()); // max_write (256 KiB)
                self.resp_buf.extend_from_slice(&1u32.to_le_bytes()); // time_gran
                self.resp_buf.extend_from_slice(&64u16.to_le_bytes()); // max_pages
                self.resp_buf.extend_from_slice(&0u16.to_le_bytes()); // map_alignment
                self.resp_buf.extend_from_slice(&flags2.to_le_bytes());
                self.resp_buf.extend_from_slice(&[0u8; 28]);
                self.finish_ok()
            }
            FUSE_DESTROY => self.write_ok_slice(unique, &[]),
            // No reply for either.
            FUSE_FORGET => {
                if let Some(count) = body.get(..8) {
                    self.forget(nodeid, u64::from_le_bytes(count.try_into().unwrap()));
                }
                false
            }
            FUSE_BATCH_FORGET => {
                if body.len() >= 8 {
                    let count = u32::from_le_bytes(body[..4].try_into().unwrap()) as usize;
                    for one in body[8..].as_chunks::<16>().0.iter().take(count) {
                        let id = u64::from_le_bytes(one[..8].try_into().unwrap());
                        let n = u64::from_le_bytes(one[8..].try_into().unwrap());
                        self.forget(id, n);
                    }
                }
                false
            }
            FUSE_LOOKUP => {
                let cname = match CStr::from_bytes_until_nul(body) {
                    Ok(name) => Cow::Borrowed(name),
                    Err(_) => match CString::new(body) {
                        Ok(name) => Cow::Owned(name),
                        Err(_) => return self.write_err(unique, LINUX_EINVAL),
                    },
                };
                let name = cname.to_bytes();
                if self.read_only
                    && let Some(replied) = self.ro_cached_lookup(unique, nodeid, name)
                {
                    return replied;
                }
                match self.lookup_entry(nodeid, &cname) {
                    Ok((id, st)) => {
                        if self.read_only {
                            self.ro_remember_entry(nodeid, cname.to_bytes(), Ok((id, st)));
                        }
                        self.write_entry(unique, id, &st)
                    }
                    Err(le) => {
                        if self.read_only && le != LINUX_ENFILE {
                            self.ro_remember_entry(nodeid, cname.to_bytes(), Err(le));
                        }
                        self.write_err(unique, le)
                    }
                }
            }
            FUSE_GETATTR => {
                if self.read_only
                    && let Some((st, valid)) = self.ro_cached_attr(nodeid)
                {
                    return self.write_attr_valid(unique, nodeid, &st, valid);
                }
                match self.node_stat(nodeid, body) {
                    Ok(st) => {
                        if self.read_only && self.nodes.contains_key(&nodeid) {
                            let now = self.clock_ms();
                            self.ro_remember_attr(nodeid, st, now);
                        }
                        self.write_attr(unique, nodeid, &st)
                    }
                    Err(errno) => self.write_err(unique, errno),
                }
            }
            FUSE_SETATTR => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                if body.len() < 88 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let valid = u32::from_le_bytes(body[0..4].try_into().unwrap());
                match self.set_attributes(nodeid, body, valid) {
                    Ok(st) => self.write_attr(unique, nodeid, &st),
                    Err(errno) => self.write_err(unique, errno),
                }
            }
            FUSE_READLINK => {
                let mut lbuf = [0u8; 4096];
                let read = self.at_leaf(nodeid, |dfd, name| {
                    let n = unsafe {
                        libc::readlinkat(dfd, name.as_ptr(), lbuf.as_mut_ptr().cast(), lbuf.len())
                    };
                    if n < 0 {
                        Err(last_os_errno_linux())
                    } else {
                        Ok(n as usize)
                    }
                });
                match read {
                    Ok(n) => self.write_ok_slice(unique, &lbuf[..n]),
                    Err(e) => self.write_err(unique, e),
                }
            }
            FUSE_OPEN => {
                if body.len() < 8 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let flags = u32::from_le_bytes(body[0..4].try_into().unwrap());
                if self.read_only {
                    if let Err(e) = Self::linux_open_flags_to_darwin(flags, true) {
                        return self.write_err(unique, e);
                    }
                    // Tell Linux FUSE to activate fc->no_open=1 + FOPEN_KEEP_CACHE so subsequent
                    // opens/execs/closes on read-only binaries incur ZERO FUSE VM exits!
                    return self.write_err(unique, LINUX_ENOSYS);
                }
                // Validate the opened inode before applying a truncating open.
                // FUSE_CREATE is responsible for creating missing pathnames.
                let base_darwin = match Self::linux_open_flags_to_darwin(
                    flags & !(0o100 | 0o200 | 0o1000),
                    false,
                ) {
                    Ok(f) => f,
                    Err(e) => return self.write_err(unique, e),
                };
                if self.handles_full() {
                    return self.write_err(unique, LINUX_ENFILE);
                }
                let (file, st) = match self.open_node(nodeid, base_darwin) {
                    Ok(opened) => opened,
                    Err(e) => {
                        let errno = self.open_failure(nodeid, e);
                        return self.write_err(unique, errno);
                    }
                };
                if flags & 0o1000 != 0 && unsafe { libc::ftruncate(file.as_raw_fd(), 0) } != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                let fh = self.add_open_file(nodeid, file, &st);
                let mut out = [0u8; 16];
                out[0..8].copy_from_slice(&fh.to_le_bytes());
                // An ordinary read must go to the host descriptor in direct
                // mode even when host writes leave size and mtime unchanged.
                let mut open_flags = self.direct_open_flags(&st);
                // Skipping FLUSH remains safe for handles that cannot write.
                if flags & (3 | 0o1000 | 0o2000) == 0 {
                    open_flags |= FOPEN_NOFLUSH;
                }
                out[8..12].copy_from_slice(&open_flags.to_le_bytes());
                self.write_ok_slice(unique, &out)
            }
            FUSE_CREATE => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                if body.len() < 16 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let flags = u32::from_le_bytes(body[0..4].try_into().unwrap());
                let mode = u32::from_le_bytes(body[4..8].try_into().unwrap());
                let (name, _) = Self::parse_cstr(&body[16..]);
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                // An existing symlink at the name is never opened through, and
                // an existing FIFO is not waited on (see `open_entry_at`).
                let darwin_flags = match Self::linux_open_flags_to_darwin(flags | 0o100, false) {
                    Ok(f) => f,
                    Err(e) => return self.write_err(unique, e),
                };
                if self.handles_full() {
                    return self.write_err(unique, LINUX_ENFILE);
                }
                if let Err(e) = self.node_room() {
                    return self.write_err(unique, e);
                }
                let create_mode = guest_mode(mode & 0o7777, false) as libc::c_uint;
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                let opened = open_entry_at(pfd.as_raw_fd(), &cname, darwin_flags, create_mode)
                    .and_then(|fd| {
                        let st = fstat_fd(fd.as_raw_fd())?;
                        if mode_is_dir(st.mode) {
                            return Err(LINUX_EISDIR);
                        }
                        Ok((host_handle(fd, &st, darwin_flags)?, st))
                    });
                let (file, st) = match opened {
                    Ok(opened) => opened,
                    Err(e) => return self.write_err(unique, e),
                };
                let id = match self.bind_entry(nodeid, pfd.as_raw_fd(), &cname, &st) {
                    Ok(id) => id,
                    Err(e) => return self.write_err(unique, e),
                };
                let fh = self.add_open_file(id, file, &st);
                self.add_lookup(id);
                let attr = self.guest_attr(id, &st);
                let valid = self.validity();
                self.begin_ok(unique);
                Self::encode_entry_out_stat(id, &st, valid, attr, &mut self.resp_buf);
                self.resp_buf.extend_from_slice(&fh.to_le_bytes());
                self.resp_buf
                    .extend_from_slice(&self.direct_open_flags(&st).to_le_bytes());
                self.resp_buf.extend_from_slice(&0i32.to_le_bytes());
                self.finish_ok()
            }
            FUSE_READ => {
                if body.len() < 24 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let offset = u64::from_le_bytes(body[8..16].try_into().unwrap());
                let size = (u32::from_le_bytes(body[16..20].try_into().unwrap()) as usize)
                    .min(1024 * 1024);
                let file = match self.resolve_read_file(nodeid, fh) {
                    Ok(f) => f,
                    Err(e) => return self.write_err(unique, e),
                };
                if self.read_buf.len() < size {
                    self.read_buf.resize(size, 0);
                }
                match file.read_at(&mut self.read_buf[..size], offset) {
                    Ok(n) => {
                        self.metrics
                            .bytes_read
                            .fetch_add(n as u64, Ordering::Relaxed);
                        self.begin_ok(unique);
                        self.resp_buf.extend_from_slice(&self.read_buf[..n]);
                        self.finish_ok()
                    }
                    Err(e) => self.write_err(unique, io_err_to_linux(&e)),
                }
            }
            FUSE_WRITE => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                if body.len() < 40 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let offset = u64::from_le_bytes(body[8..16].try_into().unwrap());
                let size = u32::from_le_bytes(body[16..20].try_into().unwrap()) as usize;
                let data = &body[40..body.len().min(40 + size)];
                let Some(file) = self.open_files.get(&fh) else {
                    return self.write_err(unique, LINUX_EBADF);
                };
                match file.file.write_at(data, offset) {
                    Ok(n) => {
                        self.metrics
                            .bytes_written
                            .fetch_add(n as u64, Ordering::Relaxed);
                        let mut out = [0u8; 8];
                        out[0..4].copy_from_slice(&(n as u32).to_le_bytes());
                        self.write_ok_slice(unique, &out)
                    }
                    Err(e) => self.write_err(unique, io_err_to_linux(&e)),
                }
            }
            FUSE_FLUSH => self.write_err(unique, LINUX_ENOSYS),
            FUSE_FSYNC | FUSE_FSYNCDIR => {
                // fuse_fsync_in is a handle, a flag word and four padding bytes.
                if body.len() != 16
                    || u32::from_le_bytes(req[0..4].try_into().unwrap()) as usize != req.len()
                {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let flags = u32::from_le_bytes(body[8..12].try_into().unwrap());
                if flags & !FUSE_FSYNC_FDATASYNC != 0 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                match self.sync_handle(opcode, nodeid, fh, flags & FUSE_FSYNC_FDATASYNC != 0) {
                    Ok(()) => self.write_ok_slice(unique, &[]),
                    // Linux interprets ENOSYS as permission to skip future syncs.
                    Err(LINUX_ENOSYS) => self.write_err(unique, LINUX_EOPNOTSUPP),
                    Err(e) => self.write_err(unique, e),
                }
            }
            FUSE_RELEASE => {
                if body.len() >= 8 {
                    let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                    if let Some(open) = self.open_files.remove(&fh) {
                        self.metrics.open_handles.fetch_sub(1, Ordering::Relaxed);
                        // The last handle on a file the guest unlinked.
                        if self.owners.contains_key(&open.identity) {
                            let gone =
                                fstat_fd(open.file.as_raw_fd()).is_ok_and(|st| st.nlink == 0);
                            self.release_owner(open.identity, gone);
                        }
                    }
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_OPENDIR => {
                if self.handles_full() || self.open_dirs.len() >= self.limits.dirs {
                    return self.write_err(unique, LINUX_ENFILE);
                }
                let dir_fd = match self.open_node(nodeid, libc::O_RDONLY | libc::O_DIRECTORY) {
                    Ok((dir, st)) if mode_is_dir(st.mode) => OwnedFd::from(dir),
                    Ok(_) => return self.write_err(unique, LINUX_ENOTDIR),
                    Err(e) => {
                        let errno = self.open_failure(nodeid, e);
                        return self.write_err(unique, errno);
                    }
                };
                // Also populate dir_fds cache via dup so subsequent child lookups/opens use dirfd!
                if nodeid != FUSE_ROOT_ID && !self.dir_fds.contains_key(&nodeid) {
                    let dup_fd =
                        unsafe { libc::fcntl(dir_fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
                    if dup_fd >= 0 {
                        self.cache_dir(nodeid, Arc::new(unsafe { OwnedFd::from_raw_fd(dup_fd) }));
                    }
                }
                let fh = self.next_fh;
                self.next_fh += 1;
                self.open_dirs.insert(
                    fh,
                    OpenDir {
                        dir_nodeid: nodeid,
                        dir_fd,
                        listing: DirListing::default(),
                    },
                );
                self.metrics.open_handles.fetch_add(1, Ordering::Relaxed);
                let mut out = [0u8; 16];
                out[0..8].copy_from_slice(&fh.to_le_bytes());
                let open_flags = if self.read_only {
                    FOPEN_KEEP_CACHE | FOPEN_CACHE_DIR | FOPEN_NOFLUSH
                } else {
                    0
                };
                out[8..12].copy_from_slice(&open_flags.to_le_bytes());
                self.write_ok_slice(unique, &out)
            }
            FUSE_READDIR | FUSE_READDIRPLUS => {
                if body.len() < 20 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let offset = u64::from_le_bytes(body[8..16].try_into().unwrap()) as usize;
                let max_size = u32::from_le_bytes(body[16..20].try_into().unwrap()) as usize;
                self.read_directory(unique, opcode == FUSE_READDIRPLUS, fh, offset, max_size)
            }
            FUSE_RELEASEDIR => {
                if body.len() >= 8 {
                    let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                    if self.open_dirs.remove(&fh).is_some() {
                        self.metrics.open_handles.fetch_sub(1, Ordering::Relaxed);
                    }
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_MKDIR => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                if body.len() < 8 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let mode = u32::from_le_bytes(body[0..4].try_into().unwrap());
                let (name, _) = Self::parse_cstr(&body[8..]);
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                if let Err(e) = self.node_room() {
                    return self.write_err(unique, e);
                }
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                let dir_mode = guest_mode(mode & 0o7777, true) as libc::mode_t;
                if unsafe { libc::mkdirat(pfd.as_raw_fd(), cname.as_ptr(), dir_mode) } != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                self.write_new_entry(unique, nodeid, pfd.as_raw_fd(), &cname)
            }
            FUSE_UNLINK | FUSE_RMDIR => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let (name, _) = Self::parse_cstr(body);
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                // The entry's node, under the name the host stores it by, and
                // its file when an owner is pinned on it (the pin goes with
                // the last name).
                let known = self
                    .child_id(nodeid, &cname)
                    .and_then(|id| self.nodes.get(&id)?.identity);
                let before = match known {
                    Some(identity) if !self.owners.contains_key(&identity) => None,
                    _ => fstatat_cstr(pfd.as_raw_fd(), &cname).ok(),
                };
                let key = match &before {
                    Some(st) => self
                        .child_key(nodeid, pfd.as_raw_fd(), &cname, st)
                        .into_owned(),
                    None => cname.clone(),
                };
                let flags = if opcode == FUSE_RMDIR {
                    libc::AT_REMOVEDIR
                } else {
                    0
                };
                if unsafe { libc::unlinkat(pfd.as_raw_fd(), cname.as_ptr(), flags) } != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                // Open handles to the removed file stay valid; its node does not.
                self.retire_child(nodeid, &key);
                if let Some(st) = before {
                    self.release_owner((st.dev, st.ino), mode_is_dir(st.mode) || st.nlink <= 1);
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_RENAME | FUSE_RENAME2 => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let hdr_len = if opcode == FUSE_RENAME2 { 16 } else { 8 };
                if body.len() < hdr_len {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let newdir = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let rename_flags = if opcode == FUSE_RENAME2 {
                    u32::from_le_bytes(body[8..12].try_into().unwrap())
                } else {
                    0
                };
                if rename_flags & !(LINUX_RENAME_NOREPLACE | LINUX_RENAME_EXCHANGE) != 0
                    || rename_flags == LINUX_RENAME_NOREPLACE | LINUX_RENAME_EXCHANGE
                {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let (oldname, rest) = Self::parse_cstr(&body[hdr_len..]);
                let (newname, _) = Self::parse_cstr(rest);
                let (old_cname, new_cname) = match (entry_name(oldname), entry_name(newname)) {
                    (Ok(o), Ok(n)) => (o, n),
                    (Err(e), _) | (_, Err(e)) => return self.write_err(unique, e),
                };
                let (opfd, npfd) = match (self.dir_fd(nodeid), self.dir_fd(newdir)) {
                    (Ok(o), Ok(n)) => (o, n),
                    (Err(e), _) | (_, Err(e)) => return self.write_err(unique, e),
                };
                let (opfd, npfd) = (opfd.as_raw_fd(), npfd.as_raw_fd());
                // Both entries before the rename, under the names the host
                // stores them by (the guest may use other spellings).
                let src = fstatat_cstr(opfd, &old_cname).ok();
                let dst = fstatat_cstr(npfd, &new_cname).ok();
                let old_key = match &src {
                    Some(st) => self.child_key(nodeid, opfd, &old_cname, st).into_owned(),
                    None => old_cname.clone(),
                };
                let dst_key = match &dst {
                    Some(st) => self.child_key(newdir, npfd, &new_cname, st).into_owned(),
                    None => new_cname.clone(),
                };
                if let Err(e) = host_rename(opfd, &old_cname, npfd, &new_cname, rename_flags) {
                    return self.write_err(unique, e);
                }
                if rename_flags & LINUX_RENAME_EXCHANGE != 0 {
                    self.exchange_children(nodeid, &old_key, newdir, &dst_key);
                } else {
                    let same_file = matches!((&src, &dst), (Some(s), Some(d)) if (s.dev, s.ino) == (d.dev, d.ino));
                    let same_entry = (nodeid, &old_key) == (newdir, &dst_key);
                    // Renaming one hard link onto another of the same file
                    // leaves both. Renaming an entry to another spelling of its
                    // own name (case or normalisation only) renames it.
                    if !same_file || same_entry {
                        let new_key = src
                            .as_ref()
                            .and_then(|st| darwin_bulk::stored_name(npfd, &new_cname, st))
                            .unwrap_or_else(|| new_cname.clone());
                        self.move_child(nodeid, &old_key, newdir, new_key, &dst_key);
                        if let Some(d) = dst.filter(|_| !same_file) {
                            self.release_owner((d.dev, d.ino), mode_is_dir(d.mode) || d.nlink <= 1);
                        }
                    }
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_SYMLINK => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let (name, rest) = Self::parse_cstr(body);
                let (target, _) = Self::parse_cstr(rest);
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let ctarget = match CString::new(target) {
                    Ok(c) => c,
                    Err(_) => return self.write_err(unique, LINUX_EINVAL),
                };
                if let Err(e) = self.node_room() {
                    return self.write_err(unique, e);
                }
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                if unsafe { libc::symlinkat(ctarget.as_ptr(), pfd.as_raw_fd(), cname.as_ptr()) }
                    != 0
                {
                    return self.write_err(unique, last_os_errno_linux());
                }
                self.write_new_entry(unique, nodeid, pfd.as_raw_fd(), &cname)
            }
            FUSE_LINK => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                if body.len() < 8 {
                    return self.write_err(unique, LINUX_EINVAL);
                }
                let old_id = u64::from_le_bytes(body[0..8].try_into().unwrap());
                let (name, _) = Self::parse_cstr(&body[8..]);
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                if let Err(e) = self.node_room() {
                    return self.write_err(unique, e);
                }
                let npfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                // The source entry must still be the file the guest names.
                if let Err(e) = self.stat_node(old_id) {
                    return self.write_err(unique, e);
                }
                let linked = self.at_leaf(old_id, |ofd, oname| {
                    // Flags 0: a symlink source is linked itself, never followed.
                    let rc = unsafe {
                        libc::linkat(ofd, oname.as_ptr(), npfd.as_raw_fd(), cname.as_ptr(), 0)
                    };
                    if rc == 0 {
                        Ok(())
                    } else {
                        Err(last_os_errno_linux())
                    }
                });
                if let Err(e) = linked {
                    return self.write_err(unique, e);
                }
                self.write_new_entry(unique, nodeid, npfd.as_raw_fd(), &cname)
            }
            FUSE_STATFS => {
                let mut st: libc::statfs = unsafe { std::mem::zeroed() };
                if unsafe { libc::fstatfs(self.root_fd.as_raw_fd(), &mut st) } != 0 {
                    return self.write_err(unique, LINUX_EIO);
                }
                self.begin_ok(unique);
                self.resp_buf
                    .extend_from_slice(&(st.f_blocks).to_le_bytes());
                self.resp_buf.extend_from_slice(&(st.f_bfree).to_le_bytes());
                self.resp_buf
                    .extend_from_slice(&(st.f_bavail).to_le_bytes());
                self.resp_buf.extend_from_slice(&(st.f_files).to_le_bytes());
                self.resp_buf.extend_from_slice(&(st.f_ffree).to_le_bytes());
                self.resp_buf.extend_from_slice(&(st.f_bsize).to_le_bytes());
                self.resp_buf.extend_from_slice(&255u32.to_le_bytes()); // namelen
                self.resp_buf.extend_from_slice(&(st.f_bsize).to_le_bytes()); // frsize
                self.resp_buf.extend_from_slice(&[0u8; 28]); // padding + spare[6]
                self.finish_ok()
            }
            FUSE_ACCESS | FUSE_GETXATTR | FUSE_LISTXATTR | FUSE_LSEEK | FUSE_STATX => {
                self.write_err(unique, LINUX_ENOSYS)
            }
            _ => self.write_err(unique, LINUX_ENOSYS),
        }
    }

    fn sync_handle(
        &mut self,
        opcode: u32,
        nodeid: u64,
        fh: u64,
        data_only: bool,
    ) -> Result<(), i32> {
        if opcode == FUSE_FSYNCDIR {
            let dir = self
                .open_dirs
                .get(&fh)
                .filter(|dir| dir.dir_nodeid == nodeid)
                .ok_or(LINUX_EBADF)?;
            return sync_host_fd(dir.dir_fd.as_raw_fd(), false);
        }
        if fh != 0 {
            let open = self
                .open_files
                .get(&fh)
                .filter(|open| open.nodeid == nodeid)
                .ok_or(LINUX_EBADF)?;
            return sync_host_fd(open.file.as_raw_fd(), data_only);
        }
        if !self.read_only {
            return Err(LINUX_EBADF);
        }

        // Read-only shares negotiate FUSE_NO_OPEN_SUPPORT. Their regular files
        // have no server-side handle, so open the known leaf only for this sync.
        if !self.nodes.contains_key(&nodeid) {
            return Err(LINUX_EBADF);
        }
        let (file, st) = self.open_node(nodeid, libc::O_RDONLY)?;
        if st.mode & libc::S_IFMT as u32 != libc::S_IFREG as u32 {
            return Err(LINUX_EINVAL);
        }
        sync_host_fd(file.as_raw_fd(), data_only)
    }

    fn resolve_read_file(&mut self, nodeid: u64, fh: u64) -> Result<Arc<File>, i32> {
        if fh != 0 {
            self.open_files
                .get(&fh)
                .map(|f| f.file.clone())
                .ok_or(LINUX_EBADF)
        } else if self.read_only {
            if let Some(cached) = self.ro_file_cache.get(&nodeid) {
                return Ok(cached.clone());
            }
            if !self.nodes.contains_key(&nodeid) {
                return Err(LINUX_ENOENT);
            }
            let (file, st) = self.open_node(nodeid, libc::O_RDONLY)?;
            if mode_is_dir(st.mode) {
                return Err(LINUX_EISDIR);
            }
            let arc_f = Arc::new(file);
            if self.ro_file_cache.len() < 256 {
                self.ro_file_cache.insert(nodeid, arc_f.clone());
            }
            Ok(arc_f)
        } else {
            Err(LINUX_EBADF)
        }
    }

    /// Snapshot of the node table: `next_nodeid`, `next_fh`, each node's path
    /// relative to the share root (so a restored guest keeps its dentries),
    /// then pinned owners: `OWN1` by node (what a restore onto another
    /// directory carries over, by path), then `OWN2` by host identity (pins
    /// on files no node names). Older blobs end before either section.
    fn snapshot_blob(&self) -> Vec<u8> {
        let mut blob = Vec::new();
        blob.extend_from_slice(&self.next_nodeid.to_le_bytes());
        blob.extend_from_slice(&self.next_fh.to_le_bytes());
        let mut rels: Vec<(u64, Vec<u8>)> = self
            .nodes
            .keys()
            .filter(|&&id| id != FUSE_ROOT_ID)
            .filter_map(|&id| Some((id, self.node_rel_path(id)?)))
            .collect();
        rels.sort_by_key(|(id, _)| *id);
        blob.extend_from_slice(&(rels.len() as u32).to_le_bytes());
        for (id, rel) in &rels {
            blob.extend_from_slice(&id.to_le_bytes());
            blob.extend_from_slice(&(rel.len() as u32).to_le_bytes());
            blob.extend_from_slice(rel);
        }
        let pin_of = |id: u64| -> Option<(u32, u32)> {
            if id == FUSE_ROOT_ID {
                let st = fstat_fd(self.root_fd.as_raw_fd()).ok()?;
                return self.owners.get(&(st.dev, st.ino)).copied();
            }
            self.owners.get(&self.nodes.get(&id)?.identity?).copied()
        };
        let mut by_node: Vec<(u64, (u32, u32))> = self
            .nodes
            .keys()
            .filter_map(|&id| Some((id, pin_of(id)?)))
            .collect();
        by_node.sort_by_key(|(id, _)| *id);
        blob.extend_from_slice(SNAPSHOT_OWNERS_TAG);
        blob.extend_from_slice(&(by_node.len() as u32).to_le_bytes());
        for (id, (uid, gid)) in by_node {
            blob.extend_from_slice(&id.to_le_bytes());
            blob.push(3); // both fields
            blob.extend_from_slice(&uid.to_le_bytes());
            blob.extend_from_slice(&gid.to_le_bytes());
        }
        let mut by_file: Vec<((u64, u64), (u32, u32))> =
            self.owners.iter().map(|(&k, &v)| (k, v)).collect();
        by_file.sort_unstable();
        blob.extend_from_slice(SNAPSHOT_FILE_OWNERS_TAG);
        blob.extend_from_slice(&(by_file.len() as u32).to_le_bytes());
        for ((dev, ino), (uid, gid)) in by_file {
            blob.extend_from_slice(&dev.to_le_bytes());
            blob.extend_from_slice(&ino.to_le_bytes());
            blob.extend_from_slice(&uid.to_le_bytes());
            blob.extend_from_slice(&gid.to_le_bytes());
        }
        if self.direct_io_mmap {
            blob.extend_from_slice(SNAPSHOT_DIRECT_IO_MMAP_TAG);
        }
        blob
    }

    fn restore_blob(&mut self, blob: &[u8]) {
        // Negotiation belongs to the captured FUSE session. Older snapshots omit the trailer.
        self.direct_io_mmap = false;
        if blob.len() < 20 {
            return;
        }
        self.next_nodeid = u64::from_le_bytes(blob[0..8].try_into().unwrap());
        self.next_fh = u64::from_le_bytes(blob[8..16].try_into().unwrap());
        let count = u32::from_le_bytes(blob[16..20].try_into().unwrap()) as usize;
        let mut pos = 20usize;
        let mut records: Vec<(u64, &[u8])> = Vec::new();
        for _ in 0..count {
            if pos + 12 > blob.len() {
                return;
            }
            let id = u64::from_le_bytes(blob[pos..pos + 8].try_into().unwrap());
            let len = u32::from_le_bytes(blob[pos + 8..pos + 12].try_into().unwrap()) as usize;
            pos += 12;
            if pos + len > blob.len() {
                return;
            }
            records.push((id, &blob[pos..pos + len]));
            pos += len;
        }
        // Parents first, so every entry is resolved through its restored parent.
        records.sort_by_key(|(_, rel)| rel.iter().filter(|&&b| b == b'/').count());
        let mut by_path: HashMap<&[u8], u64> = HashMap::new();
        for (id, rel) in records {
            if id == FUSE_ROOT_ID || self.nodes.contains_key(&id) {
                continue;
            }
            let (parent_rel, leaf) = match rel.iter().rposition(|&b| b == b'/') {
                Some(i) => (&rel[..i], &rel[i + 1..]),
                None => (&rel[..0], rel),
            };
            let parent = if parent_rel.is_empty() {
                FUSE_ROOT_ID
            } else {
                match by_path.get(parent_rel) {
                    Some(&p) => p,
                    None => continue,
                }
            };
            let Ok(name) = entry_name(leaf) else {
                continue;
            };
            if self.child_id(parent, &name).is_some() {
                continue;
            }
            // Only restore nodes that exist under the root now (e.g. a fork pointed at a
            // fresh host directory, or a file the host replaced since), so missing files
            // return clean ESTALE/ENOENT and new files with the same name bind fresh host
            // inodes.
            let Ok(pfd) = self.dir_fd(parent) else {
                continue;
            };
            let Ok(st) = fstatat_cstr(pfd.as_raw_fd(), &name) else {
                continue;
            };
            self.insert_node(id, parent, name, Some((st.dev, st.ino)));
            // The restored guest references it; its own count is unknown, and
            // a FORGET carries the guest's whole count, so one is enough.
            self.add_lookup(id);
            by_path.insert(rel, id);
        }
        if self.read_only {
            return;
        }
        if blob.len() >= pos + 8 && &blob[pos..pos + 4] == SNAPSHOT_OWNERS_TAG {
            let owners = u32::from_le_bytes(blob[pos + 4..pos + 8].try_into().unwrap());
            pos += 8;
            let root = fstat_fd(self.root_fd.as_raw_fd())
                .ok()
                .map(|st| (st.dev, st.ino));
            for _ in 0..owners {
                if pos + 17 > blob.len() {
                    return;
                }
                let id = u64::from_le_bytes(blob[pos..pos + 8].try_into().unwrap());
                let flags = blob[pos + 8];
                let uid = u32::from_le_bytes(blob[pos + 9..pos + 13].try_into().unwrap());
                let gid = u32::from_le_bytes(blob[pos + 13..pos + 17].try_into().unwrap());
                pos += 17;
                let identity = if id == FUSE_ROOT_ID {
                    root
                } else {
                    self.nodes.get(&id).and_then(|n| n.identity)
                };
                // An older blob may pin one field: the other settles at root's.
                let pin = (
                    if flags & 1 != 0 { uid } else { 0 },
                    if flags & 2 != 0 { gid } else { 0 },
                );
                if let Some(identity) = identity
                    && flags & 3 != 0
                    && self.owners.len() < self.limits.pins
                {
                    self.owners.insert(identity, pin);
                }
            }
        }
        if blob.len() >= pos + 8 && &blob[pos..pos + 4] == SNAPSHOT_FILE_OWNERS_TAG {
            let owners = u32::from_le_bytes(blob[pos + 4..pos + 8].try_into().unwrap());
            pos += 8;
            for _ in 0..owners {
                if pos + 24 > blob.len() {
                    return;
                }
                let dev = u64::from_le_bytes(blob[pos..pos + 8].try_into().unwrap());
                let ino = u64::from_le_bytes(blob[pos + 8..pos + 16].try_into().unwrap());
                let uid = u32::from_le_bytes(blob[pos + 16..pos + 20].try_into().unwrap());
                let gid = u32::from_le_bytes(blob[pos + 20..pos + 24].try_into().unwrap());
                pos += 24;
                if self.owners.len() < self.limits.pins {
                    self.owners.entry((dev, ino)).or_insert((uid, gid));
                }
            }
            self.direct_io_mmap = self.writable_workspace
                && blob.get(pos..) == Some(SNAPSHOT_DIRECT_IO_MMAP_TAG.as_slice());
        }
        if self.direct_io_requested && !self.direct_io_mmap {
            eprintln!("[virtiofs-workspace] direct_io_mmap=false restored_without_negotiation");
        }
    }

    /// Zero-copy Virtio-FS descriptor chain handler:
    /// - `FUSE_READ`: `libc::preadv()` straight into `GuestMemory` writable descriptors (0 allocs, 0 copies).
    /// - `FUSE_WRITE`: `libc::pwritev()` straight from `GuestMemory` readable descriptors (0 allocs, 0 copies).
    /// - All other opcodes: reuse `req_scratch` + `self.resp_buf` (0 heap allocations after warmup).
    fn handle_fuse_chain(
        &mut self,
        bufs: &[DescBuf],
        mem: &GuestMemory,
        req_scratch: &mut Vec<u8>,
    ) -> u32 {
        let mut hdr = [0u8; 80];
        let mut hdr_copied = 0usize;
        // Only guest memory that exists counts: descriptor lengths are the
        // guest's word, and the request is assembled from these bytes alone.
        let mut total_readable = 0usize;
        for b in bufs {
            if b.is_write {
                continue;
            }
            let Some(s) = mem.read_slice(b.addr, b.len as usize) else {
                continue;
            };
            total_readable = total_readable.saturating_add(s.len());
            if hdr_copied < hdr.len() {
                let take = s.len().min(hdr.len() - hdr_copied);
                hdr[hdr_copied..hdr_copied + take].copy_from_slice(&s[..take]);
                hdr_copied += take;
            }
        }
        if hdr_copied < 40 {
            return 0;
        }
        let opcode = u32::from_le_bytes(hdr[4..8].try_into().unwrap());
        let unique = u64::from_le_bytes(hdr[8..16].try_into().unwrap());
        let nodeid = u64::from_le_bytes(hdr[16..24].try_into().unwrap());
        // No request this device accepts is larger (`max_write` is 256 KiB).
        if total_readable > MAX_FUSE_REQUEST {
            self.metrics.requests.fetch_add(1, Ordering::Relaxed);
            self.write_err(unique, LINUX_EINVAL);
            return scatter_writable(bufs, mem, &self.resp_buf);
        }

        // Fast path 1: ZERO-COPY FUSE_READ -> libc::preadv() straight into GuestMemory!
        if opcode == FUSE_READ && hdr_copied >= 64 {
            self.metrics.requests.fetch_add(1, Ordering::Relaxed);
            let fh = u64::from_le_bytes(hdr[40..48].try_into().unwrap());
            let offset = u64::from_le_bytes(hdr[48..56].try_into().unwrap());
            let size =
                (u32::from_le_bytes(hdr[56..60].try_into().unwrap()) as usize).min(1024 * 1024);

            let mut hdr_dst_ipa: Option<u64> = None;
            let mut iovs = [libc::iovec {
                iov_base: std::ptr::null_mut(),
                iov_len: 0,
            }; 64];
            let mut niov = 0usize;
            let mut data_cap = 0usize;
            let mut can_zero_copy = true;
            for b in bufs {
                if !b.is_write {
                    continue;
                }
                let blen = b.len as usize;
                if hdr_dst_ipa.is_none() {
                    if blen < 16 {
                        can_zero_copy = false;
                        break;
                    }
                    hdr_dst_ipa = Some(b.addr);
                    if blen > 16 && data_cap < size {
                        let take = (blen - 16).min(size - data_cap);
                        if let Some(ptr) = mem.translate(b.addr + 16, take) {
                            iovs[niov] = libc::iovec {
                                iov_base: ptr.cast(),
                                iov_len: take,
                            };
                            niov += 1;
                            data_cap += take;
                        } else {
                            can_zero_copy = false;
                            break;
                        }
                    }
                } else if data_cap < size {
                    if niov >= iovs.len() {
                        can_zero_copy = false;
                        break;
                    }
                    let take = blen.min(size - data_cap);
                    if let Some(ptr) = mem.translate(b.addr, take) {
                        iovs[niov] = libc::iovec {
                            iov_base: ptr.cast(),
                            iov_len: take,
                        };
                        niov += 1;
                        data_cap += take;
                    } else {
                        can_zero_copy = false;
                        break;
                    }
                }
            }

            if can_zero_copy && let Some(hdr_ipa) = hdr_dst_ipa {
                match self.resolve_read_file(nodeid, fh) {
                    Ok(file) => {
                        let rc = if niov == 0 {
                            0
                        } else {
                            unsafe {
                                libc::preadv(
                                    file.as_raw_fd(),
                                    iovs.as_ptr(),
                                    niov as libc::c_int,
                                    offset as libc::off_t,
                                )
                            }
                        };
                        if rc >= 0 {
                            let n = rc as usize;
                            self.metrics
                                .bytes_read
                                .fetch_add(n as u64, Ordering::Relaxed);
                            let total_out = (16 + n) as u32;
                            if let Some(h) = mem.write_slice(hdr_ipa, 16) {
                                h[0..4].copy_from_slice(&total_out.to_le_bytes());
                                h[4..8].copy_from_slice(&0i32.to_le_bytes());
                                h[8..16].copy_from_slice(&unique.to_le_bytes());
                            }
                            return total_out;
                        }
                        let errno = last_os_errno_linux();
                        if let Some(h) = mem.write_slice(hdr_ipa, 16) {
                            h[0..4].copy_from_slice(&16u32.to_le_bytes());
                            h[4..8].copy_from_slice(&(-errno).to_le_bytes());
                            h[8..16].copy_from_slice(&unique.to_le_bytes());
                        }
                        return 16;
                    }
                    Err(errno) => {
                        if let Some(h) = mem.write_slice(hdr_ipa, 16) {
                            h[0..4].copy_from_slice(&16u32.to_le_bytes());
                            h[4..8].copy_from_slice(&(-errno).to_le_bytes());
                            h[8..16].copy_from_slice(&unique.to_le_bytes());
                        }
                        return 16;
                    }
                }
            }
            self.metrics.requests.fetch_sub(1, Ordering::Relaxed);
        }

        // Fast path 2: ZERO-COPY FUSE_WRITE -> libc::pwritev() straight from GuestMemory!
        if opcode == FUSE_WRITE && hdr_copied >= 80 && !self.read_only {
            let fh = u64::from_le_bytes(hdr[40..48].try_into().unwrap());
            let offset = u64::from_le_bytes(hdr[48..56].try_into().unwrap());
            let size = (u32::from_le_bytes(hdr[56..60].try_into().unwrap()) as usize)
                .min(total_readable.saturating_sub(80));
            let mut iovs = [libc::iovec {
                iov_base: std::ptr::null_mut(),
                iov_len: 0,
            }; 64];
            let mut niov = 0usize;
            let mut skip = 80usize;
            let mut collected = 0usize;
            let mut can_zero_copy = true;
            for b in bufs {
                if b.is_write || collected >= size {
                    continue;
                }
                let blen = b.len as usize;
                if skip >= blen {
                    skip -= blen;
                    continue;
                }
                if niov >= iovs.len() {
                    can_zero_copy = false;
                    break;
                }
                let Some(s) = mem.read_slice(b.addr, blen) else {
                    can_zero_copy = false;
                    break;
                };
                let slice = &s[skip..];
                skip = 0;
                let take = slice.len().min(size - collected);
                if take > 0 {
                    iovs[niov] = libc::iovec {
                        iov_base: slice.as_ptr() as *mut libc::c_void,
                        iov_len: take,
                    };
                    niov += 1;
                    collected += take;
                }
            }
            if can_zero_copy && collected == size {
                self.metrics.requests.fetch_add(1, Ordering::Relaxed);
                let Some(open) = self.open_files.get(&fh) else {
                    self.write_err(unique, LINUX_EBADF);
                    return scatter_writable(bufs, mem, &self.resp_buf);
                };
                let rc = if niov == 0 {
                    0
                } else {
                    unsafe {
                        libc::pwritev(
                            open.file.as_raw_fd(),
                            iovs.as_ptr(),
                            niov as libc::c_int,
                            offset as libc::off_t,
                        )
                    }
                };
                if rc >= 0 {
                    let n = rc as usize;
                    self.metrics
                        .bytes_written
                        .fetch_add(n as u64, Ordering::Relaxed);
                    let mut rep = [0u8; 24];
                    rep[0..4].copy_from_slice(&24u32.to_le_bytes());
                    rep[4..8].copy_from_slice(&0i32.to_le_bytes());
                    rep[8..16].copy_from_slice(&unique.to_le_bytes());
                    rep[16..20].copy_from_slice(&(n as u32).to_le_bytes());
                    return scatter_writable(bufs, mem, &rep);
                }
                let errno = last_os_errno_linux();
                self.write_err(unique, errno);
                return scatter_writable(bufs, mem, &self.resp_buf);
            }
        }

        // Small requests, including most metadata operations, are already assembled.
        if hdr_copied == total_readable {
            if self.handle_fuse_into(&hdr[..hdr_copied]) {
                return scatter_writable(bufs, mem, &self.resp_buf);
            }
            return 0;
        }

        // Assemble the full request only when it did not fit in the prefix.
        req_scratch.clear();
        if req_scratch.capacity() < total_readable {
            req_scratch.reserve(total_readable);
        }
        for b in bufs {
            if !b.is_write
                && let Some(s) = mem.read_slice(b.addr, b.len as usize)
            {
                req_scratch.extend_from_slice(s);
            }
        }
        if self.handle_fuse_into(req_scratch) {
            scatter_writable(bufs, mem, &self.resp_buf)
        } else {
            0
        }
    }
}

/// Dedicated P-core Virtio-FS async I/O worker with Virtio 1.2 `VRING_USED_F_NO_NOTIFY`
/// kick suppression and adaptive spinning (eliminates vCPU MMIO exits & pipelines I/O).
fn run_fs_io_loop(shared: Arc<FsShared>) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let mut local_qs = Vec::<Option<VirtQueue>>::new();
    let mut desc_buf = Vec::with_capacity(16);
    let mut req_scratch = Vec::with_capacity(4096);

    loop {
        if shared.shutdown.load(Ordering::Relaxed) {
            return;
        }
        let (mem, irq) = {
            let mut st = shared.state.0.lock().unwrap();
            // Sync live queue indices back when pausing/sleeping so snapshots capture exact state
            for (lq, sq) in local_qs.iter().zip(st.queues.iter_mut()) {
                if let (Some(lq), Some(sq)) = (lq.as_ref(), sq.as_mut()) {
                    sq.next_avail = lq.next_avail;
                    sq.next_used = lq.next_used;
                }
            }
            st.worker_parked = true;
            shared.state.1.notify_all();
            while (shared.paused.load(Ordering::Acquire) || !st.kicked)
                && !shared.shutdown.load(Ordering::Relaxed)
            {
                if !shared.paused.load(Ordering::Relaxed)
                    && let Some(ref mem) = st.mem
                    && local_qs
                        .iter()
                        .flatten()
                        .any(|q| q.ready && q.has_avail(mem))
                {
                    break;
                }
                // The drain loop rearms guest notifications, fences, and rechecks
                // the ring. QueueNotify records its kick under this same mutex.
                st = shared.state.1.wait(st).unwrap();
            }
            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            st.kicked = false;
            st.worker_parked = false;
            local_qs.clone_from(&st.queues);
            (st.mem.clone(), st.irq.clone())
        };

        let (Some(mem), Some(irq)) = (mem, irq) else {
            continue;
        };
        if !local_qs.iter().flatten().any(|q| q.ready) {
            continue;
        }

        for q in local_qs.iter().flatten() {
            if q.ready {
                q.set_no_notify(&mem, true);
            }
        }
        let mut last_activity = Instant::now();
        let adaptive_spin = Duration::from_micros(150);
        let mut spin_iters: u32 = 0;

        loop {
            if shared.shutdown.load(Ordering::Acquire) || shared.paused.load(Ordering::Acquire) {
                for q in local_qs.iter().flatten() {
                    q.set_no_notify(&mem, false);
                }
                break;
            }
            let has_work = local_qs
                .iter()
                .flatten()
                .any(|q| q.ready && q.has_avail(&mem));
            if has_work {
                let mut used_any = false;
                let mut want_irq = false;
                {
                    let mut core = shared.core.lock().unwrap();
                    for q_opt in &mut local_qs {
                        let Some(q) = q_opt.as_mut() else {
                            continue;
                        };
                        if !q.ready {
                            continue;
                        }
                        let old_used = q.next_used;
                        // A continuously refilled low-numbered queue cannot starve its
                        // siblings, hiprio, or the handoff for a device reset.
                        for _ in 0..32 {
                            let Some(head) = q.pop_into(&mem, &mut desc_buf) else {
                                break;
                            };
                            let written = core.handle_fuse_chain(&desc_buf, &mem, &mut req_scratch);
                            q.push_used(&mem, head, written);
                            used_any = true;
                        }
                        if q.next_used != old_used && q.guest_wants_irq_since(&mem, old_used) {
                            want_irq = true;
                        }
                    }
                }
                if used_any {
                    if let Some(metrics) = &shared.workspace_metrics {
                        metrics
                            .workspace_used_batches
                            .fetch_add(1, Ordering::Relaxed);
                        if want_irq {
                            metrics
                                .workspace_irq_requests
                                .fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    if want_irq {
                        irq.raise_used_buffer();
                    }
                    last_activity = Instant::now();
                    spin_iters = 0;
                    continue;
                }
            }

            spin_iters = spin_iters.wrapping_add(1);
            if (spin_iters & 63) != 0 || last_activity.elapsed() < adaptive_spin {
                std::hint::spin_loop();
                continue;
            }

            for q in local_qs.iter().flatten() {
                if q.ready {
                    q.set_no_notify(&mem, false);
                }
            }
            if local_qs
                .iter()
                .flatten()
                .any(|q| q.ready && q.has_avail(&mem))
            {
                for q in local_qs.iter().flatten() {
                    if q.ready {
                        q.set_no_notify(&mem, true);
                    }
                }
                last_activity = Instant::now();
                continue;
            }
            break;
        }
    }
}

impl VirtioBackend for VirtioFs {
    fn device_id(&self) -> u32 {
        26
    }
    fn features(&self) -> u64 {
        if self.offer_event_idx {
            crate::VIRTIO_F_EVENT_IDX
        } else {
            0
        }
    }
    fn num_queues(&self) -> usize {
        1 + usize::from(self.request_queues) // queue 0 is hiprio
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        256
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 40];
        cfg[0..36].copy_from_slice(&self.tag);
        cfg[36..40].copy_from_slice(&u32::from(self.request_queues).to_le_bytes());
        let start = offset as usize;
        for (i, b) in data.iter_mut().enumerate() {
            *b = cfg.get(start + i).copied().unwrap_or(0);
        }
    }
    fn attach(&mut self, mem: Arc<GuestMemory>, irq: IrqLine) {
        let mut st = self.shared.state.0.lock().unwrap();
        st.mem = Some(mem);
        st.irq = Some(irq);
    }
    fn queue_ready(&mut self, q_idx: usize, q: &VirtQueue) {
        if q_idx < self.num_queues() {
            let mut st = self.park_worker();
            st.queues[q_idx] = Some(q.clone());
            self.resume_worker(&mut st);
            drop(st);
            self.ensure_worker_started();
        }
    }
    fn queue_disabled(&mut self, q_idx: usize) {
        let mut st = self.park_worker();
        st.queues[q_idx] = None;
        self.resume_worker(&mut st);
    }
    fn reset(&mut self) {
        let mut st = self.park_worker();
        st.queues.fill(None);
        self.resume_worker(&mut st);
    }
    fn snapshot_pause(&mut self, queues: &mut [VirtQueue], mem: &GuestMemory) -> Vec<u8> {
        let st = self.park_worker();
        for (sq, q) in st.queues.iter().zip(queues.iter_mut()) {
            if let Some(sq) = sq {
                q.next_avail = sq.next_avail;
                q.next_used = sq.next_used;
                if q.ready {
                    q.set_no_notify(mem, false);
                }
            }
        }
        drop(st);
        self.shared.core.lock().unwrap().snapshot_blob()
    }
    fn snapshot_resume(&mut self) {
        let mut st = self.shared.state.0.lock().unwrap();
        self.resume_worker(&mut st);
    }
    fn snapshot_restore(&mut self, blob: &[u8], queues: &[VirtQueue]) {
        let mut st = self.park_worker();
        self.shared.core.lock().unwrap().restore_blob(blob);
        for (slot, q) in st.queues.iter_mut().zip(queues) {
            *slot = q.ready.then(|| q.clone());
        }
        self.resume_worker(&mut st);
        drop(st);
        if queues.iter().any(|q| q.ready) {
            self.ensure_worker_started();
        }
    }
    fn handle_queue(
        &mut self,
        q_idx: usize,
        _queues: &mut [VirtQueue],
        _mem: &GuestMemory,
    ) -> bool {
        let mut st = self.shared.state.0.lock().unwrap();
        if st.queues.get(q_idx).is_some_and(Option::is_some) {
            if let Some(metrics) = &self.shared.workspace_metrics {
                metrics.workspace_kicks.fetch_add(1, Ordering::Relaxed);
            }
            st.kicked = true;
            self.shared.state.1.notify_one();
        }
        false
    }
}

impl Drop for FsCore {
    fn drop(&mut self) {
        let handles = (self.open_files.len() + self.open_dirs.len()) as u64;
        self.metrics
            .nodes
            .fetch_sub(self.nodes.len() as u64, Ordering::Relaxed);
        self.metrics
            .open_handles
            .fetch_sub(handles, Ordering::Relaxed);
    }
}

impl Drop for VirtioFs {
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::SeqCst);
        {
            let _st = self
                .shared
                .state
                .0
                .lock()
                .unwrap_or_else(|poison| poison.into_inner());
            self.shared.state.1.notify_all();
        }
        if let Some(h) = self.worker_handle.take() {
            let _ = h.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    fn request_bytes(opcode: u32, nodeid: u64, body: &[u8]) -> Vec<u8> {
        let mut req = vec![0; 40];
        let size = (req.len() + body.len()) as u32;
        req[0..4].copy_from_slice(&size.to_le_bytes());
        req[4..8].copy_from_slice(&opcode.to_le_bytes());
        req[8..16].copy_from_slice(&1u64.to_le_bytes());
        req[16..24].copy_from_slice(&nodeid.to_le_bytes());
        req.extend_from_slice(body);
        req
    }

    fn request(fsys: &mut VirtioFs, opcode: u32, nodeid: u64, body: &[u8]) -> Vec<u8> {
        fsys.handle_fuse(&request_bytes(opcode, nodeid, body))
            .unwrap()
    }

    fn errno(reply: &[u8]) -> i32 {
        -i32::from_le_bytes(reply[4..8].try_into().unwrap())
    }

    fn lookup(fsys: &mut VirtioFs, name: &[u8]) -> u64 {
        let reply = request(fsys, FUSE_LOOKUP, FUSE_ROOT_ID, name);
        assert_eq!(errno(&reply), 0);
        u64::from_le_bytes(reply[16..24].try_into().unwrap())
    }

    fn open(fsys: &mut VirtioFs, nodeid: u64, flags: u32) -> Vec<u8> {
        let mut body = [0; 8];
        body[..4].copy_from_slice(&flags.to_le_bytes());
        request(fsys, FUSE_OPEN, nodeid, &body)
    }

    fn sync(fsys: &mut VirtioFs, opcode: u32, nodeid: u64, fh: u64, flags: u32) -> i32 {
        let mut body = [0u8; 16];
        body[..8].copy_from_slice(&fh.to_le_bytes());
        body[8..12].copy_from_slice(&flags.to_le_bytes());
        errno(&request(fsys, opcode, nodeid, &body))
    }

    fn request_as(
        fsys: &mut VirtioFs,
        opcode: u32,
        nodeid: u64,
        body: &[u8],
        caller: (u32, u32),
    ) -> Vec<u8> {
        let mut req = request_bytes(opcode, nodeid, body);
        req[24..28].copy_from_slice(&caller.0.to_le_bytes());
        req[28..32].copy_from_slice(&caller.1.to_le_bytes());
        fsys.handle_fuse(&req).unwrap()
    }

    /// (uid, gid) in a fuse_attr that starts at `attr` in `reply`.
    fn attr_owner(reply: &[u8], attr: usize) -> (u32, u32) {
        let uid = u32::from_le_bytes(reply[attr + 68..attr + 72].try_into().unwrap());
        let gid = u32::from_le_bytes(reply[attr + 72..attr + 76].try_into().unwrap());
        (uid, gid)
    }

    const ENTRY_ATTR: usize = 16 + 40; // fuse_out_header + fuse_entry_out prefix
    const ATTR_OUT_ATTR: usize = 16 + 16; // fuse_out_header + fuse_attr_out prefix

    #[test]
    fn writable_shares_present_files_to_their_user_and_remember_chown() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-owner-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("data"), b"x").unwrap();
        fs::write(dir.join("other"), b"y").unwrap();
        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();

        // An unclaimed host file belongs to whichever guest user asks.
        let reply = request_as(
            &mut fsys,
            FUSE_LOOKUP,
            FUSE_ROOT_ID,
            b"data\0",
            (1000, 1000),
        );
        assert_eq!(errno(&reply), 0);
        assert_eq!(attr_owner(&reply, ENTRY_ATTR), (1000, 1000));
        let data = u64::from_le_bytes(reply[16..24].try_into().unwrap());

        // Root chowns it (as an image entrypoint does before dropping privileges).
        let mut setattr = [0u8; 88];
        setattr[0..4].copy_from_slice(&(FATTR_UID | FATTR_GID).to_le_bytes());
        setattr[76..80].copy_from_slice(&999u32.to_le_bytes());
        setattr[80..84].copy_from_slice(&998u32.to_le_bytes());
        let reply = request_as(&mut fsys, FUSE_SETATTR, data, &setattr, (0, 0));
        assert_eq!(errno(&reply), 0);
        assert_eq!(attr_owner(&reply, ATTR_OUT_ATTR), (999, 998));

        // Every guest user now sees the recorded owner.
        for caller in [(0, 0), (999, 998), (1000, 1000)] {
            let reply = request_as(&mut fsys, FUSE_GETATTR, data, &[0u8; 16], caller);
            assert_eq!(attr_owner(&reply, ATTR_OUT_ATTR), (999, 998), "{caller:?}");
        }
        // Changing only the group keeps the recorded user.
        let mut chgrp = [0u8; 88];
        chgrp[0..4].copy_from_slice(&FATTR_GID.to_le_bytes());
        chgrp[80..84].copy_from_slice(&5u32.to_le_bytes());
        let reply = request_as(&mut fsys, FUSE_SETATTR, data, &chgrp, (0, 0));
        assert_eq!(attr_owner(&reply, ATTR_OUT_ATTR), (999, 5));

        // Other files are unaffected; the host file itself keeps its real owner.
        let reply = request_as(
            &mut fsys,
            FUSE_LOOKUP,
            FUSE_ROOT_ID,
            b"other\0",
            (1234, 1234),
        );
        assert_eq!(attr_owner(&reply, ENTRY_ATTR), (1234, 1234));
        assert_eq!(fs::metadata(dir.join("data")).unwrap().uid(), unsafe {
            libc::getuid()
        });

        // Read-only tool shares stay root-owned whoever asks.
        let mut ro = VirtioFs::new(
            "oci-tools",
            dir.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let reply = request_as(&mut ro, FUSE_LOOKUP, FUSE_ROOT_ID, b"data\0", (1000, 1000));
        assert_eq!(attr_owner(&reply, ENTRY_ATTR), (0, 0));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn dropping_virtiofs_releases_worker_guest_memory() {
        let mut fsys = VirtioFs::new(
            "workspace",
            std::env::temp_dir(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let mut bytes = vec![0u8; 4096];
        let memory = Arc::new(unsafe { GuestMemory::new(bytes.as_mut_ptr(), 0, bytes.len()) });
        let worker_memory = Arc::downgrade(&memory);
        fsys.shared.state.0.lock().unwrap().mem = Some(memory);
        fsys.ensure_worker_started();

        drop(fsys);
        assert!(worker_memory.upgrade().is_none());
    }

    #[test]
    fn workspace_request_queues_survive_reconfiguration_and_restore() {
        for event_idx in [false, true] {
            check_request_queue_lifecycle(event_idx);
        }
    }

    fn check_request_queue_lifecycle(event_idx: bool) {
        use crate::VirtioMmioDevice;

        let mut backing = vec![0u64; 1024];
        let mem = Arc::new(unsafe {
            GuestMemory::new(
                backing.as_mut_ptr().cast(),
                0,
                std::mem::size_of_val(&backing[..]),
            )
        });
        let device = |count, offer_event_idx| {
            let mut fs = VirtioFs::with_request_queues(
                "workspace",
                std::env::temp_dir(),
                false,
                Arc::default(),
                count,
            )
            .unwrap();
            fs.offer_event_idx = offer_event_idx;
            VirtioMmioDevice::new(32, mem.clone(), Box::new(fs))
        };
        let mut dev = device(4, true);
        assert_eq!(dev.mmio_read(0x010, 4), crate::VIRTIO_F_EVENT_IDX);
        if event_idx {
            dev.mmio_write(0x020, 4, crate::VIRTIO_F_EVENT_IDX);
        }
        assert_eq!(dev.mmio_read(0x100 + 36, 4), 4);

        let configure = |dev: &mut VirtioMmioDevice, q: u64| {
            let base = q * 1024;
            let (desc, avail, used, input, output) =
                (base, base + 64, base + 128, base + 256, base + 512);
            mem.write_slice(base, 1024).unwrap().fill(0);
            // Two descriptors and one FUSE_GETATTR on the root. Each ring has
            // its own unique ID and writable memory; suppress hardware IRQs.
            mem.write_slice(desc, 8)
                .unwrap()
                .copy_from_slice(&input.to_le_bytes());
            mem.write_u32(desc + 8, 56).unwrap();
            mem.write_u16(desc + 12, crate::VIRTQ_DESC_F_NEXT).unwrap();
            mem.write_u16(desc + 14, 1).unwrap();
            mem.write_slice(desc + 16, 8)
                .unwrap()
                .copy_from_slice(&output.to_le_bytes());
            mem.write_u32(desc + 24, 256).unwrap();
            mem.write_u16(desc + 28, crate::VIRTQ_DESC_F_WRITE).unwrap();
            if event_idx {
                mem.write_u16(avail + 8, u16::MAX).unwrap();
            } else {
                mem.write_u16(avail, 1).unwrap();
            }
            let req = request_bytes(FUSE_GETATTR, FUSE_ROOT_ID, &[0; 16]);
            mem.write_slice(input, req.len())
                .unwrap()
                .copy_from_slice(&req);
            mem.write_slice(input + 8, 8)
                .unwrap()
                .copy_from_slice(&q.to_le_bytes());
            for (reg, value) in [
                (0x030, q),
                (0x038, 2),
                (0x080, desc),
                (0x090, avail),
                (0x0a0, used),
                (0x044, 1),
            ] {
                dev.mmio_write(reg, 4, value);
            }
        };
        let submit = |dev: &mut VirtioMmioDevice, q: u64, seq: u16| {
            mem.write_u16_release(q * 1024 + 66, seq).unwrap();
            dev.mmio_write(0x050, 4, q);
        };
        let completion = |q: u64, seq| {
            let deadline = Instant::now() + Duration::from_secs(2);
            while mem.read_u16_acquire(q * 1024 + 130) != Some(seq) {
                assert!(Instant::now() < deadline, "queue {q} stalled at {seq}");
                std::thread::yield_now();
            }
            assert_eq!(mem.read_u32(q * 1024 + 516), Some(0));
            assert_eq!(mem.read_u64(q * 1024 + 520), Some(q));
        };
        // Register each ring while earlier rings can still be completing.
        for q in 1..=4 {
            configure(&mut dev, q);
            submit(&mut dev, q, 1);
        }
        for q in 1..=4 {
            completion(q, 1);
            for seq in 2..=q as u16 + 1 {
                submit(&mut dev, q, seq);
                completion(q, seq);
            }
        }
        let saved = dev.snapshot_pause();
        for q in 1..=4 {
            assert_eq!(saved.queues[q].next_used, q as u16 + 1);
        }
        drop(dev);
        assert!(
            device(1, true)
                .snapshot_restore(&saved)
                .unwrap_err()
                .contains("queue count")
        );
        if event_idx {
            assert!(
                device(4, false)
                    .snapshot_restore(&saved)
                    .unwrap_err()
                    .contains("EVENT_IDX")
            );
        }
        // A snapshot taken without the feature still restores on a legacy device.
        let mut restored = device(4, event_idx);
        restored.snapshot_restore(&saved).unwrap();
        for q in 1..=4 {
            submit(&mut restored, q, q as u16 + 2);
        }
        for q in 1..=4 {
            completion(q, q as u16 + 2);
        }
        // Reuse one ring at the same addresses, while the sibling keeps its index.
        restored.mmio_write(0x030, 4, 3);
        restored.mmio_write(0x044, 4, 0);
        configure(&mut restored, 3);
        submit(&mut restored, 3, 1);
        submit(&mut restored, 4, 7);
        completion(3, 1);
        completion(4, 7);
        restored.mmio_write(0x070, 4, 0);
        configure(&mut restored, 4);
        submit(&mut restored, 4, 1);
        completion(4, 1);
    }

    #[test]
    fn sync_validates_packets_and_uses_open_file_and_directory_handles() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-sync-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("directory")).unwrap();
        fs::write(dir.join("file"), b"original").unwrap();
        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let file_id = lookup(&mut fsys, b"file\0");
        let dir_id = lookup(&mut fsys, b"directory\0");
        let file_open = open(&mut fsys, file_id, 2);
        let dir_open = request(&mut fsys, FUSE_OPENDIR, dir_id, &[0; 8]);
        assert_eq!(errno(&file_open), 0);
        assert_eq!(errno(&dir_open), 0);
        let file_fh = u64::from_le_bytes(file_open[16..24].try_into().unwrap());
        let dir_fh = u64::from_le_bytes(dir_open[16..24].try_into().unwrap());

        for (opcode, nodeid, fh) in [
            (FUSE_FSYNC, file_id, file_fh),
            (FUSE_FSYNCDIR, dir_id, dir_fh),
        ] {
            assert_eq!(
                errno(&request(&mut fsys, opcode, nodeid, &fh.to_le_bytes())),
                LINUX_EINVAL
            );
            assert_eq!(sync(&mut fsys, opcode, nodeid, fh, 2), LINUX_EINVAL);
            assert_eq!(sync(&mut fsys, opcode, nodeid, 0, 0), LINUX_EBADF);
            assert_eq!(sync(&mut fsys, opcode, nodeid, u64::MAX, 0), LINUX_EBADF);
            assert_eq!(sync(&mut fsys, opcode, FUSE_ROOT_ID, fh, 0), LINUX_EBADF);

            let mut bad_len = [0u8; 56];
            bad_len[..4].copy_from_slice(&40u32.to_le_bytes());
            bad_len[4..8].copy_from_slice(&opcode.to_le_bytes());
            bad_len[16..24].copy_from_slice(&nodeid.to_le_bytes());
            bad_len[40..48].copy_from_slice(&fh.to_le_bytes());
            assert_eq!(errno(&fsys.handle_fuse(&bad_len).unwrap()), LINUX_EINVAL);
        }
        assert_eq!(sync(&mut fsys, FUSE_FSYNC, dir_id, dir_fh, 0), LINUX_EBADF);
        assert_eq!(
            sync(&mut fsys, FUSE_FSYNCDIR, file_id, file_fh, 0),
            LINUX_EBADF
        );

        fs::rename(dir.join("file"), dir.join("old-file")).unwrap();
        fs::write(dir.join("file"), b"new leaf").unwrap();
        fs::rename(dir.join("directory"), dir.join("old-directory")).unwrap();
        fs::create_dir(dir.join("directory")).unwrap();
        assert_ne!(lookup(&mut fsys, b"file\0"), file_id);
        assert_ne!(lookup(&mut fsys, b"directory\0"), dir_id);
        for flags in [0, FUSE_FSYNC_FDATASYNC] {
            assert_eq!(sync(&mut fsys, FUSE_FSYNC, file_id, file_fh, flags), 0);
            assert_eq!(sync(&mut fsys, FUSE_FSYNCDIR, dir_id, dir_fh, flags), 0);
        }

        request(&mut fsys, FUSE_RELEASE, file_id, &file_fh.to_le_bytes());
        request(&mut fsys, FUSE_RELEASEDIR, dir_id, &dir_fh.to_le_bytes());
        assert_eq!(
            sync(&mut fsys, FUSE_FSYNC, file_id, file_fh, 0),
            LINUX_EBADF
        );
        assert_eq!(
            sync(&mut fsys, FUSE_FSYNCDIR, dir_id, dir_fh, 0),
            LINUX_EBADF
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn sync_handles_read_only_no_open_and_reports_host_error() {
        use std::os::unix::net::UnixStream;

        let dir = std::env::temp_dir().join(format!("mp-vfs-sync-ro-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("file"), b"source").unwrap();
        let mut fsys = VirtioFs::new(
            "oci-tools",
            dir.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let file_id = lookup(&mut fsys, b"file\0");
        assert_eq!(errno(&open(&mut fsys, file_id, 0)), LINUX_ENOSYS);
        assert_eq!(sync(&mut fsys, FUSE_FSYNC, file_id, 0, 0), 0);
        assert_eq!(
            sync(&mut fsys, FUSE_FSYNC, file_id, 0, FUSE_FSYNC_FDATASYNC),
            0
        );
        assert_eq!(sync(&mut fsys, FUSE_FSYNC, u64::MAX, 0, 0), LINUX_EBADF);
        fs::remove_file(dir.join("file")).unwrap();
        assert_eq!(sync(&mut fsys, FUSE_FSYNC, file_id, 0, 0), LINUX_ENOENT);

        // Use real owned descriptors that the host cannot sync. Neither opcode
        // may report success after its host syscall fails.
        let (left, right) = UnixStream::pair().unwrap();
        {
            let mut core = fsys.shared.core.lock().unwrap();
            core.open_files.insert(
                1,
                OpenFile {
                    nodeid: file_id,
                    file: Arc::new(File::from(OwnedFd::from(left))),
                    identity: (0, 0),
                },
            );
            core.open_dirs.insert(
                2,
                OpenDir {
                    dir_nodeid: FUSE_ROOT_ID,
                    dir_fd: OwnedFd::from(right),
                    listing: DirListing::default(),
                },
            );
        }
        #[cfg(target_vendor = "apple")]
        let expected = LINUX_EBADF; // Darwin's F_FULLFSYNC requires a vnode.
        #[cfg(not(target_vendor = "apple"))]
        let expected = LINUX_EINVAL;
        assert_eq!(sync(&mut fsys, FUSE_FSYNC, file_id, 1, 0), expected);
        assert_eq!(sync(&mut fsys, FUSE_FSYNCDIR, FUSE_ROOT_ID, 2, 0), expected);
        fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn mutable_opens_only_skip_flush_for_read_only_handles() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-open-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        let path = dir.join("source");
        fs::write(&path, b"unchanged").unwrap();
        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let id = lookup(&mut fsys, b"source\0");
        for (flags, expected) in [(0, FOPEN_NOFLUSH), (0, FOPEN_NOFLUSH), (2, 0)] {
            let reply = open(&mut fsys, id, flags);
            assert_eq!(errno(&reply), 0);
            assert_eq!(
                u32::from_le_bytes(reply[24..28].try_into().unwrap()),
                expected
            );
        }
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn live_workspace_reads_require_kernel_support_and_apply_to_open_and_create() {
        let (base, share, _) = scratch("direct-io-mmap");
        fs::write(share.join("existing"), b"old bytes").unwrap();
        let mut fsys = writable(&share);
        let mut init = [0; 64];
        init[..4].copy_from_slice(&7u32.to_le_bytes());
        init[4..8].copy_from_slice(&FUSE_DIRECT_IO_MMAP_MINOR.to_le_bytes());
        init[12..16].copy_from_slice(&FUSE_INIT_EXT.to_le_bytes());
        init[16..20].copy_from_slice(&FUSE_DIRECT_IO_ALLOW_MMAP_FLAGS2.to_le_bytes());

        let legacy = request(&mut fsys, FUSE_INIT, ROOT, &init);
        assert_eq!(u32::from_le_bytes(legacy[20..24].try_into().unwrap()), 31);
        assert_eq!(u32::from_le_bytes(legacy[48..52].try_into().unwrap()), 0);

        core(&fsys).direct_io_requested = true;
        let mut missing = init;
        missing[12..16].fill(0);
        assert_eq!(
            errno(&request(&mut fsys, FUSE_INIT, ROOT, &missing)),
            LINUX_EOPNOTSUPP
        );
        let reply = request(&mut fsys, FUSE_INIT, ROOT, &init);
        assert_eq!(errno(&reply), 0);
        assert_eq!(
            u32::from_le_bytes(reply[20..24].try_into().unwrap()),
            FUSE_DIRECT_IO_MMAP_MINOR
        );
        assert_ne!(
            u32::from_le_bytes(reply[28..32].try_into().unwrap()) & FUSE_INIT_EXT,
            0
        );
        assert_eq!(
            u32::from_le_bytes(reply[48..52].try_into().unwrap()),
            FUSE_DIRECT_IO_ALLOW_MMAP_FLAGS2
        );
        let id = lookup_in(&mut fsys, ROOT, b"existing").unwrap();
        for (access, flags) in [(0, FOPEN_DIRECT_IO | FOPEN_NOFLUSH), (2, FOPEN_DIRECT_IO)] {
            let reply = open(&mut fsys, id, access);
            assert_eq!(errno(&reply), 0);
            assert_eq!(u32::from_le_bytes(reply[24..28].try_into().unwrap()), flags);
        }
        let reply = create_in(&mut fsys, ROOT, b"created", O_WRONLY_CREAT, 0o644);
        assert_eq!(errno(&reply), 0);
        assert_eq!(
            u32::from_le_bytes(reply[152..156].try_into().unwrap()),
            FOPEN_DIRECT_IO
        );

        let state = core(&fsys).snapshot_blob();
        let restored = writable(&share);
        core(&restored).direct_io_requested = false;
        core(&restored).restore_blob(&state);
        assert!(core(&restored).direct_io_mmap);
        core(&restored).restore_blob(&state[..state.len() - SNAPSHOT_DIRECT_IO_MMAP_TAG.len()]);
        assert!(!core(&restored).direct_io_mmap);
        core(&restored).restore_blob(&state);
        let legacy_end = state
            .windows(4)
            .position(|b| b == SNAPSHOT_OWNERS_TAG)
            .unwrap();
        core(&restored).restore_blob(&state[..legacy_end]);
        assert!(!core(&restored).direct_io_mmap);
        for (tag, read_only) in [("workspace", true), ("other", false)] {
            let other = VirtioFs::new(tag, share.clone(), read_only, Arc::default()).unwrap();
            core(&other).restore_blob(&state);
            assert!(!core(&other).direct_io_mmap);
        }
        fs::remove_dir_all(base).unwrap();
    }

    #[test]
    fn mutable_share_keeps_open_inode_across_host_replacement() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-replace-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        let path = dir.join("source");
        fs::write(&path, b"original").unwrap();
        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let first = lookup(&mut fsys, b"source\0");
        let opened = open(&mut fsys, first, 2);
        assert_eq!(errno(&opened), 0);
        let old_fh = u64::from_le_bytes(opened[16..24].try_into().unwrap());
        let old_file = fsys.shared.core.lock().unwrap().open_files[&old_fh]
            .file
            .clone();
        let new_path = dir.join("replacement");
        fs::write(&new_path, b"revision").unwrap();
        fs::rename(&new_path, &path).unwrap();
        assert_eq!(errno(&open(&mut fsys, first, 0o1002)), LINUX_ESTALE);
        assert_eq!(fs::read(&path).unwrap(), b"revision");
        let second = lookup(&mut fsys, b"source\0");
        assert_ne!(first, second);
        assert_eq!(errno(&open(&mut fsys, first, 0o1002)), LINUX_ESTALE);
        assert_eq!(
            fsys.shared
                .core
                .lock()
                .unwrap()
                .node_stat(first, &[])
                .unwrap()
                .ino,
            old_file.metadata().unwrap().ino()
        );
        let mut getattr = [0; 16];
        getattr[..4].copy_from_slice(&FUSE_GETATTR_FH.to_le_bytes());
        getattr[8..16].copy_from_slice(&old_fh.to_le_bytes());
        let old_attr = request(&mut fsys, FUSE_GETATTR, first, &getattr);
        assert_eq!(errno(&old_attr), 0);
        assert_eq!(u64::from_le_bytes(old_attr[40..48].try_into().unwrap()), 8);
        assert_eq!(
            errno(&request(&mut fsys, FUSE_GETATTR, second, &getattr)),
            LINUX_EBADF
        );
        let mut body = [0; 88];
        body[8..16].copy_from_slice(&old_fh.to_le_bytes());
        body[16..24].copy_from_slice(&1u64.to_le_bytes());
        fsys.shared
            .core
            .lock()
            .unwrap()
            .set_attributes(first, &body, FATTR_FH | FATTR_SIZE)
            .unwrap();
        assert_eq!(old_file.metadata().unwrap().size(), 1);
        assert_eq!(fs::read(&path).unwrap(), b"revision");
        assert_eq!(
            fsys.shared
                .core
                .lock()
                .unwrap()
                .set_attributes(second, &body, FATTR_FH | FATTR_SIZE)
                .unwrap_err(),
            LINUX_EBADF
        );
        body[40..48].copy_from_slice(&1_600_000_000i64.to_le_bytes());
        body[68..72].copy_from_slice(&0o640u32.to_le_bytes());
        let md = fsys
            .shared
            .core
            .lock()
            .unwrap()
            .set_attributes(second, &body, FATTR_MTIME | FATTR_MODE)
            .unwrap();
        assert_eq!((md.mtime, md.mode & 0o777), (1_600_000_000, 0o640));
        assert_eq!(errno(&open(&mut fsys, second, 0o1002)), 0);
        assert_eq!(fs::metadata(&path).unwrap().size(), 0);
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn rename_overwrite_retires_the_destination_and_readdirplus_reports_the_current_type() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-rename-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        let path = dir.join("destination");
        fs::write(&path, b"displaced").unwrap();
        fs::write(dir.join("backup"), b"replacement").unwrap();
        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let old = lookup(&mut fsys, b"destination\0");
        let new = lookup(&mut fsys, b"backup\0");
        let old_open = open(&mut fsys, old, 0);
        assert_eq!(errno(&old_open), 0);

        let mut rename = FUSE_ROOT_ID.to_le_bytes().to_vec();
        rename.extend_from_slice(b"backup\0destination\0");
        assert_eq!(
            errno(&request(&mut fsys, FUSE_RENAME, FUSE_ROOT_ID, &rename)),
            0
        );
        assert!(!fsys.shared.core.lock().unwrap().nodes.contains_key(&old));
        assert_eq!(lookup(&mut fsys, b"destination\0"), new);
        let mut read = [0; 24];
        read[..8].copy_from_slice(&old_open[16..24]);
        read[16..20].copy_from_slice(&64u32.to_le_bytes());
        let old_data = request(&mut fsys, FUSE_READ, old, &read);
        assert_eq!(errno(&old_data), 0);
        assert_eq!(&old_data[16..], b"displaced");

        let opendir = request(&mut fsys, FUSE_OPENDIR, FUSE_ROOT_ID, &[0; 8]);
        assert_eq!(errno(&opendir), 0);
        std::os::unix::fs::symlink("new-target", dir.join("link")).unwrap();
        fs::rename(dir.join("link"), &path).unwrap();
        assert_eq!(errno(&open(&mut fsys, new, 0)), LINUX_ESTALE);

        read[..8].copy_from_slice(&opendir[16..24]);
        read[16..20].copy_from_slice(&4096u32.to_le_bytes());
        let directory = request(&mut fsys, FUSE_READDIRPLUS, FUSE_ROOT_ID, &read);
        assert_eq!(errno(&directory), 0);
        let current = u64::from_le_bytes(directory[16..24].try_into().unwrap());
        assert_ne!(current, new);
        assert_eq!(lookup(&mut fsys, b"destination\0"), current);
        assert_eq!(
            u32::from_le_bytes(directory[164..168].try_into().unwrap()),
            libc::DT_LNK as u32
        );
        assert_eq!(&directory[168..179], b"destination");
        fs::remove_file(path).unwrap();
        fs::remove_dir(dir).unwrap();
    }

    #[test]
    fn virtiofs_init_lookup_and_read() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("hello.txt"), b"hello-virtiofs").unwrap();

        let mut vfs = VirtioFs::new(
            "test-tag",
            dir.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        // FUSE_INIT
        let mut init_req = vec![0u8; 56];
        init_req[0..4].copy_from_slice(&56u32.to_le_bytes());
        init_req[4..8].copy_from_slice(&FUSE_INIT.to_le_bytes());
        init_req[8..16].copy_from_slice(&1u64.to_le_bytes());
        let resp = vfs.handle_fuse(&init_req).unwrap();
        assert_eq!(i32::from_le_bytes(resp[4..8].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(resp[16..20].try_into().unwrap()), 7);

        // FUSE_LOOKUP "hello.txt"
        let mut lookup = vec![0u8; 40];
        lookup[4..8].copy_from_slice(&FUSE_LOOKUP.to_le_bytes());
        lookup[8..16].copy_from_slice(&2u64.to_le_bytes());
        lookup[16..24].copy_from_slice(&FUSE_ROOT_ID.to_le_bytes());
        lookup.extend_from_slice(b"hello.txt\0");
        let l = lookup.len() as u32;
        lookup[0..4].copy_from_slice(&l.to_le_bytes());
        let lresp = vfs.handle_fuse(&lookup).unwrap();
        assert_eq!(i32::from_le_bytes(lresp[4..8].try_into().unwrap()), 0);
        let child_id = u64::from_le_bytes(lresp[16..24].try_into().unwrap());
        assert!(child_id >= 2);

        // FUSE_OPEN on read-only share returns ENOSYS (activating Linux fc->no_open + FOPEN_KEEP_CACHE)
        let mut open_req = vec![0u8; 48];
        open_req[0..4].copy_from_slice(&48u32.to_le_bytes());
        open_req[4..8].copy_from_slice(&FUSE_OPEN.to_le_bytes());
        open_req[8..16].copy_from_slice(&3u64.to_le_bytes());
        open_req[16..24].copy_from_slice(&child_id.to_le_bytes());
        let oresp = vfs.handle_fuse(&open_req).unwrap();
        assert_eq!(
            i32::from_le_bytes(oresp[4..8].try_into().unwrap()),
            -LINUX_ENOSYS
        );

        // FUSE_READ with fh == 0 resolves directly via nodeid cache
        let mut read_req = vec![0u8; 64];
        read_req[0..4].copy_from_slice(&64u32.to_le_bytes());
        read_req[4..8].copy_from_slice(&FUSE_READ.to_le_bytes());
        read_req[8..16].copy_from_slice(&4u64.to_le_bytes());
        read_req[16..24].copy_from_slice(&child_id.to_le_bytes());
        read_req[56..60].copy_from_slice(&64u32.to_le_bytes()); // size = 64
        let rresp = vfs.handle_fuse(&read_req).unwrap();
        assert_eq!(i32::from_le_bytes(rresp[4..8].try_into().unwrap()), 0);
        assert_eq!(&rresp[16..], b"hello-virtiofs");

        // Path traversal rejected
        for name in [&b"../etc"[..], b"..", b".", b"a/b", b""] {
            assert_eq!(entry_name(name).unwrap_err(), LINUX_EINVAL);
        }

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_only_no_open_reads_never_follow_symlinks_outside_the_share() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-ro-link-{}", std::process::id()));
        let outside = std::env::temp_dir().join(format!("mp-vfs-ro-secret-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_file(&outside);
        fs::create_dir_all(&dir).unwrap();
        fs::write(&outside, b"host-secret").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("escape")).unwrap();

        let mut fsys = VirtioFs::new(
            "oci-tools",
            dir.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let id = lookup(&mut fsys, b"escape\0");
        let mut read = [0u8; 24];
        read[16..20].copy_from_slice(&64u32.to_le_bytes());
        let reply = request(&mut fsys, FUSE_READ, id, &read);
        assert_eq!(errno(&reply), LINUX_ELOOP);

        let _ = fs::remove_file(&outside);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mutable_lookup_over_split_descriptors_observes_host_changes() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-lookup-chain-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let long_name = c"long-filename-beyond-the-initial-request-prefix";
        let short_path = dir.join("source");
        fs::write(&short_path, b"same-size").unwrap();
        fs::set_permissions(&short_path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(dir.join(OsStr::from_bytes(long_name.to_bytes())), b"long").unwrap();
        let fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();

        let mut backing = vec![0u8; 1024];
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), 0, backing.len()) };
        let mut core = fsys.shared.core.lock().unwrap();
        let mut scratch = Vec::new();
        let mut lookup = |name: &CStr| {
            let req = request_bytes(FUSE_LOOKUP, FUSE_ROOT_ID, name.to_bytes_with_nul());
            let (header, rest) = req.split_at(24);
            mem.write_slice(0, header.len())
                .unwrap()
                .copy_from_slice(header);
            mem.write_slice(128, rest.len())
                .unwrap()
                .copy_from_slice(rest);
            let bufs = [
                DescBuf {
                    addr: 0,
                    len: header.len() as u32,
                    is_write: false,
                },
                DescBuf {
                    addr: 128,
                    len: rest.len() as u32,
                    is_write: false,
                },
                DescBuf {
                    addr: 256,
                    len: 16,
                    is_write: true,
                },
                DescBuf {
                    addr: 512,
                    len: 128,
                    is_write: true,
                },
            ];
            assert_eq!(core.handle_fuse_chain(&bufs, &mem, &mut scratch), 144);
            assert_eq!(errno(mem.read_slice(256, 16).unwrap()), 0);
            let entry = mem.read_slice(512, 128).unwrap();
            let nodeid = u64::from_le_bytes(entry[..8].try_into().unwrap());
            let attr_ino = u64::from_le_bytes(entry[40..48].try_into().unwrap());
            // The inode number is the host's; the node ID is the server's own.
            let host = fs::symlink_metadata(dir.join(OsStr::from_bytes(name.to_bytes()))).unwrap();
            assert_eq!(attr_ino, host.ino());
            let mode = u32::from_le_bytes(entry[100..104].try_into().unwrap());
            (nodeid, mode & 0o777, scratch.capacity())
        };

        let (id, mode, scratch_capacity) = lookup(c"source");
        assert_eq!((mode, scratch_capacity), (0o600, 0));
        fs::set_permissions(&short_path, fs::Permissions::from_mode(0o640)).unwrap();
        assert_eq!(lookup(c"source"), (id, 0o640, 0));
        let (long_id, _, scratch_capacity) = lookup(long_name);
        assert_ne!(long_id, id);
        assert!(scratch_capacity >= 40 + long_name.to_bytes_with_nul().len());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn virtiofs_zero_copy_read_and_write_via_guest_memory() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-zc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("zc.bin");
        fs::write(&file_path, b"initial").unwrap();

        let mut fsys = VirtioFs::new(
            "workspace",
            dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let id = lookup(&mut fsys, b"zc.bin\0");
        let opened = open(&mut fsys, id, 2);
        assert_eq!(errno(&opened), 0);
        let fh = u64::from_le_bytes(opened[16..24].try_into().unwrap());

        let mut backing = vec![0u8; 8192];
        let ram_base = 0x4000_0000u64;
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), ram_base, backing.len()) };

        // Zero-copy FUSE_WRITE via scatter-gather GuestMemory descriptors
        let payload = b"zero-copy-pwritev-payload-1234567890!";
        let mut whdr = [0u8; 80];
        whdr[0..4].copy_from_slice(&((80 + payload.len()) as u32).to_le_bytes());
        whdr[4..8].copy_from_slice(&FUSE_WRITE.to_le_bytes());
        whdr[8..16].copy_from_slice(&99u64.to_le_bytes());
        whdr[16..24].copy_from_slice(&id.to_le_bytes());
        whdr[40..48].copy_from_slice(&fh.to_le_bytes());
        whdr[48..56].copy_from_slice(&0u64.to_le_bytes()); // offset 0
        whdr[56..60].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        mem.write_slice(ram_base, 80)
            .unwrap()
            .copy_from_slice(&whdr);
        mem.write_slice(ram_base + 128, payload.len())
            .unwrap()
            .copy_from_slice(payload);
        let wbufs = [
            DescBuf {
                addr: ram_base,
                len: 80,
                is_write: false,
            },
            DescBuf {
                addr: ram_base + 128,
                len: payload.len() as u32,
                is_write: false,
            },
            DescBuf {
                addr: ram_base + 512,
                len: 24,
                is_write: true,
            },
        ];
        let wlen = fsys.handle_fuse_chain(&wbufs, &mem);
        assert_eq!(wlen, 24);
        let wrep = mem.read_slice(ram_base + 512, 24).unwrap();
        assert_eq!(i32::from_le_bytes(wrep[4..8].try_into().unwrap()), 0);
        assert_eq!(
            u32::from_le_bytes(wrep[16..20].try_into().unwrap()) as usize,
            payload.len()
        );

        // Zero-copy FUSE_READ via scatter-gather GuestMemory descriptors
        let mut rhdr = [0u8; 64];
        rhdr[0..4].copy_from_slice(&64u32.to_le_bytes());
        rhdr[4..8].copy_from_slice(&FUSE_READ.to_le_bytes());
        rhdr[8..16].copy_from_slice(&100u64.to_le_bytes());
        rhdr[16..24].copy_from_slice(&id.to_le_bytes());
        rhdr[40..48].copy_from_slice(&fh.to_le_bytes());
        rhdr[48..56].copy_from_slice(&0u64.to_le_bytes());
        rhdr[56..60].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        mem.write_slice(ram_base + 1024, 64)
            .unwrap()
            .copy_from_slice(&rhdr);
        let rbufs = [
            DescBuf {
                addr: ram_base + 1024,
                len: 64,
                is_write: false,
            },
            DescBuf {
                addr: ram_base + 2048,
                len: 16,
                is_write: true,
            },
            DescBuf {
                addr: ram_base + 2100,
                len: 16,
                is_write: true,
            },
            DescBuf {
                addr: ram_base + 2200,
                len: 64,
                is_write: true,
            },
        ];
        let rlen = fsys.handle_fuse_chain(&rbufs, &mem);
        assert_eq!(rlen as usize, 16 + payload.len());
        let rrep = mem.read_slice(ram_base + 2048, 16).unwrap();
        assert_eq!(i32::from_le_bytes(rrep[4..8].try_into().unwrap()), 0);
        let mut read_back = Vec::new();
        read_back.extend_from_slice(mem.read_slice(ram_base + 2100, 16).unwrap());
        read_back.extend_from_slice(mem.read_slice(ram_base + 2200, payload.len() - 16).unwrap());
        assert_eq!(read_back.as_slice(), payload);

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn darwin_getattrlistbulk_matches_symlink_metadata() {
        let dir = std::env::temp_dir().join(format!("mp-vfs-bulk-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("subdir")).unwrap();
        fs::write(dir.join("alpha.txt"), b"0123456789abcdef").unwrap();
        std::os::unix::fs::symlink("alpha.txt", dir.join("sym")).unwrap();

        let cpath = path_to_cstr(&dir).unwrap();
        let raw_fd = unsafe {
            libc::open(
                cpath.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        assert!(raw_fd >= 0);
        let owned = unsafe { OwnedFd::from_raw_fd(raw_fd) };
        let mut buf = Vec::new();
        let entries = darwin_bulk::read_dir_bulk(owned.as_raw_fd(), &mut buf).unwrap();
        assert_eq!(entries.len(), 3);
        for e in &entries {
            let name = e.name.to_str().unwrap();
            let md = fs::symlink_metadata(dir.join(name)).unwrap();
            assert_eq!(e.stat.dev, md.dev(), "dev mismatch for {name}");
            assert_eq!(e.stat.ino, md.ino(), "ino mismatch for {name}");
            assert_eq!(
                e.stat.mode & (libc::S_IFMT as u32),
                md.mode() & (libc::S_IFMT as u32),
                "ifmt mismatch for {name}"
            );
            assert_eq!(
                e.stat.mode & 0o777,
                md.mode() & 0o777,
                "perm mismatch for {name}"
            );
            if md.is_file() {
                assert_eq!(e.stat.size, md.size(), "size mismatch for {name}");
            }
            assert_eq!(
                (
                    e.stat.mtime,
                    e.stat.mtime_nsec,
                    e.stat.ctime,
                    e.stat.ctime_nsec
                ),
                (md.mtime(), md.mtime_nsec(), md.ctime(), md.ctime_nsec()),
                "timestamp mismatch for {name}"
            );
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn virtiofs_snapshot_restore_rebinds_cross_workspace_safely() {
        let base_dir = std::env::temp_dir().join(format!("mp-fs-base-{}", std::process::id()));
        let fork_dir = std::env::temp_dir().join(format!("mp-fs-fork-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base_dir);
        let _ = fs::remove_dir_all(&fork_dir);
        fs::create_dir_all(&base_dir).unwrap();
        fs::create_dir_all(&fork_dir).unwrap();
        fs::write(base_dir.join("shared.txt"), b"base").unwrap();
        fs::write(base_dir.join("only_base.txt"), b"gone").unwrap();
        fs::write(fork_dir.join("shared.txt"), b"fork-version").unwrap();

        let mut src = VirtioFs::new(
            "workspace",
            base_dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let shared_id = lookup(&mut src, b"shared.txt\0");
        let only_base_id = lookup(&mut src, b"only_base.txt\0");
        let mut backing = vec![0u8; 4096];
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), 0x4000_0000, backing.len()) };
        let mut queues = vec![VirtQueue::new(64), VirtQueue::new(64)];
        let blob = src.snapshot_pause(&mut queues, &mem);

        let mut dst = VirtioFs::new(
            "workspace",
            fork_dir.clone(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        dst.snapshot_restore(&blob, &queues);

        let fork_canon = fs::canonicalize(&fork_dir).unwrap();
        {
            let core = dst.shared.core.lock().unwrap();
            assert_eq!(
                core.node_rel_path(shared_id).as_deref(),
                Some(&b"shared.txt"[..])
            );
            let fork_md = fs::symlink_metadata(fork_canon.join("shared.txt")).unwrap();
            assert_eq!(
                core.nodes[&shared_id].identity,
                Some((fork_md.dev(), fork_md.ino()))
            );
            assert!(
                !core.nodes.contains_key(&only_base_id),
                "missing file in new fork workspace should not bind a phantom node"
            );
        }
        // FUSE_GETATTR on missing pre-snapshot node returns ESTALE cleanly; shared node returns fork size (12)
        let stale_reply = request(&mut dst, FUSE_GETATTR, only_base_id, &[0u8; 16]);
        assert_eq!(errno(&stale_reply), LINUX_ESTALE);
        let shared_reply = request(&mut dst, FUSE_GETATTR, shared_id, &[0u8; 16]);
        assert_eq!(errno(&shared_reply), 0);
        let shared_size = u64::from_le_bytes(shared_reply[40..48].try_into().unwrap());
        assert_eq!(shared_size, 12);

        let _ = fs::remove_dir_all(&base_dir);
        let _ = fs::remove_dir_all(&fork_dir);
    }

    // ---- containment: a node never resolves through a host path ----

    const O_WRONLY_CREAT: u32 = 0o101;
    const ROOT: u64 = FUSE_ROOT_ID;

    /// A fresh canonical scratch directory with `share/` and `outside/` in it.
    fn scratch(name: &str) -> (PathBuf, PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("mp-vfs-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("share")).unwrap();
        fs::create_dir_all(base.join("outside")).unwrap();
        let base = fs::canonicalize(base).unwrap();
        (base.clone(), base.join("share"), base.join("outside"))
    }

    fn writable(share: &Path) -> VirtioFs {
        VirtioFs::new(
            "workspace",
            share.to_path_buf(),
            false,
            Arc::new(FsMetrics::default()),
        )
        .unwrap()
    }

    fn core(fsys: &VirtioFs) -> std::sync::MutexGuard<'_, FsCore> {
        fsys.shared.core.lock().unwrap()
    }

    fn with_name(prefix: &[u8], name: &[u8]) -> Vec<u8> {
        let mut body = prefix.to_vec();
        body.extend_from_slice(name);
        body.push(0);
        body
    }

    fn entry_id(reply: &[u8]) -> Result<u64, i32> {
        match errno(reply) {
            0 => Ok(u64::from_le_bytes(reply[16..24].try_into().unwrap())),
            e => Err(e),
        }
    }

    fn lookup_in(fsys: &mut VirtioFs, parent: u64, name: &[u8]) -> Result<u64, i32> {
        entry_id(&request(fsys, FUSE_LOOKUP, parent, &with_name(&[], name)))
    }

    fn mkdir_in(fsys: &mut VirtioFs, parent: u64, name: &[u8], mode: u32) -> Result<u64, i32> {
        let mut hdr = [0u8; 8];
        hdr[..4].copy_from_slice(&mode.to_le_bytes());
        entry_id(&request(fsys, FUSE_MKDIR, parent, &with_name(&hdr, name)))
    }

    fn create_body(name: &[u8], flags: u32, mode: u32) -> Vec<u8> {
        let mut hdr = [0u8; 16];
        hdr[..4].copy_from_slice(&flags.to_le_bytes());
        hdr[4..8].copy_from_slice(&mode.to_le_bytes());
        with_name(&hdr, name)
    }

    fn create_in(fsys: &mut VirtioFs, parent: u64, name: &[u8], flags: u32, mode: u32) -> Vec<u8> {
        request(fsys, FUSE_CREATE, parent, &create_body(name, flags, mode))
    }

    fn symlink_in(
        fsys: &mut VirtioFs,
        parent: u64,
        name: &[u8],
        target: &[u8],
    ) -> Result<u64, i32> {
        let mut body = with_name(&[], name);
        body.extend_from_slice(target);
        body.push(0);
        entry_id(&request(fsys, FUSE_SYMLINK, parent, &body))
    }

    fn link_in(fsys: &mut VirtioFs, old: u64, parent: u64, name: &[u8]) -> Result<u64, i32> {
        entry_id(&request(
            fsys,
            FUSE_LINK,
            parent,
            &with_name(&old.to_le_bytes(), name),
        ))
    }

    fn rename2(
        fsys: &mut VirtioFs,
        (old_dir, old): (u64, &[u8]),
        (new_dir, new): (u64, &[u8]),
        flags: u32,
    ) -> i32 {
        let mut body = new_dir.to_le_bytes().to_vec();
        let opcode = if flags == 0 {
            FUSE_RENAME
        } else {
            body.extend_from_slice(&flags.to_le_bytes());
            body.extend_from_slice(&[0; 4]);
            FUSE_RENAME2
        };
        body.extend_from_slice(old);
        body.push(0);
        body.extend_from_slice(new);
        body.push(0);
        errno(&request(fsys, opcode, old_dir, &body))
    }

    fn rename_in(fsys: &mut VirtioFs, old: (u64, &[u8]), new: (u64, &[u8])) -> i32 {
        rename2(fsys, old, new, 0)
    }

    fn listing(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn attr_mode(reply: &[u8]) -> u32 {
        u32::from_le_bytes(
            reply[ATTR_OUT_ATTR + 60..ATTR_OUT_ATTR + 64]
                .try_into()
                .unwrap(),
        )
    }

    #[test]
    fn rename_moves_the_subtree_and_link_cannot_follow_a_planted_symlink() {
        let (base, share, outside) = scratch("link-escape");
        fs::create_dir_all(outside.join("Library/LaunchAgents")).unwrap();
        let mut fsys = writable(&share);
        let d = mkdir_in(&mut fsys, ROOT, b"d", 0o755).unwrap();
        let lib = mkdir_in(&mut fsys, d, b"Library", 0o755).unwrap();
        let agents = mkdir_in(&mut fsys, lib, b"LaunchAgents", 0o755).unwrap();
        let payload = entry_id(&create_in(
            &mut fsys,
            ROOT,
            b"payload",
            O_WRONLY_CREAT,
            0o644,
        ))
        .unwrap();

        // `cd d/Library/LaunchAgents && mv /app/d /app/e && ln -s <outside> /app/d`
        assert_eq!(rename_in(&mut fsys, (ROOT, b"d"), (ROOT, b"e")), 0);
        symlink_in(&mut fsys, ROOT, b"d", outside.as_os_str().as_bytes()).unwrap();
        assert_eq!(
            core(&fsys).node_rel_path(agents).as_deref(),
            Some(&b"e/Library/LaunchAgents"[..])
        );

        // `ln /app/payload evil` relative to the old cwd, with the directory
        // descriptors cached and again after the cache was emptied.
        link_in(&mut fsys, payload, agents, b"evil").unwrap();
        core(&fsys).dir_fds.clear();
        link_in(&mut fsys, payload, agents, b"evil2").unwrap();
        // Every other mutation in the moved subtree stays in it as well.
        core(&fsys).dir_fds.clear();
        mkdir_in(&mut fsys, agents, b"sub", 0o755).unwrap();
        core(&fsys).dir_fds.clear();
        entry_id(&create_in(
            &mut fsys,
            agents,
            b"made",
            O_WRONLY_CREAT,
            0o644,
        ))
        .unwrap();
        core(&fsys).dir_fds.clear();
        symlink_in(&mut fsys, agents, b"lnk", b"target").unwrap();
        core(&fsys).dir_fds.clear();
        assert_eq!(
            rename_in(&mut fsys, (agents, b"made"), (agents, b"moved")),
            0
        );
        core(&fsys).dir_fds.clear();
        assert_eq!(
            errno(&request(&mut fsys, FUSE_UNLINK, agents, b"evil2\0")),
            0
        );

        assert_eq!(
            listing(&share.join("e/Library/LaunchAgents")),
            ["evil", "lnk", "moved", "sub"]
        );
        assert!(listing(&outside.join("Library/LaunchAgents")).is_empty());
        assert_eq!(listing(&outside), ["Library"]);
        assert_eq!(
            fs::metadata(share.join("e/Library/LaunchAgents/evil"))
                .unwrap()
                .ino(),
            fs::metadata(share.join("payload")).unwrap().ino()
        );
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn lookups_in_a_moved_subtree_cannot_follow_a_planted_symlink() {
        let (base, share, outside) = scratch("lookup-escape");
        fs::create_dir_all(outside.join("etc")).unwrap();
        fs::write(outside.join("etc/secret"), b"host-secret").unwrap();
        fs::set_permissions(outside.join("etc"), fs::Permissions::from_mode(0o700)).unwrap();
        let mut fsys = writable(&share);
        let x = mkdir_in(&mut fsys, ROOT, b"x", 0o755).unwrap();
        let etc = mkdir_in(&mut fsys, x, b"etc", 0o755).unwrap();

        // `cd x/etc && mv /app/x /app/y && ln -s <outside> /app/x`, then enough
        // directory traffic that the descriptor cache is emptied.
        assert_eq!(rename_in(&mut fsys, (ROOT, b"x"), (ROOT, b"y")), 0);
        symlink_in(&mut fsys, ROOT, b"x", outside.as_os_str().as_bytes()).unwrap();
        for i in 0..MAX_CACHED_DIR_FDS + 8 {
            let name = format!("f{i}");
            let id = mkdir_in(&mut fsys, ROOT, name.as_bytes(), 0o755).unwrap();
            assert_eq!(lookup_in(&mut fsys, id, b"none"), Err(LINUX_ENOENT));
        }
        assert!(!core(&fsys).dir_fds.contains_key(&etc));
        assert!(!core(&fsys).dir_fds.contains_key(&x));

        assert_eq!(lookup_in(&mut fsys, etc, b"secret"), Err(LINUX_ENOENT));
        core(&fsys).dir_fds.clear();
        let reply = request(&mut fsys, FUSE_GETATTR, etc, &[0u8; 16]);
        assert_eq!(errno(&reply), 0);
        // The moved directory (0755), not the one behind the link (0700).
        assert_eq!(attr_mode(&reply) & 0o777, 0o755);
        core(&fsys).dir_fds.clear();
        let opened = request(&mut fsys, FUSE_OPENDIR, etc, &[0; 8]);
        assert_eq!(errno(&opened), 0);
        let mut read = [0u8; 24];
        read[..8].copy_from_slice(&opened[16..24]);
        read[16..20].copy_from_slice(&4096u32.to_le_bytes());
        let entries = request(&mut fsys, FUSE_READDIRPLUS, etc, &read);
        assert_eq!(
            (errno(&entries), entries.len()),
            (0, 16),
            "listed a host directory"
        );
        core(&fsys).dir_fds.clear();
        entry_id(&create_in(&mut fsys, etc, b"new", O_WRONLY_CREAT, 0o644)).unwrap();

        assert_eq!(listing(&share.join("y/etc")), ["new"]);
        assert_eq!(listing(&outside.join("etc")), ["secret"]);
        let secret = fs::metadata(outside.join("etc/secret")).unwrap();
        assert!(
            core(&fsys)
                .nodes
                .values()
                .all(|n| n.identity != Some((secret.dev(), secret.ino())))
        );
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn a_directory_swapped_for_a_symlink_goes_stale_and_nothing_resolves_outside() {
        let (base, share, outside) = scratch("swap");
        fs::write(outside.join("f"), b"outside").unwrap();
        let mut fsys = writable(&share);
        let a = mkdir_in(&mut fsys, ROOT, b"a", 0o755).unwrap();
        let f = entry_id(&create_in(&mut fsys, a, b"f", O_WRONLY_CREAT, 0o644)).unwrap();
        let g = entry_id(&create_in(&mut fsys, ROOT, b"g", O_WRONLY_CREAT, 0o644)).unwrap();
        // No open handle may stand in for the files (GETATTR falls back to one).
        core(&fsys).open_files.clear();
        fs::rename(share.join("a"), share.join("a2")).unwrap();
        std::os::unix::fs::symlink(&outside, share.join("a")).unwrap();
        core(&fsys).dir_fds.clear();

        let mut truncate = [0u8; 88];
        truncate[..4].copy_from_slice(&FATTR_SIZE.to_le_bytes());
        let results = [
            lookup_in(&mut fsys, a, b"f").err(),
            entry_id(&create_in(&mut fsys, a, b"new", O_WRONLY_CREAT, 0o644)).err(),
            mkdir_in(&mut fsys, a, b"dir", 0o755).err(),
            symlink_in(&mut fsys, a, b"lnk", b"x").err(),
            link_in(&mut fsys, g, a, b"hard").err(),
            link_in(&mut fsys, f, ROOT, b"hard").err(),
            Some(errno(&request(&mut fsys, FUSE_UNLINK, a, b"f\0"))),
            Some(rename_in(&mut fsys, (a, b"f"), (ROOT, b"moved"))),
            Some(rename_in(&mut fsys, (ROOT, b"g"), (a, b"g"))),
            Some(errno(&request(&mut fsys, FUSE_OPENDIR, a, &[0; 8]))),
            Some(errno(&request(&mut fsys, FUSE_GETATTR, a, &[0; 16]))),
            Some(errno(&request(&mut fsys, FUSE_GETATTR, f, &[0; 16]))),
            Some(errno(&open(&mut fsys, f, 2))),
            Some(errno(&request(&mut fsys, FUSE_SETATTR, f, &truncate))),
            Some(errno(&request(
                &mut fsys,
                FUSE_SETATTR,
                a,
                &setattr_mode(0o777),
            ))),
            Some(errno(&request(&mut fsys, FUSE_READLINK, f, &[]))),
        ];
        assert!(
            results.iter().all(|r| *r == Some(LINUX_ESTALE)),
            "{results:?}"
        );
        assert_eq!(listing(&outside), ["f"]);
        assert_eq!(fs::read(outside.join("f")).unwrap(), b"outside");
        assert_eq!(fs::metadata(&outside).unwrap().mode() & 0o777, 0o755);
        assert_eq!(listing(&share.join("a2")), ["f"]);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn creates_and_opens_never_follow_a_symlink_at_the_name() {
        let (base, share, outside) = scratch("leaf-link");
        let target = outside.join("victim");
        let mut fsys = writable(&share);
        let lnk = symlink_in(&mut fsys, ROOT, b"lnk", target.as_os_str().as_bytes()).unwrap();
        let dlnk = symlink_in(&mut fsys, ROOT, b"dlnk", outside.as_os_str().as_bytes()).unwrap();
        assert_eq!(
            errno(&create_in(
                &mut fsys,
                ROOT,
                b"lnk",
                O_WRONLY_CREAT | 0o1000,
                0o644
            )),
            LINUX_ELOOP
        );
        assert_eq!(errno(&open(&mut fsys, lnk, 2)), LINUX_ELOOP);
        // Darwin reports O_DIRECTORY|O_NOFOLLOW on a symlink as ENOTDIR.
        assert!(matches!(
            errno(&request(&mut fsys, FUSE_OPENDIR, dlnk, &[0; 8])),
            LINUX_ELOOP | LINUX_ENOTDIR
        ));
        assert_eq!(lookup_in(&mut fsys, dlnk, b"victim"), Err(LINUX_ESTALE));
        let mut truncate = [0u8; 88];
        truncate[..4].copy_from_slice(&FATTR_SIZE.to_le_bytes());
        assert_eq!(
            errno(&request(&mut fsys, FUSE_SETATTR, lnk, &truncate)),
            LINUX_ELOOP
        );
        assert!(listing(&outside).is_empty());

        // The link text itself is still served.
        let reply = request(&mut fsys, FUSE_READLINK, lnk, &[]);
        assert_eq!(&reply[16..], target.as_os_str().as_bytes());
        // `.` and `..` are never entry names, and `..` looks up the parent node.
        let sub = mkdir_in(&mut fsys, ROOT, b"sub", 0o755).unwrap();
        assert_eq!(lookup_in(&mut fsys, sub, b".."), Ok(ROOT));
        assert_eq!(lookup_in(&mut fsys, sub, b"."), Ok(sub));
        assert_eq!(lookup_in(&mut fsys, ROOT, b".."), Ok(ROOT));
        for name in [&b".."[..], b"."] {
            assert_eq!(mkdir_in(&mut fsys, sub, name, 0o755), Err(LINUX_EINVAL));
            assert_eq!(
                errno(&create_in(&mut fsys, sub, name, O_WRONLY_CREAT, 0o644)),
                LINUX_EINVAL
            );
            assert_eq!(symlink_in(&mut fsys, sub, name, b"x"), Err(LINUX_EINVAL));
            assert_eq!(link_in(&mut fsys, lnk, sub, name), Err(LINUX_EINVAL));
            assert_eq!(
                errno(&request(&mut fsys, FUSE_UNLINK, sub, &with_name(&[], name))),
                LINUX_EINVAL
            );
            assert_eq!(
                rename_in(&mut fsys, (sub, name), (ROOT, b"z")),
                LINUX_EINVAL
            );
            assert_eq!(
                rename_in(&mut fsys, (ROOT, b"lnk"), (sub, name)),
                LINUX_EINVAL
            );
        }
        assert_eq!(listing(&share), ["dlnk", "lnk", "sub"]);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn deep_chains_resolve_one_entry_at_a_time() {
        let (base, share, outside) = scratch("deep");
        let mut fsys = writable(&share);
        let mut id = ROOT;
        // Longer than one O_NOFOLLOW_ANY open takes, short enough for a host path.
        let long = [b'n'; 230];
        for _ in 0..4 {
            id = mkdir_in(&mut fsys, id, &long, 0o755).unwrap();
        }
        core(&fsys).dir_fds.clear();
        entry_id(&create_in(&mut fsys, id, b"leaf", O_WRONLY_CREAT, 0o644)).unwrap();
        let mut path = share.clone();
        for _ in 0..4 {
            path.push(OsStr::from_bytes(&long));
        }
        assert!(fs::symlink_metadata(path.join("leaf")).is_ok());
        assert!(listing(&outside).is_empty());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn rename2_honours_noreplace_and_exchange() {
        let (base, share, _) = scratch("rename2");
        fs::write(share.join("a"), b"A").unwrap();
        fs::write(share.join("b"), b"B").unwrap();
        let mut fsys = writable(&share);
        let a = lookup_in(&mut fsys, ROOT, b"a").unwrap();
        let b = lookup_in(&mut fsys, ROOT, b"b").unwrap();
        assert_eq!(
            rename2(
                &mut fsys,
                (ROOT, b"a"),
                (ROOT, b"b"),
                LINUX_RENAME_NOREPLACE
            ),
            LINUX_EEXIST
        );
        assert_eq!(
            rename2(&mut fsys, (ROOT, b"a"), (ROOT, b"b"), 4),
            LINUX_EINVAL
        );
        assert_eq!(fs::read(share.join("a")).unwrap(), b"A");
        assert_eq!(fs::read(share.join("b")).unwrap(), b"B");
        assert_eq!(
            rename2(&mut fsys, (ROOT, b"a"), (ROOT, b"b"), LINUX_RENAME_EXCHANGE),
            0
        );
        assert_eq!(fs::read(share.join("a")).unwrap(), b"B");
        assert_eq!(lookup_in(&mut fsys, ROOT, b"a"), Ok(b));
        assert_eq!(lookup_in(&mut fsys, ROOT, b"b"), Ok(a));
        assert_eq!(
            rename2(
                &mut fsys,
                (ROOT, b"a"),
                (ROOT, b"c"),
                LINUX_RENAME_NOREPLACE
            ),
            0
        );
        assert_eq!(lookup_in(&mut fsys, ROOT, b"c"), Ok(b));
        assert_eq!(listing(&share), ["b", "c"]);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn directory_listing_without_getattrlistbulk_uses_the_descriptor() {
        let (base, share, _) = scratch("readdir-fd");
        fs::write(share.join("file"), b"x").unwrap();
        fs::create_dir(share.join("dir")).unwrap();
        std::os::unix::fs::symlink("file", share.join("lnk")).unwrap();
        let fd = open_dir_at(
            libc::AT_FDCWD,
            &path_to_cstr(&share).unwrap(),
            libc::O_NOFOLLOW,
        )
        .unwrap();
        let mut listing = DirListing {
            stream: Some(DirStream::open(fd.as_raw_fd()).unwrap()),
            ..DirListing::default()
        };
        listing.rewind(fd.as_raw_fd());
        let mut buf = Vec::new();
        while !listing.eof {
            listing.fill(fd.as_raw_fd(), &mut buf).unwrap();
        }
        let mut entries: Vec<_> = listing.window.into();
        entries.sort_by(|x, y| x.name.cmp(&y.name));
        let names: Vec<_> = entries.iter().map(|e| e.name.to_str().unwrap()).collect();
        assert_eq!(names, ["dir", "file", "lnk"]);
        for e in &entries {
            let md = fs::symlink_metadata(share.join(e.name.to_str().unwrap())).unwrap();
            assert_eq!((e.stat.ino, e.stat.mode), (md.ino(), md.mode()));
        }
        let _ = fs::remove_dir_all(base);
    }

    // ---- ownership ----

    fn setattr_owner(uid: Option<u32>, gid: Option<u32>) -> [u8; 88] {
        let mut body = [0u8; 88];
        let mut valid = 0;
        if let Some(uid) = uid {
            valid |= FATTR_UID;
            body[76..80].copy_from_slice(&uid.to_le_bytes());
        }
        if let Some(gid) = gid {
            valid |= FATTR_GID;
            body[80..84].copy_from_slice(&gid.to_le_bytes());
        }
        body[..4].copy_from_slice(&valid.to_le_bytes());
        body
    }

    fn setattr_mode(mode: u32) -> [u8; 88] {
        let mut body = [0u8; 88];
        body[..4].copy_from_slice(&FATTR_MODE.to_le_bytes());
        body[68..72].copy_from_slice(&mode.to_le_bytes());
        body
    }

    fn getattr_as(fsys: &mut VirtioFs, id: u64, caller: (u32, u32)) -> ((u32, u32), u32) {
        let reply = request_as(fsys, FUSE_GETATTR, id, &[0u8; 16], caller);
        assert_eq!(errno(&reply), 0);
        (attr_owner(&reply, ATTR_OUT_ATTR), attr_mode(&reply))
    }

    fn chown_as(
        fsys: &mut VirtioFs,
        id: u64,
        owner: (Option<u32>, Option<u32>),
        caller: (u32, u32),
    ) {
        let reply = request_as(
            fsys,
            FUSE_SETATTR,
            id,
            &setattr_owner(owner.0, owner.1),
            caller,
        );
        assert_eq!(errno(&reply), 0);
    }

    #[test]
    fn root_keeps_seeing_the_recent_non_root_owner_of_an_unclaimed_file() {
        let (base, share, _) = scratch("adopt");
        fs::write(share.join("f"), b"x").unwrap();
        let mut fsys = writable(&share);
        let f = entry_id(&request_as(&mut fsys, FUSE_LOOKUP, ROOT, b"f\0", (0, 0))).unwrap();
        // Nobody else has used it: root sees root.
        assert_eq!(getattr_as(&mut fsys, f, (0, 0)).0, (0, 0));
        // A non-root user sees itself, and a root refresh right after keeps
        // that owner in the guest's single attribute cache instead of flapping.
        assert_eq!(getattr_as(&mut fsys, f, (1000, 1001)).0, (1000, 1001));
        assert_eq!(getattr_as(&mut fsys, f, (0, 0)).0, (1000, 1001));
        let reply = request_as(&mut fsys, FUSE_LOOKUP, ROOT, b"f\0", (0, 0));
        assert_eq!(attr_owner(&reply, ENTRY_ATTR), (1000, 1001));
        // Another non-root user still sees itself.
        assert_eq!(getattr_as(&mut fsys, f, (70, 70)).0, (70, 70));
        assert_eq!(getattr_as(&mut fsys, f, (0, 0)).0, (70, 70));
        // Once that activity is old, root sees root again.
        core(&fsys).adopt_window_ms = 0;
        assert_eq!(getattr_as(&mut fsys, f, (0, 0)).0, (0, 0));
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn a_chown_of_either_field_pins_both_and_self_chown_pins_nothing() {
        let (base, share, _) = scratch("pin");
        for name in ["u", "g", "adopted", "mine", "self"] {
            fs::write(share.join(name), b"x").unwrap();
        }
        let mut fsys = writable(&share);
        let u = lookup_in(&mut fsys, ROOT, b"u").unwrap();
        let g = lookup_in(&mut fsys, ROOT, b"g").unwrap();
        let adopted = lookup_in(&mut fsys, ROOT, b"adopted").unwrap();
        let mine = lookup_in(&mut fsys, ROOT, b"mine").unwrap();
        let me = lookup_in(&mut fsys, ROOT, b"self").unwrap();
        // `chown 999 u` (`chown root tool; chmod 0770 tool`) settles the group
        // at what root saw (root's), so no other user is left in the group;
        // `chgrp 5 g` settles the owner the same way.
        chown_as(&mut fsys, u, (Some(999), None), (0, 0));
        chown_as(&mut fsys, g, (None, Some(5)), (0, 0));
        for caller in [(0, 0), (1000, 1000), (70, 70)] {
            assert_eq!(getattr_as(&mut fsys, u, caller).0, (999, 0), "{caller:?}");
            assert_eq!(getattr_as(&mut fsys, g, caller).0, (0, 5), "{caller:?}");
        }
        // Root sees a floating file as the user that just used it, and a
        // `chown 70` then keeps that user's group, as a chown on Linux keeps
        // the group the file had.
        assert_eq!(getattr_as(&mut fsys, adopted, (1000, 1001)).0, (1000, 1001));
        chown_as(&mut fsys, adopted, (Some(70), None), (0, 0));
        assert_eq!(getattr_as(&mut fsys, adopted, (1234, 1234)).0, (70, 1001));
        // A non-root `chgrp` to another of its groups pins it as the owner.
        chown_as(&mut fsys, mine, (None, Some(44)), (1000, 1000));
        core(&fsys).adopt_window_ms = 0;
        assert_eq!(getattr_as(&mut fsys, mine, (70, 70)).0, (1000, 44));
        assert_eq!(getattr_as(&mut fsys, mine, (0, 0)).0, (1000, 44));
        // A non-root `chown 1000:1000` (or `chown 1000`) of a file it already
        // sees as its own is a no-op.
        chown_as(&mut fsys, me, (Some(1000), Some(1000)), (1000, 1000));
        chown_as(&mut fsys, me, (Some(1000), None), (1000, 1000));
        assert_eq!(getattr_as(&mut fsys, me, (70, 70)).0, (70, 70));
        // Root pinning root is a real change.
        chown_as(&mut fsys, me, (Some(0), Some(0)), (0, 0));
        assert_eq!(getattr_as(&mut fsys, me, (70, 70)).0, (0, 0));
        // Owner changes never open the entry: a symlink and a file nobody may
        // read are chowned all the same (lchown, `chown -R`, `tar x`).
        std::os::unix::fs::symlink("target", share.join("lnk")).unwrap();
        fs::write(share.join("locked"), b"x").unwrap();
        fs::set_permissions(share.join("locked"), fs::Permissions::from_mode(0o000)).unwrap();
        let lnk = lookup_in(&mut fsys, ROOT, b"lnk").unwrap();
        let locked = lookup_in(&mut fsys, ROOT, b"locked").unwrap();
        chown_as(&mut fsys, lnk, (Some(5), Some(5)), (0, 0));
        chown_as(&mut fsys, locked, (Some(6), None), (0, 0));
        assert_eq!(getattr_as(&mut fsys, lnk, (1000, 1000)).0, (5, 5));
        assert_eq!(getattr_as(&mut fsys, locked, (1000, 1000)).0, (6, 0));
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn writable_shares_never_keep_or_report_set_id_bits_on_files() {
        let (base, share, _) = scratch("setid");
        fs::write(share.join("host-suid"), b"x").unwrap();
        fs::set_permissions(share.join("host-suid"), fs::Permissions::from_mode(0o6755)).unwrap();
        let mut fsys = writable(&share);
        // A set-id file from the Mac shows no set-id bits to anyone.
        let host = lookup_in(&mut fsys, ROOT, b"host-suid").unwrap();
        for caller in [(0, 0), (1000, 1000)] {
            assert_eq!(getattr_as(&mut fsys, host, caller).1 & 0o7777, 0o755);
        }
        // A non-root user cannot make its floating file set-id, on the host or in the guest.
        let reply = request_as(
            &mut fsys,
            FUSE_CREATE,
            ROOT,
            &create_body(b"sh", O_WRONLY_CREAT, 0o4755),
            (1000, 1000),
        );
        let sh = entry_id(&reply).unwrap();
        assert_eq!(
            fs::metadata(share.join("sh")).unwrap().mode() & 0o7777,
            0o755
        );
        let reply = request_as(
            &mut fsys,
            FUSE_SETATTR,
            sh,
            &setattr_mode(0o4755),
            (1000, 1000),
        );
        assert_eq!(errno(&reply), 0);
        assert_eq!(attr_mode(&reply) & 0o7777, 0o755);
        assert_eq!(
            fs::metadata(share.join("sh")).unwrap().mode() & 0o7777,
            0o755
        );
        assert_eq!(getattr_as(&mut fsys, sh, (0, 0)).1 & 0o7777, 0o755);
        // Nor can root on a root-owned file: the share is nosuid even where a
        // container runtime's bind remount drops the mount flag.
        chown_as(&mut fsys, sh, (Some(0), Some(0)), (0, 0));
        let reply = request_as(&mut fsys, FUSE_SETATTR, sh, &setattr_mode(0o6755), (0, 0));
        assert_eq!(errno(&reply), 0);
        assert_eq!(
            fs::metadata(share.join("sh")).unwrap().mode() & 0o7777,
            0o755
        );
        assert_eq!(
            getattr_as(&mut fsys, sh, (1000, 1000)),
            ((0, 0), libc::S_IFREG as u32 | 0o755)
        );
        // Directories keep set-group-ID (it only steers group inheritance).
        assert_eq!(guest_mode(0o42775, true), 0o42775);
        assert_eq!(guest_mode(0o46775, true), 0o42775);
        assert_eq!(guest_mode(0o106775, false), 0o100775);
        let dir = mkdir_in(&mut fsys, ROOT, b"shared", 0o775).unwrap();
        let reply = request_as(
            &mut fsys,
            FUSE_SETATTR,
            dir,
            &setattr_mode(0o2775),
            (1000, 1000),
        );
        assert_eq!(errno(&reply), 0);
        let host = fs::metadata(share.join("shared")).unwrap().mode();
        assert_eq!(attr_mode(&reply), host);
        assert_eq!(getattr_as(&mut fsys, dir, (1000, 1000)).1, host);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn pinned_owners_end_with_their_node_and_survive_a_snapshot() {
        let (base, share, _) = scratch("owner-life");
        fs::write(share.join("data"), b"x").unwrap();
        fs::write(share.join("grp"), b"x").unwrap();
        let mut fsys = writable(&share);
        let data = lookup_in(&mut fsys, ROOT, b"data").unwrap();
        let grp = lookup_in(&mut fsys, ROOT, b"grp").unwrap();
        chown_as(&mut fsys, data, (Some(999), Some(998)), (0, 0));
        chown_as(&mut fsys, grp, (None, Some(5)), (0, 0));
        chown_as(&mut fsys, ROOT, (Some(70), Some(70)), (0, 0));

        let blob = core(&fsys).snapshot_blob();
        let mut restored = writable(&share);
        core(&restored).restore_blob(&blob);
        core(&restored).adopt_window_ms = 0;
        assert_eq!(getattr_as(&mut restored, data, (1000, 1000)).0, (999, 998));
        assert_eq!(getattr_as(&mut restored, grp, (1000, 1000)).0, (0, 5));
        assert_eq!(getattr_as(&mut restored, ROOT, (1000, 1000)).0, (70, 70));
        // Pins on files no node names survive too (by host identity).
        let data_md = fs::metadata(share.join("data")).unwrap();
        core(&fsys).forget(data, u64::MAX);
        assert!(!core(&fsys).nodes.contains_key(&data));
        let by_file = core(&fsys).snapshot_blob();
        let mut by_identity = writable(&share);
        core(&by_identity).restore_blob(&by_file);
        let again = lookup_in(&mut by_identity, ROOT, b"data").unwrap();
        assert_eq!(getattr_as(&mut by_identity, again, (7, 7)).0, (999, 998));
        let data_now = lookup_in(&mut fsys, ROOT, b"data").unwrap();
        assert_ne!(data_now, data);
        // A blob from before pinned owners existed still restores its nodes.
        let tag = blob
            .windows(4)
            .position(|w| w == SNAPSHOT_OWNERS_TAG)
            .unwrap();
        let mut legacy = writable(&share);
        core(&legacy).restore_blob(&blob[..tag]);
        assert_eq!(getattr_as(&mut legacy, data, (1000, 1000)).0, (1000, 1000));
        // One from when a chgrp pinned the group alone: the owner settles at root.
        let file_tag = blob
            .windows(4)
            .position(|w| w == SNAPSHOT_FILE_OWNERS_TAG)
            .unwrap();
        let mut old = blob[..file_tag].to_vec();
        let records = tag + 8;
        for rec in old[records..].chunks_mut(17) {
            if u64::from_le_bytes(rec[..8].try_into().unwrap()) == grp {
                rec[8] = 2;
            }
        }
        let mut single = writable(&share);
        core(&single).restore_blob(&old);
        assert_eq!(getattr_as(&mut single, grp, (1000, 1000)).0, (0, 5));

        // Removing the file removes what was recorded for it; the name binds afresh.
        assert_eq!(errno(&request(&mut fsys, FUSE_UNLINK, ROOT, b"data\0")), 0);
        assert!(!core(&fsys).nodes.contains_key(&data_now));
        assert!(
            !core(&fsys)
                .owners
                .contains_key(&(data_md.dev(), data_md.ino()))
        );
        fs::write(share.join("data"), b"y").unwrap();
        let again = lookup_in(&mut fsys, ROOT, b"data").unwrap();
        assert_ne!(again, data);
        core(&fsys).adopt_window_ms = 0;
        assert_eq!(getattr_as(&mut fsys, again, (1000, 1000)).0, (1000, 1000));
        // Replacing a file on the Mac drops it too.
        fs::write(share.join("grp.new"), b"z").unwrap();
        fs::rename(share.join("grp.new"), share.join("grp")).unwrap();
        let fresh = lookup_in(&mut fsys, ROOT, b"grp").unwrap();
        assert_ne!(fresh, grp);
        assert!(!core(&fsys).nodes.contains_key(&grp));
        assert_eq!(getattr_as(&mut fsys, fresh, (1000, 1000)).0, (1000, 1000));
        let _ = fs::remove_dir_all(base);
    }

    // ---- one owner per host file, one node per host entry ----

    /// Whether `dir`'s volume ignores case (the default for a Mac's APFS).
    fn ignores_case(dir: &Path) -> bool {
        fs::write(dir.join("case-probe"), b"").unwrap();
        let alias = fs::symlink_metadata(dir.join("CASE-PROBE")).is_ok();
        fs::remove_file(dir.join("case-probe")).unwrap();
        alias
    }

    fn attr_ino(reply: &[u8], attr: usize) -> u64 {
        u64::from_le_bytes(reply[attr..attr + 8].try_into().unwrap())
    }

    fn lookup_as(fsys: &mut VirtioFs, parent: u64, name: &[u8], caller: (u32, u32)) -> Vec<u8> {
        request_as(fsys, FUSE_LOOKUP, parent, &with_name(&[], name), caller)
    }

    #[test]
    fn hard_links_and_other_spellings_share_one_owner_and_inode_number() {
        let (base, share, _) = scratch("alias-owner");
        fs::create_dir(share.join("app")).unwrap();
        fs::write(share.join("app/secret.key"), b"s").unwrap();
        let caseless = ignores_case(&share);
        let mut fsys = writable(&share);
        let app = lookup_in(&mut fsys, ROOT, b"app").unwrap();
        let key = lookup_in(&mut fsys, app, b"secret.key").unwrap();
        // Root: `chown 70:70 secret.key && chmod 600 secret.key && ln secret.key hl`.
        chown_as(&mut fsys, key, (Some(70), Some(70)), (0, 0));
        let reply = request_as(&mut fsys, FUSE_SETATTR, key, &setattr_mode(0o600), (0, 0));
        assert_eq!(errno(&reply), 0);
        let hl = link_in(&mut fsys, key, app, b"hl").unwrap();
        assert_ne!(hl, key, "a hard link is its own entry");
        fs::hard_link(share.join("app/secret.key"), share.join("app/mac-link")).unwrap();
        let host_ino = fs::metadata(share.join("app/secret.key")).unwrap().ino();

        // Every name shows the pinned owner and the same inode number to a
        // non-root user, so it is neither owner nor group member of any.
        let mut names = vec![&b"secret.key"[..], b"hl", b"mac-link"];
        if caseless {
            names.extend([&b"SECRET.KEY"[..], b"Secret.Key", b"HL"]);
        }
        for name in names {
            let reply = lookup_as(&mut fsys, app, name, (1000, 1000));
            assert_eq!(errno(&reply), 0, "{name:?}");
            assert_eq!(attr_owner(&reply, ENTRY_ATTR), (70, 70), "{name:?}");
            assert_eq!(attr_ino(&reply, ENTRY_ATTR), host_ino, "{name:?}");
            assert_eq!(
                attr_mode(&reply[ENTRY_ATTR - ATTR_OUT_ATTR..]) & 0o777,
                0o600
            );
        }
        if caseless {
            // Other spellings are the entry's own node, not a fresh one.
            for name in [&b"SECRET.KEY"[..], b"Secret.Key", b"sEcReT.kEy"] {
                assert_eq!(lookup_in(&mut fsys, app, name), Ok(key), "{name:?}");
            }
            assert_eq!(lookup_in(&mut fsys, app, b"HL"), Ok(hl));
            // A directory spelled differently is the same node, and so are its children.
            assert_eq!(lookup_in(&mut fsys, ROOT, b"APP"), Ok(app));
        }
        // A chgrp through one link pins the file for all of them.
        chown_as(&mut fsys, hl, (None, Some(5)), (0, 0));
        assert_eq!(getattr_as(&mut fsys, key, (1000, 1000)).0, (70, 5));
        // Removing one link keeps the pin for the others; the last one drops it.
        for name in [&b"hl"[..], b"mac-link"] {
            assert_eq!(
                errno(&request(&mut fsys, FUSE_UNLINK, app, &with_name(&[], name))),
                0
            );
            assert_eq!(getattr_as(&mut fsys, key, (1000, 1000)).0, (70, 5));
        }
        let md = fs::metadata(share.join("app/secret.key")).unwrap();
        let unlink_name: &[u8] = if caseless {
            b"SECRET.KEY"
        } else {
            b"secret.key"
        };
        assert_eq!(
            errno(&request(
                &mut fsys,
                FUSE_UNLINK,
                app,
                &with_name(&[], unlink_name)
            )),
            0
        );
        assert!(
            !core(&fsys).nodes.contains_key(&key),
            "unlinked through a spelling"
        );
        assert!(!core(&fsys).owners.contains_key(&(md.dev(), md.ino())));
        assert!(core(&fsys).kin_more.is_empty());
        assert!(!core(&fsys).kin.contains_key(&(app, (md.dev(), md.ino()))));
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn spelling_storms_and_unicode_forms_bind_one_node() {
        let (base, share, _) = scratch("storm");
        if !ignores_case(&share) {
            return; // nothing aliases on a case-sensitive volume
        }
        let name = "a".repeat(40);
        fs::write(share.join(&name), b"x").unwrap();
        // Stored as NFC "café"; the guest asks with NFD "cafe\u{301}".
        fs::write(share.join("caf\u{e9}"), b"x").unwrap();
        let mut fsys = writable(&share);
        let id = lookup_in(&mut fsys, ROOT, name.as_bytes()).unwrap();
        let before = core(&fsys).nodes.len();
        let peak = core(&fsys).metrics.nodes_peak.load(Ordering::Relaxed);
        let mut seed = 0x9e37_79b9_7f4a_7c15u64;
        for _ in 0..2000 {
            let spelling: Vec<u8> = (0..40)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    if seed & 1 == 0 { b'a' } else { b'A' }
                })
                .collect();
            assert_eq!(lookup_in(&mut fsys, ROOT, &spelling), Ok(id));
        }
        assert_eq!(core(&fsys).nodes.len(), before);
        assert_eq!(core(&fsys).metrics.nodes_peak.load(Ordering::Relaxed), peak);
        let nfc = lookup_in(&mut fsys, ROOT, "caf\u{e9}".as_bytes()).unwrap();
        assert_eq!(
            lookup_in(&mut fsys, ROOT, "cafe\u{301}".as_bytes()),
            Ok(nfc)
        );
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn case_only_renames_move_the_node_and_hard_link_renames_change_nothing() {
        let (base, share, _) = scratch("case-rename");
        let caseless = ignores_case(&share);
        let mut fsys = writable(&share);
        let dir = mkdir_in(&mut fsys, ROOT, b"Dir", 0o755).unwrap();
        let inner = entry_id(&create_in(&mut fsys, dir, b"f", O_WRONLY_CREAT, 0o644)).unwrap();
        chown_as(&mut fsys, dir, (Some(70), Some(70)), (0, 0));
        if caseless {
            // `rename("Dir", "dir")`, then `rename("dir", "other")` (mv -T).
            assert_eq!(rename_in(&mut fsys, (ROOT, b"Dir"), (ROOT, b"dir")), 0);
            assert_eq!(listing(&share), ["dir"]);
            assert_eq!(core(&fsys).node_rel_path(dir).as_deref(), Some(&b"dir"[..]));
            assert_eq!(lookup_in(&mut fsys, ROOT, b"dir"), Ok(dir));
            assert_eq!(getattr_as(&mut fsys, dir, (1000, 1000)).0, (70, 70));
            assert_eq!(rename_in(&mut fsys, (ROOT, b"dir"), (ROOT, b"other")), 0);
            // Not stranded at the old spelling: the subtree still resolves.
            assert_eq!(errno(&request(&mut fsys, FUSE_GETATTR, inner, &[0; 16])), 0);
            assert_eq!(
                core(&fsys).node_rel_path(inner).as_deref(),
                Some(&b"other/f"[..])
            );
            // A rename through another spelling of the source moves its node.
            assert_eq!(rename_in(&mut fsys, (ROOT, b"OTHER"), (ROOT, b"third")), 0);
            assert_eq!(
                core(&fsys).node_rel_path(inner).as_deref(),
                Some(&b"third/f"[..])
            );
        }
        // rename(2) between two links of one file leaves both, and both nodes.
        fs::write(share.join("a"), b"x").unwrap();
        fs::hard_link(share.join("a"), share.join("b")).unwrap();
        let a = lookup_in(&mut fsys, ROOT, b"a").unwrap();
        let b = lookup_in(&mut fsys, ROOT, b"b").unwrap();
        assert_eq!(rename_in(&mut fsys, (ROOT, b"a"), (ROOT, b"b")), 0);
        assert!(share.join("a").exists() && share.join("b").exists());
        assert_ne!(a, b);
        assert_eq!(lookup_in(&mut fsys, ROOT, b"a"), Ok(a));
        assert_eq!(lookup_in(&mut fsys, ROOT, b"b"), Ok(b));
        let fh = opendir(&mut fsys, ROOT);
        let listed = read_dir(&mut fsys, FUSE_READDIRPLUS, ROOT, fh, 0, 4096);
        for (name, id) in [(&b"a"[..], a), (b"b", b)] {
            assert!(listed.iter().any(|e| e.3 == name && e.0 == id), "{name:?}");
        }

        // Renames on the Mac keep the node: within a directory its new name
        // finds it (by host identity), and so does a case-only rename.
        let src = mkdir_in(&mut fsys, ROOT, b"Src", 0o755).unwrap();
        let below = entry_id(&create_in(&mut fsys, src, b"g", O_WRONLY_CREAT, 0o644)).unwrap();
        fs::rename(share.join("Src"), share.join("moved")).unwrap();
        assert_eq!(lookup_in(&mut fsys, ROOT, b"moved"), Ok(src));
        assert_eq!(
            core(&fsys).node_rel_path(below).as_deref(),
            Some(&b"moved/g"[..])
        );
        if caseless {
            fs::rename(share.join("moved"), share.join("MOVED")).unwrap();
            let fh = opendir(&mut fsys, ROOT);
            let listed = read_dir(&mut fsys, FUSE_READDIRPLUS, ROOT, fh, 0, 4096);
            assert!(listed.iter().any(|e| e.3 == b"MOVED" && e.0 == src));
            assert_eq!(
                core(&fsys).node_rel_path(below).as_deref(),
                Some(&b"MOVED/g"[..])
            );
            assert_eq!(lookup_in(&mut fsys, ROOT, b"moved"), Ok(src));
        }
        assert_eq!(errno(&request(&mut fsys, FUSE_GETATTR, below, &[0; 16])), 0);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn owner_pins_are_bounded() {
        let (base, share, _) = scratch("pin-cap");
        fs::write(share.join("a"), b"x").unwrap();
        fs::write(share.join("b"), b"x").unwrap();
        let mut fsys = writable(&share);
        let a = lookup_in(&mut fsys, ROOT, b"a").unwrap();
        let b = lookup_in(&mut fsys, ROOT, b"b").unwrap();
        core(&fsys).limits.pins = 1;
        chown_as(&mut fsys, a, (Some(1), Some(1)), (0, 0));
        let reply = request_as(
            &mut fsys,
            FUSE_SETATTR,
            b,
            &setattr_owner(Some(2), None),
            (0, 0),
        );
        assert_eq!(errno(&reply), LINUX_ENOSPC);
        // Changing a file already pinned needs no new slot.
        chown_as(&mut fsys, a, (Some(3), None), (0, 0));
        assert_eq!(getattr_as(&mut fsys, a, (1000, 1000)).0, (3, 1));
        let _ = fs::remove_dir_all(base);
    }

    // ---- node lifetime ----

    fn forget(fsys: &mut VirtioFs, id: u64, count: u64) {
        assert!(
            fsys.handle_fuse(&request_bytes(FUSE_FORGET, id, &count.to_le_bytes()))
                .is_none()
        );
    }

    #[test]
    fn forget_removes_unreferenced_nodes_and_keeps_parents_of_live_children() {
        let (base, share, _) = scratch("forget");
        fs::create_dir_all(share.join("d/e")).unwrap();
        fs::write(share.join("d/e/f"), b"x").unwrap();
        let metrics = Arc::new(FsMetrics::default());
        let mut fsys = VirtioFs::new("workspace", share.clone(), false, metrics.clone()).unwrap();
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 1);
        let d = lookup_in(&mut fsys, ROOT, b"d").unwrap();
        let e = lookup_in(&mut fsys, d, b"e").unwrap();
        let f = lookup_in(&mut fsys, e, b"f").unwrap();
        assert_eq!(lookup_in(&mut fsys, e, b"f"), Ok(f));
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 4);
        // Forgetting a parent first keeps it while a child is addressed through it.
        forget(&mut fsys, d, 1);
        forget(&mut fsys, e, 1);
        assert!(core(&fsys).nodes.contains_key(&d) && core(&fsys).nodes.contains_key(&e));
        // One of two references to f: still there.
        forget(&mut fsys, f, 1);
        assert!(core(&fsys).nodes.contains_key(&f));
        // The last one goes, and takes the unreferenced ancestors with it.
        let mut batch = Vec::new();
        batch.extend_from_slice(&1u32.to_le_bytes());
        batch.extend_from_slice(&0u32.to_le_bytes());
        batch.extend_from_slice(&f.to_le_bytes());
        batch.extend_from_slice(&1u64.to_le_bytes());
        assert!(
            fsys.handle_fuse(&request_bytes(FUSE_BATCH_FORGET, 0, &batch))
                .is_none()
        );
        for id in [f, e, d] {
            assert!(!core(&fsys).nodes.contains_key(&id));
        }
        assert!(core(&fsys).children.is_empty());
        assert!(core(&fsys).kin.is_empty() && core(&fsys).kin_more.is_empty());
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 1);
        // A later lookup binds a new node; FORGET of an unknown or the root is ignored.
        let again = lookup_in(&mut fsys, ROOT, b"d").unwrap();
        assert_ne!(again, d);
        forget(&mut fsys, d, 5);
        forget(&mut fsys, ROOT, 5);
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 2);
        // READDIRPLUS entries count as lookups; plain READDIR binds nothing.
        let fh = opendir(&mut fsys, again);
        assert_eq!(
            read_dir(&mut fsys, FUSE_READDIR, again, fh, 0, 4096).len(),
            1
        );
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 2);
        let listed = read_dir(&mut fsys, FUSE_READDIRPLUS, again, fh, 0, 4096);
        assert_eq!(listed.len(), 1);
        let e2 = listed[0].0;
        assert_eq!(core(&fsys).nodes[&e2].lookups, 1);
        forget(&mut fsys, e2, 1);
        assert!(!core(&fsys).nodes.contains_key(&e2));
        drop(fsys);
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 0);
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 0);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn node_and_read_only_cache_bounds_hold() {
        let (base, share, _) = scratch("bounds");
        for name in ["a", "b", "c"] {
            fs::write(share.join(name), b"x").unwrap();
        }
        let mut fsys = writable(&share);
        core(&fsys).limits.nodes = 2; // the root and one more
        let a = lookup_in(&mut fsys, ROOT, b"a").unwrap();
        assert_eq!(lookup_in(&mut fsys, ROOT, b"a"), Ok(a));
        assert_eq!(lookup_in(&mut fsys, ROOT, b"b"), Err(LINUX_ENFILE));
        assert_eq!(mkdir_in(&mut fsys, ROOT, b"m", 0o755), Err(LINUX_ENFILE));
        assert!(!share.join("m").exists(), "refused before the host entry");
        let reply = create_in(&mut fsys, ROOT, b"n", O_WRONLY_CREAT, 0o644);
        assert_eq!(errno(&reply), LINUX_ENFILE);
        // A listing past the cap lists entries without binding them (node ID 0).
        let fh = opendir(&mut fsys, ROOT);
        let listed = read_dir(&mut fsys, FUSE_READDIRPLUS, ROOT, fh, 0, 4096);
        let ids: Vec<_> = listed.iter().map(|e| (e.3.as_slice(), e.0)).collect();
        assert!(
            ids.contains(&(&b"a"[..], a)) && ids.contains(&(&b"b"[..], 0)),
            "{ids:?}"
        );
        // Two lookups and the listing: the last FORGET frees the slot.
        forget(&mut fsys, a, 2);
        assert_eq!(lookup_in(&mut fsys, ROOT, b"b"), Err(LINUX_ENFILE));
        forget(&mut fsys, a, 1);
        assert!(lookup_in(&mut fsys, ROOT, b"b").is_ok());

        // Read-only caches stay bounded however many names the guest tries.
        let mut ro = VirtioFs::new(
            "oci-tools",
            share.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        for i in 0..MAX_RO_CACHE + 100 {
            assert_eq!(
                lookup_in(&mut ro, ROOT, format!("missing-{i}").as_bytes()),
                Err(LINUX_ENOENT)
            );
        }
        assert!(core(&ro).ro_lookup_cache.len() <= MAX_RO_CACHE);
        let c = lookup_in(&mut ro, ROOT, b"c").unwrap();
        assert!(core(&ro).ro_attr_cache.contains_key(&c));
        // A forgotten read-only node leaves no cache entry that would name it.
        forget(&mut ro, c, 1);
        assert!(!core(&ro).ro_attr_cache.contains_key(&c));
        let again = lookup_in(&mut ro, ROOT, b"c").unwrap();
        assert_ne!(again, c);
        let _ = fs::remove_dir_all(base);
    }

    // ---- host changes on read-only shares ----

    /// A FUSE_INIT body from a 7.31 guest offering `flags`.
    fn init_body(flags: u32) -> [u8; 64] {
        let mut init = [0; 64];
        init[..4].copy_from_slice(&7u32.to_le_bytes());
        init[4..8].copy_from_slice(&31u32.to_le_bytes());
        init[12..16].copy_from_slice(&flags.to_le_bytes());
        init
    }

    /// Entry and attribute validity of an entry reply, in milliseconds.
    fn entry_valid_ms(reply: &[u8]) -> (u64, u64) {
        let field = |secs: usize, nsec: usize| {
            u64::from_le_bytes(reply[secs..secs + 8].try_into().unwrap()) * 1000
                + u64::from(u32::from_le_bytes(
                    reply[nsec..nsec + 4].try_into().unwrap(),
                )) / 1_000_000
        };
        (field(32, 48), field(40, 52))
    }

    /// Size in an entry reply's attributes.
    fn entry_size(reply: &[u8]) -> u64 {
        u64::from_le_bytes(reply[64..72].try_into().unwrap())
    }

    /// What a read without an open handle (FUSE_NO_OPEN_SUPPORT) returns.
    fn read_node(fsys: &mut VirtioFs, id: u64) -> Vec<u8> {
        let mut body = [0u8; 24];
        body[16..20].copy_from_slice(&4096u32.to_le_bytes());
        let reply = request(fsys, FUSE_READ, id, &body);
        assert_eq!(errno(&reply), 0);
        reply[16..].to_vec()
    }

    /// Let `ms` milliseconds pass for the share's clock.
    fn age(fsys: &VirtioFs, ms: u64) {
        let mut core = core(fsys);
        core.epoch = core.epoch.checked_sub(Duration::from_millis(ms)).unwrap();
    }

    #[test]
    fn read_only_shares_show_a_host_replacement_once_their_validity_runs_out() {
        let (base, share, _) = scratch("ro-replace");
        let policy = share.join("policy.json");
        // How the host writes a policy file: a temporary file renamed over the old one.
        let replace = |content: &[u8]| {
            let tmp = share.join(".policy.json.tmp");
            fs::write(&tmp, content).unwrap();
            fs::rename(&tmp, &policy).unwrap();
        };
        replace(b"v1-initial\n");
        let metrics = Arc::new(FsMetrics::default());
        let mut ro = VirtioFs::new("mp-config", share.clone(), true, metrics.clone()).unwrap();

        // No opens, but pages follow attribute changes (no FUSE_EXPLICIT_INVAL_DATA).
        let reply = request(&mut ro, FUSE_INIT, ROOT, &init_body(FUSE_AUTO_INVAL_DATA));
        assert_eq!(errno(&reply), 0);
        let flags = u32::from_le_bytes(reply[28..32].try_into().unwrap());
        let explicit_inval_data = 1 << 25;
        assert_eq!(
            flags & (FUSE_NO_OPEN_SUPPORT | FUSE_AUTO_INVAL_DATA | explicit_inval_data),
            FUSE_NO_OPEN_SUPPORT | FUSE_AUTO_INVAL_DATA
        );

        let reply = request(&mut ro, FUSE_LOOKUP, ROOT, &with_name(&[], b"policy.json"));
        let first = entry_id(&reply).unwrap();
        assert_eq!(entry_valid_ms(&reply), (RO_VALIDITY_MS, RO_VALIDITY_MS));
        assert_eq!(read_node(&mut ro, first), b"v1-initial\n");
        assert_eq!(lookup_in(&mut ro, ROOT, b"later.json"), Err(LINUX_ENOENT));

        replace(b"v2-renamed-over-longer\n");
        fs::write(share.join("later.json"), b"{}").unwrap();
        // Until the validity runs out the cached answers stand, and say how
        // long they still may: never longer than the host answer they repeat.
        age(&ro, 400);
        let reply = request(&mut ro, FUSE_LOOKUP, ROOT, &with_name(&[], b"policy.json"));
        assert_eq!(entry_id(&reply), Ok(first));
        let (entry_left, attr_left) = entry_valid_ms(&reply);
        assert!(
            entry_left > 0 && entry_left <= RO_VALIDITY_MS - 400,
            "{entry_left}"
        );
        assert_eq!(attr_left, entry_left);
        let attr = request(&mut ro, FUSE_GETATTR, first, &[0; 16]);
        let attr_secs = u64::from_le_bytes(attr[16..24].try_into().unwrap());
        assert_eq!(attr_secs, 0, "under a second is left");
        assert_eq!(lookup_in(&mut ro, ROOT, b"later.json"), Err(LINUX_ENOENT));

        // Then the host's answer: the replacement is a new node with its own size.
        age(&ro, RO_VALIDITY_MS);
        let reply = request(&mut ro, FUSE_LOOKUP, ROOT, &with_name(&[], b"policy.json"));
        let second = entry_id(&reply).unwrap();
        assert_ne!(second, first);
        assert_eq!(entry_size(&reply), 23);
        assert_eq!(entry_valid_ms(&reply), (RO_VALIDITY_MS, RO_VALIDITY_MS));
        assert_eq!(read_node(&mut ro, second), b"v2-renamed-over-longer\n");
        assert!(lookup_in(&mut ro, ROOT, b"later.json").is_ok());
        // The old node still reads, and stats as, the file it was bound to (a
        // guest file open on it): never the new size over the old bytes.
        assert_eq!(read_node(&mut ro, first), b"v1-initial\n");
        let old = request(&mut ro, FUSE_GETATTR, first, &[0; 16]);
        assert_eq!(errno(&old), 0);
        assert_eq!(u64::from_le_bytes(old[40..48].try_into().unwrap()), 11);

        // A listing after another replacement binds the newest file and leaves
        // the node the guest had alone.
        replace(b"v3-a-third-and-longer-version\n");
        age(&ro, RO_VALIDITY_MS);
        let fh = opendir(&mut ro, ROOT);
        let listed = read_dir(&mut ro, FUSE_READDIRPLUS, ROOT, fh, 0, 4096);
        let third = listed
            .iter()
            .find(|e| e.3 == b"policy.json")
            .expect("listed")
            .0;
        assert!(third != 0 && third != second && third != first);
        assert_eq!(
            read_node(&mut ro, third),
            b"v3-a-third-and-longer-version\n"
        );
        assert_eq!(read_node(&mut ro, second), b"v2-renamed-over-longer\n");
        let reply = request(&mut ro, FUSE_LOOKUP, ROOT, &with_name(&[], b"policy.json"));
        assert_eq!((entry_id(&reply), entry_size(&reply)), (Ok(third), 30));

        // The guest forgetting a replaced node drops the descriptor it kept.
        assert!(core(&ro).ro_file_cache.contains_key(&first));
        forget(&mut ro, first, 2);
        assert!(!core(&ro).ro_file_cache.contains_key(&first));

        // A remount is a new session: nothing of the old one is kept or served.
        let reply = request(&mut ro, FUSE_INIT, ROOT, &init_body(FUSE_AUTO_INVAL_DATA));
        assert_eq!(errno(&reply), 0);
        {
            let core = core(&ro);
            assert_eq!(core.nodes.len(), 1);
            assert!(core.children.is_empty() && core.kin.is_empty());
            assert!(core.ro_lookup_cache.is_empty() && core.ro_attr_cache.is_empty());
            assert!(core.ro_file_cache.is_empty() && core.open_dirs.is_empty());
        }
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 1);
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 0);
        let fresh = lookup_in(&mut ro, ROOT, b"policy.json").unwrap();
        assert!(fresh > third);
        assert_eq!(
            read_node(&mut ro, fresh),
            b"v3-a-third-and-longer-version\n"
        );
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn a_new_fuse_session_drops_the_nodes_and_handles_of_the_last_one() {
        let (base, share, _) = scratch("session");
        fs::write(share.join("f"), b"x").unwrap();
        let metrics = Arc::new(FsMetrics::default());
        let mut fsys = VirtioFs::new("workspace", share.clone(), false, metrics.clone()).unwrap();
        let f = lookup_in(&mut fsys, ROOT, b"f").unwrap();
        let opened = open(&mut fsys, f, 0);
        assert_eq!(errno(&opened), 0);
        let fh = u64::from_le_bytes(opened[16..24].try_into().unwrap());
        opendir(&mut fsys, ROOT);
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 2);

        let reply = request(&mut fsys, FUSE_INIT, ROOT, &init_body(0));
        assert_eq!(errno(&reply), 0);
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 1);
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 0);
        let mut read = [0u8; 24];
        read[..8].copy_from_slice(&fh.to_le_bytes());
        read[16..20].copy_from_slice(&8u32.to_le_bytes());
        assert_eq!(errno(&request(&mut fsys, FUSE_READ, f, &read)), LINUX_EBADF);
        assert_eq!(
            errno(&request(&mut fsys, FUSE_GETATTR, f, &[0; 16])),
            LINUX_ESTALE
        );
        let again = lookup_in(&mut fsys, ROOT, b"f").unwrap();
        assert_ne!(again, f);
        drop(fsys);
        assert_eq!(metrics.nodes.load(Ordering::Relaxed), 0);
        let _ = fs::remove_dir_all(base);
    }

    // ---- listings and handles ----

    fn opendir(fsys: &mut VirtioFs, id: u64) -> u64 {
        let reply = request(fsys, FUSE_OPENDIR, id, &[0; 8]);
        assert_eq!(errno(&reply), 0);
        u64::from_le_bytes(reply[16..24].try_into().unwrap())
    }

    /// (node ID or 0, inode number, offset, name) of each entry in a reply.
    fn read_dir(
        fsys: &mut VirtioFs,
        opcode: u32,
        dir: u64,
        fh: u64,
        offset: u64,
        size: u32,
    ) -> Vec<(u64, u64, u64, Vec<u8>)> {
        let mut body = [0u8; 24];
        body[..8].copy_from_slice(&fh.to_le_bytes());
        body[8..16].copy_from_slice(&offset.to_le_bytes());
        body[16..20].copy_from_slice(&size.to_le_bytes());
        let reply = request(fsys, opcode, dir, &body);
        assert_eq!(errno(&reply), 0);
        let mut out = Vec::new();
        let mut pos = 16;
        while pos < reply.len() {
            let nodeid = if opcode == FUSE_READDIRPLUS {
                let id = u64::from_le_bytes(reply[pos..pos + 8].try_into().unwrap());
                pos += 128;
                id
            } else {
                0
            };
            let ino = u64::from_le_bytes(reply[pos..pos + 8].try_into().unwrap());
            let off = u64::from_le_bytes(reply[pos + 8..pos + 16].try_into().unwrap());
            let len = u32::from_le_bytes(reply[pos + 16..pos + 20].try_into().unwrap()) as usize;
            out.push((nodeid, ino, off, reply[pos + 24..pos + 24 + len].to_vec()));
            pos += (24 + len + 7) & !7;
        }
        out
    }

    #[test]
    fn large_listings_stream_in_chunks_and_resume_at_any_offset() {
        let (base, share, _) = scratch("stream");
        let total = 3000;
        for i in 0..total {
            fs::write(share.join(format!("entry-{i:05}")), b"").unwrap();
        }
        let mut fsys = writable(&share);
        for plus in [FUSE_READDIR, FUSE_READDIRPLUS] {
            let fh = opendir(&mut fsys, ROOT);
            let mut seen = Vec::new();
            let mut offset = 0;
            loop {
                let batch = read_dir(&mut fsys, plus, ROOT, fh, offset, 4096);
                if batch.is_empty() {
                    break;
                }
                // What a handle holds stays far below the directory's size.
                let held = core(&fsys).open_dirs[&fh].listing.window.len();
                assert!(held < 1000, "handle holds {held} entries");
                // The guest consumed only part of the reply: resume inside it.
                let take = batch.len().div_ceil(2);
                offset = batch[take - 1].2;
                seen.extend(batch.into_iter().take(take).map(|e| e.3));
            }
            seen.sort();
            seen.dedup();
            assert_eq!(seen.len(), total, "opcode {plus}");
            // An offset before what the handle still holds starts a new pass.
            let again = read_dir(&mut fsys, plus, ROOT, fh, 5, 4096);
            assert_eq!(again[0].2, 6);
            request(&mut fsys, FUSE_RELEASEDIR, ROOT, &fh.to_le_bytes());
        }
        // Each dirent carries the host inode number.
        let fh = opendir(&mut fsys, ROOT);
        let first = &read_dir(&mut fsys, FUSE_READDIRPLUS, ROOT, fh, 0, 4096)[0];
        let md = fs::symlink_metadata(share.join(OsStr::from_bytes(&first.3))).unwrap();
        assert_eq!(first.1, md.ino());
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn listed_directories_are_identified_as_a_lookup_would() {
        let (base, share, _) = scratch("mountpoint");
        fs::create_dir(share.join("m")).unwrap();
        let mut fsys = writable(&share);
        let m = lookup_in(&mut fsys, ROOT, b"m").unwrap();
        let real = fs::symlink_metadata(share.join("m")).unwrap();
        let covered = FuseStat {
            ino: real.ino() + 1_000_000,
            ..fstatat_cstr(core(&fsys).root_fd.as_raw_fd(), c"m").unwrap()
        };
        let root_fd = core(&fsys).root_fd.as_raw_fd();
        // A mount point lists the covered directory's identity: look it up.
        let entry = BulkDirEntry {
            name: c"m".to_owned(),
            stat: covered,
            mount_point: true,
        };
        assert_eq!(
            core(&fsys).listed_stat(ROOT, root_fd, &entry).ino,
            real.ino()
        );
        // So does a directory bound to another identity than listed (a firmlink).
        let entry = BulkDirEntry {
            mount_point: false,
            ..entry
        };
        assert_eq!(
            core(&fsys).listed_stat(ROOT, root_fd, &entry).ino,
            real.ino()
        );
        // Listing the parent leaves the directory's node (and subtree) alone.
        let fh = opendir(&mut fsys, ROOT);
        let listed = read_dir(&mut fsys, FUSE_READDIRPLUS, ROOT, fh, 0, 4096);
        assert_eq!(listed[0].0, m);
        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn open_handles_are_bounded_and_counted() {
        let (base, share, _) = scratch("handles");
        fs::write(share.join("f"), b"x").unwrap();
        fs::create_dir(share.join("d")).unwrap();
        let metrics = Arc::new(FsMetrics::default());
        let mut fsys = VirtioFs::new("workspace", share.clone(), false, metrics.clone()).unwrap();
        let f = lookup_in(&mut fsys, ROOT, b"f").unwrap();
        let d = lookup_in(&mut fsys, ROOT, b"d").unwrap();
        {
            let mut core = core(&fsys);
            core.limits.handles = 3;
            core.limits.dirs = 1;
        }
        let first = open(&mut fsys, f, 0);
        assert_eq!(errno(&first), 0);
        let dir_fh = opendir(&mut fsys, d);
        assert_eq!(
            errno(&request(&mut fsys, FUSE_OPENDIR, ROOT, &[0; 8])),
            LINUX_ENFILE
        );
        assert_eq!(errno(&open(&mut fsys, f, 0)), 0);
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 3);
        assert_eq!(errno(&open(&mut fsys, f, 0)), LINUX_ENFILE);
        let reply = create_in(&mut fsys, ROOT, b"g", O_WRONLY_CREAT, 0o644);
        assert_eq!(errno(&reply), LINUX_ENFILE);
        assert!(!share.join("g").exists());
        request(&mut fsys, FUSE_RELEASE, f, &first[16..24]);
        request(&mut fsys, FUSE_RELEASEDIR, d, &dir_fh.to_le_bytes());
        assert_eq!(metrics.open_handles.load(Ordering::Relaxed), 1);
        assert_eq!(errno(&open(&mut fsys, f, 0)), 0);
        // The default leaves the rest of the process's descriptors to others.
        let limits = Limits::new();
        assert!(limits.handles <= MAX_OPEN_HANDLES && limits.dirs <= limits.handles);
        let _ = fs::remove_dir_all(base);
    }

    // ---- nothing blocks the worker ----

    /// Handle one request on another thread, failing if it does not finish.
    fn request_within(fsys: &VirtioFs, opcode: u32, nodeid: u64, body: &[u8]) -> Vec<u8> {
        let shared = fsys.shared.clone();
        let req = request_bytes(opcode, nodeid, body);
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            let mut core = shared.core.lock().unwrap();
            core.handle_fuse_into(&req);
            let _ = tx.send(core.resp_buf.clone());
        });
        rx.recv_timeout(Duration::from_secs(5))
            .unwrap_or_else(|_| panic!("opcode {opcode} blocked the worker"))
    }

    fn mkfifo(path: &Path) {
        let c = path_to_cstr(path).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o644) }, 0);
    }

    #[test]
    fn fifos_and_other_special_files_never_block_or_get_host_handles() {
        let (base, share, _) = scratch("fifo");
        mkfifo(&share.join("p"));
        let caseless = ignores_case(&share);
        let mut fsys = writable(&share);
        let p = lookup_in(&mut fsys, ROOT, b"p").unwrap();
        // An adversarial guest kernel opening the FIFO itself.
        for flags in [0u32, 1, 2, 0o1001] {
            let mut body = [0u8; 8];
            body[..4].copy_from_slice(&flags.to_le_bytes());
            assert_eq!(
                errno(&request_within(&fsys, FUSE_OPEN, p, &body)),
                LINUX_ENXIO
            );
        }
        // FUSE_CREATE without O_EXCL on a name that is a FIFO.
        for flags in [O_WRONLY_CREAT, 0o102, 0o100] {
            let reply = request_within(&fsys, FUSE_CREATE, ROOT, &create_body(b"p", flags, 0o644));
            assert_eq!(errno(&reply), LINUX_ENXIO);
        }
        assert!(matches!(
            errno(&request_within(&fsys, FUSE_OPENDIR, p, &[0; 8])),
            LINUX_ENOTDIR | LINUX_ENXIO
        ));
        let mut truncate = [0u8; 88];
        truncate[..4].copy_from_slice(&FATTR_SIZE.to_le_bytes());
        assert_eq!(
            errno(&request_within(&fsys, FUSE_SETATTR, p, &truncate)),
            LINUX_ENXIO
        );
        // A chmod needs no open at all.
        assert_eq!(
            errno(&request_within(
                &fsys,
                FUSE_SETATTR,
                p,
                &setattr_mode(0o600)
            )),
            0
        );
        assert_eq!(
            fs::symlink_metadata(share.join("p")).unwrap().mode() & 0o777,
            0o600
        );
        assert!(core(&fsys).open_files.is_empty());

        // The alias route: `touch r; stat R; mv p r; cat R` within the guest's
        // 20 ms attribute window. R is r's node, which the rename retires.
        if caseless {
            let r = entry_id(&create_in(&mut fsys, ROOT, b"r", O_WRONLY_CREAT, 0o644)).unwrap();
            assert_eq!(lookup_in(&mut fsys, ROOT, b"R"), Ok(r));
            assert_eq!(rename_in(&mut fsys, (ROOT, b"p"), (ROOT, b"r")), 0);
            assert_eq!(
                errno(&request_within(&fsys, FUSE_OPEN, r, &[0; 8])),
                LINUX_ESTALE
            );
            assert_eq!(lookup_in(&mut fsys, ROOT, b"R"), Ok(p));
        }

        // A read-only share's fh-less READ of a FIFO.
        mkfifo(&share.join("q"));
        let mut ro = VirtioFs::new(
            "oci-tools",
            share.clone(),
            true,
            Arc::new(FsMetrics::default()),
        )
        .unwrap();
        let q = lookup_in(&mut ro, ROOT, b"q").unwrap();
        let mut read = [0u8; 24];
        read[16..20].copy_from_slice(&64u32.to_le_bytes());
        assert_eq!(
            errno(&request_within(&ro, FUSE_READ, q, &read)),
            LINUX_ENXIO
        );
        let _ = fs::remove_dir_all(base);
    }

    // ---- containment of cached directory descriptors ----

    #[test]
    fn a_directory_the_host_moves_out_of_the_share_is_not_served() {
        let (base, share, outside) = scratch("moved-out");
        let mut fsys = writable(&share);
        let build = mkdir_in(&mut fsys, ROOT, b"build", 0o755).unwrap();
        let sub = mkdir_in(&mut fsys, build, b"sub", 0o755).unwrap();
        entry_id(&create_in(&mut fsys, build, b"a", O_WRONLY_CREAT, 0o644)).unwrap();
        let fh = opendir(&mut fsys, build);
        assert!(core(&fsys).dir_fds.contains_key(&build));
        // `mv ~/proj/build /tmp/build.old` on the Mac.
        fs::rename(share.join("build"), outside.join("build")).unwrap();
        for cached in core(&fsys).dir_fds.values_mut() {
            cached.checked_ms = 0;
        }
        core(&fsys).epoch -= Duration::from_millis(DIR_FD_RECHECK_MS + 1);
        let results = [
            entry_id(&create_in(&mut fsys, build, b"new", O_WRONLY_CREAT, 0o644)).err(),
            mkdir_in(&mut fsys, build, b"dir", 0o755).err(),
            lookup_in(&mut fsys, build, b"a").err(),
            lookup_in(&mut fsys, sub, b"x").err(),
            Some(errno(&request(&mut fsys, FUSE_UNLINK, build, b"a\0"))),
        ];
        assert!(
            results.iter().all(|r| *r == Some(LINUX_ESTALE)),
            "{results:?}"
        );
        let mut body = [0u8; 24];
        body[..8].copy_from_slice(&fh.to_le_bytes());
        body[16..20].copy_from_slice(&4096u32.to_le_bytes());
        assert_eq!(
            errno(&request(&mut fsys, FUSE_READDIRPLUS, build, &body)),
            LINUX_ESTALE
        );
        assert_eq!(listing(&outside.join("build")), ["a", "sub"]);
        // A directory moved within the share stays usable (its node follows it).
        let kept = mkdir_in(&mut fsys, ROOT, b"kept", 0o755).unwrap();
        assert_eq!(lookup_in(&mut fsys, kept, b"none"), Err(LINUX_ENOENT));
        fs::rename(share.join("kept"), share.join("renamed")).unwrap();
        core(&fsys).epoch -= Duration::from_millis(DIR_FD_RECHECK_MS + 1);
        entry_id(&create_in(&mut fsys, kept, b"in", O_WRONLY_CREAT, 0o644)).unwrap();
        assert_eq!(listing(&share.join("renamed")), ["in"]);
        // The `..` walk used for paths F_GETPATH cannot return agrees.
        #[cfg(target_vendor = "apple")]
        {
            let inside = open_dir_at(
                libc::AT_FDCWD,
                &path_to_cstr(&share.join("renamed")).unwrap(),
                0,
            )
            .unwrap();
            let out = open_dir_at(libc::AT_FDCWD, &path_to_cstr(&outside).unwrap(), 0).unwrap();
            let core = core(&fsys);
            assert!(core.fd_within_share_by_parents(inside.as_raw_fd()));
            assert!(core.fd_within_share_by_parents(core.root_fd.as_raw_fd()));
            assert!(!core.fd_within_share_by_parents(out.as_raw_fd()));
        }
        let _ = fs::remove_dir_all(base);
    }

    // ---- SETATTR without opening ----

    #[test]
    fn setattr_works_on_unreadable_entries_symlinks_and_unlinked_open_files() {
        let (base, share, _) = scratch("setattr");
        fs::write(share.join("f"), b"x").unwrap();
        fs::create_dir(share.join("d")).unwrap();
        std::os::unix::fs::symlink("f", share.join("lnk")).unwrap();
        let mut fsys = writable(&share);
        let f = lookup_in(&mut fsys, ROOT, b"f").unwrap();
        let d = lookup_in(&mut fsys, ROOT, b"d").unwrap();
        let lnk = lookup_in(&mut fsys, ROOT, b"lnk").unwrap();
        // `chmod 000 f; chmod 644 f` (and the same for a directory).
        for (id, name, back) in [(f, "f", 0o644), (d, "d", 0o755)] {
            for mode in [0, back] {
                let reply = request(&mut fsys, FUSE_SETATTR, id, &setattr_mode(mode));
                assert_eq!(errno(&reply), 0, "{name} -> {mode:o}");
                assert_eq!(attr_mode(&reply) & 0o777, mode);
            }
            assert_eq!(fs::metadata(share.join(name)).unwrap().mode() & 0o777, back);
        }
        // `touch -h -d @1600000000 lnk` changes the link, not its target.
        let target_mtime = fs::metadata(share.join("f")).unwrap().mtime();
        let mut times = [0u8; 88];
        times[..4].copy_from_slice(&FATTR_MTIME.to_le_bytes());
        times[40..48].copy_from_slice(&1_600_000_000i64.to_le_bytes());
        assert_eq!(errno(&request(&mut fsys, FUSE_SETATTR, lnk, &times)), 0);
        assert_eq!(
            fs::symlink_metadata(share.join("lnk")).unwrap().mtime(),
            1_600_000_000
        );
        assert_eq!(fs::metadata(share.join("f")).unwrap().mtime(), target_mtime);
        // Out-of-range nanoseconds are refused.
        times[60..64].copy_from_slice(&1_000_000_000u32.to_le_bytes());
        assert_eq!(
            errno(&request(&mut fsys, FUSE_SETATTR, lnk, &times)),
            LINUX_EINVAL
        );

        // fchmod / futimens / fchown on a file unlinked while open.
        let opened = open(&mut fsys, f, 2);
        assert_eq!(errno(&opened), 0);
        let held = core(&fsys).open_files[&u64::from_le_bytes(opened[16..24].try_into().unwrap())]
            .file
            .clone();
        assert_eq!(errno(&request(&mut fsys, FUSE_UNLINK, ROOT, b"f\0")), 0);
        assert!(!core(&fsys).nodes.contains_key(&f));
        let reply = request(&mut fsys, FUSE_SETATTR, f, &setattr_mode(0o600));
        assert_eq!(errno(&reply), 0);
        assert_eq!(held.metadata().unwrap().mode() & 0o777, 0o600);
        times[60..64].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(errno(&request(&mut fsys, FUSE_SETATTR, f, &times)), 0);
        assert_eq!(held.metadata().unwrap().mtime(), 1_600_000_000);
        let reply = request_as(
            &mut fsys,
            FUSE_SETATTR,
            f,
            &setattr_owner(Some(9), Some(9)),
            (0, 0),
        );
        assert_eq!(attr_owner(&reply, ATTR_OUT_ATTR), (9, 9));
        let _ = fs::remove_dir_all(base);
    }

    // ---- guest-declared lengths ----

    #[test]
    fn descriptor_lengths_count_only_guest_memory_that_exists_and_are_capped() {
        let (base, share, _) = scratch("desc-len");
        let mut fsys = writable(&share);
        let mut backing = vec![0u8; 2 * 1024 * 1024];
        let ram = 0x4000_0000u64;
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), ram, backing.len()) };
        let req = request_bytes(FUSE_GETATTR, ROOT, &[0u8; 16]);
        mem.write_slice(ram, req.len())
            .unwrap()
            .copy_from_slice(&req);
        let reply_at = ram + 4096;
        let header = DescBuf {
            addr: ram,
            len: req.len() as u32,
            is_write: false,
        };
        let reply = DescBuf {
            addr: reply_at,
            len: 256,
            is_write: true,
        };
        // Descriptors claiming 4 GiB outside guest RAM are not counted (and
        // never reserved): the request is served from what exists.
        let bogus = DescBuf {
            addr: 0x10_0000_0000,
            len: u32::MAX,
            is_write: false,
        };
        let bufs = [header, bogus, bogus, bogus, reply];
        assert!(fsys.handle_fuse_chain(&bufs, &mem) > 16);
        assert_eq!(errno(mem.read_slice(reply_at, 16).unwrap()), 0);
        // Real memory declared many times over beyond any request: refused.
        let big = DescBuf {
            addr: ram + 8192,
            len: 1024 * 1024,
            is_write: false,
        };
        let bufs = [header, big, big, reply];
        assert_eq!(fsys.handle_fuse_chain(&bufs, &mem), 16);
        assert_eq!(errno(mem.read_slice(reply_at, 16).unwrap()), LINUX_EINVAL);
        let _ = fs::remove_dir_all(base);
    }
}
