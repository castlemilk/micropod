import { Code, ConnectError } from "@connectrpc/connect";
import { createMicropodClient, type MicropodClient } from "./client.js";

/**
 * A secret the sandbox can use without seeing it: the guest gets a random
 * placeholder in its environment; the host proxy swaps in the real value
 * only in HTTPS request heads to `hosts`.
 */
export interface SecretConfig {
  /** Host environment variable holding the value (read by this SDK). */
  from?: string;
  /** The value itself. */
  value?: string;
  /**
   * A command (argv, no shell) that prints the value — raw, or
   * `{"version":1,"value":"…","expires_at":"<RFC 3339>"}`. This SDK runs it
   * here, in the calling process (Node), before the sandbox starts and
   * again a minute before the value expires (or every `ttl`), pushing each
   * new value to the sandbox; the daemon never runs commands. Refreshing
   * stops with `stop()`/`checkpoint()`, or when this process exits — the
   * last value then serves until its expiry.
   */
  command?: string[];
  /** Working directory for `command` (default: this process's). */
  cwd?: string;
  /** Refresh interval when `command` reports no expiry, e.g. "15m". */
  ttl?: string;
  /** HTTPS hosts that get the real value ("*.example.com" for subdomains). */
  hosts: string[];
}

export interface NetworkConfig {
  /** Egress allowlist; everything else is refused. "*.npmjs.org" matches subdomains. */
  allow?: string[];
}

export interface SandboxStartOptions {
  /** Checkpoint to boot from (see `checkpoint`). */
  from?: string;
  /** OCI image to boot (default "alpine:latest"). */
  image?: string;
  /** Sandbox id; generated when omitted. */
  name?: string;
  /** vCPUs (default 2). */
  cpus?: number;
  /** Memory in MiB (default 2048). */
  memory?: number;
  /** Root disk size in MiB (default 8192). */
  diskSize?: number;
  /** NAT network with internet access (default false). */
  allowNet?: boolean;
  /** Published TCP ports, "host:guest" or "ip:host:guest" (default ip 127.0.0.1). */
  ports?: string[];
  /**
   * Host directories: `{ "./src": "/workspace" }`. Guest writes go to a
   * per-sandbox copy; append ":ro" for read-only or ":rw" to write through
   * to the host (`{ "./out": "/out:rw" }`).
   */
  mounts?: Record<string, string>;
  /** Host loopback ports the guest reaches as `host.micropod.internal:<port>`. */
  exposeHost?: number[];
  secrets?: Record<string, SecretConfig>;
  network?: NetworkConfig;
  /** Guest nameservers (needs a network). */
  dnsResolvers?: string[];
  /** Environment for the sandbox and every process in it. */
  env?: Record<string, string>;
  /** Default working directory. */
  cwd?: string;
  labels?: Record<string, string>;
  /**
   * The micropod daemon (default `$MICROPOD_API` or http://localhost:45454);
   * a bare host gets the daemon's `/api` mount appended.
   */
  baseUrl?: string;
  /** Use this client instead of creating one. */
  client?: MicropodClient;
  /** Called when refreshing a `command` secret fails (default: console.warn). It is retried in 10 s. */
  onSecretError?: (name: string, error: unknown) => void;
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export interface SpawnOptions {
  cwd?: string;
  env?: Record<string, string>;
}

export interface WatchEvent {
  event: "create" | "modify" | "delete" | "rename";
  path: string;
}

export interface WatchOptions {
  /** Watch the whole tree (default true). */
  recursive?: boolean;
}

export interface DirEntry {
  name: string;
  type: "file" | "dir" | "symlink" | "other";
  size: number;
  mode: number;
  mtime: number;
}

export interface StatResult {
  size: number;
  /** st_mode, file-type bits included. */
  mode: number;
  /** Seconds since the epoch. */
  mtime: number;
  isDir: boolean;
  isFile: boolean;
  isSymlink: boolean;
}

/**
 * A micro-VM on the local micropod daemon that stays up between calls: run
 * commands in it, stream their output, move files in and out, watch paths,
 * checkpoint it.
 *
 * ```ts
 * const sb = await Sandbox.start({ image: "python:3.12", mounts: { "./src": "/workspace" } });
 * const { stdout } = await sb.exec("python3 -c 'print(1+1)'");
 * await sb.checkpoint("after-run"); // saves the disk and stops the VM
 * ```
 */
export class Sandbox {
  private readonly refreshers = new Map<string, ReturnType<typeof setTimeout>>();
  private stopped = false;

