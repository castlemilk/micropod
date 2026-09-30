// End-to-end: the Sandbox class against a live micropod API.
//   MICROPOD_API=http://127.0.0.1:45987 node test/sandbox.e2e.mjs   (after `npm run build`)
// scripts/e2e_sandbox_sdk.sh boots a signed scratch API and runs this.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Sandbox } from "../dist/index.js";

const baseUrl = process.env.MICROPOD_API ?? "http://127.0.0.1:45454";
let passed = 0;
async function step(name, fn) {
  const t = performance.now();
  await fn();
  passed++;
  console.log(`  ✓ ${name} (${Math.round(performance.now() - t)} ms)`);
}

const host = mkdtempSync(join(tmpdir(), "sbx-sdk-"));
writeFileSync(join(host, "in.txt"), "from-host\n");

const t0 = performance.now();
const sb = await Sandbox.start({
  baseUrl,
  mounts: { [host]: "/workspace" },
  env: { GREETING: "hi" },
  cwd: "/workspace",
});
console.log(`  booted ${sb.id} in ${Math.round(performance.now() - t0)} ms`);
const checkpoint = `sdk-e2e-${Date.now()}`;
try {
  await step("exec: env, cwd, mount, stderr, exit code", async () => {
    const r = await sb.exec("echo $GREETING; cat in.txt; echo oops >&2; exit 4");
    assert.deepEqual(r, { stdout: "hi\nfrom-host\n", stderr: "oops\n", exitCode: 4 });
  });

  await step("exec with stdin and an argv", async () => {
    const r = await sb.exec(["wc", "-l"], { stdin: "a\nb\nc\n" });
    assert.equal(r.stdout.trim(), "3");
  });

  await step("spawn: streamed output, stdin, exit event", async () => {
    const proc = await sb.spawn("while read line; do echo got:$line; done; echo done >&2");
    const out = [];
    const err = [];
    proc.on("stdout", (c) => out.push(Buffer.from(c).toString()));
    proc.on("stderr", (c) => err.push(Buffer.from(c).toString()));
    let exitEvent;
    proc.on("exit", (code) => (exitEvent = code));
    await proc.write("one\n");
    await proc.write("two\n");
    await proc.closeStdin();
    assert.equal(await proc.exited, 0);
    assert.equal(exitEvent, 0);
    assert.equal(out.join(""), "got:one\ngot:two\n");
    assert.equal(err.join(""), "done\n");
    assert.ok(proc.pid > 0);
  });

  await step("spawn: several at once, kill", async () => {
    const slow = await sb.spawn("sleep 30");
    const quick = await Promise.all([1, 2, 3].map((n) => sb.exec(`echo ${n}`)));
    assert.deepEqual(quick.map((r) => r.stdout), ["1\n", "2\n", "3\n"]);
    await slow.kill("SIGKILL");
    assert.equal(await slow.exited, 137);
  });

  await step("files: write/read binary, stat, readDir, mkdir, rename, copy, chmod, exists, remove", async () => {
    const blob = new Uint8Array(70_000).map((_, i) => i % 251);
    await sb.writeFile("/data/bin/blob", blob, { createParents: true });
    assert.deepEqual(await sb.readFile("/data/bin/blob"), blob);
    await sb.writeFile("/data/note.txt", "hello");
    await sb.writeFile("/data/note.txt", " world", { append: true });
    assert.equal(new TextDecoder().decode(await sb.readFile("/data/note.txt")), "hello world");
    const st = await sb.stat("/data/note.txt");
    assert.equal(st.size, 11);
    assert.ok(st.isFile && !st.isDir);
    await sb.mkdir("/data/a/b");
    await sb.rename("/data/note.txt", "/data/a/note.txt");
    await sb.copy("/data/a", "/data/c", { recursive: true });
    await sb.chmod("/data/c/note.txt", 0o700);
    assert.equal((await sb.stat("/data/c/note.txt")).mode & 0o777, 0o700);
    const entries = (await sb.readDir("/data")).map((e) => `${e.name}:${e.type}`).sort();
    assert.deepEqual(entries, ["a:dir", "bin:dir", "c:dir"]);
    await assert.rejects(sb.remove("/data/a"), /not empty/i);
    await sb.remove("/data/a", { recursive: true });
    assert.equal(await sb.exists("/data/a"), false);
    assert.equal(await sb.exists("/data/c/note.txt"), true);
  });

  await step("mounts: guest writes stay in the sandbox's copy", async () => {
    await sb.writeFile("/workspace/in.txt", "changed in guest\n");
    assert.equal(readFileSync(join(host, "in.txt"), "utf8"), "from-host\n");
  });

  await step("watch: create, modify, delete", async () => {
    const events = [];
    const watcher = await sb.watch("/workspace", (e) => events.push(`${e.event} ${e.path}`));
    await sb.writeFile("/workspace/new.txt", "1");
    await sb.remove("/workspace/in.txt");
    await new Promise((r) => setTimeout(r, 1500));
    watcher.close();
    assert.ok(events.includes("create /workspace/new.txt"), events.join(", "));
    assert.ok(events.includes("delete /workspace/in.txt"), events.join(", "));
  });

  await step("watch: two writes within a second are both seen (inotify on alpine, no inotifywait)", async () => {
    const events = [];
    const watcher = await sb.watch("/data", (e) => events.push(`${e.event} ${e.path}`));
    await sb.writeFile("/data/tick", "1");
    await sb.writeFile("/data/tick", "22");
    await new Promise((r) => setTimeout(r, 600));
    watcher.close();
    assert.ok(events.includes("create /data/tick"), events.join(", "));
    assert.ok(events.includes("modify /data/tick"), events.join(", "));
  });

  await step("checkpoint, then start from it", async () => {
    await sb.writeFile("/data/kept.txt", "kept");
    await sb.checkpoint(checkpoint);
    assert.ok((await Sandbox.listCheckpoints({ baseUrl })).some((c) => c.name === checkpoint));
    const again = await Sandbox.start({ baseUrl, from: checkpoint });
    try {
      assert.equal(new TextDecoder().decode(await again.readFile("/data/kept.txt")), "kept");
    } finally {
      await again.stop();
    }
  });
} finally {
  await sb.stop().catch(() => {});
  await Sandbox.deleteCheckpoint(checkpoint, { baseUrl }).catch(() => {});
}

