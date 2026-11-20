use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    env,
    io::{self, BufRead, BufReader, Read, Write},
    net::Shutdown,
    os::unix::net::UnixStream,
    process,
};
#[cfg(target_os = "linux")]
mod service;
#[cfg(any(target_os = "linux", test))]
#[cfg_attr(all(test, not(target_os = "linux")), allow(dead_code))]
mod suite;

const ENV_KEYS: &[&str] = &[
    "GOENV",
    "GOTOOLCHAIN",
    "GOWORK",
    "GOFLAGS",
    "GOMAXPROCS",
    "CGO_ENABLED",
    "GOTELEMETRY",
    "GOPROXY",
    "GOSUMDB",
];
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

fn line(r: &mut impl BufRead, max: usize) -> Result<Vec<u8>> {
    let mut b = Vec::new();
    r.take(max as u64 + 1).read_until(b'\n', &mut b)?;
    if b.is_empty() {
        return Err("connection closed".into());
    }
    if b.len() > max || !b.ends_with(b"\n") {
        return Err("oversized or incomplete message".into());
    }
    Ok(b)
}
fn send(w: &mut impl Write, v: &Value) -> Result<()> {
    serde_json::to_writer(&mut *w, v)?;
    w.write_all(b"\n")?;
    Ok(())
}
fn response(r: &mut impl BufRead) -> Result<Value> {
    let v: Value = serde_json::from_slice(&line(r, 4 << 20)?)?;
    if let Some(err) = v["error"].as_str() {
        return Err(err.to_owned().into());
    }
    Ok(v)
}

fn client(args: &[String]) -> Result<i32> {
    let [socket, op, tail @ ..] = args else {
        return Err("expected SOCKET OPERATION [ARG...]".into());
    };
    let mut sock = UnixStream::connect(socket)?;
    let mut r = BufReader::new(sock.try_clone()?);
    let key = tail.first().map(String::as_str).unwrap_or("");
    match op.as_str() {
        "status" | "forget" | "prepare" | "reuse" => {
            let mut msg = json!({"op":op,"key":key});
            if op == "prepare" {
                let v: Value = serde_json::from_reader(io::stdin().take(1 << 20))?;
                msg["config"] = v
            }
            send(&mut sock, &msg)?;
            println!("{}", response(&mut r)?);
            Ok(0)
        }
        "session" | "run" => {
            let vars: serde_json::Map<_, _> = ENV_KEYS
                .iter()
                .filter_map(|k| env::var(k).ok().map(|v| (k.to_string(), Value::String(v))))
                .collect();
            send(
                &mut sock,
                &json!({"op":"session","key":key,"runtime":env::var("MICROPOD_OCI_RUNTIME").unwrap_or_else(|_|"runc".into()),"policy":env::var("MICROPOD_OCI_POLICY").unwrap_or_else(|_|"default".into()),"env":vars}),
            )?;
            let ready = response(&mut r)?;
            if ready["type"] != "ready" {
                return Err("executor did not become ready".into());
            }
            if op == "session" {
                send(&mut io::stdout().lock(), &ready)?;
                std::thread::spawn(move || {
                    let _ = io::copy(&mut io::stdin().lock(), &mut sock);
                    let _ = send(&mut sock, &json!({"op":"close"}));
                    // The explicit close frame also works with vsock bridges that do not propagate a half-close.
                    let _ = sock.shutdown(Shutdown::Write);
                });
                io::copy(&mut r, &mut io::stdout().lock())?;
                return Ok(0);
            }
            let [_, n, argv @ ..] = tail else {
                return Err("expected handle, count and argv".into());
            };
            if argv.is_empty() {
                return Err("missing command".into());
            }
            send(
                &mut sock,
                &json!({"id":"run","clients":n.parse::<u32>()?,"args":argv}),
            )?;
            loop {
                let f = response(&mut r)?;
                if f["id"] != "run" {
                    return Err("unexpected response id".into());
                }
                match f["type"].as_str() {
                    Some("stdout") => io::stdout()
                        .write_all(&STANDARD.decode(f["data"].as_str().unwrap_or(""))?)?,
                    Some("stderr") => io::stderr()
                        .write_all(&STANDARD.decode(f["data"].as_str().unwrap_or(""))?)?,
                    Some("done") => {
                        for job in f["results"].as_array().ok_or("missing job results")? {
                            if env::var("MICROPOD_OCI_TRACE").as_deref() == Ok("1") {
                                eprintln!("micropod-oci {job}");
                            } else if let Some(message) = job["error"].as_str() {
                                eprintln!("OCI job {}: {message}", job["index"]);
                            }
                        }
                        io::stdout().flush()?;
                        io::stderr().flush()?;
                        send(&mut sock, &json!({"op":"close"}))?;
                        return Ok(f["exit"].as_i64().ok_or("missing exit code")? as i32);
                    }
                    _ => return Err("invalid session frame".into()),
                }
            }
        }
        _ => Err("unknown OCI operation".into()),
    }
}
fn main() {
    let a: Vec<_> = env::args().skip(1).collect();
    #[cfg(target_os = "linux")]
    if a.as_slice() == ["serve"] {
        if let Err(e) = service::serve() {
            eprintln!("micropod OCI service: {e}");
            process::exit(1)
        }
        return;
    }
    match client(&a) {
        Ok(code) => process::exit(code),
        Err(e) => {
            eprintln!("micropod OCI: {e}");
            process::exit(1)
        }
    }
}
