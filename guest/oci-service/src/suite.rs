// Publish the fixed Go suite on the already-local source manifest. Docker owns image
// registration and GC. Nothing here interprets Dockerfiles or accepts arbitrary paths.
use super::Result;
use flate2::{Compression, GzBuilder};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    process::{Command, Stdio},
    sync::Mutex,
    time::Instant,
};
use tar::{Archive, Builder, EntryType, Header};

const MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";
const INDEX: &str = "application/vnd.oci.image.index.v1+json";
const CONFIG: &str = "application/vnd.oci.image.config.v1+json";
const LAYER: &str = "application/vnd.oci.image.layer.v1.tar+gzip";
const LABEL: &str = "io.micropod.ci.go-suite";
const ROOT: &str = "micropod-ci-suite";
const STORE: &str = "/var/lib/micropod/oci-native";

fn docker() -> Command {
    let mut command = Command::new("/usr/local/bin/docker");
    command.args(["--host", "unix:///var/lib/micropod/docker.sock"]);
    command
}
fn checked(command: &mut Command) -> Result<Vec<u8>> {
    let output = command.output()?;
    if !output.status.success() {
        return Err(format!(
            "worker command {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    Ok(output.stdout)
}
fn content_command() -> Command {
    let mut command = Command::new("/usr/local/bin/ctr");
    command.args([
        "-a",
        "/run/docker/containerd/containerd.sock",
        "-n",
        "moby",
        "content",
    ]);
    command
}

// With no label assignments ctr reads one descriptor without walking the store.
fn content_exists(layer: &Value) -> Result<bool> {
    let digest = layer["digest"].as_str().ok_or("missing layer digest")?;
    let result = content_command().args(["label", digest]).output()?;
    if result.status.success() {
        return Ok(true);
    }
    let error = String::from_utf8_lossy(&result.stderr);
    if error.contains("not found") {
        return Ok(false);
    }
    Err(format!("look up {digest}: {error}").into())
}

fn content(digest: &str) -> Result<Value> {
    if !digest.strip_prefix("sha256:").is_some_and(|v| {
        v.len() == 64
            && v.bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    }) {
        return Err("invalid local content digest".into());
    }
    let raw = checked(content_command().args(["get", digest]))?;
    Ok(serde_json::from_slice(&raw)?)
}

fn append<W: Write>(
    tar: &mut Builder<W>,
    name: &str,
    kind: EntryType,
    mode: u32,
    size: u64,
    source: impl Read,
) -> Result<()> {
    let mut h = Header::new_ustar();
    h.set_path(name)?;
    h.set_entry_type(kind);
    h.set_size(size);
    h.set_mode(mode);
    h.set_uid(0);
    h.set_gid(0);
    h.set_mtime(0);
    h.set_cksum();
    tar.append(&h, source)?;
    Ok(())
}

// Only the named compiler outputs are admissible. In particular a whiteout, link,
// device or alternate spelling cannot change a file in an inherited layer.
fn suite_entry(name: &str) -> Option<EntryType> {
    let parts: Vec<_> = name.split('/').collect();
    let number =
        |s: &str| !s.starts_with('0') && s.parse::<u32>().is_ok_and(|n| n.to_string() == s);
    match parts.as_slice() {
        [ROOT] | [ROOT, "tests"] => Some(EntryType::Directory),
        [ROOT, "suite.sh" | "test-count" | "product"] => Some(EntryType::Regular),
        [ROOT, "tests", n] if number(n) => Some(EntryType::Directory),
        [ROOT, "tests", n, "test" | "package"] if number(n) => Some(EntryType::Regular),
        _ => None,
    }
}

struct HashWriter<W> {
    output: W,
    hash: Sha256,
}
impl<W: Write> Write for HashWriter<W> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let n = self.output.write(data)?;
        self.hash.update(&data[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.output.flush()
    }
}
fn hash_writer<W: Write>(output: W) -> HashWriter<W> {
    HashWriter {
        output,
        hash: Sha256::new(),
    }
}

fn canonical_layer(source: &mut File, output: &mut File) -> Result<String> {
    let mut entries = BTreeMap::new();
    let total = source.metadata()?.len();
    let mut archive = Archive::new(&mut *source);
    for entry in archive.entries_with_seek()? {
        let entry = entry?;
        let path = entry.path_bytes();
        let name = std::str::from_utf8(&path)?;
        let name = name.strip_suffix('/').unwrap_or(name);
        let kind = suite_entry(name).ok_or("unexpected suite output path")?;
        if entry
            .raw_file_position()
            .checked_add(entry.size())
            .is_none_or(|end| end > total)
        {
            return Err("truncated compiler archive".into());
        }
        if entry.header().entry_type() != kind || (kind.is_dir() && entry.size() != 0) {
            return Err("unexpected suite output type".into());
        }
        let mode = if kind.is_dir() || entry.header().mode()? & 0o111 != 0 {
            0o755
        } else {
            0o644
        };
        if entries
            .insert(
                name.to_owned(),
                (kind, mode, entry.size(), entry.raw_file_position()),
            )
            .is_some()
        {
            return Err("duplicate suite file".into());
        }
    }
    for required in [
        ROOT,
        "micropod-ci-suite/tests",
        "micropod-ci-suite/product",
        "micropod-ci-suite/suite.sh",
        "micropod-ci-suite/test-count",
    ] {
        if !entries.contains_key(required) {
            return Err("missing suite output".into());
        }
    }
    let mut tar = Builder::new(hash_writer(output));
    for (name, (kind, mode, size, offset)) in entries {
        source.seek(SeekFrom::Start(offset))?;
        append(
            &mut tar,
            &name,
            kind,
            mode,
            size,
            Read::by_ref(source).take(size),
        )?;
    }
    Ok(format!("sha256:{:x}", tar.into_inner()?.hash.finalize()))
}

fn compress(raw: &mut File, blob: &mut File) -> Result<Value> {
    raw.rewind()?;
    let mut gz = GzBuilder::new()
        .mtime(0)
        .write(hash_writer(blob), Compression::fast());
    io::copy(raw, &mut gz)?;
    let result = gz.finish()?;
    let size = result.output.stream_position()?;
    result.output.rewind()?;
    Ok(
        json!({"mediaType":LAYER, "digest":format!("sha256:{:x}",result.hash.finalize()), "size":size}),
    )
}

// Hints contain descriptors only. Docker owns the blob and may collect it. Losing
// the whole table costs one compression on the next use of each output.
static RECENT: Mutex<VecDeque<(String, Value)>> = Mutex::new(VecDeque::new());
fn remember(diff_id: &str, layer: &Value) {
    let mut recent = RECENT.lock().unwrap();
    recent.retain(|(id, _)| id != diff_id);
    recent.push_back((diff_id.to_owned(), layer.clone()));
    if recent.len() > 128 {
        recent.pop_front();
    }
}

fn descriptor(media: &str, bytes: &[u8]) -> Value {
    json!({"mediaType":media, "digest":format!("sha256:{:x}",Sha256::digest(bytes)), "size":bytes.len()})
}

fn metadata(
    mut manifest: Value,
    mut config: Value,
    key: &str,
    layer: &Value,
    diff_id: &str,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let layers = manifest["layers"]
        .as_array_mut()
        .ok_or("missing parent layers")?;
    if !config["config"].is_null() && !config["config"].is_object()
        || !config["config"]["Labels"].is_null() && !config["config"]["Labels"].is_object()
    {
        return Err("invalid parent runtime configuration".into());
    }
    let ids = config["rootfs"]["diff_ids"]
        .as_array_mut()
        .ok_or("missing parent diff IDs")?;
    if layers.len() != ids.len() {
        return Err("parent manifest and config disagree".into());
    }
    layers.push(layer.clone());
    ids.push(json!(diff_id));
    config["config"]["Labels"][LABEL] = json!(key);
    if let Some(history) = config["history"]
        .as_array_mut()
        .filter(|history| !history.is_empty())
    {
        history.push(json!({"created_by":"Micropod prepare-go-suite"}));
    }
    let config = serde_json::to_vec(&config)?;
    manifest["config"] = descriptor(CONFIG, &config);
    Ok((config, serde_json::to_vec(&manifest)?))
}

fn add_bytes<W: Write>(tar: &mut Builder<W>, name: &str, bytes: &[u8]) -> Result<()> {
    append(
        tar,
        name,
        EntryType::Regular,
        0o644,
        bytes.len() as u64,
        bytes,
    )
}
fn blob_path(desc: &Value) -> String {
    format!("blobs/sha256/{}", &desc["digest"].as_str().unwrap()[7..])
}

// None means the parent needs the general Docker exporter. Other errors must reach
// the caller, including a stopped compiler that belongs to a different request.
pub(super) fn publish(key: &str, compiler: &str) -> Result<Option<Value>> {
    let clock = Instant::now();
    let containers: Vec<Value> =
        serde_json::from_slice(&checked(docker().args(["container", "inspect", compiler]))?)?;
    let c = containers.first().ok_or("compiler not found")?;
    if c["State"]["Status"] != "exited"
        || c["State"]["ExitCode"] != 0
        || c["Config"]["Labels"]["io.micropod.ci.go-suite.compiler"] != key
    {
        return Err("expected a successful compiler for this suite".into());
    }
    let parent = content(c["Image"].as_str().ok_or("missing compiler parent")?)?;
    if parent["schemaVersion"] != 2
        || parent["mediaType"] != MANIFEST
        || parent["config"]["mediaType"] != CONFIG
        || parent.get("artifactType").is_some()
        || parent.get("subject").is_some()
    {
        return Ok(None);
    }
    let parent_layers = parent["layers"]
        .as_array()
        .ok_or("invalid parent manifest")?
        .len();
    let config = content(
        parent["config"]["digest"]
            .as_str()
            .ok_or("missing parent config")?,
    )?;
    let mut source = tempfile::tempfile_in(STORE)?;
    checked(
        docker()
            .args(["cp", &format!("{compiler}:/tmp/{ROOT}"), "-"])
            .stdout(Stdio::from(source.try_clone()?)),
    )?;
    let copy_ms = clock.elapsed().as_millis() as u64;
    source.rewind()?;
    let mut raw = tempfile::tempfile_in(STORE)?;
    let diff_id = canonical_layer(&mut source, &mut raw)?;
    drop(source);
    let canonical_ms = clock.elapsed().as_millis() as u64 - copy_ms;
    let hint = RECENT
        .lock()
        .unwrap()
        .iter()
        .find(|(id, _)| id == &diff_id)
        .map(|(_, desc)| desc.clone());
    let shared = if let Some(layer) = &hint
        && content_exists(layer)?
    {
        match import(&parent, &config, key, layer, &diff_id, None) {
            Ok(imported) => Some(imported),
            // A GC between lookup and load may remove the referenced blob.
            Err(e) if content_exists(layer)? => return Err(e),
            Err(_) => None,
        }
    } else {
        None
    };
    let reused = shared.is_some();
    let stale = hint.is_some() && !reused;
    let (image, bytes, layer, compress_ms) = match (shared, hint) {
        (Some((image, bytes)), Some(layer)) => (image, bytes, layer, 0),
        _ => {
            let start = Instant::now();
            let mut blob = tempfile::tempfile_in(STORE)?;
            let layer = compress(&mut raw, &mut blob)?;
            drop(raw);
            let elapsed = start.elapsed().as_millis() as u64;
            let (image, bytes) = import(&parent, &config, key, &layer, &diff_id, Some(blob))?;
            remember(&diff_id, &layer);
            (image, bytes, layer, elapsed)
        }
    };
    let size = layer["size"].as_u64().ok_or("missing layer size")?;
    Ok(Some(
        json!({"method":"oci-layer","image":image,"diff_id":diff_id,"layer":layer["digest"],
        "layer_bytes":size,"parent_layers":parent_layers,"import_bytes":bytes,"blob_bytes_sent":if reused {0} else {size},
        "layer_reused":reused,"stale_hint":stale,"copy_ms":copy_ms,"canonical_ms":canonical_ms,"compress_ms":compress_ms,
        "load_ms":clock.elapsed().as_millis() as u64-copy_ms-canonical_ms-compress_ms}),
    ))
}

fn import(
    parent: &Value,
    config: &Value,
    key: &str,
    layer: &Value,
    diff_id: &str,
    blob: Option<File>,
) -> Result<(Value, u64)> {
    let (config, manifest) = metadata(parent.clone(), config.clone(), key, layer, diff_id)?;
    let cd = descriptor(CONFIG, &config);
    let mut md = descriptor(MANIFEST, &manifest);
    md["annotations"] = json!({"io.containerd.image.name":format!("docker.io/micropod-internal/ci-go-suite:{key}"),"org.opencontainers.image.ref.name":key});
    let index = serde_json::to_vec(&json!({"schemaVersion":2,"mediaType":INDEX,"manifests":[md]}))?;
    let mut tar = Builder::new(tempfile::tempfile_in(STORE)?);
    if let Some(blob) = blob {
        let size = blob.metadata()?.len();
        append(
            &mut tar,
            &blob_path(layer),
            EntryType::Regular,
            0o644,
            size,
            blob,
        )?;
    }
    add_bytes(&mut tar, &blob_path(&cd), &config)?;
    add_bytes(&mut tar, &blob_path(&md), &manifest)?;
    add_bytes(&mut tar, "index.json", &index)?;
    add_bytes(&mut tar, "oci-layout", br#"{"imageLayoutVersion":"1.0.0"}"#)?;
    let mut layout = tar.into_inner()?;
    let import_bytes = layout.stream_position()?;
    layout.rewind()?;
    checked(
        docker()
            .args(["image", "load", "--quiet"])
            .stdin(Stdio::from(layout)),
    )?;
    Ok((md["digest"].clone(), import_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempfile;

    fn layer(reverse: bool, stamp: u64, product: &[u8]) -> Result<(String, String)> {
        let mut tar = Builder::new(tempfile()?);
        let mut files = vec![
            (ROOT, EntryType::Directory, &b""[..]),
            ("micropod-ci-suite/tests", EntryType::Directory, b""),
            ("micropod-ci-suite/product", EntryType::Regular, product),
            ("micropod-ci-suite/suite.sh", EntryType::Regular, b"sh"),
            ("micropod-ci-suite/test-count", EntryType::Regular, b"0\n"),
        ];
        if reverse {
            files.reverse();
        }
        for (name, kind, data) in files {
            let mut h = Header::new_gnu();
            h.set_path(name)?;
            h.set_entry_type(kind);
            h.set_mode(if name.ends_with("product") {
                0o751
            } else {
                0o644
            });
            h.set_uid(stamp);
            h.set_gid(stamp);
            h.set_mtime(stamp);
            h.set_size(data.len() as u64);
            h.set_cksum();
            tar.append(&h, data)?;
        }
        let mut source = tar.into_inner()?;
        source.rewind()?;
        let mut blob = tempfile()?;
        let mut raw = tempfile()?;
        let diff = canonical_layer(&mut source, &mut raw)?;
        let layer = compress(&mut raw, &mut blob)?;
        let hashes = (diff, layer["digest"].as_str().unwrap().to_owned());
        blob.rewind()?;
        let mut archive = Archive::new(flate2::read::GzDecoder::new(blob));
        for file in archive.entries()? {
            let file = file?;
            let h = file.header();
            assert_eq!((h.uid()?, h.gid()?, h.mtime()?), (0, 0, 0));
            if file.path()?.ends_with("product") {
                assert_eq!(h.mode()?, 0o755);
            }
        }
        Ok(hashes)
    }
    #[test]
    fn identical_outputs_share_a_layer_across_builds() -> Result<()> {
        let a = layer(false, 0, b"hello")?;
        assert_eq!(a, layer(true, 12345, b"hello")?);
        assert_ne!(a, layer(false, 0, b"HELLO")?);
        Ok(())
    }
    #[test]
    fn only_compiler_outputs_can_be_published() {
        for path in [
            "../escape",
            "/micropod-ci-suite/product",
            "micropod-ci-suite/.wh.product",
            "micropod-ci-suite/tests/../a",
            "micropod-ci-suite/tests/01/test",
            "micropod-ci-suite/tests/1/link",
            "micropod-ci-suite//product",
        ] {
            assert!(suite_entry(path).is_none());
        }
        assert_eq!(
            suite_entry("micropod-ci-suite/tests/12/test"),
            Some(EntryType::Regular)
        );
    }
    #[test]
    fn rejects_links_and_duplicate_entries_before_import() -> Result<()> {
        for kind in [EntryType::Symlink, EntryType::Regular] {
            let mut tar = Builder::new(tempfile()?);
            for _ in 0..2 {
                append(
                    &mut tar,
                    "micropod-ci-suite/product",
                    kind,
                    0o755,
                    0,
                    io::empty(),
                )?;
            }
            let mut source = tar.into_inner()?;
            source.rewind()?;
            let error = canonical_layer(&mut source, &mut tempfile()?)
                .unwrap_err()
                .to_string();
            assert_eq!(
                error,
                if kind == EntryType::Regular {
                    "duplicate suite file"
                } else {
                    "unexpected suite output type"
                }
            );
        }
        Ok(())
    }
    #[test]
    fn inherits_parent_configuration_and_layer_descriptors() -> Result<()> {
        let runtime = json!({"ArgsEscaped":true,"User":"234","WorkingDir":"/repo","Entrypoint":["./run"],"Cmd":["build"],"Env":["A=0"],"Volumes":{"/cache":{}},"Healthcheck":{"Test":["CMD","true"]},"Labels":{"existing":"yes"}});
        let parent = json!({"architecture":"arm64","os":"linux","config":runtime,"rootfs":{"type":"layers","diff_ids":["base"]},"history":[{"created_by":"base"}]});
        let base = json!({"digest":"base","mediaType":"original","annotations":{"origin":"keep"}});
        let man = json!({"mediaType":MANIFEST,"layers":[base],"schemaVersion":2,"config":{}});
        let layer = json!({"digest":"new"});
        let (cfg, manifest) = metadata(man, parent, "key", &layer, "diff")?;
        let parsed: Value = serde_json::from_slice(&cfg)?;
        let manifest: Value = serde_json::from_slice(&manifest)?;
        let mut expect = runtime;
        expect["Labels"][LABEL] = json!("key");
        assert_eq!(parsed["config"], expect);
        assert_eq!(parsed["rootfs"]["diff_ids"], json!(["base", "diff"]));
        assert_eq!(manifest["layers"], json!([base, layer]));
        assert_eq!(manifest["config"], descriptor(CONFIG, &cfg));
        assert_eq!(parsed["history"].as_array().unwrap().len(), 2);
        Ok(())
    }
}