  private constructor(
    readonly id: string,
    private readonly client: MicropodClient,
  ) {}

  /** Boot a sandbox; resolves once it can run commands. */
  static async start(opts: SandboxStartOptions = {}): Promise<Sandbox> {
    const client = opts.client ?? Sandbox.client(opts.baseUrl);
    const secrets: Record<string, { value: string; expiresAt: string; hosts: string[] }> = {};
    const minted: Record<string, Date | undefined> = {};
    for (const [name, config] of Object.entries(opts.secrets ?? {})) {
      const { value, expiresAt } = await resolveSecret(name, config);
      secrets[name] = { value, expiresAt: expiresAt?.toISOString() ?? "", hosts: config.hosts };
      minted[name] = expiresAt;
    }
    const ref = await client.startSandbox({
      image: opts.from ? "" : (opts.image ?? ""),
      fromCheckpoint: opts.from ?? "",
      name: opts.name ?? "",
      cpus: opts.cpus ?? 0,
      memoryMib: BigInt(opts.memory ?? 0),
      env: Object.entries(opts.env ?? {}).map(([k, v]) => `${k}=${v}`),
      workdir: opts.cwd ?? "",
      mounts: Object.entries(opts.mounts ?? {}).map(([host, guest]) => {
        const [guestPath, mode = "overlay"] = guest.split(":");
        return { hostPath: absolute(host), guestPath, mode };
      }),
      ports: (opts.ports ?? []).map(parsePort),
      allowNet: opts.allowNet ?? false,
      labels: opts.labels ?? {},
      options: {
        exposeHost: opts.exposeHost ?? [],
        allowHosts: opts.network?.allow ?? [],
        dnsResolvers: opts.dnsResolvers ?? [],
        diskSizeMib: BigInt(opts.diskSize ?? 0),
        secrets,
      },
    });
    const sandbox = new Sandbox(ref.id, client);
    for (const [name, config] of Object.entries(opts.secrets ?? {})) {
      if (config.command) sandbox.scheduleRefresh(name, config, minted[name], opts.onSecretError);
    }
    return sandbox;
  }

  /** Mint `name` again shortly before it expires and push it to the sandbox. */
  private scheduleRefresh(
    name: string,
    config: SecretConfig,
    expiresAt: Date | undefined,
    onError: SandboxStartOptions["onSecretError"],
    delay?: number,
  ): void {
    if (this.stopped) return;
    const due = delay ?? refreshDelay(expiresAt, config.ttl);
    const timer = setTimeout(async () => {
      try {
        const next = await resolveSecret(name, config);
        await this.client.updateSandboxSecret({
          id: this.id,
          name,
          value: next.value,
          expiresAt: next.expiresAt?.toISOString() ?? "",
        });
        this.scheduleRefresh(name, config, next.expiresAt, onError);
      } catch (err) {
        // The sandbox is gone: nothing left to refresh.
        if (err instanceof ConnectError && (err.code === Code.NotFound || err.code === Code.FailedPrecondition)) return;
        (onError ?? ((n, e) => console.warn(`micropod: refreshing secret ${n} failed:`, e)))(name, err);
        this.scheduleRefresh(name, config, expiresAt, onError, 10_000);
      }
    }, due);
    // Refreshes never keep the host process alive on their own.
    (timer as { unref?: () => void }).unref?.();
    this.refreshers.set(name, timer);
  }

