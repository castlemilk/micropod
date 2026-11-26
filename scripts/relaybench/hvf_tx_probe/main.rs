use std::{
    env,
    ffi::c_void,
    ptr,
    time::{Duration, Instant},
};

const PAGE: usize = 16 * 1024;
const CODE: u64 = 0x4000_0000;
const DATA: u64 = CODE + PAGE as u64;
const DOORBELL: u64 = DATA + PAGE as u64;
const TOTAL: usize = 257;
const SLOTS: usize = 32;
type Result<T> = std::result::Result<T, String>;
type Window = (Device, Duration);

#[repr(C, align(16384))]
struct Page([u64; PAGE / 8]);

#[link(name = "Hypervisor", kind = "framework")]
unsafe extern "C" {
    fn hv_vm_create(config: *const c_void) -> i32;
    fn hv_vm_destroy() -> i32;
    fn hv_vcpu_create(cpu: *mut u64, exit: *mut *const c_void, config: *const c_void) -> i32;
    fn hv_vcpu_run(cpu: u64) -> i32;
    fn hv_vcpu_destroy(cpu: u64) -> i32;
    fn mp_tx_install(code: *mut c_void, size: usize) -> i32;
    fn mp_tx_map(page: *mut c_void, ipa: u64, size: usize, code: i32) -> i32;
    fn mp_tx_boot(cpu: u64, pc: u64, data: u64, bell: u64, total: u64, batch: u64) -> i32;
    fn mp_tx_exit(cpu: u64, exit: *const c_void, bell: u64, count: *mut u64) -> i32;
    fn mp_tx_produce(
        data: *mut u64,
        context: *mut c_void,
        total: u64,
        batch: u64,
        notify: extern "C" fn(*mut c_void, u64, *const u64) -> i32,
    ) -> i32;
}

fn checked(rc: i32, action: &str) -> Result<()> {
    match rc {
        0 => Ok(()),
        _ => Err(format!("{action}: {rc:#010x}")),
    }
}

#[derive(Default)]
struct Device {
    consumed: usize,
    notifications: usize,
}

impl Device {
    fn submit(&mut self, data: &Page, count: u64, batch: usize) -> Result<()> {
        let expected = batch.min(TOTAL - self.consumed);
        if count == 0 || count > SLOTS as u64 || count != expected as u64 {
            return Err(format!(
                "unexpected descriptor count {count}, expected {expected}"
            ));
        }
        for (i, slot) in data.0[..expected].iter().enumerate() {
            // The only writer has stopped at the doorbell before this read.
            if unsafe { ptr::read_volatile(slot) } != (self.consumed + i + 1) as u64 {
                return Err(format!("out-of-order descriptor at {}", self.consumed + i));
            }
        }
        self.consumed += expected;
        self.notifications += 1;
        Ok(())
    }

    fn finish(self) -> Result<Self> {
        if self.consumed != TOTAL {
            return Err(format!(
                "early completion after {} descriptors",
                self.consumed
            ));
        }
        Ok(self)
    }
}

struct NativeBackend {
    device: Device,
    batch: usize,
    complete: bool,
    error: Option<String>,
}

extern "C" fn native_notify(context: *mut c_void, count: u64, data: *const u64) -> i32 {
    // mp_tx_produce is synchronous and returns before these owners go out of scope.
    let backend = unsafe { &mut *context.cast::<NativeBackend>() };
    if count == 0 {
        backend.complete = true;
        return 0;
    }
    if let Err(e) = backend
        .device
        .submit(unsafe { &*data.cast::<Page>() }, count, backend.batch)
    {
        backend.error = Some(e);
        return -1;
    }
    0
}

fn native_control(batch: usize) -> Result<Window> {
    let mut data = Box::new(Page([0; PAGE / 8]));
    let mut backend = NativeBackend {
        device: Device::default(),
        batch,
        complete: false,
        error: None,
    };
    let start = Instant::now();
    let rc = unsafe {
        mp_tx_produce(
            data.0.as_mut_ptr(),
            ptr::addr_of_mut!(backend).cast(),
            TOTAL as u64,
            batch as u64,
            native_notify,
        )
    };
    let elapsed = start.elapsed();
    if let Some(e) = backend.error {
        return Err(e);
    }
    checked(rc, "guest producer")?;
    if !backend.complete {
        return Err("missing completion doorbell".into());
    }
    Ok((backend.device.finish()?, elapsed))
}

