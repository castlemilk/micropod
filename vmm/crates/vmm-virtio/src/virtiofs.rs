//! Virtio-FS (Device ID 26) FUSE 7.31+ host directory share device.
//! Mounts macOS host directories directly inside Linux via `mount -t virtiofs <tag> <dst>`.
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

use std::collections::HashMap;
use std::ffi::{CString, OsStr};
use std::fs::{self, File, FileTimes, OpenOptions};
use std::io::ErrorKind;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
const FUSE_EXPLICIT_INVAL_DATA: u32 = 1 << 25;

// FUSE open_flags (Linux include/uapi/linux/fuse.h)
const FOPEN_KEEP_CACHE: u32 = 1 << 1;
const FOPEN_CACHE_DIR: u32 = 1 << 3;
const FOPEN_NOFLUSH: u32 = 1 << 5;
const FUSE_FSYNC_FDATASYNC: u32 = 1;

const FATTR_MODE: u32 = 1 << 0;
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

#[cfg(target_vendor = "apple")]
const METADATA_OPEN_FLAGS: i32 = libc::O_EVTONLY;
#[cfg(not(target_vendor = "apple"))]
const METADATA_OPEN_FLAGS: i32 = 0;

const MAX_CACHED_DIR_FDS: usize = 512;

// Writable shares may be changed by a host editor while a guest file is open.
// 20ms metadata validity keeps host-edit visibility ~3.5x faster than OrbStack (~91ms)
// and ~40x faster than Apple VZ (~1004ms) while preventing mid-scan dentry thrashing.
fn cache_validity(read_only: bool) -> (u64, u32) {
    if read_only {
        (3600, 0)
    } else {
        (0, 20_000_000)
    }
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

    fn from_metadata(md: &fs::Metadata) -> Self {
        Self {
            dev: md.dev(),
            ino: md.ino(),
            mode: md.mode(),
            nlink: md.nlink() as u32,
            size: md.size(),
            blocks: md.blocks(),
            atime: md.atime(),
            atime_nsec: md.atime_nsec(),
            mtime: md.mtime(),
            mtime_nsec: md.mtime_nsec(),
            ctime: md.ctime(),
            ctime_nsec: md.ctime_nsec(),
            rdev: md.rdev(),
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
}

#[derive(Clone)]
struct BulkDirEntry {
    name: Vec<u8>,
    stat: FuseStat,
}

struct OpenDir {
    dir_nodeid: u64,
    dir_path: PathBuf,
    dir_fd: OwnedFd,
    entries: Option<Vec<BulkDirEntry>>,
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

fn fstatat_cstr(dirfd: RawFd, name: &CString) -> Result<FuseStat, i32> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstatat(dirfd, name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } == 0 {
        Ok(FuseStat::from_libc(&st))
    } else {
        Err(last_os_errno_linux())
    }
}

fn lstat_path(path: &Path) -> Result<FuseStat, i32> {
    let cpath = path_to_cstr(path)?;
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::lstat(cpath.as_ptr(), &mut st) } == 0 {
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

    pub(super) fn read_dir_bulk(
        dir_fd: RawFd,
        buf: &mut Vec<u8>,
    ) -> Result<Vec<BulkDirEntry>, i32> {
        // Rewind so any host renames since OPENDIR are observed live.
        let _ = unsafe { libc::lseek(dir_fd, 0, libc::SEEK_SET) };
        if buf.len() < 64 * 1024 {
            buf.resize(64 * 1024, 0);
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
            dirattr: ATTR_DIR_LINKCOUNT,
            fileattr: ATTR_FILE_LINKCOUNT
                | ATTR_FILE_TOTALSIZE
                | ATTR_FILE_ALLOCSIZE
                | ATTR_FILE_DEVTYPE,
            forkattr: 0,
        };

        let mut entries = Vec::with_capacity(32);
        loop {
            let count =
                unsafe { getattrlistbulk(dir_fd, &mut req, buf.as_mut_ptr().cast(), buf.len(), 0) };
            if count < 0 {
                return Err(last_os_errno_linux());
            }
            if count == 0 {
                break;
            }
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

                let mut name_bytes: Option<Vec<u8>> = None;
                if ret.commonattr & ATTR_CMN_NAME != 0 {
                    let field_start = cur;
                    let Some(aref) =
                        (unsafe { read_unaligned_adv::<AttrReference>(&mut cur, rec_end) })
                    else {
                        continue;
                    };
                    if aref.dataoffset >= 0 && aref.length > 0 {
                        let str_ptr = unsafe { field_start.add(aref.dataoffset as usize) };
                        let max_len = (rec_end as usize).saturating_sub(str_ptr as usize);
                        let raw_len = (aref.length as usize).min(max_len);
                        let slice = unsafe { std::slice::from_raw_parts(str_ptr, raw_len) };
                        let trimmed = match slice.iter().position(|&b| b == 0) {
                            Some(z) => &slice[..z],
                            None => slice,
                        };
                        if !trimmed.is_empty() && trimmed != b"." && trimmed != b".." {
                            name_bytes = Some(trimmed.to_vec());
                        }
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
                entries.push(BulkDirEntry {
                    name,
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
        Ok(entries)
    }
}

#[derive(Default)]
pub struct FsMetrics {
    pub requests: AtomicU64,
    pub bytes_read: AtomicU64,
    pub bytes_written: AtomicU64,
}

struct FsCore {
    root: PathBuf,
    read_only: bool,
    next_nodeid: u64,
    next_fh: u64,
    node_to_path: HashMap<u64, PathBuf>,
    path_to_node: HashMap<PathBuf, u64>,
    host_inodes: HashMap<u64, (u64, u64)>,
    // Phase B5 dirfd + parent-link acceleration (eliminates full-path APFS walks!)
    dir_fds: HashMap<u64, OwnedFd>,
    node_parent: HashMap<u64, (u64, CString)>,
    open_files: HashMap<u64, OpenFile>,
    open_dirs: HashMap<u64, OpenDir>,
    // Read-only hot caches (eliminates repeat host lstat/open syscalls on oci-tools!)
    ro_lookup_cache: HashMap<(u64, Vec<u8>), Result<u64, i32>>,
    ro_attr_cache: HashMap<u64, FuseStat>,
    ro_file_cache: HashMap<u64, Arc<File>>,
    // Reusable scratch buffers (zero heap allocs on hot paths)
    read_buf: Vec<u8>,
    bulk_buf: Vec<u8>,
    resp_buf: Vec<u8>,
    metrics: Arc<FsMetrics>,
}

struct FsQueueState {
    queues: [Option<VirtQueue>; 2],
    mem: Option<Arc<GuestMemory>>,
    irq: Option<IrqLine>,
    kicked: bool,
    worker_parked: bool,
}

struct FsShared {
    core: Mutex<FsCore>,
    state: (Mutex<FsQueueState>, Condvar),
    paused: AtomicBool,
    shutdown: AtomicBool,
}

pub struct VirtioFs {
    tag: [u8; 36],
    tag_name: String,
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
        let canon = fs::canonicalize(&root)?;
        let mut tag_bytes = [0u8; 36];
        let src = tag.as_bytes();
        let n = src.len().min(36);
        tag_bytes[..n].copy_from_slice(&src[..n]);

        let mut node_to_path = HashMap::new();
        let mut path_to_node = HashMap::new();
        node_to_path.insert(FUSE_ROOT_ID, canon.clone());
        path_to_node.insert(canon.clone(), FUSE_ROOT_ID);

        let mut dir_fds = HashMap::new();
        if let Ok(croot) = CString::new(canon.as_os_str().as_bytes()) {
            let fd = unsafe {
                libc::open(
                    croot.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                )
            };
            if fd >= 0 {
                dir_fds.insert(FUSE_ROOT_ID, unsafe { OwnedFd::from_raw_fd(fd) });
            }
        }

        let core = FsCore {
            root: canon,
            read_only,
            next_nodeid: 2,
            next_fh: 1,
            node_to_path,
            path_to_node,
            host_inodes: HashMap::new(),
            dir_fds,
            node_parent: HashMap::new(),
            open_files: HashMap::new(),
            open_dirs: HashMap::new(),
            ro_lookup_cache: HashMap::new(),
            ro_attr_cache: HashMap::new(),
            ro_file_cache: HashMap::new(),
            read_buf: vec![0u8; 256 * 1024],
            bulk_buf: Vec::new(),
            resp_buf: Vec::with_capacity(4096),
            metrics,
        };

        Ok(Self {
            tag: tag_bytes,
            tag_name: tag.to_string(),
            shared: Arc::new(FsShared {
                core: Mutex::new(core),
                state: (
                    Mutex::new(FsQueueState {
                        queues: [None, None],
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
    fn intern_path(&mut self, path: PathBuf) -> u64 {
        if let Some(&id) = self.path_to_node.get(&path) {
            return id;
        }
        let id = self.next_nodeid;
        self.next_nodeid += 1;
        self.node_to_path.insert(id, path.clone());
        self.path_to_node.insert(path, id);
        id
    }

    fn retire_path(&mut self, path: &Path) {
        if let Some(id) = self.path_to_node.remove(path) {
            self.node_to_path.remove(&id);
            self.host_inodes.remove(&id);
            self.dir_fds.remove(&id);
            self.node_parent.remove(&id);
        }
    }

    // An editor can atomically replace a pathname. Linux keys its page cache by
    // FUSE node ID, so the replacement must receive a distinct ID while open
    // handles to the old inode continue to address their original contents.
    fn observe_path_stat(&mut self, path: PathBuf, st: &FuseStat) -> u64 {
        if self.read_only {
            return self.intern_path(path);
        }
        let identity = (st.dev, st.ino);
        if self
            .path_to_node
            .get(&path)
            .is_some_and(|id| !self.matches_stat(*id, st))
        {
            self.retire_path(&path);
        }
        let id = self.intern_path(path);
        self.host_inodes.entry(id).or_insert(identity);
        id
    }

    fn record_parent(&mut self, id: u64, parent_id: u64, cname: CString) {
        if id != FUSE_ROOT_ID {
            self.node_parent.insert(id, (parent_id, cname));
        }
    }

    fn matches_inode(&self, nodeid: u64, md: &fs::Metadata) -> bool {
        self.host_inodes
            .get(&nodeid)
            .is_none_or(|known| *known == (md.dev(), md.ino()))
    }

    fn matches_stat(&self, nodeid: u64, st: &FuseStat) -> bool {
        self.host_inodes
            .get(&nodeid)
            .is_none_or(|known| *known == (st.dev, st.ino))
    }

    /// Return (or lazily open and cache) an `O_DIRECTORY` fd for `dir_nodeid`.
    fn ensure_dirfd(&mut self, dir_nodeid: u64) -> Option<RawFd> {
        if let Some(fd) = self.dir_fds.get(&dir_nodeid) {
            return Some(fd.as_raw_fd());
        }
        // Try openat from cached parent first to avoid full path walk
        let raw_fd = if let Some((grandparent_id, cname)) = self.node_parent.get(&dir_nodeid) {
            if let Some(gp_fd) = self.dir_fds.get(grandparent_id) {
                unsafe {
                    libc::openat(
                        gp_fd.as_raw_fd(),
                        cname.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                }
            } else {
                -1
            }
        } else {
            -1
        };
        let fd = if raw_fd >= 0 {
            raw_fd
        } else {
            let path = self.node_to_path.get(&dir_nodeid)?;
            let cpath = path_to_cstr(path).ok()?;
            unsafe {
                libc::open(
                    cpath.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            }
        };
        if fd < 0 {
            return None;
        }
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        if !self.read_only && self.host_inodes.contains_key(&dir_nodeid) {
            match fstat_fd(owned.as_raw_fd()) {
                Ok(st) if self.matches_stat(dir_nodeid, &st) => {}
                _ => return None,
            }
        }
        if self.dir_fds.len() >= MAX_CACHED_DIR_FDS {
            self.dir_fds.retain(|&k, _| k == FUSE_ROOT_ID);
        }
        let raw = owned.as_raw_fd();
        self.dir_fds.insert(dir_nodeid, owned);
        Some(raw)
    }

    /// Fast `lstat` for a node using cached `(parent_dirfd, leaf_name)` when available.
    fn stat_node_by_id(&mut self, nodeid: u64) -> Result<FuseStat, i32> {
        if let Some((parent_id, cname)) = self.node_parent.get(&nodeid)
            && let Some(pfd) = self.dir_fds.get(parent_id)
        {
            let st = fstatat_cstr(pfd.as_raw_fd(), cname)?;
            return if self.matches_stat(nodeid, &st) {
                Ok(st)
            } else {
                Err(LINUX_ESTALE)
            };
        }
        let path = self.node_to_path.get(&nodeid).ok_or(LINUX_ESTALE)?;
        let st = lstat_path(path)?;
        if self.matches_stat(nodeid, &st) {
            Ok(st)
        } else {
            Err(LINUX_ESTALE)
        }
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
        let by_path = self.stat_node_by_id(nodeid);
        if matches!(by_path, Err(LINUX_ENOENT | LINUX_ESTALE))
            && let Some(open) = self.open_files.values().find(|open| open.nodeid == nodeid)
        {
            return fstat_fd(open.file.as_raw_fd());
        }
        by_path
    }

    #[cfg(test)]
    fn node_metadata(&self, nodeid: u64, body: &[u8]) -> Result<fs::Metadata, i32> {
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
            return open.file.metadata().map_err(|e| io_err_to_linux(&e));
        }
        let by_path = self
            .node_to_path
            .get(&nodeid)
            .ok_or(LINUX_ESTALE)
            .and_then(|p| {
                let md = fs::symlink_metadata(p).map_err(|e| io_err_to_linux(&e))?;
                if self.matches_inode(nodeid, &md) {
                    Ok(md)
                } else {
                    Err(LINUX_ESTALE)
                }
            });
        if matches!(by_path, Err(LINUX_ENOENT | LINUX_ESTALE))
            && let Some(open) = self.open_files.values().find(|open| open.nodeid == nodeid)
        {
            return open.file.metadata().map_err(|e| io_err_to_linux(&e));
        }
        by_path
    }

    fn set_attributes(&self, nodeid: u64, body: &[u8], valid: u32) -> Result<fs::Metadata, i32> {
        let file = if valid & FATTR_FH != 0 {
            let fh = u64::from_le_bytes(body[8..16].try_into().unwrap());
            self.open_files
                .get(&fh)
                .filter(|f| f.nodeid == nodeid)
                .ok_or(LINUX_EBADF)?
                .file
                .clone()
        } else {
            let mut opened: Option<File> = None;
            let base_flags = if valid & FATTR_SIZE != 0 {
                libc::O_WRONLY
            } else {
                libc::O_RDONLY | METADATA_OPEN_FLAGS
            } | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC;
            if let Some((parent_id, cname)) = self.node_parent.get(&nodeid)
                && let Some(pfd) = self.dir_fds.get(parent_id)
            {
                let fd = unsafe { libc::openat(pfd.as_raw_fd(), cname.as_ptr(), base_flags) };
                if fd >= 0 {
                    opened = Some(unsafe { File::from_raw_fd(fd) });
                }
            }
            let f = match opened {
                Some(f) => f,
                None => {
                    let path = self.node_to_path.get(&nodeid).ok_or(LINUX_ESTALE)?;
                    let mut opts = OpenOptions::new();
                    if valid & FATTR_SIZE != 0 {
                        opts.write(true);
                    } else {
                        opts.read(true);
                    }
                    let flags = if valid & FATTR_SIZE != 0 {
                        0
                    } else {
                        METADATA_OPEN_FLAGS
                    };
                    opts.custom_flags(flags | libc::O_NOFOLLOW | libc::O_NONBLOCK);
                    opts.open(path).map_err(|e| io_err_to_linux(&e))?
                }
            };
            let md = f.metadata().map_err(|e| io_err_to_linux(&e))?;
            if !self.matches_inode(nodeid, &md) {
                return Err(LINUX_ESTALE);
            }
            Arc::new(f)
        };
        if valid & FATTR_SIZE != 0 {
            let size = u64::from_le_bytes(body[16..24].try_into().unwrap());
            file.set_len(size).map_err(|e| io_err_to_linux(&e))?;
        }
        if valid & FATTR_MODE != 0 {
            let mode = u32::from_le_bytes(body[68..72].try_into().unwrap());
            file.set_permissions(fs::Permissions::from_mode(mode & 0o7777))
                .map_err(|e| io_err_to_linux(&e))?;
        }
        if valid & (FATTR_ATIME | FATTR_MTIME | FATTR_ATIME_NOW | FATTR_MTIME_NOW) != 0 {
            let timestamp =
                |offset: usize, subsec_offset: usize, now_flag: u32| -> Result<SystemTime, i32> {
                    if valid & now_flag != 0 {
                        return Ok(SystemTime::now());
                    }
                    let secs = i64::from_le_bytes(body[offset..offset + 8].try_into().unwrap());
                    let nanos = u32::from_le_bytes(
                        body[subsec_offset..subsec_offset + 4].try_into().unwrap(),
                    );
                    if nanos >= 1_000_000_000 {
                        return Err(LINUX_EINVAL);
                    }
                    let whole = Duration::from_secs(secs.unsigned_abs());
                    let base = if secs < 0 {
                        UNIX_EPOCH.checked_sub(whole)
                    } else {
                        UNIX_EPOCH.checked_add(whole)
                    };
                    base.and_then(|t| t.checked_add(Duration::from_nanos(u64::from(nanos))))
                        .ok_or(LINUX_EINVAL)
                };
            let mut times = FileTimes::new();
            if valid & (FATTR_ATIME | FATTR_ATIME_NOW) != 0 {
                times = times.set_accessed(timestamp(32, 56, FATTR_ATIME_NOW)?);
            }
            if valid & (FATTR_MTIME | FATTR_MTIME_NOW) != 0 {
                times = times.set_modified(timestamp(40, 60, FATTR_MTIME_NOW)?);
            }
            file.set_times(times).map_err(|e| io_err_to_linux(&e))?;
        }
        file.metadata().map_err(|e| io_err_to_linux(&e))
    }

    fn child_path(&self, parent_id: u64, name: &[u8]) -> Result<PathBuf, i32> {
        let parent = self.node_to_path.get(&parent_id).ok_or(LINUX_ENOENT)?;
        if name.is_empty() || name.contains(&b'/') || name.contains(&0) {
            return Err(LINUX_EINVAL);
        }
        if name == b"." {
            return Ok(parent.clone());
        }
        if name == b".." {
            if parent == &self.root {
                return Ok(self.root.clone());
            }
            return Ok(parent.parent().unwrap_or(&self.root).to_path_buf());
        }
        let os = OsStr::from_bytes(name);
        Ok(parent.join(os))
    }

    fn encode_attr_stat(nodeid: u64, st: &FuseStat, out: &mut Vec<u8>) {
        // fuse_attr (88 bytes)
        out.extend_from_slice(&nodeid.to_le_bytes()); // ino
        out.extend_from_slice(&st.size.to_le_bytes()); // size
        out.extend_from_slice(&st.blocks.to_le_bytes()); // blocks
        out.extend_from_slice(&(st.atime as u64).to_le_bytes()); // atime
        out.extend_from_slice(&(st.mtime as u64).to_le_bytes()); // mtime
        out.extend_from_slice(&(st.ctime as u64).to_le_bytes()); // ctime
        out.extend_from_slice(&(st.atime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&(st.mtime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&(st.ctime_nsec as u32).to_le_bytes());
        out.extend_from_slice(&st.mode.to_le_bytes()); // mode (POSIX matches Linux!)
        out.extend_from_slice(&st.nlink.to_le_bytes());
        // Map host owner UID/GID to root (0) inside guest CI worker so containerd/apk/crun work cleanly
        out.extend_from_slice(&0u32.to_le_bytes()); // uid
        out.extend_from_slice(&0u32.to_le_bytes()); // gid
        out.extend_from_slice(&(st.rdev as u32).to_le_bytes());
        out.extend_from_slice(&4096u32.to_le_bytes()); // blksize
        out.extend_from_slice(&0u32.to_le_bytes()); // flags
    }

    fn encode_entry_out_stat(nodeid: u64, st: &FuseStat, read_only: bool, out: &mut Vec<u8>) {
        // fuse_entry_out (128 bytes); read-only tools shares get 3600s dentry/attr caching
        let (valid_secs, valid_nsecs) = cache_validity(read_only);
        out.extend_from_slice(&nodeid.to_le_bytes());
        out.extend_from_slice(&1u64.to_le_bytes()); // generation
        out.extend_from_slice(&valid_secs.to_le_bytes()); // entry_valid
        out.extend_from_slice(&valid_secs.to_le_bytes()); // attr_valid
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // entry_valid_nsec
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // attr_valid_nsec
        Self::encode_attr_stat(nodeid, st, out);
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

    fn read_dir_entries_fallback(dir_path: &Path) -> Result<Vec<BulkDirEntry>, i32> {
        let rd = fs::read_dir(dir_path).map_err(|e| io_err_to_linux(&e))?;
        let mut entries = Vec::new();
        for ent in rd.flatten() {
            let name = ent.file_name().as_os_str().as_bytes().to_vec();
            let p = ent.path();
            if let Ok(st) = lstat_path(&p) {
                entries.push(BulkDirEntry { name, stat: st });
            }
        }
        Ok(entries)
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
        let body = &req[40..];

        match opcode {
            FUSE_INIT => {
                let in_flags = body
                    .get(12..16)
                    .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                    .unwrap_or(0);
                self.begin_ok(unique);
                self.resp_buf.extend_from_slice(&7u32.to_le_bytes()); // major
                self.resp_buf.extend_from_slice(&31u32.to_le_bytes()); // minor
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
                if self.read_only {
                    // Read-only shares (e.g. oci-tools) are immutable: skip FUSE_OPEN/FLUSH/RELEASE
                    // completely (Linux sets fc->no_open=1 and FOPEN_KEEP_CACHE automatically) and
                    // keep guest page cache warm across container execs!
                    flags |= FUSE_NO_OPEN_SUPPORT | FUSE_EXPLICIT_INVAL_DATA;
                } else if (in_flags & FUSE_AUTO_INVAL_DATA) != 0 {
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
                self.resp_buf.extend_from_slice(&[0u8; 32]); // flags2 + unused[7]
                self.finish_ok()
            }
            FUSE_DESTROY => self.write_ok_slice(unique, &[]),
            FUSE_FORGET | FUSE_BATCH_FORGET => false, // No reply for FORGET
            FUSE_LOOKUP => {
                let (name, _) = Self::parse_cstr(body);
                if self.read_only
                    && let Some(cached) =
                        self.ro_lookup_cache.get(&(nodeid, name.to_vec())).copied()
                {
                    return match cached {
                        Ok(id) => {
                            if let Some(st) = self.ro_attr_cache.get(&id).copied() {
                                self.begin_ok(unique);
                                Self::encode_entry_out_stat(id, &st, true, &mut self.resp_buf);
                                self.finish_ok()
                            } else {
                                self.write_err(unique, LINUX_ENOENT)
                            }
                        }
                        Err(e) => self.write_err(unique, e),
                    };
                }
                let path = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname_opt = if name != b"." && name != b".." {
                    name_to_cstr(name).ok()
                } else {
                    None
                };
                let stat_res = match (&cname_opt, self.ensure_dirfd(nodeid)) {
                    (Some(cname), Some(pfd)) => fstatat_cstr(pfd, cname),
                    _ => lstat_path(&path),
                };
                match stat_res {
                    Ok(st) => {
                        let id = self.observe_path_stat(path, &st);
                        if let Some(cname) = cname_opt {
                            self.record_parent(id, nodeid, cname);
                        }
                        if self.read_only {
                            self.ro_lookup_cache.insert((nodeid, name.to_vec()), Ok(id));
                            self.ro_attr_cache.insert(id, st);
                        }
                        let ro = self.read_only;
                        self.begin_ok(unique);
                        Self::encode_entry_out_stat(id, &st, ro, &mut self.resp_buf);
                        self.finish_ok()
                    }
                    Err(le) => {
                        if self.read_only && self.ro_lookup_cache.len() < 4096 {
                            self.ro_lookup_cache
                                .insert((nodeid, name.to_vec()), Err(le));
                        }
                        self.write_err(unique, le)
                    }
                }
            }
            FUSE_GETATTR => {
                if self.read_only
                    && let Some(st) = self.ro_attr_cache.get(&nodeid).copied()
                {
                    self.begin_ok(unique);
                    self.resp_buf.extend_from_slice(&3600u64.to_le_bytes()); // attr_valid
                    self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
                    self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
                    Self::encode_attr_stat(nodeid, &st, &mut self.resp_buf);
                    return self.finish_ok();
                }
                match self.node_stat(nodeid, body) {
                    Ok(st) => {
                        let (valid_secs, valid_nsecs) = cache_validity(self.read_only);
                        if self.read_only {
                            self.ro_attr_cache.insert(nodeid, st);
                        }
                        self.begin_ok(unique);
                        self.resp_buf.extend_from_slice(&valid_secs.to_le_bytes());
                        self.resp_buf.extend_from_slice(&valid_nsecs.to_le_bytes());
                        self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
                        Self::encode_attr_stat(nodeid, &st, &mut self.resp_buf);
                        self.finish_ok()
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
                    Ok(md) => {
                        let st = FuseStat::from_metadata(&md);
                        let (secs, nsecs) = cache_validity(false);
                        self.begin_ok(unique);
                        self.resp_buf.extend_from_slice(&secs.to_le_bytes());
                        self.resp_buf.extend_from_slice(&nsecs.to_le_bytes());
                        self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
                        Self::encode_attr_stat(nodeid, &st, &mut self.resp_buf);
                        self.finish_ok()
                    }
                    Err(errno) => self.write_err(unique, errno),
                }
            }
            FUSE_READLINK => {
                if let Some((parent_id, cname)) = self.node_parent.get(&nodeid)
                    && let Some(pfd) = self.dir_fds.get(parent_id)
                {
                    let mut lbuf = [0u8; 4096];
                    let n = unsafe {
                        libc::readlinkat(
                            pfd.as_raw_fd(),
                            cname.as_ptr(),
                            lbuf.as_mut_ptr().cast(),
                            lbuf.len(),
                        )
                    };
                    if n >= 0 {
                        return self.write_ok_slice(unique, &lbuf[..n as usize]);
                    }
                    return self.write_err(unique, last_os_errno_linux());
                }
                let Some(path) = self.node_to_path.get(&nodeid).cloned() else {
                    return self.write_err(unique, LINUX_ENOENT);
                };
                match fs::read_link(&path) {
                    Ok(target) => self.write_ok_slice(unique, target.as_os_str().as_bytes()),
                    Err(e) => self.write_err(unique, io_err_to_linux(&e)),
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
                if !self.node_to_path.contains_key(&nodeid) {
                    return self.write_err(unique, LINUX_ESTALE);
                }
                // Validate the opened inode before applying a truncating open.
                // FUSE_CREATE is responsible for creating missing pathnames.
                let base_darwin = match Self::linux_open_flags_to_darwin(
                    flags & !(0o100 | 0o200 | 0o1000),
                    false,
                ) {
                    Ok(f) => f | libc::O_NOFOLLOW,
                    Err(e) => return self.write_err(unique, e),
                };
                let fd = if let Some((parent_id, cname)) = self.node_parent.get(&nodeid) {
                    if let Some(pfd) = self.dir_fds.get(parent_id) {
                        unsafe { libc::openat(pfd.as_raw_fd(), cname.as_ptr(), base_darwin) }
                    } else {
                        let cpath = match path_to_cstr(&self.node_to_path[&nodeid]) {
                            Ok(c) => c,
                            Err(e) => return self.write_err(unique, e),
                        };
                        unsafe { libc::open(cpath.as_ptr(), base_darwin) }
                    }
                } else {
                    let cpath = match path_to_cstr(&self.node_to_path[&nodeid]) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::open(cpath.as_ptr(), base_darwin) }
                };
                if fd >= 0 {
                    let file = unsafe { File::from_raw_fd(fd) };
                    match fstat_fd(file.as_raw_fd()) {
                        Ok(st) if self.matches_stat(nodeid, &st) => {}
                        Ok(_) => return self.write_err(unique, LINUX_ESTALE),
                        Err(e) => return self.write_err(unique, e),
                    }
                    if flags & 0o1000 != 0 && unsafe { libc::ftruncate(file.as_raw_fd(), 0) } != 0 {
                        return self.write_err(unique, last_os_errno_linux());
                    }
                    let fh = self.next_fh;
                    self.next_fh += 1;
                    self.open_files.insert(
                        fh,
                        OpenFile {
                            nodeid,
                            file: Arc::new(file),
                        },
                    );
                    let mut out = [0u8; 16];
                    out[0..8].copy_from_slice(&fh.to_le_bytes());
                    // Each mutable open invalidates cached pages. Skipping
                    // FLUSH remains safe for handles that cannot write.
                    if flags & (3 | 0o1000 | 0o2000) == 0 {
                        out[8..12].copy_from_slice(&FOPEN_NOFLUSH.to_le_bytes());
                    }
                    self.write_ok_slice(unique, &out)
                } else {
                    let open_errno = last_os_errno_linux();
                    // A stale positive dentry must be revalidated, even
                    // when the new binding prevents open (such as a symlink).
                    let stale = self.host_inodes.contains_key(&nodeid)
                        && match self.stat_node_by_id(nodeid) {
                            Ok(_) => false,
                            Err(LINUX_ESTALE | LINUX_ENOENT | LINUX_ENOTDIR | LINUX_ELOOP) => true,
                            Err(_) => false,
                        };
                    let errno = if stale { LINUX_ESTALE } else { open_errno };
                    self.write_err(unique, errno)
                }
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
                let path = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let darwin_flags = match Self::linux_open_flags_to_darwin(flags | 0o100, false) {
                    Ok(f) => f,
                    Err(e) => return self.write_err(unique, e),
                };
                let create_mode = (mode & 0o7777) as libc::c_uint;
                let fd = if let Some(pfd) = self.ensure_dirfd(nodeid) {
                    unsafe { libc::openat(pfd, cname.as_ptr(), darwin_flags, create_mode) }
                } else {
                    let cpath = match path_to_cstr(&path) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::open(cpath.as_ptr(), darwin_flags, create_mode) }
                };
                if fd >= 0 {
                    let file = unsafe { File::from_raw_fd(fd) };
                    let st = match fstat_fd(file.as_raw_fd()) {
                        Ok(s) => s,
                        Err(e) => return self.write_err(unique, e),
                    };
                    let id = self.observe_path_stat(path, &st);
                    self.record_parent(id, nodeid, cname);
                    let fh = self.next_fh;
                    self.next_fh += 1;
                    self.open_files.insert(
                        fh,
                        OpenFile {
                            nodeid: id,
                            file: Arc::new(file),
                        },
                    );
                    let ro = self.read_only;
                    self.begin_ok(unique);
                    Self::encode_entry_out_stat(id, &st, ro, &mut self.resp_buf);
                    self.resp_buf.extend_from_slice(&fh.to_le_bytes());
                    self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
                    self.resp_buf.extend_from_slice(&0i32.to_le_bytes());
                    self.finish_ok()
                } else {
                    self.write_err(unique, last_os_errno_linux())
                }
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
                    self.open_files.remove(&fh);
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_OPENDIR => {
                let Some(dir_path) = self.node_to_path.get(&nodeid).cloned() else {
                    return self.write_err(unique, LINUX_ENOENT);
                };
                let fd = if let Some((parent_id, cname)) = self.node_parent.get(&nodeid) {
                    if let Some(pfd) = self.dir_fds.get(parent_id) {
                        unsafe {
                            libc::openat(
                                pfd.as_raw_fd(),
                                cname.as_ptr(),
                                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                            )
                        }
                    } else {
                        -1
                    }
                } else {
                    -1
                };
                let fd = if fd >= 0 {
                    fd
                } else {
                    let cpath = match path_to_cstr(&dir_path) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe {
                        libc::open(
                            cpath.as_ptr(),
                            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                        )
                    }
                };
                if fd < 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                let dir_fd = unsafe { OwnedFd::from_raw_fd(fd) };
                // Also populate dir_fds cache via dup so subsequent child lookups/opens use dirfd!
                if !self.dir_fds.contains_key(&nodeid) {
                    let dup_fd =
                        unsafe { libc::fcntl(dir_fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
                    if dup_fd >= 0 {
                        if self.dir_fds.len() >= MAX_CACHED_DIR_FDS {
                            self.dir_fds.retain(|&k, _| k == FUSE_ROOT_ID);
                        }
                        self.dir_fds
                            .insert(nodeid, unsafe { OwnedFd::from_raw_fd(dup_fd) });
                    }
                }
                let fh = self.next_fh;
                self.next_fh += 1;
                self.open_dirs.insert(
                    fh,
                    OpenDir {
                        dir_nodeid: nodeid,
                        dir_path,
                        dir_fd,
                        entries: None,
                    },
                );
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

                // Populate entries lazily on offset == 0 via single-syscall Darwin getattrlistbulk!
                let need_populate = match self.open_dirs.get(&fh) {
                    Some(od) => offset == 0 || od.entries.is_none(),
                    None => return self.write_err(unique, LINUX_EBADF),
                };
                if need_populate {
                    let (raw_fd, dir_path) = {
                        let od = self.open_dirs.get(&fh).unwrap();
                        (od.dir_fd.as_raw_fd(), od.dir_path.clone())
                    };
                    #[cfg(target_vendor = "apple")]
                    let bulk_res = darwin_bulk::read_dir_bulk(raw_fd, &mut self.bulk_buf)
                        .or_else(|_| Self::read_dir_entries_fallback(&dir_path));
                    #[cfg(not(target_vendor = "apple"))]
                    let bulk_res = {
                        let _ = raw_fd;
                        Self::read_dir_entries_fallback(&dir_path)
                    };
                    let entries = match bulk_res {
                        Ok(v) => v,
                        Err(e) => return self.write_err(unique, e),
                    };
                    if let Some(od) = self.open_dirs.get_mut(&fh) {
                        od.entries = Some(entries);
                    }
                }

                // Detach entries temporarily to avoid borrow conflict with `self.observe_path_stat`
                let (dir_nodeid, dir_path, entries) = {
                    let Some(od) = self.open_dirs.get_mut(&fh) else {
                        return self.write_err(unique, LINUX_EBADF);
                    };
                    (
                        od.dir_nodeid,
                        od.dir_path.clone(),
                        od.entries.take().unwrap_or_default(),
                    )
                };

                let plus = opcode == FUSE_READDIRPLUS;
                let ro = self.read_only;
                self.begin_ok(unique);
                let body_start = self.resp_buf.len();
                for (i, e) in entries.iter().enumerate().skip(offset) {
                    let name_len = e.name.len();
                    let raw_ent = (if plus { 128 } else { 0 }) + 24 + name_len;
                    let padded = (raw_ent + 7) & !7;
                    if (self.resp_buf.len() - body_start) + padded > max_size {
                        break;
                    }
                    let child_p = dir_path.join(OsStr::from_bytes(&e.name));
                    let ino = if plus {
                        let id = self.observe_path_stat(child_p, &e.stat);
                        if let Ok(cname) = CString::new(e.name.as_slice()) {
                            self.record_parent(id, dir_nodeid, cname);
                        }
                        if ro {
                            self.ro_lookup_cache
                                .insert((dir_nodeid, e.name.clone()), Ok(id));
                            self.ro_attr_cache.insert(id, e.stat);
                        }
                        Self::encode_entry_out_stat(id, &e.stat, ro, &mut self.resp_buf);
                        id
                    } else {
                        self.intern_path(child_p)
                    };
                    let dtype = e.stat.dtype();
                    self.resp_buf.extend_from_slice(&ino.to_le_bytes());
                    self.resp_buf
                        .extend_from_slice(&((i + 1) as u64).to_le_bytes());
                    self.resp_buf
                        .extend_from_slice(&(name_len as u32).to_le_bytes());
                    self.resp_buf.extend_from_slice(&dtype.to_le_bytes());
                    self.resp_buf.extend_from_slice(&e.name);
                    while !(self.resp_buf.len() - body_start).is_multiple_of(8) {
                        self.resp_buf.push(0);
                    }
                }
                if let Some(od) = self.open_dirs.get_mut(&fh) {
                    od.entries = Some(entries);
                }
                self.finish_ok()
            }
            FUSE_RELEASEDIR => {
                if body.len() >= 8 {
                    let fh = u64::from_le_bytes(body[0..8].try_into().unwrap());
                    self.open_dirs.remove(&fh);
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
                let path = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let pfd_opt = self.ensure_dirfd(nodeid);
                let rc = if let Some(pfd) = pfd_opt {
                    unsafe { libc::mkdirat(pfd, cname.as_ptr(), (mode & 0o7777) as libc::mode_t) }
                } else {
                    let cpath = match path_to_cstr(&path) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::mkdir(cpath.as_ptr(), (mode & 0o7777) as libc::mode_t) }
                };
                if rc != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                let st_res = if let Some(pfd) = pfd_opt {
                    fstatat_cstr(pfd, &cname)
                } else {
                    lstat_path(&path)
                };
                match st_res {
                    Ok(st) => {
                        let id = self.observe_path_stat(path, &st);
                        self.record_parent(id, nodeid, cname);
                        let ro = self.read_only;
                        self.begin_ok(unique);
                        Self::encode_entry_out_stat(id, &st, ro, &mut self.resp_buf);
                        self.finish_ok()
                    }
                    Err(e) => self.write_err(unique, e),
                }
            }
            FUSE_UNLINK => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let (name, _) = Self::parse_cstr(body);
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let rc = if let Some(pfd) = self.ensure_dirfd(nodeid) {
                    unsafe { libc::unlinkat(pfd, cname.as_ptr(), 0) }
                } else {
                    let path = match self.child_path(nodeid, name) {
                        Ok(p) => p,
                        Err(e) => return self.write_err(unique, e),
                    };
                    let cpath = match path_to_cstr(&path) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::unlink(cpath.as_ptr()) }
                };
                if rc == 0 {
                    self.write_ok_slice(unique, &[])
                } else {
                    self.write_err(unique, last_os_errno_linux())
                }
            }
            FUSE_RMDIR => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let (name, _) = Self::parse_cstr(body);
                let path = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let rc = if let Some(pfd) = self.ensure_dirfd(nodeid) {
                    unsafe { libc::unlinkat(pfd, cname.as_ptr(), libc::AT_REMOVEDIR) }
                } else {
                    let cpath = match path_to_cstr(&path) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::rmdir(cpath.as_ptr()) }
                };
                if rc == 0 {
                    self.retire_path(&path);
                    self.write_ok_slice(unique, &[])
                } else {
                    self.write_err(unique, last_os_errno_linux())
                }
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
                let (oldname, rest) = Self::parse_cstr(&body[hdr_len..]);
                let (newname, _) = Self::parse_cstr(rest);
                let old_p = match self.child_path(nodeid, oldname) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let new_p = match self.child_path(newdir, newname) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let old_cname = match name_to_cstr(oldname) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let new_cname = match name_to_cstr(newname) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let old_pfd = self.ensure_dirfd(nodeid);
                let new_pfd = self.ensure_dirfd(newdir);
                let rc = match (old_pfd, new_pfd) {
                    (Some(opfd), Some(npfd)) => unsafe {
                        libc::renameat(opfd, old_cname.as_ptr(), npfd, new_cname.as_ptr())
                    },
                    _ => match (path_to_cstr(&old_p), path_to_cstr(&new_p)) {
                        (Ok(oc), Ok(nc)) => unsafe { libc::rename(oc.as_ptr(), nc.as_ptr()) },
                        _ => return self.write_err(unique, LINUX_EINVAL),
                    },
                };
                if rc == 0 {
                    if old_p != new_p {
                        // Identical hard links make rename a no-op.
                        let unchanged = lstat_path(&old_p)
                            .and_then(|old| {
                                lstat_path(&new_p)
                                    .map(|new| (old.dev, old.ino) == (new.dev, new.ino))
                            })
                            .unwrap_or(false);
                        if !unchanged {
                            // Open descriptors for the displaced inode remain in open_files.
                            self.retire_path(&new_p);
                            if let Some(id) = self.path_to_node.remove(&old_p) {
                                self.node_to_path.insert(id, new_p.clone());
                                self.path_to_node.insert(new_p, id);
                                self.record_parent(id, newdir, new_cname);
                            }
                        }
                    }
                    self.write_ok_slice(unique, &[])
                } else {
                    self.write_err(unique, last_os_errno_linux())
                }
            }
            FUSE_SYMLINK => {
                if self.read_only {
                    return self.write_err(unique, LINUX_EROFS);
                }
                let (name, rest) = Self::parse_cstr(body);
                let (target, _) = Self::parse_cstr(rest);
                let link_p = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let ctarget = match CString::new(target) {
                    Ok(c) => c,
                    Err(_) => return self.write_err(unique, LINUX_EINVAL),
                };
                let pfd_opt = self.ensure_dirfd(nodeid);
                let rc = if let Some(pfd) = pfd_opt {
                    unsafe { libc::symlinkat(ctarget.as_ptr(), pfd, cname.as_ptr()) }
                } else {
                    let clink = match path_to_cstr(&link_p) {
                        Ok(c) => c,
                        Err(e) => return self.write_err(unique, e),
                    };
                    unsafe { libc::symlink(ctarget.as_ptr(), clink.as_ptr()) }
                };
                if rc != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                let st_res = if let Some(pfd) = pfd_opt {
                    fstatat_cstr(pfd, &cname)
                } else {
                    lstat_path(&link_p)
                };
                match st_res {
                    Ok(st) => {
                        let id = self.observe_path_stat(link_p, &st);
                        self.record_parent(id, nodeid, cname);
                        let ro = self.read_only;
                        self.begin_ok(unique);
                        Self::encode_entry_out_stat(id, &st, ro, &mut self.resp_buf);
                        self.finish_ok()
                    }
                    Err(e) => self.write_err(unique, e),
                }
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
                let Some(old_p) = self.node_to_path.get(&old_id).cloned() else {
                    return self.write_err(unique, LINUX_ENOENT);
                };
                let new_p = match self.child_path(nodeid, name) {
                    Ok(p) => p,
                    Err(e) => return self.write_err(unique, e),
                };
                let cname = match name_to_cstr(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                if let Err(e) = fs::hard_link(&old_p, &new_p) {
                    return self.write_err(unique, io_err_to_linux(&e));
                }
                let st_res = if let Some(pfd) = self.ensure_dirfd(nodeid) {
                    fstatat_cstr(pfd, &cname)
                } else {
                    lstat_path(&new_p)
                };
                match st_res {
                    Ok(st) => {
                        let id = self.observe_path_stat(new_p, &st);
                        self.record_parent(id, nodeid, cname);
                        let ro = self.read_only;
                        self.begin_ok(unique);
                        Self::encode_entry_out_stat(id, &st, ro, &mut self.resp_buf);
                        self.finish_ok()
                    }
                    Err(e) => self.write_err(unique, e),
                }
            }
            FUSE_STATFS => {
                let mut st: libc::statfs = unsafe { std::mem::zeroed() };
                let rc = if let Some(rfd) = self.dir_fds.get(&FUSE_ROOT_ID) {
                    unsafe { libc::fstatfs(rfd.as_raw_fd(), &mut st) }
                } else {
                    let cpath = CString::new(self.root.as_os_str().as_bytes()).unwrap_or_default();
                    unsafe { libc::statfs(cpath.as_ptr(), &mut st) }
                };
                if rc != 0 {
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

    fn sync_handle(&self, opcode: u32, nodeid: u64, fh: u64, data_only: bool) -> Result<(), i32> {
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

        // Immutable shares negotiate FUSE_NO_OPEN_SUPPORT. Their regular files
        // have no server-side handle, so open the known leaf only for this sync.
        let path = self.node_to_path.get(&nodeid).ok_or(LINUX_EBADF)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .map_err(|e| io_err_to_linux(&e))?;
        if !file.metadata().map_err(|e| io_err_to_linux(&e))?.is_file() {
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
            let fd = if let Some((parent_id, cname)) = self.node_parent.get(&nodeid) {
                if let Some(pfd) = self.dir_fds.get(parent_id) {
                    unsafe {
                        libc::openat(
                            pfd.as_raw_fd(),
                            cname.as_ptr(),
                            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                        )
                    }
                } else {
                    -1
                }
            } else {
                -1
            };
            let f = if fd >= 0 {
                unsafe { File::from_raw_fd(fd) }
            } else {
                let path = self
                    .node_to_path
                    .get(&nodeid)
                    .cloned()
                    .ok_or(LINUX_ENOENT)?;
                OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(&path)
                    .map_err(|e| io_err_to_linux(&e))?
            };
            let arc_f = Arc::new(f);
            if self.ro_file_cache.len() < 256 {
                self.ro_file_cache.insert(nodeid, arc_f.clone());
            }
            Ok(arc_f)
        } else {
            Err(LINUX_EBADF)
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
        let mut total_readable = 0usize;
        for b in bufs {
            if b.is_write {
                continue;
            }
            let blen = b.len as usize;
            total_readable += blen;
            if hdr_copied < hdr.len()
                && let Some(s) = mem.read_slice(b.addr, blen)
            {
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

        // Standard path: reuse `req_scratch` + `self.resp_buf` (0 heap allocations after warmup!)
        req_scratch.clear();
        if req_scratch.capacity() < total_readable {
            req_scratch.reserve(total_readable - req_scratch.capacity());
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
    let mut local_qs: [Option<VirtQueue>; 2] = [None, None];
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
                let (ns, _) = shared
                    .state
                    .1
                    .wait_timeout(st, Duration::from_millis(5))
                    .unwrap();
                st = ns;
            }
            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            st.kicked = false;
            st.worker_parked = false;
            for (local, updated) in local_qs.iter_mut().zip(st.queues.iter()) {
                if let Some(updated) = updated {
                    match local {
                        Some(lq) => {
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
                        None => *local = Some(updated.clone()),
                    }
                } else {
                    *local = None;
                }
            }
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
                        let mut q_used = false;
                        while let Some(head) = q.pop_into(&mem, &mut desc_buf) {
                            let written = core.handle_fuse_chain(&desc_buf, &mem, &mut req_scratch);
                            q.push_used(&mem, head, written);
                            q_used = true;
                            used_any = true;
                        }
                        if q_used && q.guest_wants_irq(&mem) {
                            want_irq = true;
                        }
                    }
                }
                if used_any {
                    if want_irq {
                        irq.raise_used_buffer();
                    }
                    last_activity = Instant::now();
                    spin_iters = 0;
                    continue;
                }
            }

            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            if shared.paused.load(Ordering::Acquire) {
                for q in local_qs.iter().flatten() {
                    if q.ready {
                        q.set_no_notify(&mem, false);
                    }
                }
                break;
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
        0
    }
    fn num_queues(&self) -> usize {
        2 // 0 = hiprio, 1 = request queue 0
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        256
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 40];
        cfg[0..36].copy_from_slice(&self.tag);
        cfg[36..40].copy_from_slice(&1u32.to_le_bytes()); // num_request_queues = 1
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
        if q_idx < 2 {
            let mut st = self.shared.state.0.lock().unwrap();
            st.queues[q_idx] = Some(q.clone());
            st.kicked = true;
            self.shared.state.1.notify_one();
            drop(st);
            self.ensure_worker_started();
        }
    }
    fn reset(&mut self) {
        let mut st = self.shared.state.0.lock().unwrap();
        st.queues = [None, None];
        st.kicked = false;
    }
    fn snapshot_pause(&mut self, queues: &mut [VirtQueue], mem: &GuestMemory) -> Vec<u8> {
        self.shared.paused.store(true, Ordering::Release);
        self.shared.state.1.notify_all();
        let mut st = self.shared.state.0.lock().unwrap();
        if self.worker_handle.is_some() {
            while !st.worker_parked {
                st = self.shared.state.1.wait(st).unwrap();
            }
        }
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
        // Serialize relative nodeid -> path table so restored guest retains all live FUSE dentries!
        let core = self.shared.core.lock().unwrap();
        let mut blob = Vec::new();
        blob.extend_from_slice(&core.next_nodeid.to_le_bytes());
        blob.extend_from_slice(&core.next_fh.to_le_bytes());
        let mut rels: Vec<(u64, Vec<u8>)> = Vec::with_capacity(core.node_to_path.len());
        for (&id, path) in &core.node_to_path {
            if id == FUSE_ROOT_ID {
                continue;
            }
            if let Ok(rel) = path.strip_prefix(&core.root) {
                rels.push((id, rel.as_os_str().as_bytes().to_vec()));
            }
        }
        rels.sort_by_key(|(id, _)| *id);
        blob.extend_from_slice(&(rels.len() as u32).to_le_bytes());
        for (id, rel_bytes) in rels {
            blob.extend_from_slice(&id.to_le_bytes());
            blob.extend_from_slice(&(rel_bytes.len() as u32).to_le_bytes());
            blob.extend_from_slice(&rel_bytes);
        }
        blob
    }
    fn snapshot_resume(&mut self) {
        self.shared.paused.store(false, Ordering::Release);
        let mut st = self.shared.state.0.lock().unwrap();
        st.kicked = true;
        self.shared.state.1.notify_all();
    }
    fn snapshot_restore(&mut self, blob: &[u8], queues: &[VirtQueue]) {
        if blob.len() >= 20 {
            let mut core = self.shared.core.lock().unwrap();
            core.next_nodeid = u64::from_le_bytes(blob[0..8].try_into().unwrap());
            core.next_fh = u64::from_le_bytes(blob[8..16].try_into().unwrap());
            let count = u32::from_le_bytes(blob[16..20].try_into().unwrap()) as usize;
            let mut pos = 20usize;
            for _ in 0..count {
                if pos + 12 > blob.len() {
                    break;
                }
                let id = u64::from_le_bytes(blob[pos..pos + 8].try_into().unwrap());
                let len = u32::from_le_bytes(blob[pos + 8..pos + 12].try_into().unwrap()) as usize;
                pos += 12;
                if pos + len > blob.len() {
                    break;
                }
                let rel_bytes = &blob[pos..pos + len];
                pos += len;
                let full_path = core.root.join(OsStr::from_bytes(rel_bytes));
                if !core.read_only {
                    // On mutable workspace shares (e.g. a fork pointed at a fresh host directory),
                    // only restore nodes that exist under the new root so missing files return
                    // clean ESTALE/ENOENT and new files with the same name bind fresh host inodes.
                    let Ok(st) = lstat_path(&full_path) else {
                        continue;
                    };
                    core.host_inodes.insert(id, (st.dev, st.ino));
                }
                core.node_to_path.insert(id, full_path.clone());
                core.path_to_node.insert(full_path, id);
            }
        }
        for (idx, q) in queues.iter().enumerate().take(2) {
            if q.ready {
                self.queue_ready(idx, q);
            }
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], _mem: &GuestMemory) -> bool {
        if q_idx < 2 {
            let mut st = self.shared.state.0.lock().unwrap();
            if st.queues[q_idx].is_none() {
                st.queues[q_idx] = Some(queues[q_idx].clone());
            }
            st.kicked = true;
            self.shared.state.1.notify_one();
            drop(st);
            self.ensure_worker_started();
        }
        false
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

    fn request(fsys: &mut VirtioFs, opcode: u32, nodeid: u64, body: &[u8]) -> Vec<u8> {
        let mut req = vec![0; 40];
        let size = (req.len() + body.len()) as u32;
        req[0..4].copy_from_slice(&size.to_le_bytes());
        req[4..8].copy_from_slice(&opcode.to_le_bytes());
        req[8..16].copy_from_slice(&1u64.to_le_bytes());
        req[16..24].copy_from_slice(&nodeid.to_le_bytes());
        req.extend_from_slice(body);
        fsys.handle_fuse(&req).unwrap()
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
                },
            );
            core.open_dirs.insert(
                2,
                OpenDir {
                    dir_nodeid: FUSE_ROOT_ID,
                    dir_path: dir.clone(),
                    dir_fd: OwnedFd::from(right),
                    entries: None,
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
                .node_metadata(first, &[])
                .unwrap()
                .ino(),
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
        assert_eq!((md.mtime(), md.mode() & 0o777), (1_600_000_000, 0o640));
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
        assert!(
            !fsys
                .shared
                .core
                .lock()
                .unwrap()
                .node_to_path
                .contains_key(&old)
        );
        assert!(
            !fsys
                .shared
                .core
                .lock()
                .unwrap()
                .host_inodes
                .contains_key(&old)
        );
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
        assert_eq!(
            vfs.shared
                .core
                .lock()
                .unwrap()
                .child_path(FUSE_ROOT_ID, b"../etc")
                .unwrap_err(),
            LINUX_EINVAL
        );

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
            let name = std::str::from_utf8(&e.name).unwrap();
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
            assert_eq!(e.stat.mtime, md.mtime(), "mtime mismatch for {name}");
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
                core.node_to_path.get(&shared_id),
                Some(&fork_canon.join("shared.txt"))
            );
            let fork_md = fs::symlink_metadata(fork_dir.join("shared.txt")).unwrap();
            assert_eq!(
                core.host_inodes.get(&shared_id),
                Some(&(fork_md.dev(), fork_md.ino()))
            );
            assert!(
                !core.node_to_path.contains_key(&only_base_id),
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
}