  private stopRefreshing(): void {
    this.stopped = true;
    for (const timer of this.refreshers.values()) clearTimeout(timer);
    this.refreshers.clear();
  }

  /** A handle on a sandbox that is already running (e.g. from another process). */
  static attach(id: string, opts: { baseUrl?: string; client?: MicropodClient } = {}): Sandbox {
    return new Sandbox(id, opts.client ?? Sandbox.client(opts.baseUrl));
  }

  /** Checkpoints saved on this host. */
  static async listCheckpoints(opts: { baseUrl?: string; client?: MicropodClient } = {}) {
    const client = opts.client ?? Sandbox.client(opts.baseUrl);
    const res = await client.listCheckpoints({});
    return res.checkpoints.map((c) => ({
      name: c.name,
      image: c.image,
      sizeBytes: Number(c.sizeBytes),
      created: new Date(c.created),
    }));
  }

  static async deleteCheckpoint(name: string, opts: { baseUrl?: string; client?: MicropodClient } = {}) {
    const client = opts.client ?? Sandbox.client(opts.baseUrl);
    await client.deleteCheckpoint({ name });
  }

  /**
   * Run a command to completion. A string runs under `/bin/sh -c`; an array
   * is an argv.
   */
  async exec(command: string | string[], opts: SpawnOptions & { stdin?: string | Uint8Array } = {}): Promise<ExecResult> {
    const proc = await this.spawn(command, { ...opts, stdin: opts.stdin !== undefined });
    const stdout: Uint8Array[] = [];
    const stderr: Uint8Array[] = [];
    proc.on("stdout", (chunk) => stdout.push(chunk));
    proc.on("stderr", (chunk) => stderr.push(chunk));
    if (opts.stdin !== undefined) {
      await proc.write(opts.stdin);
      await proc.closeStdin();
    }
    const exitCode = await proc.exited;
    return { stdout: decode(stdout), stderr: decode(stderr), exitCode };
  }

  /**
   * Start a process and return at once; its output arrives as "stdout" and
   * "stderr" events, then "exit". Output from before a listener is attached
   * is kept for it.
   */
  async spawn(command: string | string[], opts: SpawnOptions & { stdin?: boolean } = {}): Promise<SandboxProcess> {
    const ref = await this.client.startProcess({
      id: this.id,
      command: typeof command === "string" ? ["/bin/sh", "-c", command] : command,
      cwd: opts.cwd ?? "",
      env: Object.entries(opts.env ?? {}).map(([k, v]) => `${k}=${v}`),
      stdin: opts.stdin ?? true,
    });
    return new SandboxProcess(this.client, this.id, ref.processId, ref.pid);
  }

  /**
   * Report changes under `path`, observed inside the guest. Resolves once
   * the watch is live; call `close()` on the result to stop.
   */
  async watch(path: string, handler: (event: WatchEvent) => void, opts: WatchOptions = {}): Promise<Watcher> {
    const abort = new AbortController();
    const stream = this.client.watchPath(
      { id: this.id, path, recursive: opts.recursive ?? true },
      { signal: abort.signal },
    );
    const watcher = new Watcher(abort);
    await new Promise<void>((resolve, reject) => {
      let ready = false;
      (async () => {
        try {
          for await (const e of stream) {
            if (e.event === "ready") {
              ready = true;
              resolve();
            } else {
              handler({ event: e.event as WatchEvent["event"], path: e.path });
            }
          }
          if (!ready) reject(new Error(`watch ${path} ended before it was ready`));
        } catch (err) {
          if (!ready) reject(err);
          else if (!abort.signal.aborted) watcher.fail(err);
        }
      })();
    });
    return watcher;
  }

