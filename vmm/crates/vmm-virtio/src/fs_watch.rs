//! Real-time macOS host filesystem watcher for Virtio-FS cache invalidation.
//!
//! Combines two zero-extra-FD mechanisms:
//! 1. `KqueueVnodeWatcher`: watches live `open_files` descriptors via Darwin
//!    `kqueue(EVFILT_VNODE)` (~20-60 us latency for held-fd writes, appends,
//!    exact-mtime `utimensat`, unlinks, and atomic renames).
//! 2. `FseEventsWatcher`: watches the entire workspace directory tree via macOS
//!    `FSEventStreamCreate` (`FileEvents | NoDefer`, `latency = 0.0`, ~1-4 ms
//!    latency, zero file descriptors, no `.fseventsd` disk writes on volumes
//!    with `.fseventsd/no_log`).

use std::collections::HashMap;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

#[cfg(target_vendor = "apple")]
pub const FSEVENT_FLAG_RESCAN: u32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004 | 0x0000_0020;
#[cfg(target_vendor = "apple")]
pub const FSEVENT_FLAG_ITEM_REMOVED_OR_RENAMED: u32 = 0x0000_0200 | 0x0000_0800;

/// Event delivered by `KqueueVnodeWatcher` for a watched open file descriptor.
#[derive(Clone, Copy, Debug)]
pub struct VnodeEvent {
    pub nodeid: u64,
    pub identity: (u64, u64),
    pub fflags: u32,
}

#[cfg(target_vendor = "apple")]
const VNODE_FFLAGS: u32 = libc::NOTE_DELETE
    | libc::NOTE_WRITE
    | libc::NOTE_EXTEND
    | libc::NOTE_ATTRIB
    | libc::NOTE_LINK
    | libc::NOTE_RENAME
    | libc::NOTE_REVOKE;

#[cfg(target_vendor = "apple")]
const WAKE_IDENT: usize = 0x4d50_574b; // "MPWK"

struct WatchedFd {
    nodeid: u64,
    identity: (u64, u64),
    refs: u32,
}

/// Watches currently-open regular file descriptors via `kqueue(EVFILT_VNODE)`
/// without opening any extra host file descriptors.
pub struct KqueueVnodeWatcher {
    #[cfg(target_vendor = "apple")]
    kq: RawFd,
    #[cfg(target_vendor = "apple")]
    fds: Arc<Mutex<HashMap<RawFd, WatchedFd>>>,
    #[cfg(target_vendor = "apple")]
    shutdown: Arc<AtomicBool>,
    #[cfg(target_vendor = "apple")]
    handle: Option<thread::JoinHandle<()>>,
}

