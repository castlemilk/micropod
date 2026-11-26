//! Apple Silicon HVF VM Snapshot & APFS Copy-on-Write Fork.
//!
//! Captures complete architectural & device state:
//! - Per-vCPU GPRs (`X0..X30`, `PC`, `FPCR`, `FPSR`, `CPSR`), SIMD (`Q0..Q31`),
//!   EL1/EL0 system registers, GICv3 ICC CPU interface registers, and virtual
//!   timer offset/mask (rebased smoothly against `mach_absolute_time()` on restore).
//! - Apple hardware GICv3 distributor + redistributor state via `hv_gic_state_create` /
//!   `hv_gic_set_state`.
//! - PL011 UART registers and all Virtio-MMIO v2 transport/queue/backend states
//!   (including relative Virtio-FS nodeid tables).
//! - Sparse guest RAM image (`mincore`-accelerated zero-page skipping on save,
//!   zero-copy `mmap(MAP_PRIVATE)` CoW mapping on restore) + instant APFS `clonefile`
//!   disk forks.

use std::ffi::{CString, c_void};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::ptr;

use hvf_sys::{
    HV_SUCCESS, SNAPSHOT_GIC_ICC_REGS, SNAPSHOT_SYS_REGS, check, clonefile, hv_gic_get_icc_reg,
    hv_gic_set_icc_reg, hv_gic_set_state, hv_gic_state_create, hv_gic_state_get_data,
    hv_gic_state_get_size, hv_vcpu_get_vtimer_mask, hv_vcpu_get_vtimer_offset,
    hv_vcpu_set_vtimer_mask, hv_vcpu_set_vtimer_offset, hv_vcpu_t, mach_absolute_time,
    mp_hv_vcpu_get_reg_raw, mp_hv_vcpu_get_simd_fp_reg, mp_hv_vcpu_get_sys_reg_raw,
    mp_hv_vcpu_set_reg_raw, mp_hv_vcpu_set_simd_fp_reg, mp_hv_vcpu_set_sys_reg_raw, os_release,
};
use vmm_virtio::{VirtQueueSnapshot, VirtioDeviceSnapshot};

const SNAPSHOT_MAGIC: &[u8; 8] = b"MPSNAP01";
const SNAPSHOT_VERSION: u32 = 2;
const NUM_GPRS: usize = 35; // X0..X30, PC, FPCR, FPSR, CPSR
const NUM_SIMD: usize = 32; // Q0..Q31

