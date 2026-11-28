//! Virtio-MMIO v2 transport, split virtqueue engine, and zero-copy device
//! implementations: RNG, Block, Balloon (Free-Page Reporting: reported pages go back to the host),
//! Vsock (host<->guest Unix socket & port-broker mux), and Virtio-FS (FUSE).

mod blk_flush;
mod fs_watch;
pub mod virtiofs;
pub mod vsock;

use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub use blk_flush::DiskFlush;
use blk_flush::FlushPolicy;

const VIRTIO_MMIO_MAGIC: u32 = 0x7472_6976; // "virt"
const VIRTIO_MMIO_VERSION: u32 = 2;
const VIRTIO_MMIO_VENDOR: u32 = 0x4d50_4f44; // "MPOD"

const VIRTIO_F_VERSION_1: u64 = 1 << 32;
const VIRTIO_F_EVENT_IDX: u64 = 1 << 29;
const VIRTIO_RING_F_INDIRECT_DESC: u64 = 1 << 28;

const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;
const VIRTQ_DESC_F_INDIRECT: u16 = 4;

const MADV_FREE: i32 = 5; // Darwin MADV_FREE

unsafe extern "C" {
    fn madvise(addr: *mut std::ffi::c_void, len: usize, advice: i32) -> i32;
    fn arc4random_buf(buf: *mut std::ffi::c_void, nbytes: usize);
}

/// Thread-safe level-triggered GICv3 SPI interrupt line for a Virtio-MMIO device.
/// Serializes ISR updates with `hv_gic_set_spi` so background I/O threads and vCPU
/// interrupt acknowledgments can never race and lose a level-triggered SPI.
#[derive(Clone)]
pub struct IrqLine {
    pub spi_intid: u32,
    isr: Arc<Mutex<u32>>,
}

impl IrqLine {
    pub fn new(spi_intid: u32) -> Self {
        Self {
            spi_intid,
            isr: Arc::new(Mutex::new(0)),
        }
    }

    #[inline]
    pub fn raise_used_buffer(&self) {
        let mut g = self.isr.lock().unwrap();
        *g |= 1;
        let _ = unsafe { hvf_sys::hv_gic_set_spi(self.spi_intid, true) };
    }

    #[inline]
    pub fn status(&self) -> u32 {
        *self.isr.lock().unwrap()
    }

    #[inline]
    pub fn ack(&self, bits: u32) {
        let mut g = self.isr.lock().unwrap();
        *g &= !bits;
        let _ = unsafe { hvf_sys::hv_gic_set_spi(self.spi_intid, *g != 0) };
    }

    #[inline]
    pub fn clear(&self) {
        let mut g = self.isr.lock().unwrap();
        *g = 0;
        let _ = unsafe { hvf_sys::hv_gic_set_spi(self.spi_intid, false) };
    }

    /// Restore cached ISR status bits during VM snapshot restore without pulsing the GIC
    /// (whose distributor/redistributor state is restored directly via `hv_gic_set_state`).
    #[inline]
    pub fn set_isr_silent(&self, val: u32) {
        *self.isr.lock().unwrap() = val;
    }
}

/// Shared view of guest physical memory backed by `hv_vm_allocate`.
pub struct GuestMemory {
    base_ptr: *mut u8,
    ram_base: u64,
    ram_size: usize,
    /// The guest's RAM itself (`new_guest_ram`): free pages it reports are
    /// given back to the host at once (`reclaim`). Any other view (tests,
    /// borrowed buffers) only advises the kernel.
    remap_on_reclaim: bool,
}

/// Bytes of guest RAM given back to the host by `GuestMemory::reclaim`, and
/// reclaims that could not be done (the range was left as it was).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Reclaimed {
    pub bytes: usize,
    pub failed: bool,
}

unsafe impl Send for GuestMemory {}
unsafe impl Sync for GuestMemory {}

impl GuestMemory {
    /// Create a shared view of guest physical memory.
    ///
    /// # Safety
    /// `base_ptr` must reference a live, contiguous allocation of at least `ram_size`
    /// bytes for every use of the returned object, and `ram_base` must be the guest
    /// physical address corresponding to its first byte. Callers must treat the
    /// mapping as shared mutable memory owned by the virtual machine.
    pub unsafe fn new(base_ptr: *mut u8, ram_base: u64, ram_size: usize) -> Self {
        Self {
            base_ptr,
            ram_base,
            ram_size,
            remap_on_reclaim: false,
        }
    }

    /// The guest's RAM: `ram_size` bytes at `base_ptr`, mapped into the guest
    /// at `ram_base` with `hv_vm_map(.., HV_MEMORY_RWX)`. `reclaim` replaces
    /// reported free ranges of it with fresh zero-fill pages.
    ///
    /// # Safety
    /// As `new`, and the range must be a private anonymous (or private file)
    /// `mmap` the VM owns for its whole life and maps nowhere else: `reclaim`
    /// maps over parts of it with `MAP_FIXED` and maps them into the guest
    /// again. Memory from `hv_vm_allocate` does not qualify (macOS ignores
    /// madvise on it and keeps charging the footprint for pages replaced
    /// under it).
    pub unsafe fn new_guest_ram(base_ptr: *mut u8, ram_base: u64, ram_size: usize) -> Self {
        Self {
            base_ptr,
            ram_base,
            ram_size,
            remap_on_reclaim: true,
        }
    }

    #[inline]
    pub fn ram_base(&self) -> u64 {
        self.ram_base
    }

    #[inline]
    pub fn ram_size(&self) -> usize {
        self.ram_size
    }

    #[inline]
    pub fn translate(&self, ipa: u64, len: usize) -> Option<*mut u8> {
        let off = ipa.checked_sub(self.ram_base)? as usize;
        let end = off.checked_add(len)?;
        if end > self.ram_size {
            return None;
        }
        Some(unsafe { self.base_ptr.add(off) })
    }

    #[inline]
    pub fn read_slice(&self, ipa: u64, len: usize) -> Option<&[u8]> {
        let ptr = self.translate(ipa, len)?;
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    }

    // Guest RAM is intrinsically shared mutable machine memory; unlike ordinary Rust
    // memory it is also written by the hypervisor and by independent device workers.
    // The returned slice is a transient access window rather than an exclusive owner.
    #[allow(clippy::mut_from_ref)]
    #[inline]
    pub fn write_slice(&self, ipa: u64, len: usize) -> Option<&mut [u8]> {
        let ptr = self.translate(ipa, len)?;
        Some(unsafe { std::slice::from_raw_parts_mut(ptr, len) })
    }

    #[inline]
    pub fn read_u16_acquire(&self, ipa: u64) -> Option<u16> {
        if ipa & 1 != 0 {
            return None;
        }
        let ptr = self.translate(ipa, 2)?;
        let atomic = unsafe { &*(ptr as *const AtomicU16) };
        Some(u16::from_le(atomic.load(Ordering::Acquire)))
    }

    #[inline]
    pub fn write_u16_release(&self, ipa: u64, val: u16) -> Option<()> {
        if ipa & 1 != 0 {
            return None;
        }
        let ptr = self.translate(ipa, 2)?;
        let atomic = unsafe { &*(ptr as *const AtomicU16) };
        atomic.store(val.to_le(), Ordering::Release);
        Some(())
    }

    #[inline]
    pub fn read_u16(&self, ipa: u64) -> Option<u16> {
        let s = self.read_slice(ipa, 2)?;
        Some(u16::from_le_bytes([s[0], s[1]]))
    }