  async readFile(path: string): Promise<Uint8Array> {
    return (await this.client.readFile({ id: this.id, path })).data;
  }

  async writeFile(
    path: string,
    content: Uint8Array | string,
    opts: { append?: boolean; mode?: number; createParents?: boolean } = {},
  ): Promise<void> {
    await this.client.writeFile({
      id: this.id,
      path,
      data: typeof content === "string" ? new TextEncoder().encode(content) : content,
      append: opts.append ?? false,
      mode: opts.mode,
      createParents: opts.createParents ?? false,
    });
  }

  /** Create a directory (with parents unless `recursive: false`). */
  async mkdir(path: string, opts: { recursive?: boolean } = {}): Promise<void> {
    await this.client.makeDir({ id: this.id, path, recursive: opts.recursive ?? true });
  }

  async readDir(path: string): Promise<DirEntry[]> {
    const res = await this.client.listDir({ id: this.id, path });
    return res.entries.map((e) => ({
      name: e.name,
      type: e.type as DirEntry["type"],
      size: Number(e.size),
      mode: e.mode,
      mtime: Number(e.mtime),
    }));
  }

  async stat(path: string): Promise<StatResult> {
    const s = await this.client.statPath({ id: this.id, path });
    return {
      size: Number(s.size),
      mode: s.mode,
      mtime: Number(s.mtime),
      isDir: s.type === "dir",
      isFile: s.type === "file",
      isSymlink: s.type === "symlink",
    };
  }

  /** Delete a file, or a directory — non-empty ones only with `recursive`. */
  async remove(path: string, opts: { recursive?: boolean } = {}): Promise<void> {
    await this.client.removePath({ id: this.id, path, recursive: opts.recursive ?? false });
  }

  async rename(oldPath: string, newPath: string): Promise<void> {
    await this.client.renamePath({ id: this.id, from: oldPath, to: newPath });
  }

  async copy(src: string, dst: string, opts: { recursive?: boolean } = {}): Promise<void> {
    await this.client.copyPath({ id: this.id, from: src, to: dst, recursive: opts.recursive ?? false });
  }

  async chmod(path: string, mode: number): Promise<void> {
    await this.client.chmodPath({ id: this.id, path, mode });
  }

  async exists(path: string): Promise<boolean> {
    try {
      await this.client.statPath({ id: this.id, path });
      return true;
    } catch (err) {
      if (err instanceof ConnectError && err.code === Code.NotFound) return false;
      throw err;
    }
  }

  /** Save the sandbox's disk as checkpoint `name` and stop the VM. */
  async checkpoint(name: string): Promise<void> {
    this.stopRefreshing();
    await this.client.checkpointSandbox({ id: this.id, name });
  }

  /** Stop the VM and discard its disk. */
  async stop(): Promise<void> {
    this.stopRefreshing();
    await this.client.deleteContainer({ id: this.id, force: true });
  }

  private static client(baseUrl?: string): MicropodClient {
    const env = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env;
    let url = (baseUrl ?? env?.MICROPOD_API ?? "http://localhost:45454").replace(/\/+$/, "");
    // Sandboxes live on the micropod daemon, which mounts Connect under /api.
    if (!/^[a-z][a-z0-9+.-]*:\/\/[^/]+\/./i.test(url)) url += "/api";
    // Sandbox calls aren't idempotent (a retried StartProcess runs twice).
    return createMicropodClient(url, { retry: false });
  }
}

type ProcessListener = { stdout: (chunk: Uint8Array) => void; stderr: (chunk: Uint8Array) => void; exit: (code: number) => void };

/** A process started with `Sandbox.spawn`. */
export class SandboxProcess {
  /** Resolves with the exit code (128 + n when killed by signal n). */
  readonly exited: Promise<number>;
  private readonly listeners: { [K in keyof ProcessListener]: ProcessListener[K][] } = { stdout: [], stderr: [], exit: [] };
  private readonly pending: { stdout: Uint8Array[]; stderr: Uint8Array[] } = { stdout: [], stderr: [] };
  private exitCode?: number;