/// Query the macOS host OS build string (`kern.osversion`, e.g. `"25F..."`) so snapshots
/// containing Apple's private `hv_gic_state` blob fail fast across incompatible OS upgrades.
pub fn host_os_build_id() -> String {
    let Ok(cname) = CString::new("kern.osversion") else {
        return "unknown".into();
    };
    let mut buf = [0u8; 64];
    let mut len = buf.len();
    let rc = unsafe {
        libc::sysctlbyname(
            cname.as_ptr(),
            buf.as_mut_ptr().cast(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    if rc == 0 && len > 0 {
        let end = buf[..len.min(buf.len())]
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(len.min(buf.len()));
        String::from_utf8_lossy(&buf[..end]).into_owned()
    } else {
        "unknown".into()
    }
}

/// Standard IEEE 802.3 CRC32 (zero external crate dependencies).
pub fn crc32_ieee(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xffff_ffff;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct VcpuSnapshot {
    pub cpu_id: u32,
    pub gprs: [u64; NUM_GPRS],
    pub simd: [[u8; 16]; NUM_SIMD],
    pub sys_regs: Vec<(u16, u64)>,
    pub icc_regs: Vec<(u16, u64)>,
    pub saved_cntvct: u64,
    pub vtimer_masked: bool,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Pl011Snapshot {
    pub cr: u32,
    pub imsc: u32,
    pub ris: u32,
    pub lcr_h: u32,
    pub ibrd: u32,
    pub fbrd: u32,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct VmSnapshot {
    pub host_os_version: String,
    pub created_unix_secs: u64,
    pub memory_mib: usize,
    pub num_vcpus: u32,
    pub gicd_base: u64,
    pub gicr_base: u64,
    pub pl011: Pl011Snapshot,
    pub gic_state: Vec<u8>,
    pub vcpus: Vec<VcpuSnapshot>,
    pub devices: Vec<VirtioDeviceSnapshot>,
}

/// Capture complete register state for `vcpu`. Must be called on the owning vCPU thread.
pub fn save_vcpu_state(vcpu: hv_vcpu_t, cpu_id: u32) -> Result<VcpuSnapshot, String> {
    let mut gprs = [0u64; NUM_GPRS];
    for (idx, slot) in gprs.iter_mut().enumerate() {
        check(
            unsafe { mp_hv_vcpu_get_reg_raw(vcpu, idx as u32, slot) },
            "hv_vcpu_get_reg",
        )
        .map_err(|e| format!("cpu{cpu_id} get reg {idx}: {e}"))?;
    }

    let mut simd = [[0u8; 16]; NUM_SIMD];
    for (idx, slot) in simd.iter_mut().enumerate() {
        check(
            unsafe { mp_hv_vcpu_get_simd_fp_reg(vcpu, idx as u32, slot.as_mut_ptr()) },
            "hv_vcpu_get_simd_fp_reg",
        )
        .map_err(|e| format!("cpu{cpu_id} get Q{idx}: {e}"))?;
    }

    let mut sys_regs = Vec::with_capacity(SNAPSHOT_SYS_REGS.len());
    for &reg in SNAPSHOT_SYS_REGS {
        let mut val = 0u64;
        if unsafe { mp_hv_vcpu_get_sys_reg_raw(vcpu, reg, &mut val) } == HV_SUCCESS {
            sys_regs.push((reg, val));
        }
    }

    let mut icc_regs = Vec::with_capacity(SNAPSHOT_GIC_ICC_REGS.len());
    for &reg in SNAPSHOT_GIC_ICC_REGS {
        let mut val = 0u64;
        if unsafe { hv_gic_get_icc_reg(vcpu, reg, &mut val) } == HV_SUCCESS {
            icc_regs.push((reg, val));
        }
    }

    let mut vtimer_offset = 0u64;
    check(
        unsafe { hv_vcpu_get_vtimer_offset(vcpu, &mut vtimer_offset) },
        "hv_vcpu_get_vtimer_offset",
    )
    .map_err(|e| format!("cpu{cpu_id} get vtimer_offset: {e}"))?;
    let now_mach = unsafe { mach_absolute_time() };
    let saved_cntvct = now_mach.wrapping_sub(vtimer_offset);

    let mut vtimer_masked = false;
    check(
        unsafe { hv_vcpu_get_vtimer_mask(vcpu, &mut vtimer_masked) },
        "hv_vcpu_get_vtimer_mask",
    )
    .map_err(|e| format!("cpu{cpu_id} get vtimer_mask: {e}"))?;

    Ok(VcpuSnapshot {
        cpu_id,
        gprs,
        simd,
        sys_regs,
        icc_regs,
        saved_cntvct,
        vtimer_masked,
    })
}

/// Restore complete register state onto `vcpu`. Must be called on the owning vCPU thread
/// after `hv_vcpu_create` and `MPIDR_EL1` setup, and before `hv_vcpu_run`.
pub fn restore_vcpu_state(
    vcpu: hv_vcpu_t,
    snap: &VcpuSnapshot,
    restore_mach_now: u64,
) -> Result<(), String> {
    // Rebase virtual timer offset so guest CNTVCT_EL0 resumes smoothly from `saved_cntvct`
    // without a multi-second jump that could trigger Linux softlockup or RCU stalls.
    let new_vtimer_offset = restore_mach_now.wrapping_sub(snap.saved_cntvct);
    check(
        unsafe { hv_vcpu_set_vtimer_offset(vcpu, new_vtimer_offset) },
        "hv_vcpu_set_vtimer_offset",
    )
    .map_err(|e| format!("cpu{} set vtimer_offset: {e}", snap.cpu_id))?;

    for &(reg, val) in &snap.sys_regs {
        let rc = unsafe { mp_hv_vcpu_set_sys_reg_raw(vcpu, reg, val) };
        if rc != HV_SUCCESS {
            return Err(format!(
                "cpu{} set sys_reg {reg:#06x} failed: {:#010x}",
                snap.cpu_id, rc as u32
            ));
        }
    }

    for &(reg, val) in &snap.icc_regs {
        let rc = unsafe { hv_gic_set_icc_reg(vcpu, reg, val) };
        if rc != HV_SUCCESS {
            return Err(format!(
                "cpu{} set icc_reg {reg:#06x} failed: {:#010x}",
                snap.cpu_id, rc as u32
            ));
        }
    }

    for (idx, bytes) in snap.simd.iter().enumerate() {
        check(
            unsafe { mp_hv_vcpu_set_simd_fp_reg(vcpu, idx as u32, bytes.as_ptr()) },
            "hv_vcpu_set_simd_fp_reg",
        )
        .map_err(|e| format!("cpu{} set Q{idx}: {e}", snap.cpu_id))?;
    }

    for (idx, &val) in snap.gprs.iter().enumerate() {
        check(
            unsafe { mp_hv_vcpu_set_reg_raw(vcpu, idx as u32, val) },
            "hv_vcpu_set_reg",
        )
        .map_err(|e| format!("cpu{} set reg {idx}: {e}", snap.cpu_id))?;
    }

    check(
        unsafe { hv_vcpu_set_vtimer_mask(vcpu, snap.vtimer_masked) },
        "hv_vcpu_set_vtimer_mask",
    )
    .map_err(|e| format!("cpu{} set vtimer_mask: {e}", snap.cpu_id))?;

    Ok(())
}

/// Capture Apple Hardware GICv3 distributor + redistributor state while all vCPUs are stopped.
pub fn save_gic_state() -> Result<Vec<u8>, String> {
    let state = unsafe { hv_gic_state_create() };
    if state.is_null() {
        return Err("hv_gic_state_create returned null".into());
    }
    let res = (|| -> Result<Vec<u8>, String> {
        let mut size: usize = 0;
        check(
            unsafe { hv_gic_state_get_size(state, &mut size) },
            "hv_gic_state_get_size",
        )
        .map_err(|e| e.to_string())?;
        let mut buf = vec![0u8; size];
        check(
            unsafe { hv_gic_state_get_data(state, buf.as_mut_ptr().cast()) },
            "hv_gic_state_get_data",
        )
        .map_err(|e| e.to_string())?;
        Ok(buf)
    })();
    unsafe { os_release(state) };
    res
}

/// Restore Apple Hardware GICv3 distributor + redistributor state after all vCPUs are created
/// and before any vCPU runs.
pub fn restore_gic_state(data: &[u8]) -> Result<(), String> {
    check(
        unsafe { hv_gic_set_state(data.as_ptr().cast(), data.len()) },
        "hv_gic_set_state",
    )
    .map_err(|e| e.to_string())
}

/// Write guest RAM to `path` as a sparse APFS file, skipping untouched zero pages via `mincore(2)`
/// so a 4 GiB VM with 180 MiB touched RAM writes in ~40 ms without faulting unused pages.
/// # Safety
/// `base_ptr` must point to a live, readable allocation of at least `len` bytes for
/// the duration of the call. The allocation may share pages with the running VM but
/// callers must have stopped all vCPUs first so the captured bytes form a consistent snapshot.
pub unsafe fn write_sparse_ram(
    base_ptr: *const u8,
    len: usize,
    path: &Path,
) -> Result<usize, String> {
    const PAGE: usize = 16 * 1024;
    let npages = len / PAGE;
    let mut core_vec = vec![0u8; npages];
    let has_mincore = unsafe {
        libc::mincore(
            base_ptr.cast(),
            len,
            core_vec.as_mut_ptr().cast::<libc::c_char>(),
        ) == 0
    };

    let tmp_path = path.with_extension("bin.tmp");
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp_path)
        .map_err(|e| format!("create {}: {e}", tmp_path.display()))?;
    let fd = file.as_raw_fd();
    if unsafe { libc::ftruncate(fd, len as libc::off_t) } != 0 {
        return Err(format!(
            "ftruncate {}: {}",
            tmp_path.display(),
            std::io::Error::last_os_error()
        ));
    }

    let mut written_bytes = 0usize;
    let mut run_start: Option<usize> = None;

    let flush_run = |start_pg: usize, end_pg: usize, written: &mut usize| -> Result<(), String> {
        let off = start_pg * PAGE;
        let nbytes = (end_pg - start_pg) * PAGE;
        let mut done = 0usize;
        while done < nbytes {
            let rc = unsafe {
                libc::pwrite(
                    fd,
                    base_ptr.add(off + done).cast(),
                    nbytes - done,
                    (off + done) as libc::off_t,
                )
            };
            if rc <= 0 {
                return Err(format!(
                    "pwrite ram at {off:#x}: {}",
                    std::io::Error::last_os_error()
                ));
            }
            done += rc as usize;
        }
        *written += nbytes;
        Ok(())
    };

    // Exclude MINCORE_ANONYMOUS (0x80) which Darwin sets even on untouched demand-zero pages!
    // Check INCORE (0x01) | MODIFIED (0x04) | MODIFIED_OTHER (0x10) | PAGED_OUT (0x20).
    const MINCORE_PRESENT_MASK: u8 = 0x01 | 0x04 | 0x10 | 0x20;
    for (pg, core_flags) in core_vec.iter().enumerate() {
        let touched = if has_mincore {
            (core_flags & MINCORE_PRESENT_MASK) != 0
        } else {
            true
        };
        let non_zero = touched && {
            let slice = unsafe { std::slice::from_raw_parts(base_ptr.add(pg * PAGE), PAGE) };
            let words =
                unsafe { std::slice::from_raw_parts(slice.as_ptr().cast::<u64>(), PAGE / 8) };
            words.iter().any(|&w| w != 0)
        };
        if non_zero {
            if run_start.is_none() {
                run_start = Some(pg);
            }
            // Flush in bounded 4 MiB chunks for smooth pwrite throughput
            if let Some(s) = run_start
                && (pg + 1 - s) >= 256
            {
                flush_run(s, pg + 1, &mut written_bytes)?;
                run_start = None;
            }
        } else if let Some(s) = run_start.take() {
            flush_run(s, pg, &mut written_bytes)?;
        }
    }
    if let Some(s) = run_start {
        flush_run(s, npages, &mut written_bytes)?;
    }

    drop(file);
    fs::rename(&tmp_path, path)
        .map_err(|e| format!("rename {} -> {}: {e}", tmp_path.display(), path.display()))?;
    Ok(written_bytes)
}

/// Map a snapshot RAM image read-write with `MAP_PRIVATE` so Apple Silicon HVF shares
/// clean pages across all forked VMs in UBC and transparently CoW-faults only written pages.
pub fn map_cow_ram(path: &Path, expected_len: usize) -> Result<(*mut c_void, File), String> {
    let file = File::open(path).map_err(|e| format!("open {}: {e}", path.display()))?;
    let meta_len = file
        .metadata()
        .map_err(|e| format!("stat {}: {e}", path.display()))?
        .len() as usize;
    if meta_len != expected_len {
        return Err(format!(
            "snapshot RAM size mismatch: file={} expected={}",
            meta_len, expected_len
        ));
    }
    let ptr = unsafe {
        libc::mmap(
            ptr::null_mut(),
            expected_len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_FILE,
            file.as_raw_fd(),
            0,
        )
    };
    if ptr == libc::MAP_FAILED || ptr.is_null() {
        return Err(format!(
            "mmap MAP_PRIVATE {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok((ptr, file))
}

/// Instant APFS Copy-on-Write file clone via Darwin `clonefile(2)`.
pub fn clone_file_apfs(src: &Path, dst: &Path) -> Result<(), String> {
    if dst.exists() {
        let _ = fs::remove_file(dst);
    }
    let csrc = CString::new(src.as_os_str().as_bytes()).map_err(|_| "invalid src path")?;
    let cdst = CString::new(dst.as_os_str().as_bytes()).map_err(|_| "invalid dst path")?;
    if unsafe { clonefile(csrc.as_ptr(), cdst.as_ptr(), 0) } != 0 {
        return Err(format!(
            "clonefile {} -> {}: {}",
            src.display(),
            dst.display(),
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

// ============================================================================
// Deterministic little-endian binary codec for VmSnapshot (zero external crates)
// ============================================================================
struct Enc(Vec<u8>);

impl Enc {
    fn new() -> Self {
        Self(Vec::with_capacity(64 * 1024))
    }
    fn u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn u16(&mut self, v: u16) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn bytes(&mut self, b: &[u8]) {
        self.u32(b.len() as u32);
        self.0.extend_from_slice(b);
    }
}

struct Dec<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Dec<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.pos.checked_add(n).ok_or("snapshot decode overflow")?;
        if end > self.buf.len() {
            return Err("truncated snapshot file".into());
        }
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }
    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn bytes(&mut self) -> Result<Vec<u8>, String> {
        let n = self.u32()? as usize;
        Ok(self.take(n)?.to_vec())
    }
}

impl VmSnapshot {
    pub fn encode(&self) -> Vec<u8> {
        let mut e = Enc::new();
        e.0.extend_from_slice(SNAPSHOT_MAGIC);
        e.u32(SNAPSHOT_VERSION);
        e.bytes(self.host_os_version.as_bytes());
        e.u64(self.created_unix_secs);
        e.u64(self.memory_mib as u64);
        e.u32(self.num_vcpus);
        e.u64(self.gicd_base);
        e.u64(self.gicr_base);

        e.u32(self.pl011.cr);
        e.u32(self.pl011.imsc);
        e.u32(self.pl011.ris);
        e.u32(self.pl011.lcr_h);
        e.u32(self.pl011.ibrd);
        e.u32(self.pl011.fbrd);

        e.bytes(&self.gic_state);

        e.u32(self.vcpus.len() as u32);
        for v in &self.vcpus {
            e.u32(v.cpu_id);
            for &r in &v.gprs {
                e.u64(r);
            }
            for q in &v.simd {
                e.0.extend_from_slice(q);
            }
            e.u32(v.sys_regs.len() as u32);
            for &(reg, val) in &v.sys_regs {
                e.u16(reg);
                e.u64(val);
            }
            e.u32(v.icc_regs.len() as u32);
            for &(reg, val) in &v.icc_regs {
                e.u16(reg);
                e.u64(val);
            }
            e.u64(v.saved_cntvct);
            e.u8(u8::from(v.vtimer_masked));
        }

        e.u32(self.devices.len() as u32);
        for d in &self.devices {
            e.u32(d.device_id);
            e.u32(d.device_features_sel);
            e.u64(d.driver_features);
            e.u32(d.driver_features_sel);
            e.u32(d.queue_sel);
            e.u32(d.status);
            e.u32(d.config_generation);
            e.u32(d.irq_isr);
            e.u32(d.queues.len() as u32);
            for q in &d.queues {
                e.u16(q.max_size);
                e.u16(q.size);
                e.u8(u8::from(q.ready));
                e.u64(q.desc_addr);
                e.u64(q.avail_addr);
                e.u64(q.used_addr);
                e.u16(q.next_avail);
                e.u16(q.next_used);
            }
            e.bytes(&d.backend_blob);
        }

        let crc = crc32_ieee(&e.0);
        e.u32(crc);
        e.0
    }

    pub fn decode(data: &[u8]) -> Result<Self, String> {
        if data.len() < 16 {
            return Err("truncated snapshot file".into());
        }
        if &data[0..8] != SNAPSHOT_MAGIC {
            return Err("invalid snapshot magic".into());
        }
        let ver = u32::from_le_bytes(data[8..12].try_into().unwrap());
        if ver != SNAPSHOT_VERSION {
            return Err(format!(
                "unsupported snapshot version {ver} (expected {SNAPSHOT_VERSION}); regenerate snapshot"
            ));
        }
        let payload = &data[..data.len() - 4];
        let stored_crc = u32::from_le_bytes(data[data.len() - 4..].try_into().unwrap());
        let computed_crc = crc32_ieee(payload);
        if stored_crc != computed_crc {
            return Err(format!(
                "corrupted snapshot: CRC32 mismatch (stored={stored_crc:#010x} computed={computed_crc:#010x})"
            ));
        }

        let mut d = Dec::new(payload);
        let _ = d.take(12)?; // magic + version already validated
        let host_os_bytes = d.bytes()?;
        let host_os_version = String::from_utf8(host_os_bytes)
            .map_err(|_| "invalid UTF-8 in snapshot host_os_version")?;
        let created_unix_secs = d.u64()?;
        let memory_mib = d.u64()? as usize;
        let num_vcpus = d.u32()?;
        let gicd_base = d.u64()?;
        let gicr_base = d.u64()?;

        let pl011 = Pl011Snapshot {
            cr: d.u32()?,
            imsc: d.u32()?,
            ris: d.u32()?,
            lcr_h: d.u32()?,
            ibrd: d.u32()?,
            fbrd: d.u32()?,
        };

        let gic_state = d.bytes()?;

        let nvcpus = d.u32()? as usize;
        let mut vcpus = Vec::with_capacity(nvcpus);
        for _ in 0..nvcpus {
            let cpu_id = d.u32()?;
            let mut gprs = [0u64; NUM_GPRS];
            for slot in &mut gprs {
                *slot = d.u64()?;
            }
            let mut simd = [[0u8; 16]; NUM_SIMD];
            for slot in &mut simd {
                slot.copy_from_slice(d.take(16)?);
            }
            let nsys = d.u32()? as usize;
            let mut sys_regs = Vec::with_capacity(nsys);
            for _ in 0..nsys {
                sys_regs.push((d.u16()?, d.u64()?));
            }
            let nicc = d.u32()? as usize;
            let mut icc_regs = Vec::with_capacity(nicc);
            for _ in 0..nicc {
                icc_regs.push((d.u16()?, d.u64()?));
            }
            let saved_cntvct = d.u64()?;
            let vtimer_masked = d.u8()? != 0;
            vcpus.push(VcpuSnapshot {
                cpu_id,
                gprs,
                simd,
                sys_regs,
                icc_regs,
                saved_cntvct,
                vtimer_masked,
            });
        }

        let ndevs = d.u32()? as usize;
        let mut devices = Vec::with_capacity(ndevs);
        for _ in 0..ndevs {
            let device_id = d.u32()?;
            let device_features_sel = d.u32()?;
            let driver_features = d.u64()?;
            let driver_features_sel = d.u32()?;
            let queue_sel = d.u32()?;
            let status = d.u32()?;
            let config_generation = d.u32()?;
            let irq_isr = d.u32()?;
            let nq = d.u32()? as usize;
            let mut queues = Vec::with_capacity(nq);
            for _ in 0..nq {
                queues.push(VirtQueueSnapshot {
                    max_size: d.u16()?,
                    size: d.u16()?,
                    ready: d.u8()? != 0,
                    desc_addr: d.u64()?,
                    avail_addr: d.u64()?,
                    used_addr: d.u64()?,
                    next_avail: d.u16()?,
                    next_used: d.u16()?,
                });
            }
            let backend_blob = d.bytes()?;
            devices.push(VirtioDeviceSnapshot {
                device_id,
                device_features_sel,
                driver_features,
                driver_features_sel,
                queue_sel,
                status,
                config_generation,
                irq_isr,
                queues,
                backend_blob,
            });
        }

        if d.pos != payload.len() {
            return Err(format!(
                "corrupted snapshot: {} trailing bytes after decode",
                payload.len() - d.pos
            ));
        }
        if memory_mib == 0 {
            return Err("invalid snapshot: memory_mib is 0".into());
        }
        if num_vcpus == 0 || vcpus.len() != num_vcpus as usize {
            return Err(format!(
                "invalid snapshot: num_vcpus={num_vcpus} does not match vcpu entries ({})",
                vcpus.len()
            ));
        }

        Ok(VmSnapshot {
            host_os_version,
            created_unix_secs,
            memory_mib,
            num_vcpus,
            gicd_base,
            gicr_base,
            pl011,
            gic_state,
            vcpus,
            devices,
        })
    }

    pub fn write_atomic(&self, path: &Path) -> Result<(), String> {
        let tmp = path.with_extension("bin.tmp");
        let bytes = self.encode();
        let mut f = File::create(&tmp).map_err(|e| format!("create {}: {e}", tmp.display()))?;
        f.write_all(&bytes)
            .map_err(|e| format!("write {}: {e}", tmp.display()))?;
        drop(f);
        fs::rename(&tmp, path)
            .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))
    }

    pub fn read_from(path: &Path) -> Result<Self, String> {
        let bytes = fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
        Self::decode(&bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vm_snapshot_roundtrip_and_sparse_ram() {
        let snap = VmSnapshot {
            host_os_version: host_os_build_id(),
            created_unix_secs: 1_795_560_000,
            memory_mib: 512,
            num_vcpus: 1,
            gicd_base: 0x1000_0000,
            gicr_base: 0x1002_0000,
            pl011: Pl011Snapshot {
                cr: 0x301,
                imsc: 0x10,
                ris: 0x20,
                lcr_h: 0x70,
                ibrd: 1,
                fbrd: 40,
            },
            gic_state: vec![1, 2, 3, 4, 5, 6, 7, 8],
            vcpus: vec![VcpuSnapshot {
                cpu_id: 0,
                gprs: [0x1122_3344_5566_7788; NUM_GPRS],
                simd: [[0xAB; 16]; NUM_SIMD],
                sys_regs: vec![(0xc080, 0x34d5_d91d), (0xc100, 0x4100_0000)],
                icc_regs: vec![(0xc230, 0xf0), (0xc667, 1)],
                saved_cntvct: 123_456_789,
                vtimer_masked: false,
            }],
            devices: vec![VirtioDeviceSnapshot {
                device_id: 26,
                device_features_sel: 1,
                driver_features: 1 << 32,
                driver_features_sel: 1,
                queue_sel: 1,
                status: 0x0f,
                config_generation: 0,
                irq_isr: 1,
                queues: vec![VirtQueueSnapshot {
                    max_size: 256,
                    size: 256,
                    ready: true,
                    desc_addr: 0x4200_0000,
                    avail_addr: 0x4200_1000,
                    used_addr: 0x4200_2000,
                    next_avail: 42,
                    next_used: 42,
                }],
                backend_blob: b"virtiofs-nodes".to_vec(),
            }],
        };

        let encoded = snap.encode();
        let decoded = VmSnapshot::decode(&encoded).unwrap();
        assert_eq!(snap, decoded);
        assert!(!decoded.host_os_version.is_empty());

        // Corruption detection: flipping any payload bit fails CRC32 check
        let mut flipped = encoded.clone();
        flipped[24] ^= 0x01;
        let err = VmSnapshot::decode(&flipped).unwrap_err();
        assert!(err.contains("CRC32"), "unexpected error: {err}");

        // Truncation fails cleanly
        assert!(VmSnapshot::decode(&encoded[..encoded.len() - 5]).is_err());

        // Version mismatch fails cleanly with actionable message
        let mut bad_ver = encoded.clone();
        bad_ver[8..12].copy_from_slice(&1u32.to_le_bytes());
        let err = VmSnapshot::decode(&bad_ver).unwrap_err();
        assert!(
            err.contains("unsupported snapshot version"),
            "unexpected error: {err}"
        );

        // Trailing garbage with recomputed CRC fails strict decode
        let mut trailing = encoded[..encoded.len() - 4].to_vec();
        trailing.extend_from_slice(&[0xde, 0xad]);
        let crc = crc32_ieee(&trailing);
        trailing.extend_from_slice(&crc.to_le_bytes());
        let err = VmSnapshot::decode(&trailing).unwrap_err();
        assert!(err.contains("trailing bytes"), "unexpected error: {err}");

        // Test sparse RAM write + MAP_PRIVATE CoW mapping
        let dir = std::env::temp_dir().join(format!("mp-snap-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ram_path = dir.join("ram.bin");
        let len = 64 * 1024; // 4 x 16 KiB pages
        let mut src_ram = vec![0u8; len];
        src_ram[16 * 1024..16 * 1024 + 16].copy_from_slice(b"SNAPSHOT_PAGE_1!");
        src_ram[48 * 1024..48 * 1024 + 16].copy_from_slice(b"SNAPSHOT_PAGE_3!");

        let written = unsafe { write_sparse_ram(src_ram.as_ptr(), len, &ram_path) }.unwrap();
        assert_eq!(written, 32 * 1024);

        let (ptr, _file) = map_cow_ram(&ram_path, len).unwrap();
        let mapped = unsafe { std::slice::from_raw_parts_mut(ptr.cast::<u8>(), len) };
        assert_eq!(&mapped[16 * 1024..16 * 1024 + 16], b"SNAPSHOT_PAGE_1!");
        assert_eq!(&mapped[48 * 1024..48 * 1024 + 16], b"SNAPSHOT_PAGE_3!");
        // Writing to MAP_PRIVATE must NOT modify ram.bin on disk!
        mapped[16 * 1024] = b'X';
        let on_disk = fs::read(&ram_path).unwrap();
        assert_eq!(&on_disk[16 * 1024..16 * 1024 + 16], b"SNAPSHOT_PAGE_1!");
        unsafe { libc::munmap(ptr, len) };

        let _ = fs::remove_dir_all(&dir);
    }
}