// Distroless: no shell, no coreutils — idling, files and watches still work
// (the guest helper), as the image's non-root user.
const distroless = await Sandbox.start({ baseUrl, image: "gcr.io/distroless/static-debian12:nonroot" });
try {
  await step("distroless: idle, write/read/stat/list, watch, errors", async () => {
    await distroless.writeFile("/tmp/x/y.txt", "no shell here", { createParents: true });
    assert.equal(new TextDecoder().decode(await distroless.readFile("/tmp/x/y.txt")), "no shell here");
    assert.ok((await distroless.stat("/tmp/x/y.txt")).isFile);
    assert.deepEqual((await distroless.readDir("/tmp/x")).map((e) => e.name), ["y.txt"]);
    const events = [];
    const watcher = await distroless.watch("/tmp/x", (e) => events.push(`${e.event} ${e.path}`));
    await distroless.remove("/tmp/x/y.txt");
    await new Promise((r) => setTimeout(r, 500));
    watcher.close();
    assert.ok(events.includes("delete /tmp/x/y.txt"), events.join(", "));
    await assert.rejects(distroless.writeFile("/etc/owned", "x"), /permission/i, "nonroot can't write /etc");
    await assert.rejects(distroless.exec("echo hi"), /cannot start \/bin\/sh/, "no /bin/sh");
  });
} finally {
  await distroless.stop().catch(() => {});
}

// A command secret is minted here, by the SDK, and pushed: the daemon runs
// nothing on the host.
{
  const mint = join(host, "mint.sh");
  writeFileSync(mint, `#!/bin/sh\nn=$(cat ${host}/n 2>/dev/null || echo 0); n=$((n+1)); echo $n > ${host}/n\n` +
    `printf '{"version":1,"value":"tok-%s","expires_at":"%s"}' "$n" "$(date -u -v+62S +%Y-%m-%dT%H:%M:%SZ)"\n`, { mode: 0o755 });
  const sec = await Sandbox.start({
    baseUrl, allowNet: true,
    secrets: { TOKEN: { command: [mint], hosts: ["example.invalid"] } },
  });
  try {
    await step("command secret minted by the SDK, refreshed by push", async () => {
      const r = await sec.exec("echo $TOKEN");
      assert.match(r.stdout, /^micropod_secret_[0-9a-f]{24}\n$/, "the guest only sees a placeholder");
      assert.equal(readFileSync(join(host, "n"), "utf8").trim(), "1", "minted once at start");
      // expires in ~62 s: the SDK refreshes a minute early, i.e. within ~2 s.
      await new Promise((r) => setTimeout(r, 3500));
      assert.ok(Number(readFileSync(join(host, "n"), "utf8").trim()) >= 2, "re-minted and pushed before expiry");
    });
  } finally {
    await sec.stop().catch(() => {});
  }
}
console.log("  (the API refuses command secrets itself — see the unit tests)");
console.log(`\n${passed} passed`);