  constructor(
    private readonly client: MicropodClient,
    readonly sandboxId: string,
    readonly id: string,
    readonly pid: number,
  ) {
    this.exited = this.follow();
    // An unobserved failure shouldn't crash the host process; `exited` still rejects.
    this.exited.catch(() => {});
  }

  on<K extends keyof ProcessListener>(event: K, listener: ProcessListener[K]): this {
    (this.listeners[event] as ProcessListener[K][]).push(listener);
    if (event === "exit") {
      if (this.exitCode !== undefined) (listener as ProcessListener["exit"])(this.exitCode);
    } else {
      const kept = this.pending[event as "stdout" | "stderr"].splice(0);
      for (const chunk of kept) (listener as ProcessListener["stdout"])(chunk);
    }
    return this;
  }

  off<K extends keyof ProcessListener>(event: K, listener: ProcessListener[K]): this {
    const list = this.listeners[event] as ProcessListener[K][];
    const i = list.indexOf(listener);
    if (i >= 0) list.splice(i, 1);
    return this;
  }

  /** Write to the process's stdin. */
  async write(data: string | Uint8Array): Promise<void> {
    await this.client.writeProcessStdin({
      id: this.sandboxId,
      processId: this.id,
      data: typeof data === "string" ? new TextEncoder().encode(data) : data,
      close: false,
    });
  }

  /** Close stdin (EOF). */
  async closeStdin(): Promise<void> {
    await this.client.writeProcessStdin({ id: this.sandboxId, processId: this.id, close: true });
  }

  /** Send a signal (default SIGTERM). */
  async kill(signal = "SIGTERM"): Promise<void> {
    await this.client.signalProcess({ id: this.sandboxId, processId: this.id, signal });
  }

  private async follow(): Promise<number> {
    for await (const e of this.client.streamProcess({ id: this.sandboxId, processId: this.id })) {
      switch (e.event.case) {
        case "stdout":
        case "stderr": {
          const stream = e.event.case;
          const listeners = this.listeners[stream];
          if (listeners.length === 0) this.pending[stream].push(e.event.value);
          for (const l of listeners) l(e.event.value);
          break;
        }
        case "exitCode":
          this.exitCode = e.event.value;
          for (const l of this.listeners.exit) l(e.event.value);
          return e.event.value;
      }
    }
    throw new Error(`process ${this.id}: stream ended without an exit`);
  }
}

/** A live `Sandbox.watch`. */
export class Watcher {
  private error?: unknown;

  constructor(private readonly abort: AbortController) {}

  /** Stop watching. */
  close(): void {
    this.abort.abort();
  }

  /** The error that ended the watch early, if any. */
  get failure(): unknown {
    return this.error;
  }