#[cfg(target_vendor = "apple")]
impl KqueueVnodeWatcher {
    pub fn start<F>(on_event: F) -> std::io::Result<Self>
    where
        F: Fn(VnodeEvent) + Send + 'static,
    {
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return Err(std::io::Error::last_os_error());
        }
        unsafe {
            let _ = libc::fcntl(kq, libc::F_SETFD, libc::FD_CLOEXEC);
        }
        // Register EVFILT_USER wake event for instant lock-free Drop wakeup.
        let wake_reg = libc::kevent {
            ident: WAKE_IDENT,
            filter: libc::EVFILT_USER,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: 0,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        if unsafe { libc::kevent(kq, &wake_reg, 1, std::ptr::null_mut(), 0, std::ptr::null()) } < 0
        {
            let err = std::io::Error::last_os_error();
            unsafe { libc::close(kq) };
            return Err(err);
        }

        let fds = Arc::new(Mutex::new(HashMap::<RawFd, WatchedFd>::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let fds_t = fds.clone();
        let shut_t = shutdown.clone();
        let handle = thread::Builder::new()
            .name("vmm-fs-kq".into())
            .spawn(move || {
                unsafe {
                    libc::pthread_set_qos_class_self_np(
                        libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE,
                        0,
                    );
                }
                let mut events = [libc::kevent {
                    ident: 0,
                    filter: 0,
                    flags: 0,
                    fflags: 0,
                    data: 0,
                    udata: std::ptr::null_mut(),
                }; 32];
                loop {
                    if shut_t.load(Ordering::Acquire) {
                        break;
                    }
                    let n = unsafe {
                        libc::kevent(
                            kq,
                            std::ptr::null(),
                            0,
                            events.as_mut_ptr(),
                            events.len() as libc::c_int,
                            std::ptr::null(),
                        )
                    };
                    if n < 0 {
                        let err = std::io::Error::last_os_error();
                        if err.raw_os_error() == Some(libc::EINTR) {
                            continue;
                        }
                        break;
                    }
                    if shut_t.load(Ordering::Acquire) {
                        break;
                    }
                    let mut batch = Vec::with_capacity(n as usize);
                    {
                        let map = fds_t.lock().unwrap();
                        for ev in &events[..n as usize] {
                            if ev.filter != libc::EVFILT_VNODE {
                                continue;
                            }
                            let fd = ev.ident as RawFd;
                            if let Some(w) = map.get(&fd) {
                                batch.push(VnodeEvent {
                                    nodeid: w.nodeid,
                                    identity: w.identity,
                                    fflags: ev.fflags,
                                });
                            }
                        }
                    }
                    for ev in batch {
                        on_event(ev);
                    }
                }
            })
            .inspect_err(|_| {
                unsafe { libc::close(kq) };
            })?;

        Ok(Self {
            kq,
            fds,
            shutdown,
            handle: Some(handle),
        })
    }

    pub fn watch_fd(&self, fd: RawFd, nodeid: u64, identity: (u64, u64)) {
        let mut map = self.fds.lock().unwrap();
        if let Some(existing) = map.get_mut(&fd) {
            existing.refs = existing.refs.saturating_add(1);
            existing.nodeid = nodeid;
            existing.identity = identity;
            return;
        }
        let reg = libc::kevent {
            ident: fd as usize,
            filter: libc::EVFILT_VNODE,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: VNODE_FFLAGS,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        if unsafe { libc::kevent(self.kq, &reg, 1, std::ptr::null_mut(), 0, std::ptr::null()) } == 0
        {
            map.insert(
                fd,
                WatchedFd {
                    nodeid,
                    identity,
                    refs: 1,
                },
            );
        }
    }

    pub fn unwatch_fd(&self, fd: RawFd) {
        let mut map = self.fds.lock().unwrap();
        let remove = match map.get_mut(&fd) {
            Some(existing) if existing.refs > 1 => {
                existing.refs -= 1;
                false
            }
            Some(_) => true,
            None => false,
        };
        if remove {
            map.remove(&fd);
            let del = libc::kevent {
                ident: fd as usize,
                filter: libc::EVFILT_VNODE,
                flags: libc::EV_DELETE,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            unsafe {
                let _ = libc::kevent(self.kq, &del, 1, std::ptr::null_mut(), 0, std::ptr::null());
            }
        }
    }
}

#[cfg(target_vendor = "apple")]
impl Drop for KqueueVnodeWatcher {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        let trigger = libc::kevent {
            ident: WAKE_IDENT,
            filter: libc::EVFILT_USER,
            flags: 0,
            fflags: libc::NOTE_TRIGGER,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        unsafe {
            let _ = libc::kevent(
                self.kq,
                &trigger,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            );
        }
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        unsafe {
            libc::close(self.kq);
        }
    }
}

#[cfg(not(target_vendor = "apple"))]
impl KqueueVnodeWatcher {
    pub fn start<F>(_on_event: F) -> std::io::Result<Self>
    where
        F: Fn(VnodeEvent) + Send + 'static,
    {
        Ok(Self {})
    }
    pub fn watch_fd(&self, _fd: RawFd, _nodeid: u64, _identity: (u64, u64)) {}
    pub fn unwatch_fd(&self, _fd: RawFd) {}
}

// ============================================================================
// macOS CoreServices FSEventStream zero-FD workspace tree watcher
// ============================================================================

#[cfg(target_vendor = "apple")]
mod darwin_fsevents {
    use std::ffi::{CStr, CString, c_char, c_void};
    use std::sync::atomic::{AtomicBool, Ordering};

    type CFAllocatorRef = *const c_void;
    type CFStringRef = *const c_void;
    type CFArrayRef = *const c_void;
    type FSEventStreamRef = *mut c_void;
    type DispatchQueueT = *mut c_void;

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const K_FS_EVENT_STREAM_EVENT_ID_SINCE_NOW: u64 = u64::MAX;
    const K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER: u32 = 0x0000_0002;
    const K_FS_EVENT_STREAM_CREATE_FLAG_FILE_EVENTS: u32 = 0x0000_0010;

    #[repr(C)]
    struct FSEventStreamContext {
        version: libc::c_long,
        info: *mut c_void,
        retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
        release: Option<extern "C" fn(*const c_void)>,
        copy_description: Option<extern "C" fn(*const c_void) -> CFStringRef>,
    }

    type FSEventStreamCallback = extern "C" fn(
        stream: FSEventStreamRef,
        client_info: *mut c_void,
        num_events: usize,
        event_paths: *mut c_void,
        event_flags: *const u32,
        event_ids: *const u64,
    );

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFTypeArrayCallBacks: c_void;
        fn CFStringCreateWithBytes(
            alloc: CFAllocatorRef,
            bytes: *const u8,
            num_bytes: isize,
            encoding: u32,
            is_external: u8,
        ) -> CFStringRef;
        fn CFArrayCreate(
            alloc: CFAllocatorRef,
            values: *const *const c_void,
            num_values: isize,
            callbacks: *const c_void,
        ) -> CFArrayRef;
        fn CFRelease(cf: *const c_void);
    }

    #[link(name = "CoreServices", kind = "framework")]
    unsafe extern "C" {
        fn FSEventStreamCreate(
            allocator: CFAllocatorRef,
            callback: FSEventStreamCallback,
            context: *mut FSEventStreamContext,
            paths_to_watch: CFArrayRef,
            since_when: u64,
            latency: f64,
            flags: u32,
        ) -> FSEventStreamRef;
        fn FSEventStreamSetDispatchQueue(stream: FSEventStreamRef, q: DispatchQueueT);
        fn FSEventStreamStart(stream: FSEventStreamRef) -> u8;
        fn FSEventStreamStop(stream: FSEventStreamRef);
        fn FSEventStreamInvalidate(stream: FSEventStreamRef);
        fn FSEventStreamRelease(stream: FSEventStreamRef);
    }

    unsafe extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> DispatchQueueT;
        fn dispatch_sync_f(
            queue: DispatchQueueT,
            context: *mut c_void,
            work: extern "C" fn(*mut c_void),
        );
        fn dispatch_release(object: DispatchQueueT);
    }

    extern "C" fn noop_barrier(_ctx: *mut c_void) {}

    /// Receives one FSEvents batch of (path, flags) pairs.
    type BatchCallback = Box<dyn Fn(&[(&[u8], u32)]) + Send + Sync>;

    struct CallbackBox {
        stopped: AtomicBool,
        cb: BatchCallback,
    }

    extern "C" fn stream_trampoline(
        _stream: FSEventStreamRef,
        client_info: *mut c_void,
        num_events: usize,
        event_paths: *mut c_void,
        event_flags: *const u32,
        _event_ids: *const u64,
    ) {
        if client_info.is_null()
            || num_events == 0
            || event_paths.is_null()
            || event_flags.is_null()
        {
            return;
        }
        let state = unsafe { &*(client_info as *const CallbackBox) };
        if state.stopped.load(Ordering::Acquire) {
            return;
        }
        let paths_ptr = event_paths as *const *const c_char;
        let mut batch: Vec<(&[u8], u32)> = Vec::with_capacity(num_events);
        for i in 0..num_events {
            let p = unsafe { *paths_ptr.add(i) };
            let flags = unsafe { *event_flags.add(i) };
            if !p.is_null() {
                let bytes = unsafe { CStr::from_ptr(p) }.to_bytes();
                batch.push((bytes, flags));
            }
        }
        if !batch.is_empty() {
            (state.cb)(&batch);
        }
    }

    pub struct FseEventsWatcher {
        stream: FSEventStreamRef,
        queue: DispatchQueueT,
        cb_ptr: *mut CallbackBox,
    }

    // SAFETY: stream/queue are only torn down once in Drop with a GCD sync barrier.
    unsafe impl Send for FseEventsWatcher {}
    unsafe impl Sync for FseEventsWatcher {}

    impl FseEventsWatcher {
        pub fn start<F>(root_path: &[u8], on_batch: F) -> std::io::Result<Self>
        where
            F: Fn(&[(&[u8], u32)]) + Send + Sync + 'static,
        {
            if root_path.is_empty() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "empty root path for FSEvents watcher",
                ));
            }
            let cf_str = unsafe {
                CFStringCreateWithBytes(
                    std::ptr::null(),
                    root_path.as_ptr(),
                    root_path.len() as isize,
                    K_CF_STRING_ENCODING_UTF8,
                    0,
                )
            };
            if cf_str.is_null() {
                return Err(std::io::Error::other("CFStringCreateWithBytes failed"));
            }
            let values = [cf_str];
            let cf_arr = unsafe {
                CFArrayCreate(
                    std::ptr::null(),
                    values.as_ptr(),
                    1,
                    &raw const kCFTypeArrayCallBacks,
                )
            };
            unsafe { CFRelease(cf_str) };
            if cf_arr.is_null() {
                return Err(std::io::Error::other("CFArrayCreate failed"));
            }

            let cb_ptr = Box::into_raw(Box::new(CallbackBox {
                stopped: AtomicBool::new(false),
                cb: Box::new(on_batch),
            }));
            let mut ctx = FSEventStreamContext {
                version: 0,
                info: cb_ptr.cast(),
                retain: None,
                release: None,
                copy_description: None,
            };
            let stream = unsafe {
                FSEventStreamCreate(
                    std::ptr::null(),
                    stream_trampoline,
                    &mut ctx,
                    cf_arr,
                    K_FS_EVENT_STREAM_EVENT_ID_SINCE_NOW,
                    0.0,
                    K_FS_EVENT_STREAM_CREATE_FLAG_FILE_EVENTS
                        | K_FS_EVENT_STREAM_CREATE_FLAG_NO_DEFER,
                )
            };
            unsafe { CFRelease(cf_arr) };
            if stream.is_null() {
                unsafe { drop(Box::from_raw(cb_ptr)) };
                return Err(std::io::Error::other("FSEventStreamCreate failed"));
            }

            let label = CString::new("com.micropod.vmm.fsevents").unwrap();
            let queue = unsafe { dispatch_queue_create(label.as_ptr(), std::ptr::null()) };
            if queue.is_null() {
                unsafe {
                    FSEventStreamRelease(stream);
                    drop(Box::from_raw(cb_ptr));
                }
                return Err(std::io::Error::other("dispatch_queue_create failed"));
            }

            unsafe {
                FSEventStreamSetDispatchQueue(stream, queue);
                if FSEventStreamStart(stream) == 0 {
                    FSEventStreamInvalidate(stream);
                    FSEventStreamRelease(stream);
                    dispatch_release(queue);
                    drop(Box::from_raw(cb_ptr));
                    return Err(std::io::Error::other("FSEventStreamStart failed"));
                }
            }

            Ok(Self {
                stream,
                queue,
                cb_ptr,
            })
        }
    }

    impl Drop for FseEventsWatcher {
        fn drop(&mut self) {
            unsafe {
                (*self.cb_ptr).stopped.store(true, Ordering::Release);
                FSEventStreamStop(self.stream);
                FSEventStreamInvalidate(self.stream);
                FSEventStreamRelease(self.stream);
                // Drain any in-flight callback on the serial GCD queue before freeing `cb_ptr`.
                dispatch_sync_f(self.queue, std::ptr::null_mut(), noop_barrier);
                dispatch_release(self.queue);
                drop(Box::from_raw(self.cb_ptr));
            }
        }
    }
}

#[cfg(target_vendor = "apple")]
pub use darwin_fsevents::FseEventsWatcher;

#[cfg(not(target_vendor = "apple"))]
pub struct FseEventsWatcher;

#[cfg(not(target_vendor = "apple"))]
impl FseEventsWatcher {
    pub fn start<F>(_root_path: &[u8], _on_batch: F) -> std::io::Result<Self>
    where
        F: Fn(&[(&[u8], u32)]) + Send + Sync + 'static,
    {
        Ok(Self)
    }
}