fn run_cpu(cpu: u64, exit: *const c_void, data: *const Page, batch: usize) -> Result<Window> {
    checked(
        unsafe { mp_tx_boot(cpu, CODE, DATA, DOORBELL, TOTAL as u64, batch as u64) },
        "boot",
    )?;
    let mut device = Device::default();
    let start = Instant::now();
    for _ in 0..=TOTAL.div_ceil(batch) {
        checked(unsafe { hv_vcpu_run(cpu) }, "hv_vcpu_run")?;
        let mut count = 0;
        match unsafe { mp_tx_exit(cpu, exit, DOORBELL, &mut count) } {
            // No guest writer is running while this shared reference exists.
            0 => device.submit(unsafe { &*data }, count, batch)?,
            1 => return Ok((device.finish()?, start.elapsed())),
            _ => return Err("unexpected guest exit".into()),
        }
    }
    Err("missing completion doorbell".into())
}

fn cleanup<T>(result: Result<T>, teardown: Result<()>) -> Result<T> {
    match (result, teardown) {
        (Ok(v), Ok(())) => Ok(v),
        (Err(a), Err(b)) => Err(format!("{a}; cleanup: {b}")),
        (Err(e), Ok(())) | (Ok(_), Err(e)) => Err(e),
    }
}

fn hardware(batch: usize) -> Result<Window> {
    let mut code = Box::new(Page([0; PAGE / 8]));
    let mut data = Box::new(Page([0; PAGE / 8]));
    let code_ptr = code.0.as_mut_ptr().cast();
    let data_ptr = data.0.as_mut_ptr().cast();
    checked(
        unsafe { mp_tx_install(code_ptr, PAGE) },
        "install guest image",
    )?;
    checked(unsafe { hv_vm_create(ptr::null()) }, "hv_vm_create")?;
    let result = (|| {
        checked(
            unsafe { mp_tx_map(code_ptr, CODE, PAGE, 1) },
            "map guest code",
        )?;
        checked(
            unsafe { mp_tx_map(data_ptr, DATA, PAGE, 0) },
            "map descriptor page",
        )?;
        let mut cpu = 0;
        let mut exit = ptr::null();
        checked(
            unsafe { hv_vcpu_create(&mut cpu, &mut exit, ptr::null()) },
            "hv_vcpu_create",
        )?;
        let result = run_cpu(cpu, exit, data_ptr.cast(), batch);
        cleanup(
            result,
            checked(unsafe { hv_vcpu_destroy(cpu) }, "hv_vcpu_destroy"),
        )
    })();
    // Destroying the VM releases its mappings before their backing boxes drop.
    let destroyed = checked(unsafe { hv_vm_destroy() }, "hv_vm_destroy");
    if destroyed.is_err() {
        // A surviving mapping must keep its backing pages until process exit.
        std::mem::forget((code, data));
    }
    cleanup(result, destroyed)
}

fn main() -> Result<()> {
    let args: Vec<_> = env::args().skip(1).collect();
    let [mode] = args.as_slice() else {
        return Err("use --native, --hvf or --paired".into());
    };
    if mode == "--paired" {
        for batch in [1, 8] {
            hardware(batch)?;
        }
        // Predeclared balanced order. Each arm starts a fresh, single-vCPU VM.
        let first_batches = [1, 8, 8, 1, 8, 1, 1, 8, 1, 8, 8, 1];
        for (index, first) in first_batches.into_iter().enumerate() {
            for batch in [first, 9 - first] {
                let (device, elapsed) = hardware(batch)?;
                println!(
                    "pair={} first_batch={} batch={} descriptors={} data_notifications={} window_ns={}",
                    index + 1,
                    first,
                    batch,
                    device.consumed,
                    device.notifications,
                    elapsed.as_nanos()
                );
            }
        }
        return Ok(());
    }
    let run = match mode.as_str() {
        "--native" => native_control,
        "--hvf" => hardware,
        _ => return Err("use --native, --hvf or --paired".into()),
    };
    for batch in [1, 8] {
        let (device, _) = run(batch)?;
        println!(
            "{} batch={} descriptors={} data_notifications={}",
            &mode[2..],
            batch,
            device.consumed,
            device.notifications
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guest_producer_handles_full_batches_and_the_last_short_batch() {
        for batch in [1, 8, SLOTS] {
            assert_eq!(
                native_control(batch).unwrap().0.notifications,
                TOTAL.div_ceil(batch)
            );
        }
    }

    #[test]
    fn invalid_doorbells_and_payloads_do_not_advance_the_device() {
        let page = Page([0; PAGE / 8]);
        let mut dev = Device::default();
        for count in [0, 1, 8, (SLOTS + 1) as u64, u64::MAX] {
            assert!(dev.submit(&page, count, 8).is_err());
        }
        assert_eq!((dev.consumed, dev.notifications), (0, 0));
        assert!(dev.finish().is_err());
    }
}