  /** @internal */
  fail(err: unknown): void {
    this.error = err;
  }
}

type Env = { process?: { env?: Record<string, string | undefined> } };

/** A secret's current value: from the environment, as given, or minted by its command. */
async function resolveSecret(name: string, s: SecretConfig): Promise<{ value: string; expiresAt?: Date }> {
  const sources = [s.from, s.value, s.command].filter((x) => x !== undefined).length;
  if (sources !== 1) throw new Error(`secret ${name}: set exactly one of from, value or command`);
  if (s.command) {
    if (s.command.length === 0) throw new Error(`secret ${name}: command is empty`);
    return parseSecretOutput(name, await runCommand(name, s.command, s.cwd));
  }
  if (s.from !== undefined) {
    const value = (globalThis as Env).process?.env?.[s.from] ?? "";
    if (!value) throw new Error(`secret ${name}: environment variable ${s.from} is unset`);
    return { value };
  }
  return { value: s.value ?? "" };
}

type ExecFile = (
  file: string,
  args: string[],
  options: { cwd?: string; timeout: number; maxBuffer: number },
  callback: (error: Error | null, stdout: string | Uint8Array, stderr: string | Uint8Array) => void,
) => unknown;

async function runCommand(name: string, argv: string[], cwd?: string): Promise<string> {
  let execFile: ExecFile;
  try {
    // A computed specifier: bundlers and browser builds leave it alone.
    const specifier = "node:child_process";
    ({ execFile } = (await import(specifier)) as { execFile: ExecFile });
  } catch {
    throw new Error(`secret ${name}: command secrets need Node (child_process)`);
  }
  return new Promise((resolve, reject) =>
    execFile(argv[0], argv.slice(1), { cwd, timeout: 30_000, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      if (err) {
        const detail = String(stderr || err.message).trim().slice(-500);
        reject(new Error(`secret ${name}: ${argv[0]} failed: ${detail}`));
      } else {
        resolve(String(stdout));
      }
    }),
  );
}

/** Raw stdout, or `{"version":1,"value":"…","expires_at":"…"}` (AWS credential_process shape). */
export function parseSecretOutput(name: string, output: string): { value: string; expiresAt?: Date } {
  const text = output.trim();
  let value = text;
  let expiresAt: Date | undefined;
  if (text.startsWith("{")) {
    let parsed: { version?: unknown; value?: unknown; expires_at?: unknown };
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error(`secret ${name}: the command printed malformed JSON`);
    }
    if (parsed.version !== undefined && parsed.version !== 1) {
      throw new Error(`secret ${name}: unsupported version ${String(parsed.version)}`);
    }
    if (typeof parsed.value !== "string") throw new Error(`secret ${name}: the command's JSON has no string "value"`);
    value = parsed.value;
    if (parsed.expires_at !== undefined) {
      expiresAt = new Date(String(parsed.expires_at));
      if (Number.isNaN(expiresAt.getTime())) throw new Error(`secret ${name}: unreadable expires_at`);
    }
  }
  if (!value) throw new Error(`secret ${name}: the command printed an empty value`);
  if (/[\r\n\0]/.test(value)) throw new Error(`secret ${name}: the value contains a line break or NUL`);
  return { value, expiresAt };
}

/** When to mint again: a minute before expiry, else every `ttl` (default 5m). */
export function refreshDelay(expiresAt: Date | undefined, ttl: string | undefined, now = Date.now()): number {
  if (expiresAt) return Math.max(1000, expiresAt.getTime() - now - 60_000);
  const match = /^(\d+)(s|m|h)?$/.exec(ttl ?? "");
  if (ttl && !match) throw new Error(`ttl ${ttl}: want e.g. 90s, 15m, 1h`);
  const n = match ? Number(match[1]) : 300;
  const unit = match?.[2] === "h" ? 3_600_000 : match?.[2] === "m" ? 60_000 : 1000;
  return Math.max(1000, n * unit);
}

function parsePort(spec: string) {
  const parts = spec.split(":");
  if (parts.length < 2 || parts.length > 3) throw new Error(`port ${spec}: want host:guest or ip:host:guest`);
  const [hostIp, host, guest] = parts.length === 3 ? parts : ["", ...parts];
  return { hostIp, hostPort: Number(host), containerPort: Number(guest), protocol: "tcp" };
}

/** Host paths go to the daemon absolute: resolve against this process's cwd. */
function absolute(path: string): string {
  if (path.startsWith("/")) return path;
  const cwd = (globalThis as { process?: { cwd?: () => string } }).process?.cwd?.();
  if (!cwd) throw new Error(`mount ${path}: use an absolute host path`);
  const parts: string[] = [];
  for (const part of `${cwd}/${path}`.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return "/" + parts.join("/");
}

function decode(chunks: Uint8Array[]): string {
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const all = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    all.set(c, offset);
    offset += c.length;
  }
  return new TextDecoder().decode(all);
}