    #[inline]
    pub fn read_u32(&self, ipa: u64) -> Option<u32> {
        let s = self.read_slice(ipa, 4)?;
        Some(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }

    #[inline]
    pub fn read_u64(&self, ipa: u64) -> Option<u64> {
        let s = self.read_slice(ipa, 8)?;
        Some(u64::from_le_bytes(s.try_into().ok()?))
    }

    #[inline]
    pub fn write_u16(&self, ipa: u64, val: u16) -> Option<()> {
        let s = self.write_slice(ipa, 2)?;
        s.copy_from_slice(&val.to_le_bytes());
        Some(())
    }

    #[inline]
    pub fn write_u32(&self, ipa: u64, val: u32) -> Option<()> {
        let s = self.write_slice(ipa, 4)?;
        s.copy_from_slice(&val.to_le_bytes());
        Some(())
    }

    /// Give a range the guest reported free (free page reporting, or a
    /// balloon inflate) back to the host. The range is aligned inward to the
    /// host's 16 KiB pages, so no neighbouring live data is touched.
    ///
    /// On the guest's RAM (`new_guest_ram`) the pages are freed at once:
    /// the range is taken out of the guest's stage-2 mapping, replaced with
    /// fresh zero-fill pages (`mmap(MAP_FIXED)`, which frees the old ones and
    /// their footprint) and mapped into the guest again. Without the unmap,
    /// Hypervisor.framework keeps translating the guest's accesses to the old
    /// pages while the VMM's devices write the new ones. The guest does not
    /// touch a range while it reports it (the pages are off its free lists
    /// until the device answers), and afterwards it may use the pages again
    /// with any contents, which zero pages are. Elsewhere this only advises
    /// the kernel (`MADV_FREE`), which macOS acts on only under pressure.
    pub fn reclaim(&self, ipa: u64, len: usize) -> Reclaimed {
        const HOST_PAGE: usize = 16 * 1024;
        let none = Reclaimed::default();
        let Some(off) = ipa.checked_sub(self.ram_base).map(|v| v as usize) else {
            return none;
        };
        let Some(end) = off.checked_add(len) else {
            return none;
        };
        if end > self.ram_size {
            return none;
        }
        let aligned_start = (off + HOST_PAGE - 1) & !(HOST_PAGE - 1);
        let aligned_end = end & !(HOST_PAGE - 1);
        if aligned_end <= aligned_start {
            return none;
        }
        let reclaim_len = aligned_end - aligned_start;
        let addr = unsafe { self.base_ptr.add(aligned_start) };
        if !self.remap_on_reclaim {
            let rc = unsafe { madvise(addr.cast(), reclaim_len, MADV_FREE) };
            return Reclaimed {
                bytes: if rc == 0 { reclaim_len } else { 0 },
                failed: rc != 0,
            };
        }
        if !host_backed(addr, reclaim_len) {
            // Nothing of it is in host memory (never touched, or freed
            // before): there is nothing to give back, and remapping it would
            // only split the mapping (the whole of free memory is reported
            // at boot).
            return none;
        }
        let range_ipa = self.ram_base + aligned_start as u64;
        if unsafe { hvf_sys::hv_vm_unmap(range_ipa, reclaim_len) } != hvf_sys::HV_SUCCESS {
            return Reclaimed {
                bytes: 0,
                failed: true,
            };
        }
        let fresh = unsafe {
            libc::mmap(
                addr.cast(),
                reclaim_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_FIXED | libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            )
        };
        let replaced = fresh == addr.cast();
        // Map the range back whether or not the pages were replaced (a failed
        // MAP_FIXED leaves the old mapping): the guest may use it again as
        // soon as the report is answered.
        let mut mapped = false;
        for _ in 0..8 {
            if unsafe {
                hvf_sys::hv_vm_map(addr.cast(), range_ipa, reclaim_len, hvf_sys::HV_MEMORY_RWX)
            } == hvf_sys::HV_SUCCESS
            {
                mapped = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        if !mapped {
            // The guest would fault on its own RAM: stop loudly rather than
            // run a guest with a hole in its memory.
            eprintln!(
                "[micropod-vmm] FATAL: cannot map reclaimed guest RAM {range_ipa:#x}+{reclaim_len:#x} back into the guest"
            );
            std::process::abort();
        }
        Reclaimed {
            bytes: if replaced { reclaim_len } else { 0 },
            failed: !replaced,
        }
    }
}

/// Whether any page of `len` bytes at `addr` (host-page aligned) is in host
/// memory, resident or compressed. On an error, assume it is.
fn host_backed(addr: *mut u8, len: usize) -> bool {
    const HOST_PAGE: usize = 16 * 1024;
    const MINCORE_INCORE: u8 = 0x1;
    const MINCORE_PAGED_OUT: u8 = 0x20;
    let mut vec = vec![0u8; len.div_ceil(HOST_PAGE)];
    let rc = unsafe { libc::mincore(addr.cast(), len, vec.as_mut_ptr().cast()) };
    rc != 0
        || vec
            .iter()
            .any(|v| v & (MINCORE_INCORE | MINCORE_PAGED_OUT) != 0)
}

#[derive(Debug, Clone, Copy)]
pub struct DescBuf {
    pub addr: u64,
    pub len: u32,
    pub is_write: bool,
}

#[derive(Debug, Clone)]
pub struct VirtQueue {
    pub max_size: u16,
    pub size: u16,
    pub ready: bool,
    pub desc_addr: u64,
    pub avail_addr: u64,
    pub used_addr: u64,
    pub next_avail: u16,
    pub next_used: u16,
    // The snapshot already saves the negotiated features for the entire device.
    event_idx: bool,
}

impl VirtQueue {
    pub fn new(max_size: u16) -> Self {
        Self {
            max_size,
            size: max_size,
            ready: false,
            desc_addr: 0,
            avail_addr: 0,
            used_addr: 0,
            next_avail: 0,
            next_used: 0,
            event_idx: false,
        }
    }

    pub fn reset(&mut self) {
        self.size = self.max_size;
        self.ready = false;
        self.desc_addr = 0;
        self.avail_addr = 0;
        self.used_addr = 0;
        self.next_avail = 0;
        self.next_used = 0;
        self.event_idx = false;
    }

    pub fn has_avail(&self, mem: &GuestMemory) -> bool {
        if !self.ready || self.size == 0 {
            return false;
        }
        mem.read_u16_acquire(self.avail_addr + 2)
            .is_some_and(|avail_idx| avail_idx != self.next_avail)
    }

    pub fn pop_into(&mut self, mem: &GuestMemory, bufs: &mut Vec<DescBuf>) -> Option<u16> {
        bufs.clear();
        if !self.ready || self.size == 0 {
            return None;
        }
        // ARM64 Acquire load of avail->idx MUST precede reading avail->ring[] and desc[]!
        let avail_idx = mem.read_u16_acquire(self.avail_addr + 2)?;
        if avail_idx == self.next_avail {
            return None;
        }
        std::sync::atomic::fence(Ordering::Acquire);
        let ring_slot = (self.next_avail % self.size) as u64;
        let head = mem.read_u16(self.avail_addr + 4 + ring_slot * 2)?;
        self.next_avail = self.next_avail.wrapping_add(1);

        let mut idx = head;
        let mut steps = 0u32;
        while steps < 256 {
            steps += 1;
            let base = self.desc_addr + (idx as u64) * 16;
            let addr = mem.read_u64(base)?;
            let len = mem.read_u32(base + 8)?;
            let flags = mem.read_u16(base + 12)?;
            let next = mem.read_u16(base + 14)?;
            if (flags & VIRTQ_DESC_F_INDIRECT) != 0 {
                let count = (len / 16) as u16;
                let mut i_idx = 0u16;
                let mut i_steps = 0u32;
                while i_idx < count && i_steps < 256 {
                    i_steps += 1;
                    let ibase = addr + (i_idx as u64) * 16;
                    let iaddr = mem.read_u64(ibase)?;
                    let ilen = mem.read_u32(ibase + 8)?;
                    let iflags = mem.read_u16(ibase + 12)?;
                    let inext = mem.read_u16(ibase + 14)?;
                    bufs.push(DescBuf {
                        addr: iaddr,
                        len: ilen,
                        is_write: (iflags & VIRTQ_DESC_F_WRITE) != 0,
                    });
                    if (iflags & VIRTQ_DESC_F_NEXT) != 0 {
                        i_idx = inext;
                    } else {
                        break;
                    }
                }
            } else {
                bufs.push(DescBuf {
                    addr,
                    len,
                    is_write: (flags & VIRTQ_DESC_F_WRITE) != 0,
                });
            }
            if (flags & VIRTQ_DESC_F_NEXT) != 0 {
                idx = next;
            } else {
                break;
            }
        }
        Some(head)
    }

    pub fn pop(&mut self, mem: &GuestMemory) -> Option<(u16, Vec<DescBuf>)> {
        let mut bufs = Vec::with_capacity(4);
        let head = self.pop_into(mem, &mut bufs)?;
        Some((head, bufs))
    }

    pub fn push_used(&mut self, mem: &GuestMemory, head: u16, written: u32) {
        if !self.ready || self.size == 0 {
            return;
        }
        let ring_slot = (self.next_used % self.size) as u64;
        let elem = self.used_addr + 4 + ring_slot * 8;
        let _ = mem.write_u32(elem, head as u32);
        let _ = mem.write_u32(elem + 4, written);
        self.next_used = self.next_used.wrapping_add(1);
        let _ = mem.write_u16_release(self.used_addr + 2, self.next_used);
    }

    /// Atomically publish multiple used descriptors with a single Release store to `used->idx`.
    /// Required for `VIRTIO_NET_F_MRG_RXBUF` multi-buffer RX chains on weak-ordered ARM64!
    pub fn push_used_batch(&mut self, mem: &GuestMemory, items: &[(u16, u32)]) {
        if !self.ready || self.size == 0 || items.is_empty() {
            return;
        }
        for &(head, written) in items {
            let ring_slot = (self.next_used % self.size) as u64;
            let elem = self.used_addr + 4 + ring_slot * 8;
            let _ = mem.write_u32(elem, head as u32);
            let _ = mem.write_u32(elem + 4, written);
            self.next_used = self.next_used.wrapping_add(1);
        }
        let _ = mem.write_u16_release(self.used_addr + 2, self.next_used);
    }

    /// Virtio 1.2 split-ring interrupt suppression check (`VRING_AVAIL_F_NO_INTERRUPT`).
    /// Must be called after `push_used` updates `used->idx`.
    #[inline]
    pub fn guest_wants_irq(&self, mem: &GuestMemory) -> bool {
        self.guest_wants_irq_since(mem, self.next_used.wrapping_sub(1))
    }

    /// Check the entire interval published since the last notification decision.
    /// With EVENT_IDX the driver gives the index of the first used entry it wants.
    fn guest_wants_irq_since(&self, mem: &GuestMemory, old_used: u16) -> bool {
        if !self.ready || self.size == 0 {
            return false;
        }
        std::sync::atomic::fence(Ordering::SeqCst);
        if self.event_idx {
            let event = self
                .avail_addr
                .checked_add(4 + 2 * u64::from(self.size))
                .and_then(|addr| mem.read_u16_acquire(addr));
            return event.is_none_or(|idx| {
                self.next_used.wrapping_sub(idx).wrapping_sub(1)
                    < self.next_used.wrapping_sub(old_used)
            });
        }
        let flags = mem.read_u16_acquire(self.avail_addr).unwrap_or(0);
        (flags & 1) == 0
    }

    /// Virtio 1.2 split-ring kick suppression (`VRING_USED_F_NO_NOTIFY`).
    /// Tells the guest driver whether to skip MMIO `QueueNotify` writes while the host
    /// async worker is actively draining this queue.
    #[inline]
    pub fn set_no_notify(&self, mem: &GuestMemory, suppress: bool) {
        if !self.ready || self.size == 0 {
            return;
        }
        if self.event_idx {
            // While draining, an index just behind the consumer suppresses kicks
            // until wraparound. Before sleeping, request the next available entry.
            if let Some(addr) = self.used_addr.checked_add(4 + 8 * u64::from(self.size)) {
                let event = self.next_avail.wrapping_sub(u16::from(suppress));
                let _ = mem.write_u16_release(addr, event);
            }
        } else {
            let _ = mem.write_u16_release(self.used_addr, u16::from(suppress));
        }
        std::sync::atomic::fence(Ordering::SeqCst);
    }

    fn configure_notifications(&mut self, mem: &GuestMemory, event_idx: bool) {
        self.event_idx = event_idx;
        if self.ready && event_idx {
            let _ = mem.write_u16_release(self.used_addr, 0);
            self.set_no_notify(mem, false);
        }
    }
}

/// Read all readable descriptor bytes into a contiguous Vec.
pub fn collect_readable(bufs: &[DescBuf], mem: &GuestMemory) -> Vec<u8> {
    let total: usize = bufs
        .iter()
        .filter(|b| !b.is_write)
        .map(|b| b.len as usize)
        .sum();
    let mut out = Vec::with_capacity(total);
    for b in bufs {
        if !b.is_write
            && let Some(s) = mem.read_slice(b.addr, b.len as usize)
        {
            out.extend_from_slice(s);
        }
    }
    out
}

/// Scatter-write bytes across all writable descriptors in `bufs`, returning total written.
pub fn scatter_writable(bufs: &[DescBuf], mem: &GuestMemory, mut data: &[u8]) -> u32 {
    let mut written = 0u32;
    for b in bufs {
        if !b.is_write || data.is_empty() {
            continue;
        }
        if let Some(dst) = mem.write_slice(b.addr, b.len as usize) {
            let n = dst.len().min(data.len());
            dst[..n].copy_from_slice(&data[..n]);
            data = &data[n..];
            written += n as u32;
        }
    }
    written
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct VirtQueueSnapshot {
    pub max_size: u16,
    pub size: u16,
    pub ready: bool,
    pub desc_addr: u64,
    pub avail_addr: u64,
    pub used_addr: u64,
    pub next_avail: u16,
    pub next_used: u16,
}

impl From<&VirtQueue> for VirtQueueSnapshot {
    fn from(q: &VirtQueue) -> Self {
        Self {
            max_size: q.max_size,
            size: q.size,
            ready: q.ready,
            desc_addr: q.desc_addr,
            avail_addr: q.avail_addr,
            used_addr: q.used_addr,
            next_avail: q.next_avail,
            next_used: q.next_used,
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct VirtioDeviceSnapshot {
    pub device_id: u32,
    pub device_features_sel: u32,
    pub driver_features: u64,
    pub driver_features_sel: u32,
    pub queue_sel: u32,
    pub status: u32,
    pub config_generation: u32,
    pub irq_isr: u32,
    pub queues: Vec<VirtQueueSnapshot>,
    pub backend_blob: Vec<u8>,
}

pub trait VirtioBackend: Send {
    fn device_id(&self) -> u32;
    fn features(&self) -> u64;
    fn num_queues(&self) -> usize;
    fn queue_max_size(&self, _q: usize) -> u16 {
        256
    }
    fn read_config(&self, _offset: u64, data: &mut [u8]) {
        data.fill(0);
    }
    fn write_config(&mut self, _offset: u64, _data: &[u8]) {}
    /// Called once when the device is wired onto the MMIO bus with its IRQ line & guest RAM.
    fn attach(&mut self, _mem: Arc<GuestMemory>, _irq: IrqLine) {}
    /// Called whenever the guest updates negotiated driver features (or confirms FEATURES_OK).
    fn set_features(&mut self, _features: u64) {}
    /// Called when a queue's `ready` flag transitions to true (gives async backends a handle to RX queue).
    fn queue_ready(&mut self, _q_idx: usize, _q: &VirtQueue) {}
    /// Stop accessing this ring before the guest can reuse its backing memory.
    fn queue_disabled(&mut self, _q_idx: usize) {}
    /// Called on device reset (status == 0).
    fn reset(&mut self) {}
    /// Pause any background workers, sync live queue indices back into `queues`,
    /// flush storage state, and return an optional backend-specific state blob.
    fn snapshot_pause(&mut self, _queues: &mut [VirtQueue], _mem: &GuestMemory) -> Vec<u8> {
        Vec::new()
    }
    /// Resume background workers after a snapshot completes.
    fn snapshot_resume(&mut self) {}
    /// Restore backend-specific state and restart background workers for ready queues.
    fn snapshot_restore(&mut self, _blob: &[u8], _queues: &[VirtQueue]) {}
    /// Handle guest kick on queue `q_idx`. Returns true if an interrupt should be raised.
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool;
}

pub struct VirtioMmioDevice {
    pub irq: IrqLine,
    mem: Arc<GuestMemory>,
    backend: Box<dyn VirtioBackend>,
    queues: Vec<VirtQueue>,
    device_features_sel: u32,
    driver_features: u64,
    driver_features_sel: u32,
    queue_sel: u32,
    status: u32,
    config_generation: u32,
}

impl VirtioMmioDevice {
    pub fn new(spi_intid: u32, mem: Arc<GuestMemory>, mut backend: Box<dyn VirtioBackend>) -> Self {
        let irq = IrqLine::new(spi_intid);
        backend.attach(mem.clone(), irq.clone());
        let queues = (0..backend.num_queues())
            .map(|i| VirtQueue::new(backend.queue_max_size(i)))
            .collect();
        Self {
            irq,
            mem,
            backend,
            queues,
            device_features_sel: 0,
            driver_features: 0,
            driver_features_sel: 0,
            queue_sel: 0,
            status: 0,
            config_generation: 0,
        }
    }

    pub fn device_id(&self) -> u32 {
        self.backend.device_id()
    }

    pub fn mmio_read(&self, offset: u64, size: usize) -> u64 {
        if offset >= 0x100 {
            let mut buf = [0u8; 8];
            let n = size.min(8);
            self.backend.read_config(offset - 0x100, &mut buf[..n]);
            return u64::from_le_bytes(buf);
        }
        let val: u32 = match offset {
            0x000 => VIRTIO_MMIO_MAGIC,
            0x004 => VIRTIO_MMIO_VERSION,
            0x008 => self.backend.device_id(),
            0x00c => VIRTIO_MMIO_VENDOR,
            0x010 => {
                let feats = self.backend.features() | VIRTIO_F_VERSION_1;
                if self.device_features_sel == 0 {
                    feats as u32
                } else if self.device_features_sel == 1 {
                    (feats >> 32) as u32
                } else {
                    0
                }
            }
            0x034 => self
                .queues
                .get(self.queue_sel as usize)
                .map_or(0, |q| q.max_size as u32),
            0x044 => self
                .queues
                .get(self.queue_sel as usize)
                .map_or(0, |q| u32::from(q.ready)),
            0x060 => self.irq.status(),
            0x070 => self.status,
            // Virtio-MMIO v2: SHM_LEN_LOW/HIGH == ~0 indicates no shared memory region (e.g., no virtiofs DAX)
            0x0b0 | 0x0b4 | 0x0b8 | 0x0bc => 0xffff_ffff,
            0x0fc => self.config_generation,
            _ => 0,
        };
        val as u64
    }

    pub fn mmio_write(&mut self, offset: u64, size: usize, val: u64) {
        if offset >= 0x100 {
            let bytes = val.to_le_bytes();
            let n = size.min(8);
            self.backend.write_config(offset - 0x100, &bytes[..n]);
            return;
        }
        let v = val as u32;
        match offset {
            0x014 => self.device_features_sel = v,
            0x020 => {
                if self.driver_features_sel == 0 {
                    self.driver_features = (self.driver_features & !0xffff_ffff) | (v as u64);
                } else if self.driver_features_sel == 1 {
                    self.driver_features =
                        (self.driver_features & 0xffff_ffff) | ((v as u64) << 32);
                }
                self.backend.set_features(self.driver_features);
            }
            0x024 => self.driver_features_sel = v,
            0x030 => self.queue_sel = v,
            0x038 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.size = (v as u16).min(q.max_size);
                }
            }
            0x044 => {
                let idx = self.queue_sel as usize;
                if let Some(q) = self.queues.get_mut(idx)
                    && q.ready != (v != 0)
                {
                    q.ready = v != 0;
                    if q.ready {
                        let event_idx =
                            self.driver_features & self.backend.features() & VIRTIO_F_EVENT_IDX
                                != 0;
                        q.configure_notifications(&self.mem, event_idx);
                        let snap = q.clone();
                        self.backend.queue_ready(idx, &snap);
                    } else {
                        self.backend.queue_disabled(idx);
                        q.next_avail = 0;
                        q.next_used = 0;
                    }
                }
            }
            0x050 => {
                let q_idx = v as usize;
                if q_idx < self.queues.len()
                    && self
                        .backend
                        .handle_queue(q_idx, &mut self.queues, &self.mem)
                {
                    self.irq.raise_used_buffer();
                }
            }
            0x064 => {
                self.irq.ack(v);
            }
            0x070 => {
                self.status = v;
                if v == 0 {
                    self.backend.reset();
                    self.driver_features = 0;
                    for q in &mut self.queues {
                        q.reset();
                    }
                    self.irq.clear();
                }
            }
            0x080 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.desc_addr = (q.desc_addr & !0xffff_ffff) | (v as u64);
                }
            }
            0x084 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.desc_addr = (q.desc_addr & 0xffff_ffff) | ((v as u64) << 32);
                }
            }
            0x090 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.avail_addr = (q.avail_addr & !0xffff_ffff) | (v as u64);
                }
            }
            0x094 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.avail_addr = (q.avail_addr & 0xffff_ffff) | ((v as u64) << 32);
                }
            }
            0x0a0 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.used_addr = (q.used_addr & !0xffff_ffff) | (v as u64);
                }
            }
            0x0a4 => {
                if let Some(q) = self.queues.get_mut(self.queue_sel as usize) {
                    q.used_addr = (q.used_addr & 0xffff_ffff) | ((v as u64) << 32);
                }
            }
            _ => {}
        }
    }

    pub fn snapshot_pause(&mut self) -> VirtioDeviceSnapshot {
        let backend_blob = self.backend.snapshot_pause(&mut self.queues, &self.mem);
        VirtioDeviceSnapshot {
            device_id: self.backend.device_id(),
            device_features_sel: self.device_features_sel,
            driver_features: self.driver_features,
            driver_features_sel: self.driver_features_sel,
            queue_sel: self.queue_sel,
            status: self.status,
            config_generation: self.config_generation,
            irq_isr: self.irq.status(),
            queues: self.queues.iter().map(VirtQueueSnapshot::from).collect(),
            backend_blob,
        }
    }

    pub fn snapshot_resume(&mut self) {
        self.backend.snapshot_resume();
    }

    pub fn snapshot_restore(&mut self, snap: &VirtioDeviceSnapshot) -> Result<(), String> {
        if snap.device_id != self.backend.device_id() {
            return Err(format!(
                "virtio device_id mismatch: snapshot={} device={}",
                snap.device_id,
                self.backend.device_id()
            ));
        }
        if snap.queues.len() != self.queues.len() {
            return Err(format!(
                "virtio queue count mismatch for dev {}: snapshot={} device={}",
                snap.device_id,
                snap.queues.len(),
                self.queues.len()
            ));
        }
        let event_idx = snap.driver_features & VIRTIO_F_EVENT_IDX != 0;
        if event_idx && self.backend.features() & VIRTIO_F_EVENT_IDX == 0 {
            return Err(format!(
                "virtio device {} requires EVENT_IDX for snapshot restore",
                snap.device_id
            ));
        }
        self.device_features_sel = snap.device_features_sel;
        self.driver_features = snap.driver_features;
        self.driver_features_sel = snap.driver_features_sel;
        self.queue_sel = snap.queue_sel;
        self.status = snap.status;
        self.config_generation = snap.config_generation;
        self.irq.set_isr_silent(snap.irq_isr);
        for (q, qs) in self.queues.iter_mut().zip(snap.queues.iter()) {
            q.max_size = qs.max_size;
            q.size = qs.size;
            q.ready = qs.ready;
            q.desc_addr = qs.desc_addr;
            q.avail_addr = qs.avail_addr;
            q.used_addr = qs.used_addr;
            q.next_avail = qs.next_avail;
            q.next_used = qs.next_used;
            q.configure_notifications(&self.mem, event_idx);
            if q.ready && !event_idx {
                q.set_no_notify(&self.mem, false);
            }
        }
        self.backend.set_features(self.driver_features);
        self.backend
            .snapshot_restore(&snap.backend_blob, &self.queues);
        Ok(())
    }
}

