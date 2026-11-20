use super::{ENV_KEYS, Result, line, send};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{BufReader, Read, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::Duration,
};

const DATA: &str = "/var/lib/micropod/oci-native";
const RUN: &str = "/run/micropod-oci";
const SOCKET: &str = "/var/lib/micropod/oci.sock";
#[derive(Default)]
struct Counts {
    active: usize,
    opened: u64,
    servicing: usize,
    draining: bool,
    prepare_hits: u64,
    prepare_loads: u64,
    sessions_by_scope: BTreeMap<String, usize>,
}
type Registry = Arc<Mutex<Counts>>;
struct Admission {
    registry: Registry,
    session: bool,
}
impl Admission {
    fn new(r: &Registry, session: bool) -> Result<Self> {
        let mut c = r.lock().unwrap();
        if c.draining {
            return Err("worker is draining".into());
        }
        c.servicing += 1;
        if session {
            c.active += 1;
            c.opened += 1
        }
        Ok(Self {
            registry: r.clone(),
            session,
        })
    }
}
impl Drop for Admission {
    fn drop(&mut self) {
        let mut c = self.registry.lock().unwrap();
        c.servicing -= 1;
        if self.session {
            c.active -= 1
        }
    }
}
fn status(r: &Registry) -> Value {
    let c = r.lock().unwrap();
    json!({"version":1,"pid":std::process::id(),"active_sessions":c.active,"opened_sessions":c.opened,
        "draining":c.draining,"prepare_hits":c.prepare_hits,"prepare_loads":c.prepare_loads,
        "sessions_by_scope":c.sessions_by_scope})
}
// Keep this path independent of Docker, containerd and the session registry. It must
// stay usable when a cold burst is waiting on memory reclaim or container creation.
fn kernel_metrics() -> Value {
    let read = |path| fs::read_to_string(path).unwrap_or_default();
    let fields = |text: &str, name: &str| -> Option<u64> {
        text.lines().find_map(|line| {
            let mut words = line.split_whitespace();
            if words.next()? != name {
                return None;
            }
            words.next()?.parse().ok()
        })
    };
    let pressure = |path| {
        let text = read(path);
        let total = |kind| -> Option<u64> {
            let row = text
                .lines()
                .find(|line| line.split_whitespace().next() == Some(kind))?;
            row.split_whitespace()
                .find_map(|word| word.strip_prefix("total=")?.parse().ok())
        };
        json!({"some_usec":total("some"),"full_usec":total("full")})
    };
    let memory = read("/proc/meminfo");
    json!({
        "boot":read("/proc/sys/kernel/random/boot_id").trim(),
        "uptime_seconds":read("/proc/uptime").split_whitespace().next().and_then(|s| s.parse::<f64>().ok()),
        "available_bytes":fields(&memory,"MemAvailable:").and_then(|n| n.checked_mul(1024)),
        "memory_bytes":fields(&memory,"MemTotal:").and_then(|n| n.checked_mul(1024)),
        "oom_kills":fields(&read("/proc/vmstat"),"oom_kill"),
        "cpu":pressure("/proc/pressure/cpu"),"memory":pressure("/proc/pressure/memory"),"io":pressure("/proc/pressure/io")
    })
}
fn key(v: &str) -> bool {
    v.len() == 64
        && v.bytes()
            .all(|a| a.is_ascii_digit() || (b'a'..=b'f').contains(&a))
}
fn scope(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 63
        && v.bytes().enumerate().all(|(i, a)| {
            a.is_ascii_lowercase() || a.is_ascii_digit() || i > 0 && matches!(a, b'-' | b'_')
        })
}
fn handle(k: &str) -> PathBuf {
    Path::new(DATA).join("handles").join(k)
}
fn lower(k: &str) -> String {
    format!("{RUN}/lowers/{k}")
}
fn lock(k: &str) -> Result<File> {
    Ok(OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(format!("{DATA}/locks/{k}"))?)
}
fn ctr(args: &[&str]) -> Result<String> {
    let p = Command::new("/usr/local/bin/ctr")
        .args([
            "--address",
            "/run/docker/containerd/containerd.sock",
            "--namespace",
            "moby",
            "--timeout",
            "60s",
        ])
        .args(args)
        .output()?;
    if !p.status.success() {
        return Err(format!(
            "ctr {}: {}",
            args.first().unwrap_or(&""),
            String::from_utf8_lossy(&p.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(p.stdout)?)
}
fn mounted(point: &str) -> Result<bool> {
    Ok(fs::read_to_string("/proc/self/mountinfo")?
        .lines()
        .any(|s| s.split_whitespace().nth(4) == Some(point)))
}
fn mount_image(k: &str) -> Result<()> {
    let path = lower(k);
    if mounted(&path)? {
        return Ok(());
    }
    fs::create_dir_all(&path)?;
    ctr(&[
        "images",
        "mount",
        "--platform",
        "linux/arm64",
        &format!("docker.io/micropod-internal/oci-native:{k}"),
        &path,
    ])?;
    // A prepared handle can span many days. Keep its view rooted independently of ctr's one-hour lease.
    if let Err(e) = ctr(&[
        "snapshots",
        "label",
        &path,
        "containerd.io/gc.root=micropod",
    ]) {
        let _ = ctr(&[
            "images",
            "unmount",
            "--snapshotter",
            "overlayfs",
            "--rm",
            &path,
        ]);
        return Err(e);
    }
    Ok(())
}
// Return true when the immutable policy and its live image mount were reused.
fn register(k: &str, cfg: &Value) -> Result<bool> {
    let f = lock(k)?;
    f.lock_shared()?;
    let current = handle(k).join("config.json");
    if current.is_file() && mounted(&lower(k))? {
        if serde_json::from_slice::<Value>(&fs::read(current)?)? != *cfg {
            return Err("conflicting immutable handle".into());
        }
        return Ok(true);
    }
    f.unlock()?;
    f.lock()?;
    let sc = cfg["scope"].as_str().ok_or("missing scope")?;
    if !scope(sc) || !cfg["spec"].is_object() || cfg["resolver"].as_str().is_none() {
        return Err("invalid prepared configuration".into());
    }
    for name in ["gomod", "gobuild"] {
        if !Path::new(&format!(
            "/var/lib/docker/volumes/micropod-ci-scoped-{sc}-{name}/_data"
        ))
        .is_dir()
        {
            return Err(format!("missing prepared {name} volume").into());
        }
    }
    let h = handle(k);
    if h.exists() {
        if serde_json::from_slice::<Value>(&fs::read(h.join("config.json"))?)? != *cfg {
            return Err("conflicting immutable handle".into());
        }
        if mounted(&lower(k))? {
            return Ok(true);
        }
    } else {
        let staging = h.with_extension("pending");
        if staging.exists() {
            fs::remove_dir_all(&staging)?
        }
        fs::create_dir(&staging)?;
        fs::write(staging.join("config.json"), serde_json::to_vec(cfg)?)?;
        fs::write(
            staging.join("template.json"),
            serde_json::to_vec(&cfg["spec"])?,
        )?;
        fs::write(
            staging.join("resolv.conf"),
            cfg["resolver"].as_str().unwrap(),
        )?;
        fs::set_permissions(
            staging.join("resolv.conf"),
            fs::Permissions::from_mode(0o644),
        )?;
        fs::rename(staging, &h)?;
    }
    mount_image(k)?;
    Ok(false)
}
fn forget(k: &str) -> Result<()> {
    let f = lock(k)?;
    f.try_lock()
        .map_err(|_| "handle has active sessions or preparation")?;
    let path = lower(k);
    let h = handle(k);
    if h.exists() || Path::new(&path).exists() {
        // The tmpfs mountpoint disappears on reboot. The snapshot and its lease are on ext4.
        fs::create_dir_all(&path)?;
        ctr(&[
            "images",
            "unmount",
            "--snapshotter",
            "overlayfs",
            "--rm",
            &path,
        ])?;
        fs::remove_dir(&path)?
    }
    if h.exists() {
        fs::remove_dir_all(h)?
    }
    Ok(())
}
fn uid() -> Result<String> {
    let mut b = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut b)?;
    Ok(b.iter().map(|n| format!("{n:02x}")).collect())
}
fn session(sock: &UnixStream, k: &str, v: &Value, registry: &Registry) -> Result<()> {
    let f = lock(k)?;
    f.lock_shared()?;
    // An established handle survives a kernel reboot. Serialize the first cold re-mount.
    if !mounted(&lower(k))? {
        f.unlock()?;
        f.lock()?;
        if !handle(k).is_dir() {
            return Err("unknown handle".into());
        }
        mount_image(k)?;
        f.unlock()?;
        f.lock_shared()?;
    }
    let cfg: Value = serde_json::from_slice(&fs::read(handle(k).join("config.json"))?)?;
    if !mounted(&lower(k))? {
        return Err("handle released during session open".into());
    }
    let id = uid()?;
    let rt = v["runtime"].as_str().unwrap_or("runc");
    if !matches!(rt, "runc" | "crun") {
        return Err("unsupported OCI runtime".into());
    }
    let policy = v["policy"].as_str().unwrap_or("default");
    if !matches!(
        policy,
        "default"
            | "parallel"
            | "single"
            | "window4"
            | "window8"
            | "window16"
            | "affinity"
            | "batch"
            | "batch-affinity"
    ) {
        return Err("unknown OCI scheduling policy".into());
    }
    let scope = cfg["scope"].as_str().ok_or("invalid scope")?;
    let mut child = Command::new("/opt/micropod-oci/executor");
    child
        .arg("session")
        .env_clear()
        .env(
            "PATH",
            "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        )
        .env("MICROPOD_NATIVE_SESSION", &id)
        .env("MICROPOD_NATIVE_HANDLE", k)
        .env("MICROPOD_NATIVE_SCOPE", scope)
        .env("MICROPOD_JOB_RUNTIME", rt)
        .env("MICROPOD_NATIVE_POLICY", policy);
    if let Some(vars) = v["env"].as_object() {
        for (name, value) in vars {
            if !ENV_KEYS.contains(&name.as_str()) {
                return Err("unsupported job environment setting".into());
            }
            child.env(name, value.as_str().ok_or("invalid environment value")?);
        }
    }
    child
        .stdin(Stdio::from(std::os::fd::OwnedFd::from(sock.try_clone()?)))
        .stdout(Stdio::from(std::os::fd::OwnedFd::from(sock.try_clone()?)));
    let parent = std::process::id() as i32;
    // Only async-signal-safe syscalls run between fork and exec. A session owns its mount namespace.
    unsafe {
        child.pre_exec(move || {
            libc::umask(0o022);
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) < 0
                || libc::unshare(libc::CLONE_NEWNS) < 0
                || libc::mount(
                    std::ptr::null(),
                    c"/".as_ptr(),
                    std::ptr::null(),
                    libc::MS_REC | libc::MS_PRIVATE,
                    std::ptr::null(),
                ) < 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent {
                return Err(std::io::Error::from_raw_os_error(libc::ECANCELED));
            }
            Ok(())
        });
    }
    let mut child = child.spawn()?;
    {
        let mut c = registry.lock().unwrap();
        *c.sessions_by_scope.entry(scope.to_owned()).or_default() += 1;
    }
    let done = child.wait();
    {
        let mut c = registry.lock().unwrap();
        if let Some(n) = c.sessions_by_scope.get_mut(scope) {
            *n -= 1;
            if *n == 0 {
                c.sessions_by_scope.remove(scope);
            }
        }
    }
    let done = done?;
    for dir in [format!("{RUN}/sessions/{id}"), format!("{DATA}/jobs/{id}")] {
        if Path::new(&dir).exists() {
            fs::remove_dir_all(dir)?
        }
    }
    if !done.success() {
        return Err(format!("OCI executor exited with {done}").into());
    }
    Ok(())
}
fn serve_one(mut sock: UnixStream, r: &Registry) -> Result<()> {
    sock.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(sock.try_clone()?);
    let head = line(&mut reader, 1 << 20)?;
    if head.starts_with(b"GET ") || head.starts_with(b"POST ") {
        let request = std::str::from_utf8(&head)?;
        let mut total = 0;
        loop {
            let h = line(&mut reader, 8192)?;
            total += h.len();
            if total > 16384 {
                return Err("oversized control headers".into());
            }
            if h == b"\r\n" || h == b"\n" {
                break;
            }
        }
        let route = request
            .split_whitespace()
            .nth(1)
            .unwrap_or("")
            .trim_start_matches('/');
        let code = match (request.split_whitespace().next(), route) {
            (Some("GET"), "status" | "oci/v1/status" | "kernel" | "oci/v1/kernel") => 200,
            (Some("POST"), "drain" | "oci/v1/drain") => {
                let mut c = r.lock().unwrap();
                if c.servicing != 0 {
                    409
                } else {
                    c.draining = true;
                    200
                }
            }
            _ => 404,
        };
        let body = if code == 200 && matches!(route, "kernel" | "oci/v1/kernel") {
            kernel_metrics()
        } else {
            status(r)
        }
        .to_string();
        write!(
            sock,
            "HTTP/1.1 {code} {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            if code == 200 { "OK" } else { "Unavailable" },
            body.len()
        )?;
        return Ok(());
    }
    if !reader.buffer().is_empty() {
        return Err("wait for the session greeting before sending work".into());
    }
    drop(reader);
    sock.set_read_timeout(None)?;
    let v: Value = serde_json::from_slice(&head)?;
    let op = v["op"].as_str().unwrap_or("");
    if op == "status" {
        return send(&mut sock, &status(r));
    }
    let k = v["key"].as_str().ok_or("missing handle")?;
    if !key(k) {
        return Err("invalid handle".into());
    }
    let _admitted = Admission::new(r, op == "session")?;
    match op {
        "reuse" => {
            let f = lock(k)?;
            f.lock_shared()?;
            if !handle(k).join("config.json").is_file() || !mounted(&lower(k))? {
                return Err("handle needs preparation".into());
            }
            r.lock().unwrap().prepare_hits += 1;
        }
        "prepare" => {
            let hit = register(k, &v["config"])?;
            let mut c = r.lock().unwrap();
            if hit {
                c.prepare_hits += 1
            } else {
                c.prepare_loads += 1
            }
        }
        "forget" => forget(k)?,
        "session" => return session(&sock, k, &v, r),
        _ => return Err("unknown service operation".into()),
    }
    send(&mut sock, &json!({"ok":true}))
}
pub fn serve() -> Result<()> {
    unsafe {
        libc::umask(0o077);
    }
    for dir in ["handles", "jobs", "locks"] {
        fs::create_dir_all(Path::new(DATA).join(dir))?
    }
    for dir in ["lowers", "sessions"] {
        fs::create_dir_all(Path::new(RUN).join(dir))?
    }
    let owner = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(format!("{RUN}/owner"))?;
    owner.try_lock()?;
    let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
    let marker = Path::new(DATA).join("boot");
    if fs::read_to_string(&marker).ok().as_ref() != Some(&boot) {
        for entry in fs::read_dir(format!("{DATA}/jobs"))? {
            let e = entry?;
            let name = e.file_name();
            if e.file_type()?.is_dir()
                && name
                    .to_str()
                    .is_some_and(|v| v.len() == 32 && v.bytes().all(|c| c.is_ascii_hexdigit()))
            {
                fs::remove_dir_all(e.path())?
            }
        }
        fs::write(&marker, boot)?;
    }
    if Path::new(SOCKET).exists() {
        fs::remove_file(SOCKET)?
    }
    let listener = UnixListener::bind(SOCKET)?;
    eprintln!("micropod OCI listening on {SOCKET}");
    let r: Registry = Default::default();
    for conn in listener.incoming() {
        let Ok(sock) = conn else { continue };
        let r = r.clone();
        std::thread::spawn(move || {
            if let Ok(mut reply) = sock.try_clone()
                && let Err(e) = serve_one(sock, &r)
            {
                let _ = send(&mut reply, &json!({"error": e.to_string()}));
            }
        });
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_paths() {
        assert!(key(&"a".repeat(64)));
        assert!(!key(&"/".repeat(64)));
        assert!(scope("repo_12-a"));
        assert!(!scope("../repo"));
        assert!(!scope("-repo"));
    }
}
