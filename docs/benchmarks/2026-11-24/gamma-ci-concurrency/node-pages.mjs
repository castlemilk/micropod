import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const stage = process.argv[2];
assert.ok(["create", "append", "verify"].includes(stage));
const auxv = readFileSync("/proc/self/auxv");
let pageBytes = 0;
for (let i = 0; i + 16 <= auxv.length; i += 16) {
  if (auxv.readBigUInt64LE(i) === 6n) pageBytes = Number(auxv.readBigUInt64LE(i + 8));
}

const db = new DatabaseSync("/data/jobs.sqlite", { readOnly: stage === "verify" });
if (stage === "create") {
  db.exec("PRAGMA page_size=4096");
  db.exec("CREATE TABLE artifacts (id INTEGER PRIMARY KEY, digest BLOB NOT NULL)");
}
const journal = db.prepare(stage === "verify" ? "PRAGMA journal_mode" : "PRAGMA journal_mode=WAL").get().journal_mode;
const mmap = db.prepare("PRAGMA mmap_size=16777216").get().mmap_size;
assert.equal(journal, "wal");
assert.equal(mmap, 16777216);
assert.equal(db.prepare("PRAGMA page_size").get().page_size, 4096);
const artifact = (id) => createHash("sha256").update("build-artifact-" + id).digest();
function verify(count) {
  const hash = createHash("sha256");
  let index = 0;
  for (const row of db.prepare("SELECT id, digest FROM artifacts ORDER BY id").iterate()) {
    const bytes = Buffer.from(row.digest);
    assert.equal(row.id, index);
    assert.ok(bytes.equals(artifact(index)));
    hash.update(bytes);
    index++;
  }
  assert.equal(index, count);
  return hash.digest("hex");
}
const before = verify(stage === "create" ? 0 : stage === "append" ? 8192 : 10240);
let walFrames = null;
if (stage !== "verify") {
  const insert = db.prepare("INSERT INTO artifacts VALUES (?, ?)");
  db.exec("BEGIN IMMEDIATE");
  const [first, end] = stage === "create" ? [0, 8192] : [8192, 10240];
  for (let i = first; i < end; i++) insert.run(i, artifact(i));
  db.exec("COMMIT");
  const checkpoint = db.prepare("PRAGMA wal_checkpoint(PASSIVE)").get();
  assert.equal(checkpoint.busy, 0);
  assert.ok(checkpoint.log > 0);
  assert.equal(checkpoint.checkpointed, checkpoint.log);
  walFrames = checkpoint.log;
}
const rows = stage === "create" ? 8192 : 10240;
const after = verify(rows);
assert.equal(db.prepare("PRAGMA integrity_check").get().integrity_check, "ok");
const sqlite = db.prepare("SELECT sqlite_version() AS version").get().version;
db.close();
console.log(JSON.stringify({stage, node: process.version, arch: process.arch, sqlite, pageBytes, sqlPageBytes: 4096,
  mmap, journal, walFrames, rows, before, after, boot: readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim()}));
