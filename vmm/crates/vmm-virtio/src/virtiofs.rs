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
//! fails with ESTALE instead of being looked up by path.
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
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::fs::{self, File, FileTimes};
use std::io::ErrorKind;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileExt, MetadataExt, PermissionsExt};
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
    name: CString,
    stat: FuseStat,
}

struct OpenDir {
    dir_nodeid: u64,
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

                let mut name_bytes: Option<CString> = None;
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
                            name_bytes = CString::new(trimmed).ok();
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

/// Marks the pinned-owner section of a snapshot blob.
const SNAPSHOT_OWNERS_TAG: &[u8; 4] = b"OWN1";

// renameat2(2) flags the guest may send in FUSE_RENAME2.
const LINUX_RENAME_NOREPLACE: u32 = 1 << 0;
const LINUX_RENAME_EXCHANGE: u32 = 1 << 1;

const DIR_OPEN_FLAGS: i32 = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;

/// Guest-visible ownership of one node on a writable share.
///
/// Host uids mean nothing in the guest, so a field no guest `chown` set
/// "floats": a non-root caller sees itself as the owner, so non-root
/// containers can use the Mac's files (as with Docker Desktop), and a root
/// caller, which passes permission checks without owning anything, sees the
/// non-root user that used the node within [`OWNER_ADOPT_WINDOW`], else root.
/// A guest `chown`/`chgrp` pins only the field it names, for every caller,
/// for as long as the node exists. Set-id bits are never honoured on a
/// writable share (see [`guest_mode`]).
#[derive(Clone, Copy, Default)]
struct GuestOwner {
    uid: Option<u32>,
    gid: Option<u32>,
    /// Last non-root caller that saw this node, and when (ms since the share opened).
    recent_user: Option<(u32, u32)>,
    recent_at_ms: u64,
}

/// One node the guest can name: the directory entry it was last seen at and
/// the host file it is bound to. Nodes are addressed by (parent, name), never
/// by a host path, so renaming a directory moves its whole subtree at once and
/// every host access is resolved again from the share root.
struct Node {
    parent: u64,
    /// Entry name in `parent` (the root node is `.` in itself).
    name: CString,
    /// Host (dev, ino) this node is bound to (mutable shares).
    identity: Option<(u64, u64)>,
    owner: GuestOwner,
}

/// Mode, uid and gid the guest sees for a node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GuestAttr {
    mode: u32,
    uid: u32,
    gid: u32,
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

/// Open the directory reached from `base` through `names` (entry names, never
/// `.` or `..`) without following a symlink in any component, so the result
/// can only be a directory inside the tree `base` heads.
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

/// List a directory through its descriptor (when `getattrlistbulk` is not
/// available), with `fstatat` relative to the same descriptor.
fn read_dir_entries_fd(dir_fd: RawFd) -> Result<Vec<BulkDirEntry>, i32> {
    let dup = unsafe { libc::fcntl(dir_fd, libc::F_DUPFD_CLOEXEC, 0) };
    if dup < 0 {
        return Err(last_os_errno_linux());
    }
    let dirp = unsafe { libc::fdopendir(dup) };
    if dirp.is_null() {
        let errno = last_os_errno_linux();
        unsafe { libc::close(dup) };
        return Err(errno);
    }
    unsafe { libc::rewinddir(dirp) };
    let mut entries = Vec::new();
    loop {
        let ent = unsafe { libc::readdir(dirp) };
        if ent.is_null() {
            break;
        }
        let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        if let Ok(stat) = fstatat_cstr(dir_fd, name) {
            entries.push(BulkDirEntry {
                name: name.to_owned(),
                stat,
            });
        }
    }
    unsafe { libc::closedir(dirp) };
    Ok(entries)
}

struct FsCore {
    read_only: bool,
    /// The share root, opened once. Every host access is a `*at` call on a
    /// directory reached from here without following symlinks.
    root_fd: Arc<OwnedFd>,
    next_nodeid: u64,
    next_fh: u64,
    nodes: HashMap<u64, Node>,
    /// (parent node, entry name) -> node.
    children: HashMap<u64, HashMap<CString, u64>>,
    /// Open directories by node; a descriptor keeps naming its directory
    /// across renames, so it stays valid until the node is retired.
    dir_fds: HashMap<u64, Arc<OwnedFd>>,
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
    /// Guest uid/gid of the request being handled (from `fuse_in_header`).
    caller: (u32, u32),
    epoch: Instant,
    adopt_window_ms: u64,
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
        let core = FsCore::new(&root, read_only, metrics)?;
        let mut tag_bytes = [0u8; 36];
        let src = tag.as_bytes();
        let n = src.len().min(36);
        tag_bytes[..n].copy_from_slice(&src[..n]);

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
    fn new(root: &Path, read_only: bool, metrics: Arc<FsMetrics>) -> std::io::Result<Self> {
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
        let mut nodes = HashMap::new();
        nodes.insert(
            FUSE_ROOT_ID,
            Node {
                parent: FUSE_ROOT_ID,
                name: c".".to_owned(),
                identity: None,
                owner: GuestOwner::default(),
            },
        );
        Ok(Self {
            read_only,
            root_fd: Arc::new(unsafe { OwnedFd::from_raw_fd(fd) }),
            next_nodeid: 2,
            next_fh: 1,
            nodes,
            children: HashMap::new(),
            dir_fds: HashMap::new(),
            open_files: HashMap::new(),
            open_dirs: HashMap::new(),
            ro_lookup_cache: HashMap::new(),
            ro_attr_cache: HashMap::new(),
            ro_file_cache: HashMap::new(),
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
        self.nodes.insert(
            id,
            Node {
                parent,
                name,
                identity,
                owner: GuestOwner::default(),
            },
        );
    }

    /// Forget a node and everything below it: later requests for them get
    /// ESTALE (open handles keep working), and the name can bind afresh.
    fn retire(&mut self, id: u64) {
        let mut stack = vec![id];
        while let Some(id) = stack.pop() {
            if id == FUSE_ROOT_ID {
                continue;
            }
            let Some(node) = self.nodes.remove(&id) else {
                continue;
            };
            if let Some(siblings) = self.children.get_mut(&node.parent)
                && siblings.get(node.name.as_c_str()) == Some(&id)
            {
                siblings.remove(node.name.as_c_str());
                if siblings.is_empty() {
                    self.children.remove(&node.parent);
                }
            }
            if let Some(kids) = self.children.remove(&id) {
                stack.extend(kids.into_values());
            }
            self.dir_fds.remove(&id);
        }
    }

    fn retire_child(&mut self, parent: u64, name: &CStr) {
        if let Some(id) = self.child_id(parent, name) {
            self.retire(id);
        }
    }

    /// Bind the entry `name` of `parent` to the host file `st` describes.
    ///
    /// An editor can atomically replace a pathname. Linux keys its page cache by
    /// FUSE node ID, so the replacement must receive a distinct ID while open
    /// handles to the old inode continue to address their original contents.
    fn observe_child(&mut self, parent: u64, name: &CStr, st: &FuseStat) -> u64 {
        let identity = (st.dev, st.ino);
        if let Some(id) = self.child_id(parent, name) {
            if self.read_only {
                return id;
            }
            if let Some(node) = self.nodes.get_mut(&id) {
                match node.identity {
                    None => {
                        node.identity = Some(identity);
                        return id;
                    }
                    Some(known) if known == identity => return id,
                    Some(_) => {}
                }
            }
            self.retire(id);
        }
        let identity = (!self.read_only).then_some(identity);
        self.insert_child(parent, name.to_owned(), identity)
    }

    /// Move the node at (`old_parent`, `old`) to (`new_parent`, `new`) after a
    /// host rename. Its descendants are addressed through it, so they move too.
    fn move_child(&mut self, old_parent: u64, old: &CStr, new_parent: u64, new: CString) {
        let moving = self.child_id(old_parent, old);
        // The displaced destination is gone; its open handles stay valid.
        if let Some(dst) = self.child_id(new_parent, &new)
            && Some(dst) != moving
        {
            self.retire(dst);
        }
        let Some(id) = moving else {
            return;
        };
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
    }

    /// Swap two entries after a host `RENAME_SWAP`.
    fn exchange_children(&mut self, a_parent: u64, a: &CStr, b_parent: u64, b: &CStr) {
        let a_id = self.child_id(a_parent, a);
        let b_id = self.child_id(b_parent, b);
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
        self.read_only
            || self
                .nodes
                .get(&nodeid)
                .and_then(|n| n.identity)
                .is_none_or(|known| known == (st.dev, st.ino))
    }

    fn has_identity(&self, nodeid: u64) -> bool {
        !self.read_only
            && self
                .nodes
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
        if let Some(fd) = self.dir_fds.get(&id) {
            return Ok(fd.clone());
        }
        // Walk up to the nearest directory already open, collecting entry names.
        let mut chain = Vec::new();
        let mut cur = id;
        let base = loop {
            if cur == FUSE_ROOT_ID {
                break self.root_fd.clone();
            }
            if let Some(fd) = self.dir_fds.get(&cur) {
                break fd.clone();
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
        if self.dir_fds.len() >= MAX_CACHED_DIR_FDS {
            self.dir_fds.clear();
        }
        let fd = Arc::new(fd);
        self.dir_fds.insert(id, fd.clone());
        Ok(fd)
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

    /// Open a node's host file without following a symlink, ESTALE if its
    /// entry now names a different host file.
    fn open_node(&mut self, nodeid: u64, flags: i32) -> Result<File, i32> {
        let fd = self.at_leaf(nodeid, |dfd, name| {
            let fd = unsafe {
                libc::openat(
                    dfd,
                    name.as_ptr(),
                    flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                Err(last_os_errno_linux())
            } else {
                Ok(unsafe { OwnedFd::from_raw_fd(fd) })
            }
        })?;
        if self.has_identity(nodeid) {
            let st = fstat_fd(fd.as_raw_fd())?;
            if !self.identity_matches(nodeid, &st) {
                return Err(LINUX_ESTALE);
            }
        }
        Ok(File::from(fd))
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
        if matches!(by_path, Err(LINUX_ENOENT | LINUX_ESTALE))
            && let Some(open) = self.open_files.values().find(|open| open.nodeid == nodeid)
        {
            return fstat_fd(open.file.as_raw_fd());
        }
        by_path
    }

    /// Recorded owner fields after a SETATTR with `valid`, from this caller.
    fn owner_after(&self, nodeid: u64, body: &[u8], valid: u32) -> (Option<u32>, Option<u32>) {
        let (mut uid, mut gid) = self
            .nodes
            .get(&nodeid)
            .map_or((None, None), |n| (n.owner.uid, n.owner.gid));
        let (caller_uid, caller_gid) = self.caller;
        // A non-root user handing a floating field to itself changes nothing
        // (it already sees itself there) and must not pin it for other users.
        if valid & FATTR_UID != 0 {
            let new = u32::from_le_bytes(body[76..80].try_into().unwrap());
            if !(caller_uid != 0 && uid.is_none() && new == caller_uid) {
                uid = Some(new);
            }
        }
        if valid & FATTR_GID != 0 {
            let new = u32::from_le_bytes(body[80..84].try_into().unwrap());
            if !(caller_uid != 0 && gid.is_none() && new == caller_gid) {
                gid = Some(new);
            }
        }
        (uid, gid)
    }

    fn set_attributes(
        &mut self,
        nodeid: u64,
        body: &[u8],
        valid: u32,
    ) -> Result<fs::Metadata, i32> {
        let file = if valid & FATTR_FH != 0 {
            let fh = u64::from_le_bytes(body[8..16].try_into().unwrap());
            self.open_files
                .get(&fh)
                .filter(|f| f.nodeid == nodeid)
                .ok_or(LINUX_EBADF)?
                .file
                .clone()
        } else {
            let flags = if valid & FATTR_SIZE != 0 {
                libc::O_WRONLY
            } else {
                libc::O_RDONLY | METADATA_OPEN_FLAGS
            } | libc::O_NONBLOCK;
            match self.open_node(nodeid, flags) {
                Ok(file) => Arc::new(file),
                Err(e) => return Err(self.open_failure(nodeid, e)),
            }
        };
        let (uid, gid) = if self.read_only {
            (None, None)
        } else {
            self.owner_after(nodeid, body, valid)
        };
        if valid & FATTR_SIZE != 0 {
            let size = u64::from_le_bytes(body[16..24].try_into().unwrap());
            file.set_len(size).map_err(|e| io_err_to_linux(&e))?;
        }
        if valid & FATTR_MODE != 0 {
            let is_dir = file.metadata().map_err(|e| io_err_to_linux(&e))?.is_dir();
            let mode = u32::from_le_bytes(body[68..72].try_into().unwrap()) & 0o7777;
            let mode = guest_mode(mode, is_dir);
            file.set_permissions(fs::Permissions::from_mode(mode))
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
        let md = file.metadata().map_err(|e| io_err_to_linux(&e))?;
        if let Some(node) = self.nodes.get_mut(&nodeid) {
            node.owner.uid = uid;
            node.owner.gid = gid;
        }
        Ok(md)
    }

    fn clock_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    /// Mode and owner the current caller sees for node `nodeid` (see [`GuestOwner`]).
    /// Read-only tool shares stay root-owned: their attributes are cached for an
    /// hour and must not depend on who looked first.
    fn guest_attr(&mut self, nodeid: u64, st: &FuseStat) -> GuestAttr {
        if self.read_only {
            return GuestAttr {
                mode: st.mode,
                uid: 0,
                gid: 0,
            };
        }
        let caller = self.caller;
        let now = self.clock_ms();
        let window = self.adopt_window_ms;
        let (uid, gid, floating) = match self.nodes.get_mut(&nodeid) {
            Some(node) => {
                let owner = &mut node.owner;
                let floating = if caller.0 != 0 {
                    owner.recent_user = Some(caller);
                    owner.recent_at_ms = now;
                    caller
                } else {
                    match owner.recent_user {
                        Some(user) if now.saturating_sub(owner.recent_at_ms) < window => user,
                        _ => (0, 0),
                    }
                };
                (owner.uid, owner.gid, floating)
            }
            // A retired node reached through an open handle.
            None => (None, None, caller),
        };
        GuestAttr {
            mode: guest_mode(st.mode, mode_is_dir(st.mode)),
            uid: uid.unwrap_or(floating.0),
            gid: gid.unwrap_or(floating.1),
        }
    }

    fn encode_attr_stat(nodeid: u64, st: &FuseStat, attr: GuestAttr, out: &mut Vec<u8>) {
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
        read_only: bool,
        attr: GuestAttr,
        out: &mut Vec<u8>,
    ) {
        // fuse_entry_out (128 bytes); read-only tools shares get 3600s dentry/attr caching
        let (valid_secs, valid_nsecs) = cache_validity(read_only);
        out.extend_from_slice(&nodeid.to_le_bytes());
        out.extend_from_slice(&1u64.to_le_bytes()); // generation
        out.extend_from_slice(&valid_secs.to_le_bytes()); // entry_valid
        out.extend_from_slice(&valid_secs.to_le_bytes()); // attr_valid
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // entry_valid_nsec
        out.extend_from_slice(&valid_nsecs.to_le_bytes()); // attr_valid_nsec
        Self::encode_attr_stat(nodeid, st, attr, out);
    }

    /// Reply with a `fuse_entry_out` for node `id`.
    fn write_entry(&mut self, unique: u64, id: u64, st: &FuseStat) -> bool {
        let attr = self.guest_attr(id, st);
        let ro = self.read_only;
        self.begin_ok(unique);
        Self::encode_entry_out_stat(id, st, ro, attr, &mut self.resp_buf);
        self.finish_ok()
    }

    /// Reply with a `fuse_attr_out` for node `id`.
    fn write_attr(&mut self, unique: u64, id: u64, st: &FuseStat) -> bool {
        let (valid_secs, valid_nsecs) = cache_validity(self.read_only);
        let attr = self.guest_attr(id, st);
        self.begin_ok(unique);
        self.resp_buf.extend_from_slice(&valid_secs.to_le_bytes());
        self.resp_buf.extend_from_slice(&valid_nsecs.to_le_bytes());
        self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
        Self::encode_attr_stat(id, st, attr, &mut self.resp_buf);
        self.finish_ok()
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
        Ok((self.observe_child(parent, cname, &st), st))
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
                let cname = match CStr::from_bytes_until_nul(body) {
                    Ok(name) => Cow::Borrowed(name),
                    Err(_) => match CString::new(body) {
                        Ok(name) => Cow::Owned(name),
                        Err(_) => return self.write_err(unique, LINUX_EINVAL),
                    },
                };
                let name = cname.to_bytes();
                if self.read_only
                    && let Some(cached) =
                        self.ro_lookup_cache.get(&(nodeid, name.to_vec())).copied()
                {
                    return match cached {
                        Ok(id) => match self.ro_attr_cache.get(&id).copied() {
                            Some(st) => self.write_entry(unique, id, &st),
                            None => self.write_err(unique, LINUX_ENOENT),
                        },
                        Err(e) => self.write_err(unique, e),
                    };
                }
                match self.lookup_entry(nodeid, &cname) {
                    Ok((id, st)) => {
                        if self.read_only {
                            self.ro_lookup_cache
                                .insert((nodeid, cname.to_bytes().to_vec()), Ok(id));
                            self.ro_attr_cache.insert(id, st);
                        }
                        self.write_entry(unique, id, &st)
                    }
                    Err(le) => {
                        if self.read_only && self.ro_lookup_cache.len() < 4096 {
                            self.ro_lookup_cache
                                .insert((nodeid, cname.to_bytes().to_vec()), Err(le));
                        }
                        self.write_err(unique, le)
                    }
                }
            }
            FUSE_GETATTR => {
                if self.read_only
                    && let Some(st) = self.ro_attr_cache.get(&nodeid).copied()
                {
                    return self.write_attr(unique, nodeid, &st);
                }
                match self.node_stat(nodeid, body) {
                    Ok(st) => {
                        if self.read_only {
                            self.ro_attr_cache.insert(nodeid, st);
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
                    Ok(md) => {
                        let st = FuseStat::from_metadata(&md);
                        self.write_attr(unique, nodeid, &st)
                    }
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
                let file = match self.open_node(nodeid, base_darwin) {
                    Ok(file) => file,
                    Err(e) => {
                        let errno = self.open_failure(nodeid, e);
                        return self.write_err(unique, errno);
                    }
                };
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
                // O_NOFOLLOW: an existing symlink at the name is never opened through.
                let darwin_flags = match Self::linux_open_flags_to_darwin(flags | 0o100, false) {
                    Ok(f) => f | libc::O_NOFOLLOW,
                    Err(e) => return self.write_err(unique, e),
                };
                let create_mode = guest_mode(mode & 0o7777, false) as libc::c_uint;
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                let fd = unsafe {
                    libc::openat(pfd.as_raw_fd(), cname.as_ptr(), darwin_flags, create_mode)
                };
                if fd < 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                let file = unsafe { File::from_raw_fd(fd) };
                let st = match fstat_fd(file.as_raw_fd()) {
                    Ok(s) => s,
                    Err(e) => return self.write_err(unique, e),
                };
                let id = self.observe_child(nodeid, &cname, &st);
                let fh = self.next_fh;
                self.next_fh += 1;
                self.open_files.insert(
                    fh,
                    OpenFile {
                        nodeid: id,
                        file: Arc::new(file),
                    },
                );
                let attr = self.guest_attr(id, &st);
                let ro = self.read_only;
                self.begin_ok(unique);
                Self::encode_entry_out_stat(id, &st, ro, attr, &mut self.resp_buf);
                self.resp_buf.extend_from_slice(&fh.to_le_bytes());
                self.resp_buf.extend_from_slice(&0u32.to_le_bytes());
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
                    self.open_files.remove(&fh);
                }
                self.write_ok_slice(unique, &[])
            }
            FUSE_OPENDIR => {
                let dir_fd = match self.open_node(nodeid, libc::O_RDONLY | libc::O_DIRECTORY) {
                    Ok(dir) => OwnedFd::from(dir),
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
                        if self.dir_fds.len() >= MAX_CACHED_DIR_FDS {
                            self.dir_fds.clear();
                        }
                        self.dir_fds
                            .insert(nodeid, Arc::new(unsafe { OwnedFd::from_raw_fd(dup_fd) }));
                    }
                }
                let fh = self.next_fh;
                self.next_fh += 1;
                self.open_dirs.insert(
                    fh,
                    OpenDir {
                        dir_nodeid: nodeid,
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
                    let raw_fd = self.open_dirs[&fh].dir_fd.as_raw_fd();
                    #[cfg(target_vendor = "apple")]
                    let bulk_res = darwin_bulk::read_dir_bulk(raw_fd, &mut self.bulk_buf)
                        .or_else(|_| read_dir_entries_fd(raw_fd));
                    #[cfg(not(target_vendor = "apple"))]
                    let bulk_res = read_dir_entries_fd(raw_fd);
                    let entries = match bulk_res {
                        Ok(v) => v,
                        Err(e) => return self.write_err(unique, e),
                    };
                    if let Some(od) = self.open_dirs.get_mut(&fh) {
                        od.entries = Some(entries);
                    }
                }

                // Detach entries temporarily to avoid borrow conflict with `self.observe_child`
                let (dir_nodeid, entries) = {
                    let Some(od) = self.open_dirs.get_mut(&fh) else {
                        return self.write_err(unique, LINUX_EBADF);
                    };
                    (od.dir_nodeid, od.entries.take().unwrap_or_default())
                };

                let plus = opcode == FUSE_READDIRPLUS;
                let ro = self.read_only;
                self.begin_ok(unique);
                let body_start = self.resp_buf.len();
                for (i, e) in entries.iter().enumerate().skip(offset) {
                    let name = e.name.to_bytes();
                    let name_len = name.len();
                    let raw_ent = (if plus { 128 } else { 0 }) + 24 + name_len;
                    let padded = (raw_ent + 7) & !7;
                    if (self.resp_buf.len() - body_start) + padded > max_size {
                        break;
                    }
                    let ino = self.observe_child(dir_nodeid, &e.name, &e.stat);
                    if plus {
                        if ro {
                            self.ro_lookup_cache
                                .insert((dir_nodeid, name.to_vec()), Ok(ino));
                            self.ro_attr_cache.insert(ino, e.stat);
                        }
                        let attr = self.guest_attr(ino, &e.stat);
                        Self::encode_entry_out_stat(ino, &e.stat, ro, attr, &mut self.resp_buf);
                    }
                    let dtype = e.stat.dtype();
                    self.resp_buf.extend_from_slice(&ino.to_le_bytes());
                    self.resp_buf
                        .extend_from_slice(&((i + 1) as u64).to_le_bytes());
                    self.resp_buf
                        .extend_from_slice(&(name_len as u32).to_le_bytes());
                    self.resp_buf.extend_from_slice(&dtype.to_le_bytes());
                    self.resp_buf.extend_from_slice(name);
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
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                let dir_mode = guest_mode(mode & 0o7777, true) as libc::mode_t;
                if unsafe { libc::mkdirat(pfd.as_raw_fd(), cname.as_ptr(), dir_mode) } != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                match fstatat_cstr(pfd.as_raw_fd(), &cname) {
                    Ok(st) => {
                        let id = self.observe_child(nodeid, &cname, &st);
                        self.write_entry(unique, id, &st)
                    }
                    Err(e) => self.write_err(unique, e),
                }
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
                let flags = if opcode == FUSE_RMDIR {
                    libc::AT_REMOVEDIR
                } else {
                    0
                };
                if unsafe { libc::unlinkat(pfd.as_raw_fd(), cname.as_ptr(), flags) } != 0 {
                    return self.write_err(unique, last_os_errno_linux());
                }
                // Open handles to the removed file stay valid; its node does not.
                self.retire_child(nodeid, &cname);
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
                if let Err(e) = host_rename(
                    opfd.as_raw_fd(),
                    &old_cname,
                    npfd.as_raw_fd(),
                    &new_cname,
                    rename_flags,
                ) {
                    return self.write_err(unique, e);
                }
                if rename_flags & LINUX_RENAME_EXCHANGE != 0 {
                    self.exchange_children(nodeid, &old_cname, newdir, &new_cname);
                } else if (nodeid, &old_cname) != (newdir, &new_cname) {
                    // Renaming one hard link onto another of the same file is a no-op.
                    let unchanged = match (
                        fstatat_cstr(opfd.as_raw_fd(), &old_cname),
                        fstatat_cstr(npfd.as_raw_fd(), &new_cname),
                    ) {
                        (Ok(old), Ok(new)) => (old.dev, old.ino) == (new.dev, new.ino),
                        _ => false,
                    };
                    if !unchanged {
                        self.move_child(nodeid, &old_cname, newdir, new_cname);
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
                let pfd = match self.dir_fd(nodeid) {
                    Ok(fd) => fd,
                    Err(e) => return self.write_err(unique, e),
                };
                if unsafe { libc::symlinkat(ctarget.as_ptr(), pfd.as_raw_fd(), cname.as_ptr()) }
                    != 0
                {
                    return self.write_err(unique, last_os_errno_linux());
                }
                match fstatat_cstr(pfd.as_raw_fd(), &cname) {
                    Ok(st) => {
                        let id = self.observe_child(nodeid, &cname, &st);
                        self.write_entry(unique, id, &st)
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
                let cname = match entry_name(name) {
                    Ok(c) => c,
                    Err(e) => return self.write_err(unique, e),
                };
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
                match fstatat_cstr(npfd.as_raw_fd(), &cname) {
                    Ok(st) => {
                        let id = self.observe_child(nodeid, &cname, &st);
                        self.write_entry(unique, id, &st)
                    }
                    Err(e) => self.write_err(unique, e),
                }
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

        // Immutable shares negotiate FUSE_NO_OPEN_SUPPORT. Their regular files
        // have no server-side handle, so open the known leaf only for this sync.
        if !self.nodes.contains_key(&nodeid) {
            return Err(LINUX_EBADF);
        }
        let file = self.open_node(nodeid, libc::O_RDONLY | libc::O_NONBLOCK)?;
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
            if !self.nodes.contains_key(&nodeid) {
                return Err(LINUX_ENOENT);
            }
            let arc_f = Arc::new(self.open_node(nodeid, libc::O_RDONLY)?);
            if self.ro_file_cache.len() < 256 {
                self.ro_file_cache.insert(nodeid, arc_f.clone());
            }
            Ok(arc_f)
        } else {
            Err(LINUX_EBADF)
        }
    }

    /// Snapshot of the node table: `next_nodeid`, `next_fh`, each node's path
    /// relative to the share root (so a restored guest keeps its dentries), then
    /// the owner fields guest `chown`s pinned (a section older blobs lack).
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
        let mut owners: Vec<(u64, GuestOwner)> = self
            .nodes
            .iter()
            .filter(|(_, n)| n.owner.uid.is_some() || n.owner.gid.is_some())
            .map(|(&id, n)| (id, n.owner))
            .collect();
        owners.sort_by_key(|(id, _)| *id);
        blob.extend_from_slice(SNAPSHOT_OWNERS_TAG);
        blob.extend_from_slice(&(owners.len() as u32).to_le_bytes());
        for (id, owner) in owners {
            let flags = u8::from(owner.uid.is_some()) | (u8::from(owner.gid.is_some()) << 1);
            blob.extend_from_slice(&id.to_le_bytes());
            blob.push(flags);
            blob.extend_from_slice(&owner.uid.unwrap_or(0).to_le_bytes());
            blob.extend_from_slice(&owner.gid.unwrap_or(0).to_le_bytes());
        }
        blob
    }

    fn restore_blob(&mut self, blob: &[u8]) {
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
            let identity = if self.read_only {
                None
            } else {
                // On mutable workspace shares (e.g. a fork pointed at a fresh host directory),
                // only restore nodes that exist under the new root so missing files return
                // clean ESTALE/ENOENT and new files with the same name bind fresh host inodes.
                let Ok(pfd) = self.dir_fd(parent) else {
                    continue;
                };
                let Ok(st) = fstatat_cstr(pfd.as_raw_fd(), &name) else {
                    continue;
                };
                Some((st.dev, st.ino))
            };
            self.insert_node(id, parent, name, identity);
            by_path.insert(rel, id);
        }
        if blob.len() >= pos + 8 && &blob[pos..pos + 4] == SNAPSHOT_OWNERS_TAG {
            let owners = u32::from_le_bytes(blob[pos + 4..pos + 8].try_into().unwrap());
            pos += 8;
            for _ in 0..owners {
                if pos + 17 > blob.len() {
                    break;
                }
                let id = u64::from_le_bytes(blob[pos..pos + 8].try_into().unwrap());
                let flags = blob[pos + 8];
                let uid = u32::from_le_bytes(blob[pos + 9..pos + 13].try_into().unwrap());
                let gid = u32::from_le_bytes(blob[pos + 13..pos + 17].try_into().unwrap());
                pos += 17;
                if let Some(node) = self.nodes.get_mut(&id) {
                    node.owner.uid = (flags & 1 != 0).then_some(uid);
                    node.owner.gid = (flags & 2 != 0).then_some(gid);
                }
            }
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
        self.shared.core.lock().unwrap().snapshot_blob()
    }
    fn snapshot_resume(&mut self) {
        self.shared.paused.store(false, Ordering::Release);
        let mut st = self.shared.state.0.lock().unwrap();
        st.kicked = true;
        self.shared.state.1.notify_all();
    }
    fn snapshot_restore(&mut self, blob: &[u8], queues: &[VirtQueue]) {
        self.shared.core.lock().unwrap().restore_blob(blob);
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
    use std::ffi::OsStr;

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
            assert_eq!(nodeid, attr_ino);
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
        let mut entries = read_dir_entries_fd(fd.as_raw_fd()).unwrap();
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
    fn chown_pins_only_the_named_field_and_self_chown_pins_nothing() {
        let (base, share, _) = scratch("pin");
        for name in ["u", "g", "self"] {
            fs::write(share.join(name), b"x").unwrap();
        }
        let mut fsys = writable(&share);
        let u = lookup_in(&mut fsys, ROOT, b"u").unwrap();
        let g = lookup_in(&mut fsys, ROOT, b"g").unwrap();
        let me = lookup_in(&mut fsys, ROOT, b"self").unwrap();
        // `chown 999 u` keeps the group floating; `chgrp 5 g` keeps the user floating.
        chown_as(&mut fsys, u, (Some(999), None), (0, 0));
        chown_as(&mut fsys, g, (None, Some(5)), (0, 0));
        core(&fsys).adopt_window_ms = 0;
        assert_eq!(getattr_as(&mut fsys, u, (1000, 1000)).0, (999, 1000));
        assert_eq!(getattr_as(&mut fsys, u, (0, 0)).0, (999, 0));
        assert_eq!(getattr_as(&mut fsys, g, (1000, 1000)).0, (1000, 5));
        assert_eq!(getattr_as(&mut fsys, g, (70, 70)).0, (70, 5));
        // A non-root `chown 1000:1000` of a file it already sees as its own is a no-op.
        chown_as(&mut fsys, me, (Some(1000), Some(1000)), (1000, 1000));
        assert_eq!(getattr_as(&mut fsys, me, (70, 70)).0, (70, 70));
        // Root pinning root is a real change.
        chown_as(&mut fsys, me, (Some(0), Some(0)), (0, 0));
        assert_eq!(getattr_as(&mut fsys, me, (70, 70)).0, (0, 0));
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
        assert_eq!(getattr_as(&mut restored, grp, (1000, 1000)).0, (1000, 5));
        assert_eq!(getattr_as(&mut restored, ROOT, (1000, 1000)).0, (70, 70));
        // A blob from before pinned owners existed still restores its nodes.
        let tag = blob
            .windows(4)
            .rposition(|w| w == SNAPSHOT_OWNERS_TAG)
            .unwrap();
        let mut legacy = writable(&share);
        core(&legacy).restore_blob(&blob[..tag]);
        assert_eq!(getattr_as(&mut legacy, data, (1000, 1000)).0, (1000, 1000));

        // Removing the file removes what was recorded for it; the name binds afresh.
        assert_eq!(errno(&request(&mut fsys, FUSE_UNLINK, ROOT, b"data\0")), 0);
        assert!(!core(&fsys).nodes.contains_key(&data));
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
}