// ============================================================================
// 1. Virtio-RNG (Device ID 4) — instant kernel entropy
// ============================================================================
pub struct VirtioRng;

impl VirtioBackend for VirtioRng {
    fn device_id(&self) -> u32 {
        4
    }
    fn features(&self) -> u64 {
        0
    }
    fn num_queues(&self) -> usize {
        1
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool {
        let q = &mut queues[q_idx];
        let mut used_any = false;
        while let Some((head, bufs)) = q.pop(mem) {
            let mut total = 0u32;
            for b in bufs {
                if b.is_write
                    && let Some(slice) = mem.write_slice(b.addr, b.len as usize)
                {
                    unsafe { arc4random_buf(slice.as_mut_ptr().cast(), slice.len()) };
                    total = total.saturating_add(b.len);
                }
            }
            q.push_used(mem, head, total);
            used_any = true;
        }
        used_any
    }
}

// ============================================================================
// 2. Virtio-Blk (Device ID 2) — async zero-copy worker thread + coalesced flushes (DiskFlush)
// ============================================================================
/// Upper bounds, in bytes, of the block request-size histogram's buckets
/// (`BlkMetrics::read_sizes`, `write_sizes`); one more bucket counts larger
/// requests. A guest whose requests sit in the first bucket writes a page per
/// request: what a device without `VIRTIO_BLK_F_SEG_MAX` gets.
pub const BLK_REQUEST_BYTES_BOUNDS: [u64; 6] =
    [4 << 10, 16 << 10, 64 << 10, 256 << 10, 1 << 20, 4 << 20];

/// Upper bounds, in microseconds, of the host flush-sync histogram's buckets
/// (`BlkMetrics::flush_sync_hist`); one more bucket counts longer syncs. An
/// idle Mac syncs a guest flush in about 0.1 ms; another writer streaming
/// 400 MB/s to the same disk triples that, and every flush the guest's
/// metadata commits wait on pays it.
pub const BLK_FLUSH_SYNC_USEC_BOUNDS: [u64; 8] = [50, 100, 200, 500, 1_000, 5_000, 20_000, 100_000];

#[derive(Default)]
pub struct BlkMetrics {
    pub read_ops: AtomicU64,
    pub write_ops: AtomicU64,
    pub flush_ops: AtomicU64,
    pub discard_ops: AtomicU64,
    pub read_bytes: AtomicU64,
    pub write_bytes: AtomicU64,
    pub discarded_bytes: AtomicU64,
    /// Host syncs run for guest flushes (one may answer several flushes).
    pub flush_syncs: AtomicU64,
    /// Time those host syncs took, in microseconds, and the longest one.
    pub flush_sync_usec: AtomicU64,
    pub flush_sync_usec_max: AtomicU64,
    /// Read and write requests by data bytes (`BLK_REQUEST_BYTES_BOUNDS`,
    /// not cumulative).
    pub read_sizes: [AtomicU64; BLK_REQUEST_BYTES_BOUNDS.len() + 1],
    pub write_sizes: [AtomicU64; BLK_REQUEST_BYTES_BOUNDS.len() + 1],
    /// Host syncs by duration (`BLK_FLUSH_SYNC_USEC_BOUNDS`, not cumulative).
    pub flush_sync_hist: [AtomicU64; BLK_FLUSH_SYNC_USEC_BOUNDS.len() + 1],
}

impl BlkMetrics {
    fn record_flush_sync(&self, took: Duration) {
        let us = took.as_micros() as u64;
        self.flush_syncs.fetch_add(1, Ordering::Relaxed);
        self.flush_sync_usec.fetch_add(us, Ordering::Relaxed);
        self.flush_sync_usec_max.fetch_max(us, Ordering::Relaxed);
        let bucket = BLK_FLUSH_SYNC_USEC_BOUNDS.partition_point(|&bound| bound < us);
        self.flush_sync_hist[bucket].fetch_add(1, Ordering::Relaxed);
    }

    fn record_request(sizes: &[AtomicU64], bytes: u64) {
        let bucket = BLK_REQUEST_BYTES_BOUNDS.partition_point(|&bound| bound < bytes);
        sizes[bucket].fetch_add(1, Ordering::Relaxed);
    }
}

struct BlkQueueState {
    queue: Option<VirtQueue>,
    mem: Option<Arc<GuestMemory>>,
    irq: Option<IrqLine>,
    kicked: bool,
    worker_parked: bool,
}

struct BlkShared {
    file: File,
    read_only: bool,
    /// How guest flushes (and the device's own) reach the host disk.
    flush: FlushPolicy,
    metrics: Arc<BlkMetrics>,
    state: (Mutex<BlkQueueState>, Condvar),
    paused: AtomicBool,
    shutdown: AtomicBool,
}

pub struct VirtioBlk {
    capacity_sectors: u64,
    read_only: bool,
    shared: Arc<BlkShared>,
    worker_handle: Option<thread::JoinHandle<()>>,
}

const VIRTIO_BLK_F_SEG_MAX: u64 = 1 << 2;
const VIRTIO_BLK_F_RO: u64 = 1 << 5;
const VIRTIO_BLK_F_BLK_SIZE: u64 = 1 << 6;
const VIRTIO_BLK_F_FLUSH: u64 = 1 << 9;
const VIRTIO_BLK_F_DISCARD: u64 = 1 << 13;

/// Host iovecs one block request is read or written with (one preadv or
/// pwritev); a request with more data descriptors takes one call each.
const BLK_IOVECS: usize = 64;
/// Data segments per request the device offers (`VIRTIO_BLK_F_SEG_MAX`).
/// Without it Linux sends one segment per request, so a write-out of
/// scattered page-cache pages is a request per 4 KiB page: 16 x 128 MiB of
/// random buffered writes and their fsync were 522,860 write requests and
/// 3.5-3.6 s, with 62 segments 10,210 requests and 0.9-1.1 s (4 runs each,
/// boots interleaved); a 1 GiB sequential read 2,700-2,960 requests against
/// 294-302. With the header and status a full request is 64 descriptors,
/// which indirect descriptors (`VIRTIO_RING_F_INDIRECT_DESC`) keep to one
/// ring entry.
const BLK_SEG_MAX: u32 = 62;
const _: () = assert!(BLK_SEG_MAX as usize <= BLK_IOVECS);

const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;
const VIRTIO_BLK_T_FLUSH: u32 = 4;
const VIRTIO_BLK_T_GET_ID: u32 = 8;
const VIRTIO_BLK_T_DISCARD: u32 = 11;

fn blk_data_direction_valid(req_type: u32, data_descs: &[DescBuf]) -> bool {
    match req_type {
        // Block reads and ID strings write into guest memory.
        VIRTIO_BLK_T_IN | VIRTIO_BLK_T_GET_ID => data_descs.iter().all(|d| d.is_write),
        // Block writes and discard tables read from guest memory.
        VIRTIO_BLK_T_OUT | VIRTIO_BLK_T_DISCARD => data_descs.iter().all(|d| !d.is_write),
        // Flush carries no data payload. Unknown commands are rejected before direction matters.
        VIRTIO_BLK_T_FLUSH => data_descs.is_empty(),
        _ => true,
    }
}

#[cfg(target_vendor = "apple")]
fn darwin_punch_hole(fd: std::os::fd::RawFd, byte_off: u64, byte_len: u64) -> u64 {
    const APFS_BLOCK: u64 = 4096;
    let aligned_start = (byte_off + APFS_BLOCK - 1) & !(APFS_BLOCK - 1);
    let end = byte_off.saturating_add(byte_len);
    let aligned_end = end & !(APFS_BLOCK - 1);
    if aligned_end <= aligned_start {
        return 0;
    }
    let punch_len = aligned_end - aligned_start;
    let mut ph = libc::fpunchhole_t {
        fp_flags: 0,
        reserved: 0,
        fp_offset: aligned_start as libc::off_t,
        fp_length: punch_len as libc::off_t,
    };
    let rc = unsafe { libc::fcntl(fd, libc::F_PUNCHHOLE, &mut ph) };
    if rc == 0 { punch_len } else { 0 }
}

#[cfg(not(target_vendor = "apple"))]
fn darwin_punch_hole(_fd: std::os::fd::RawFd, _byte_off: u64, _byte_len: u64) -> u64 {
    0
}

fn run_blk_io_loop(shared: Arc<BlkShared>) {
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let mut q_local: Option<VirtQueue> = None;
    let mut pending_flushes: Vec<(u16, u64)> = Vec::with_capacity(16);
    let mut bufs: Vec<DescBuf> = Vec::with_capacity(BLK_IOVECS + 2);

    loop {
        if shared.shutdown.load(Ordering::Relaxed) {
            return;
        }
        let (mem, irq) = {
            let mut st = shared.state.0.lock().unwrap();
            if let (Some(lq), Some(sq)) = (q_local.as_ref(), st.queue.as_mut()) {
                sq.next_avail = lq.next_avail;
                sq.next_used = lq.next_used;
            }
            st.worker_parked = true;
            shared.state.1.notify_all();
            while (shared.paused.load(Ordering::Acquire) || !st.kicked)
                && !shared.shutdown.load(Ordering::Relaxed)
            {
                if !shared.paused.load(Ordering::Relaxed)
                    && let (Some(mem), Some(q)) = (st.mem.as_ref(), q_local.as_ref())
                    && q.has_avail(mem)
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
            if let Some(ref updated) = st.queue {
                match q_local {
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
                    None => q_local = Some(updated.clone()),
                }
            }
            (st.mem.clone(), st.irq.clone())
        };

        let (Some(mem), Some(irq), Some(ref mut q)) = (mem, irq, q_local.as_mut()) else {
            continue;
        };
        if !q.ready {
            continue;
        }

        q.set_no_notify(&mem, true);
        let mut last_activity = Instant::now();
        let adaptive_spin = Duration::from_micros(30);
        let fd = shared.file.as_raw_fd();
        let mut iovecs: [libc::iovec; BLK_IOVECS] = [libc::iovec {
            iov_base: std::ptr::null_mut(),
            iov_len: 0,
        }; BLK_IOVECS];

        loop {
            let mut used_any = false;
            pending_flushes.clear();

            while let Some(head) = q.pop_into(&mem, &mut bufs) {
                if bufs.len() < 2 {
                    q.push_used(&mem, head, 0);
                    used_any = true;
                    continue;
                }
                let hdr_desc = bufs[0];
                let status_desc = *bufs.last().unwrap();
                let data_descs = &bufs[1..bufs.len() - 1];
                let header_status_valid = !hdr_desc.is_write
                    && hdr_desc.len >= 16
                    && status_desc.is_write
                    && status_desc.len >= 1;
                let mut status: u8 = 0;
                let mut written: u32 = 1;

                if !header_status_valid {
                    status = 1;
                } else if let Some(hdr) = mem.read_slice(hdr_desc.addr, 16) {
                    let req_type = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
                    if !blk_data_direction_valid(req_type, data_descs) {
                        status = 1;
                    }
                    let sector = u64::from_le_bytes(hdr[8..16].try_into().unwrap());
                    let mut byte_off = sector.saturating_mul(512);
                    match req_type {
                        VIRTIO_BLK_T_IN if status == 0 => {
                            let mut total = 0u64;
                            if data_descs.len() > 1 && data_descs.len() <= iovecs.len() {
                                let mut expected = 0usize;
                                let mut ok = true;
                                for (i, d) in data_descs.iter().enumerate() {
                                    if let Some(ptr) = mem.translate(d.addr, d.len as usize) {
                                        iovecs[i] = libc::iovec {
                                            iov_base: ptr.cast(),
                                            iov_len: d.len as usize,
                                        };
                                        expected += d.len as usize;
                                    } else {
                                        ok = false;
                                        break;
                                    }
                                }
                                if ok {
                                    let n = unsafe {
                                        libc::preadv(
                                            fd,
                                            iovecs.as_ptr(),
                                            data_descs.len() as i32,
                                            byte_off as libc::off_t,
                                        )
                                    };
                                    if n as usize == expected {
                                        total = expected as u64;
                                        written += expected as u32;
                                    } else {
                                        status = 1;
                                    }
                                } else {
                                    status = 1;
                                }
                            } else {
                                for d in data_descs {
                                    if let Some(dst) = mem.write_slice(d.addr, d.len as usize) {
                                        if shared.file.read_exact_at(dst, byte_off).is_err() {
                                            status = 1;
                                            break;
                                        }
                                        byte_off += d.len as u64;
                                        total += d.len as u64;
                                        written += d.len;
                                    } else {
                                        status = 1;
                                        break;
                                    }
                                }
                            }
                            shared.metrics.read_ops.fetch_add(1, Ordering::Relaxed);
                            shared
                                .metrics
                                .read_bytes
                                .fetch_add(total, Ordering::Relaxed);
                            BlkMetrics::record_request(&shared.metrics.read_sizes, total);
                        }
                        VIRTIO_BLK_T_OUT if status == 0 => {
                            if shared.read_only {
                                status = 1;
                            } else {
                                let mut total = 0u64;
                                if data_descs.len() > 1 && data_descs.len() <= iovecs.len() {
                                    let mut expected = 0usize;
                                    let mut ok = true;
                                    for (i, d) in data_descs.iter().enumerate() {
                                        if let Some(ptr) = mem.translate(d.addr, d.len as usize) {
                                            iovecs[i] = libc::iovec {
                                                iov_base: ptr.cast(),
                                                iov_len: d.len as usize,
                                            };
                                            expected += d.len as usize;
                                        } else {
                                            ok = false;
                                            break;
                                        }
                                    }
                                    if ok {
                                        let n = unsafe {
                                            libc::pwritev(
                                                fd,
                                                iovecs.as_ptr(),
                                                data_descs.len() as i32,
                                                byte_off as libc::off_t,
                                            )
                                        };
                                        if n as usize == expected {
                                            total = expected as u64;
                                        } else {
                                            status = 1;
                                        }
                                    } else {
                                        status = 1;
                                    }
                                } else {
                                    for d in data_descs {
                                        if let Some(src) = mem.read_slice(d.addr, d.len as usize) {
                                            if shared.file.write_all_at(src, byte_off).is_err() {
                                                status = 1;
                                                break;
                                            }
                                            byte_off += d.len as u64;
                                            total += d.len as u64;
                                        } else {
                                            status = 1;
                                            break;
                                        }
                                    }
                                }
                                shared.metrics.write_ops.fetch_add(1, Ordering::Relaxed);
                                shared
                                    .metrics
                                    .write_bytes
                                    .fetch_add(total, Ordering::Relaxed);
                                BlkMetrics::record_request(&shared.metrics.write_sizes, total);
                            }
                        }
                        VIRTIO_BLK_T_FLUSH if status == 0 => {
                            // Coalesce concurrent flush barriers in the same batch!
                            pending_flushes.push((head, status_desc.addr));
                            continue;
                        }
                        VIRTIO_BLK_T_GET_ID if status == 0 => {
                            let id = b"micropod-vmm-blk0\0\0\0";
                            if let Some(first) = data_descs.first()
                                && let Some(dst) = mem.write_slice(first.addr, first.len as usize)
                            {
                                let n = dst.len().min(id.len());
                                dst[..n].copy_from_slice(&id[..n]);
                                written += n as u32;
                            }
                        }
                        VIRTIO_BLK_T_DISCARD if status == 0 => {
                            if shared.read_only {
                                status = 1;
                            } else {
                                let mut punched = 0u64;
                                for d in data_descs {
                                    if let Some(raw) = mem.read_slice(d.addr, d.len as usize) {
                                        for seg in raw.as_chunks::<16>().0 {
                                            let seg_sec =
                                                u64::from_le_bytes(seg[0..8].try_into().unwrap());
                                            let num_sec =
                                                u32::from_le_bytes(seg[8..12].try_into().unwrap());
                                            let off = seg_sec.saturating_mul(512);
                                            let len = (num_sec as u64).saturating_mul(512);
                                            punched += darwin_punch_hole(fd, off, len);
                                        }
                                    }
                                }
                                shared.metrics.discard_ops.fetch_add(1, Ordering::Relaxed);
                                shared
                                    .metrics
                                    .discarded_bytes
                                    .fetch_add(punched, Ordering::Relaxed);
                            }
                        }
                        _ => {
                            if status == 0 {
                                status = 2;
                            }
                        }
                    }
                } else {
                    status = 1;
                }
                if status_desc.is_write
                    && status_desc.len >= 1
                    && let Some(st) = mem.write_slice(status_desc.addr, 1)
                {
                    st[0] = status;
                }
                q.push_used(&mem, head, written);
                used_any = true;
            }

            if !pending_flushes.is_empty() {
                // One host sync answers every flush of the batch: each was
                // submitted after the writes it covers had completed.
                let began = Instant::now();
                let flush_status = if shared.flush.flush(fd).is_ok() { 0 } else { 1 };
                shared.metrics.record_flush_sync(began.elapsed());
                shared
                    .metrics
                    .flush_ops
                    .fetch_add(pending_flushes.len() as u64, Ordering::Relaxed);
                for &(fhead, fstatus_addr) in &pending_flushes {
                    if let Some(st) = mem.write_slice(fstatus_addr, 1) {
                        st[0] = flush_status;
                    }
                    q.push_used(&mem, fhead, 1);
                    used_any = true;
                }
            }

            if used_any {
                if q.guest_wants_irq(&mem) {
                    irq.raise_used_buffer();
                }
                last_activity = Instant::now();
                continue;
            }

            if shared.shutdown.load(Ordering::Relaxed) {
                return;
            }
            if shared.paused.load(Ordering::Acquire) {
                q.set_no_notify(&mem, false);
                break;
            }
            if last_activity.elapsed() < adaptive_spin {
                std::hint::spin_loop();
                continue;
            }
            q.set_no_notify(&mem, false);
            if q.has_avail(&mem) {
                q.set_no_notify(&mem, true);
                last_activity = Instant::now();
                continue;
            }
            break;
        }
    }
}

impl VirtioBlk {
    pub fn new(
        file: File,
        read_only: bool,
        metrics: Arc<BlkMetrics>,
        flush: DiskFlush,
    ) -> std::io::Result<Self> {
        Self::with_flush_policy(file, read_only, metrics, FlushPolicy::new(flush))
    }

    fn with_flush_policy(
        file: File,
        read_only: bool,
        metrics: Arc<BlkMetrics>,
        flush: FlushPolicy,
    ) -> std::io::Result<Self> {
        let len = file.metadata()?.len();
        Ok(Self {
            capacity_sectors: len / 512,
            read_only,
            shared: Arc::new(BlkShared {
                file,
                read_only,
                flush,
                metrics,
                state: (
                    Mutex::new(BlkQueueState {
                        queue: None,
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
        let handle = thread::Builder::new()
            .name("vmm-blk-io".into())
            .spawn(move || run_blk_io_loop(shared))
            .expect("spawn vmm-blk-io worker");
        self.worker_handle = Some(handle);
    }
}

impl VirtioBackend for VirtioBlk {
    fn device_id(&self) -> u32 {
        2
    }
    fn features(&self) -> u64 {
        let mut f = VIRTIO_BLK_F_BLK_SIZE
            | VIRTIO_BLK_F_FLUSH
            | VIRTIO_BLK_F_SEG_MAX
            | VIRTIO_RING_F_INDIRECT_DESC;
        if self.read_only {
            f |= VIRTIO_BLK_F_RO;
        } else {
            f |= VIRTIO_BLK_F_DISCARD;
        }
        f
    }
    fn num_queues(&self) -> usize {
        1
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        256
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 48];
        cfg[0..8].copy_from_slice(&self.capacity_sectors.to_le_bytes());
        cfg[12..16].copy_from_slice(&BLK_SEG_MAX.to_le_bytes()); // seg_max
        cfg[20..24].copy_from_slice(&4096u32.to_le_bytes()); // blk_size
        cfg[36..40].copy_from_slice(&65536u32.to_le_bytes()); // max_discard_sectors (32 MiB)
        cfg[40..44].copy_from_slice(&16u32.to_le_bytes()); // max_discard_seg
        cfg[44..48].copy_from_slice(&8u32.to_le_bytes()); // discard_sector_alignment (4 KiB)
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
        if q_idx == 0 {
            let mut st = self.shared.state.0.lock().unwrap();
            st.queue = Some(q.clone());
            st.kicked = true;
            self.shared.state.1.notify_one();
            drop(st);
            self.ensure_worker_started();
        }
    }
    fn reset(&mut self) {
        let mut st = self.shared.state.0.lock().unwrap();
        st.queue = None;
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
        if let Some(ref sq) = st.queue {
            queues[0].next_avail = sq.next_avail;
            queues[0].next_used = sq.next_used;
            if queues[0].ready {
                queues[0].set_no_notify(mem, false);
            }
        }
        if !self.read_only {
            let _ = self.shared.flush.flush(self.shared.file.as_raw_fd());
        }
        Vec::new()
    }
    fn snapshot_resume(&mut self) {
        self.shared.paused.store(false, Ordering::Release);
        let mut st = self.shared.state.0.lock().unwrap();
        st.kicked = true;
        self.shared.state.1.notify_all();
    }
    fn snapshot_restore(&mut self, _blob: &[u8], queues: &[VirtQueue]) {
        if let Some(q) = queues.first()
            && q.ready
        {
            self.queue_ready(0, q);
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], _mem: &GuestMemory) -> bool {
        if q_idx == 0 {
            let mut st = self.shared.state.0.lock().unwrap();
            if st.queue.is_none() {
                st.queue = Some(queues[0].clone());
            }
            st.kicked = true;
            self.shared.state.1.notify_one();
            drop(st);
            self.ensure_worker_started();
        }
        false
    }
}

impl Drop for VirtioBlk {
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
        if !self.read_only {
            let _ = self.shared.flush.flush(self.shared.file.as_raw_fd());
        }
    }
}

// ============================================================================
// 3. Virtio-Balloon (Device ID 5) — Free-Page Reporting: reported pages go back to the host
// ============================================================================
const VIRTIO_BALLOON_F_REPORTING: u64 = 1 << 5;

#[derive(Default)]
pub struct BalloonMetrics {
    pub report_kicks: AtomicU64,
    pub reported_ranges: AtomicU64,
    pub reclaimed_bytes: AtomicU64,
    /// Reported ranges the host could not give back (left as they were).
    pub reclaim_failures: AtomicU64,
}

impl BalloonMetrics {
    fn record(&self, r: Reclaimed) {
        self.reclaimed_bytes
            .fetch_add(r.bytes as u64, Ordering::Relaxed);
        if r.failed {
            self.reclaim_failures.fetch_add(1, Ordering::Relaxed);
        }
    }
}

pub struct VirtioBalloon {
    num_pages: u32,
    actual: u32,
    metrics: Arc<BalloonMetrics>,
}

impl VirtioBalloon {
    pub fn new(metrics: Arc<BalloonMetrics>) -> Self {
        Self {
            num_pages: 0,
            actual: 0,
            metrics,
        }
    }
}

impl VirtioBackend for VirtioBalloon {
    fn device_id(&self) -> u32 {
        5
    }
    fn features(&self) -> u64 {
        VIRTIO_BALLOON_F_REPORTING
    }
    fn num_queues(&self) -> usize {
        3
    }
    fn queue_max_size(&self, _q: usize) -> u16 {
        128
    }
    fn read_config(&self, offset: u64, data: &mut [u8]) {
        let mut cfg = [0u8; 8];
        cfg[0..4].copy_from_slice(&self.num_pages.to_le_bytes());
        cfg[4..8].copy_from_slice(&self.actual.to_le_bytes());
        let start = offset as usize;
        for (i, b) in data.iter_mut().enumerate() {
            *b = cfg.get(start + i).copied().unwrap_or(0);
        }
    }
    fn write_config(&mut self, offset: u64, data: &[u8]) {
        if offset == 4 && data.len() >= 4 {
            self.actual = u32::from_le_bytes(data[0..4].try_into().unwrap());
        }
    }
    fn handle_queue(&mut self, q_idx: usize, queues: &mut [VirtQueue], mem: &GuestMemory) -> bool {
        let q = &mut queues[q_idx];
        let mut used_any = false;
        while let Some((head, bufs)) = q.pop(mem) {
            match q_idx {
                0 => {
                    for b in &bufs {
                        if let Some(raw) = mem.read_slice(b.addr, b.len as usize) {
                            for chunk in raw.as_chunks::<4>().0 {
                                let pfn = u32::from_le_bytes(*chunk) as u64;
                                self.metrics.record(mem.reclaim(pfn * 4096, 4096));
                            }
                        }
                    }
                    q.push_used(mem, head, 0);
                }
                1 => q.push_used(mem, head, 0),
                2 => {
                    self.metrics.report_kicks.fetch_add(1, Ordering::Relaxed);
                    let mut total_written = 0u32;
                    for b in &bufs {
                        self.metrics.record(mem.reclaim(b.addr, b.len as usize));
                        self.metrics.reported_ranges.fetch_add(1, Ordering::Relaxed);
                        if b.is_write {
                            total_written = total_written.saturating_add(b.len);
                        }
                    }
                    q.push_used(mem, head, total_written);
                }
                _ => q.push_used(mem, head, 0),
            }
            used_any = true;
        }
        used_any
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_ring_event_thresholds_cover_each_published_entry_across_wrap() {
        let mut backing = [0u64; 32];
        let mem = unsafe {
            GuestMemory::new(
                backing.as_mut_ptr().cast(),
                0,
                std::mem::size_of_val(&backing),
            )
        };
        let mut q = VirtQueue::new(4);
        q.ready = true;
        q.avail_addr = 32;
        q.used_addr = 128;
        let used_event = 44;
        let avail_event = 164;
        mem.write_u16(used_event, 37).unwrap();
        mem.write_u16(avail_event, 91).unwrap();
        q.set_no_notify(&mem, true);
        assert_eq!(mem.read_u16(q.used_addr), Some(1));
        assert_eq!(mem.read_u16(avail_event), Some(91));
        mem.write_u16(q.avail_addr, 1).unwrap();
        assert!(!q.guest_wants_irq_since(&mem, 0));

        q.next_avail = u16::MAX;
        q.configure_notifications(&mem, true);
        assert_eq!(mem.read_u16(q.used_addr), Some(0));
        assert_eq!(mem.read_u16(avail_event), Some(u16::MAX));
        q.next_avail = 0;
        q.set_no_notify(&mem, true);
        assert_eq!(mem.read_u16(avail_event), Some(u16::MAX));
        q.set_no_notify(&mem, false);
        assert_eq!(mem.read_u16(avail_event), Some(0));
        assert_eq!(mem.read_u16(used_event), Some(37));

        q.next_used = 1;
        let old = u16::MAX - 1;
        for (event, requested) in [
            (old - 1, false),
            (old, true),
            (u16::MAX, true),
            (0, true),
            (1, false),
        ] {
            mem.write_u16_release(used_event, event).unwrap();
            assert_eq!(q.guest_wants_irq_since(&mem, old), requested);
        }
        assert!(!q.guest_wants_irq_since(&mem, q.next_used));
    }

    #[test]
    fn storage_workers_complete_requests_after_rearming_and_snapshot_resume() {
        const AVAIL: u64 = 0x200;
        const USED: u64 = 0x300;
        const INPUT: u64 = 0x400;
        const OUTPUT: u64 = 0x500;
        const STATUS: u64 = 0x800;
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let file = File::open(std::env::current_exe().unwrap()).unwrap();
        let mut expected = [0; 32];
        file.read_exact_at(&mut expected, 0).unwrap();
        let block = VirtioBlk::new(file, true, Arc::default(), DiskFlush::default()).unwrap();
        let fs =
            virtiofs::VirtioFs::new("workspace", root.to_owned(), false, Arc::default()).unwrap();
        let devices: [Box<dyn VirtioBackend>; 2] = [Box::new(block), Box::new(fs)];

        for backend in devices {
            let is_fs = backend.device_id() == 26;
            let queue = u64::from(is_fs);
            let mut backing = [0u64; 512];
            let mem = Arc::new(unsafe {
                GuestMemory::new(
                    backing.as_mut_ptr().cast(),
                    0,
                    std::mem::size_of_val(&backing),
                )
            });
            let mut dev = VirtioMmioDevice::new(32, mem.clone(), backend);
            // One ordinary FUSE GETATTR or virtio-blk READ. Suppress guest IRQs.
            mem.write_u16(AVAIL, 1).unwrap();
            if is_fs {
                mem.write_u32(INPUT, 56).unwrap();
                mem.write_u32(INPUT + 4, 3).unwrap();
                mem.write_u32(INPUT + 8, 37).unwrap();
                mem.write_u32(INPUT + 16, 1).unwrap();
            }
            let descs = [
                (INPUT, if is_fs { 56 } else { 16 }, VIRTQ_DESC_F_NEXT),
                (
                    OUTPUT,
                    512,
                    if is_fs {
                        VIRTQ_DESC_F_WRITE
                    } else {
                        VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT
                    },
                ),
                (STATUS, 1, VIRTQ_DESC_F_WRITE),
            ];
            for (i, (addr, len, flags)) in descs.into_iter().enumerate() {
                let d = 0x100 + i as u64 * 16;
                mem.write_slice(d, 8)
                    .unwrap()
                    .copy_from_slice(&addr.to_le_bytes());
                mem.write_u32(d + 8, len).unwrap();
                mem.write_u16(d + 12, flags).unwrap();
                mem.write_u16(d + 14, i as u16 + 1).unwrap();
            }
            for (reg, value) in [
                (0x030, queue),
                (0x038, 4),
                (0x080, 0x100),
                (0x090, AVAIL),
                (0x0a0, USED),
                (0x044, 1),
            ] {
                dev.mmio_write(reg, 4, value);
            }
            for seq in 1..=96u16 {
                if seq % 8 == 0 {
                    thread::sleep(Duration::from_millis(1));
                }
                let paused = seq == 49;
                if paused {
                    assert_eq!(
                        dev.snapshot_pause().queues[queue as usize].next_used,
                        seq - 1
                    );
                }
                mem.write_slice(OUTPUT, 512).unwrap().fill(0xff);
                mem.write_slice(STATUS, 1).unwrap()[0] = 0xff;
                mem.write_u16_release(AVAIL + 2, seq).unwrap();
                std::sync::atomic::fence(Ordering::SeqCst);
                if mem.read_u16_acquire(USED).unwrap() & 1 == 0 {
                    dev.mmio_write(0x050, 4, queue);
                }
                if paused {
                    assert_eq!(mem.read_u16_acquire(USED + 2), Some(seq - 1));
                    dev.snapshot_resume();
                }
                let limit = Instant::now() + Duration::from_secs(2);
                while mem.read_u16_acquire(USED + 2) != Some(seq) {
                    assert!(
                        Instant::now() < limit,
                        "queue {queue} stalled at request {seq}"
                    );
                    thread::yield_now();
                }
                if is_fs {
                    assert_eq!(mem.read_u32(OUTPUT + 4), Some(0));
                    assert_eq!(mem.read_u64(OUTPUT + 8), Some(37));
                } else {
                    assert_eq!(mem.read_slice(STATUS, 1).unwrap(), &[0]);
                    assert_eq!(mem.read_slice(OUTPUT, 32).unwrap(), expected);
                }
            }
        }
    }

    #[test]
    fn guest_memory_reclaim_aligns_inward() {
        let mut backing = vec![0u8; 64 * 1024];
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), 0x4000_0000, backing.len()) };
        assert_eq!(mem.reclaim(0x4000_0000, 4096), Reclaimed::default());
        assert_eq!(mem.reclaim(0x3000_0000, 32768), Reclaimed::default());
        assert_eq!(
            mem.reclaim(0x4000_0000 + 48 * 1024, 32768),
            Reclaimed::default()
        );
    }

    #[test]
    fn virtio_blk_descriptor_directions_are_enforced() {
        let read = DescBuf {
            addr: 0,
            len: 512,
            is_write: false,
        };
        let write = DescBuf {
            addr: 512,
            len: 512,
            is_write: true,
        };
        assert!(blk_data_direction_valid(VIRTIO_BLK_T_IN, &[write]));
        assert!(!blk_data_direction_valid(VIRTIO_BLK_T_IN, &[read]));
        assert!(blk_data_direction_valid(VIRTIO_BLK_T_OUT, &[read]));
        assert!(!blk_data_direction_valid(VIRTIO_BLK_T_OUT, &[write]));
        assert!(blk_data_direction_valid(VIRTIO_BLK_T_DISCARD, &[read]));
        assert!(blk_data_direction_valid(VIRTIO_BLK_T_FLUSH, &[]));
        assert!(!blk_data_direction_valid(VIRTIO_BLK_T_FLUSH, &[read]));
    }

    #[test]
    fn guest_memory_atomic_u16_accesses_reject_unaligned_addresses() {
        let mut backing = vec![0u8; 4096];
        let mem = unsafe { GuestMemory::new(backing.as_mut_ptr(), 0x4000_0000, backing.len()) };
        assert_eq!(mem.read_u16_acquire(0x4000_0001), None);
        assert_eq!(mem.write_u16_release(0x4000_0001, 1), None);
        assert!(mem.write_u16_release(0x4000_0002, 0x1234).is_some());
        assert_eq!(mem.read_u16_acquire(0x4000_0002), Some(0x1234));
    }

    #[test]
    fn virtio_blk_discard_punches_apfs_hole() {
        use std::io::Write;
        use std::os::unix::fs::MetadataExt;
        let path = std::env::temp_dir().join(format!("mp-blk-discard-{}.img", std::process::id()));
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        let data = vec![0xABu8; 256 * 1024];
        f.write_all(&data).unwrap();
        f.sync_all().unwrap();
        let blocks_before = f.metadata().unwrap().blocks();
        let punched = darwin_punch_hole(f.as_raw_fd(), 16 * 1024, 128 * 1024);
        assert_eq!(punched, 128 * 1024);
        let blocks_after = f.metadata().unwrap().blocks();
        assert!(blocks_after <= blocks_before);
        // Verify punched range reads back as zeros
        let mut check = vec![0xFFu8; 16 * 1024];
        f.read_exact_at(&mut check, 16 * 1024).unwrap();
        assert!(check.iter().all(|&b| b == 0));
        drop(f);
        let _ = std::fs::remove_file(&path);
    }

    /// The device offers multi-segment requests (`seg_max` 62) in indirect
    /// tables, and a request whose header, data segments and status all sit
    /// in an indirect table is written and read back as one vectored call,
    /// counted in the request-size histogram.
    #[test]
    fn virtio_blk_serves_multi_segment_requests_from_indirect_tables() {
        const AVAIL: u64 = 0x200;
        const USED: u64 = 0x300;
        const SEG: u32 = 4096;
        let path = std::env::temp_dir().join(format!("mp-blk-indirect-{}.img", std::process::id()));
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        file.set_len(1 << 20).unwrap();
        let _ = std::fs::remove_file(&path);
        let metrics = Arc::new(BlkMetrics::default());
        let block = VirtioBlk::new(
            file.try_clone().unwrap(),
            false,
            metrics.clone(),
            DiskFlush::default(),
        )
        .unwrap();
        let mut backing = vec![0u64; 8192];
        let mem = Arc::new(unsafe {
            GuestMemory::new(backing.as_mut_ptr().cast(), 0, backing.len() * 8)
        });
        let mut dev = VirtioMmioDevice::new(32, mem.clone(), Box::new(block));
        let features = dev.mmio_read(0x010, 4);
        assert_ne!(features & VIRTIO_BLK_F_SEG_MAX, 0, "SEG_MAX offered");
        assert_ne!(
            features & VIRTIO_RING_F_INDIRECT_DESC,
            0,
            "indirect descriptors offered"
        );
        assert_eq!(dev.mmio_read(0x100 + 12, 4), u64::from(BLK_SEG_MAX));

        let write_desc = |at: u64, addr: u64, len: u32, flags: u16, next: u16| {
            mem.write_slice(at, 8)
                .unwrap()
                .copy_from_slice(&addr.to_le_bytes());
            mem.write_u32(at + 8, len).unwrap();
            mem.write_u16(at + 12, flags).unwrap();
            mem.write_u16(at + 14, next).unwrap();
        };
        // Request 0 writes three segments at sector 8; request 1 reads them
        // back into other pages. Each is ring descriptor `slot`, an indirect
        // table of header, three data segments and the status byte.
        let requests = [
            (
                0u16,
                VIRTIO_BLK_T_OUT,
                0x1000u64,
                0x1800u64,
                0x2000u64,
                0x5800u64,
            ),
            (1u16, VIRTIO_BLK_T_IN, 0x1100, 0x1880, 0x9000, 0xc000),
        ];
        for (seg, byte) in (0..3u64).zip([0x11u8, 0x22, 0x33]) {
            mem.write_slice(0x2000 + seg * u64::from(SEG), SEG as usize)
                .unwrap()
                .fill(byte);
        }
        for (slot, kind, table, header, data, status) in requests {
            mem.write_u32(header, kind).unwrap();
            mem.write_slice(header + 8, 8)
                .unwrap()
                .copy_from_slice(&8u64.to_le_bytes());
            mem.write_slice(status, 1).unwrap()[0] = 0xff;
            let data_flags = if kind == VIRTIO_BLK_T_IN {
                VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT
            } else {
                VIRTQ_DESC_F_NEXT
            };
            write_desc(table, header, 16, VIRTQ_DESC_F_NEXT, 1);
            for seg in 0..3u16 {
                write_desc(
                    table + 16 * u64::from(seg + 1),
                    data + u64::from(seg) * u64::from(SEG),
                    SEG,
                    data_flags,
                    seg + 2,
                );
            }
            write_desc(table + 64, status, 1, VIRTQ_DESC_F_WRITE, 0);
            write_desc(
                0x100 + 16 * u64::from(slot),
                table,
                5 * 16,
                VIRTQ_DESC_F_INDIRECT,
                0,
            );
            mem.write_u16(AVAIL + 4 + 2 * u64::from(slot), slot)
                .unwrap();
        }
        // The driver takes every offered feature, as Linux does.
        for (reg, value) in [
            (0x024, 0),
            (0x020, features),
            (0x024, 1),
            (0x020, VIRTIO_F_VERSION_1 >> 32),
            (0x030, 0),
            (0x038, 4),
            (0x080, 0x100),
            (0x090, AVAIL),
            (0x0a0, USED),
            (0x044, 1),
        ] {
            dev.mmio_write(reg, 4, value);
        }
        for done in 1..=2u16 {
            mem.write_u16_release(AVAIL + 2, done).unwrap();
            dev.mmio_write(0x050, 4, 0);
            let limit = Instant::now() + Duration::from_secs(2);
            while mem.read_u16_acquire(USED + 2) != Some(done) {
                assert!(Instant::now() < limit, "request {done} never completed");
                thread::yield_now();
            }
        }
        for (_, _, _, _, _, status) in requests {
            assert_eq!(mem.read_slice(status, 1).unwrap(), &[0]);
        }
        let mut on_disk = vec![0u8; 3 * SEG as usize];
        file.read_exact_at(&mut on_disk, 8 * 512).unwrap();
        assert_eq!(mem.read_slice(0x2000, on_disk.len()).unwrap(), &on_disk[..]);
        assert_eq!(mem.read_slice(0x9000, on_disk.len()).unwrap(), &on_disk[..]);
        assert_eq!(on_disk[2 * SEG as usize], 0x33);
        // 12 KiB each: the second bucket (4-16 KiB).
        let counts = |sizes: &[AtomicU64]| -> Vec<u64> {
            sizes.iter().map(|c| c.load(Ordering::Relaxed)).collect()
        };
        assert_eq!(counts(&metrics.write_sizes), [0, 1, 0, 0, 0, 0, 0]);
        assert_eq!(counts(&metrics.read_sizes), [0, 1, 0, 0, 0, 0, 0]);
        assert_eq!(
            metrics.write_bytes.load(Ordering::Relaxed),
            3 * u64::from(SEG)
        );

        // A snapshot keeps the negotiated indirect descriptors, and a device
        // restored from it serves the next indirect request.
        let snap = dev.snapshot_pause();
        assert_ne!(snap.driver_features & VIRTIO_RING_F_INDIRECT_DESC, 0);
        drop(dev);
        let block = VirtioBlk::new(file, false, metrics.clone(), DiskFlush::default()).unwrap();
        let mut dev = VirtioMmioDevice::new(32, mem.clone(), Box::new(block));
        dev.snapshot_restore(&snap).unwrap();
        mem.write_slice(0x9000, on_disk.len()).unwrap().fill(0);
        mem.write_slice(0xc000, 1).unwrap()[0] = 0xff;
        mem.write_u16(AVAIL + 4 + 2 * 2, 1).unwrap();
        mem.write_u16_release(AVAIL + 2, 3).unwrap();
        dev.mmio_write(0x050, 4, 0);
        let limit = Instant::now() + Duration::from_secs(2);
        while mem.read_u16_acquire(USED + 2) != Some(3) {
            assert!(
                Instant::now() < limit,
                "the restored device never completed"
            );
            thread::yield_now();
        }
        assert_eq!(mem.read_slice(0xc000, 1).unwrap(), &[0]);
        assert_eq!(mem.read_slice(0x9000, on_disk.len()).unwrap(), &on_disk[..]);
    }

    #[test]
    fn blk_request_sizes_fall_in_their_buckets() {
        let sizes: [AtomicU64; BLK_REQUEST_BYTES_BOUNDS.len() + 1] = Default::default();
        for bytes in [0, 512, 4096, 4097, 16384, 1 << 20, (4 << 20) + 1, u64::MAX] {
            BlkMetrics::record_request(&sizes, bytes);
        }
        let counts: Vec<u64> = sizes.iter().map(|c| c.load(Ordering::Relaxed)).collect();
        assert_eq!(counts, [3, 2, 0, 0, 1, 0, 2]);

        let metrics = BlkMetrics::default();
        for us in [10, 100, 101, 900, 150_000] {
            metrics.record_flush_sync(Duration::from_micros(us));
        }
        let syncs: Vec<u64> = metrics
            .flush_sync_hist
            .iter()
            .map(|c| c.load(Ordering::Relaxed))
            .collect();
        assert_eq!(syncs, [1, 1, 1, 0, 1, 0, 0, 0, 1]);
        assert_eq!(metrics.flush_sync_usec.load(Ordering::Relaxed), 151_111);
    }

    /// A guest's VIRTIO_BLK_T_FLUSH reaches the host as the device's flush
    /// mode, a barrier unless configured otherwise, and a failed host sync
    /// is the guest's VIRTIO_BLK_S_IOERR.
    #[test]
    fn guest_flushes_run_the_configured_host_sync() {
        use std::sync::atomic::AtomicU8;
        const AVAIL: u64 = 0x200;
        const USED: u64 = 0x300;
        const HEADER: u64 = 0x400;
        const STATUS: u64 = 0x800;
        // The host syncs each case's device ran (the tests share a process).
        static SEEN: Mutex<Vec<(u8, DiskFlush)>> = Mutex::new(Vec::new());
        static CASE: AtomicU8 = AtomicU8::new(0);
        fn record(_fd: std::os::fd::RawFd, mode: DiskFlush) -> std::io::Result<()> {
            SEEN.lock()
                .unwrap()
                .push((CASE.load(Ordering::SeqCst), mode));
            Ok(())
        }
        fn fail(_fd: std::os::fd::RawFd, mode: DiskFlush) -> std::io::Result<()> {
            SEEN.lock()
                .unwrap()
                .push((CASE.load(Ordering::SeqCst), mode));
            Err(std::io::Error::from_raw_os_error(libc::EIO))
        }
        let seen = |case: u8| -> Vec<DiskFlush> {
            SEEN.lock()
                .unwrap()
                .iter()
                .filter(|(c, _)| *c == case)
                .map(|(_, m)| *m)
                .collect()
        };
        let path =
            std::env::temp_dir().join(format!("mp-blk-flush-dev-{}.img", std::process::id()));
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        file.set_len(1 << 20).unwrap();
        let _ = std::fs::remove_file(&path);

        let cases: [(u8, Option<DiskFlush>, blk_flush::SyncFn, DiskFlush, u8); 3] = [
            (1, None, record, DiskFlush::Barrier, 0),
            (2, Some(DiskFlush::Full), record, DiskFlush::Full, 0),
            (3, None, fail, DiskFlush::Barrier, 1),
        ];
        for (case, configured, sync, want_mode, want_status) in cases {
            CASE.store(case, Ordering::SeqCst);
            let block = VirtioBlk::with_flush_policy(
                file.try_clone().unwrap(),
                false,
                Arc::default(),
                FlushPolicy::with_sync(configured.unwrap_or_default(), sync),
            )
            .unwrap();
            let mut backing = [0u64; 512];
            let mem = Arc::new(unsafe {
                GuestMemory::new(
                    backing.as_mut_ptr().cast(),
                    0,
                    std::mem::size_of_val(&backing),
                )
            });
            let mut dev = VirtioMmioDevice::new(32, mem.clone(), Box::new(block));
            mem.write_u32(HEADER, VIRTIO_BLK_T_FLUSH).unwrap();
            mem.write_slice(STATUS, 1).unwrap()[0] = 0xff;
            for (i, (addr, len, flags)) in [
                (HEADER, 16, VIRTQ_DESC_F_NEXT),
                (STATUS, 1, VIRTQ_DESC_F_WRITE),
            ]
            .into_iter()
            .enumerate()
            {
                let d = 0x100 + i as u64 * 16;
                mem.write_slice(d, 8)
                    .unwrap()
                    .copy_from_slice(&addr.to_le_bytes());
                mem.write_u32(d + 8, len).unwrap();
                mem.write_u16(d + 12, flags).unwrap();
                mem.write_u16(d + 14, i as u16 + 1).unwrap();
            }
            for (reg, value) in [
                (0x030, 0),
                (0x038, 4),
                (0x080, 0x100),
                (0x090, AVAIL),
                (0x0a0, USED),
                (0x044, 1),
            ] {
                dev.mmio_write(reg, 4, value);
            }
            mem.write_u16_release(AVAIL + 2, 1).unwrap();
            dev.mmio_write(0x050, 4, 0);
            let limit = Instant::now() + Duration::from_secs(2);
            while mem.read_u16_acquire(USED + 2) != Some(1) {
                assert!(
                    Instant::now() < limit,
                    "case {case}: the flush never completed"
                );
                thread::yield_now();
            }
            assert_eq!(
                mem.read_slice(STATUS, 1).unwrap(),
                &[want_status],
                "case {case}: status"
            );
            assert_eq!(seen(case), [want_mode], "case {case}: the guest's flush");
            // A writable device flushes once more when it goes, the same way.
            drop(dev);
            assert_eq!(
                seen(case),
                [want_mode, want_mode],
                "case {case}: the exit flush"
            );
        }
    }
}
