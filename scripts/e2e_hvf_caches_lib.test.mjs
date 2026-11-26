// Unit tests for the pure parts of scripts/e2e_hvf_caches.sh: the plan's
// GOFLAGS merge, the store paths each check expects, the docker arguments of
// auto mode and of QUAL_MANUAL_WIRING=1, and the check/control bookkeeping.
// No machine is needed: the script is sourced with QUAL_LIB_ONLY=1, which
// defines its functions and returns before any install, container or trap.
//
//   node --test scripts/e2e_hvf_caches_lib.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const SCRIPT = fileURLToPath(new URL('./e2e_hvf_caches.sh', import.meta.url));

// Run bash snippet after sourcing the script's functions; returns stdout lines.
function lib(snippet, env = {}) {
  const out = mkdtempSync(join(tmpdir(), 'qual-lib-'));
  try {
    const r = spawnSync('/bin/bash', ['-c', `source "${SCRIPT}" || exit 9\n${snippet}`], {
      encoding: 'utf8',
      env: { PATH: process.env.PATH, HOME: process.env.HOME, QUAL_LIB_ONLY: '1', QUAL_OUT: out, ...env },
    });
    assert.equal(r.status, 0, `bash failed (${r.status}): ${r.stderr}`);
    return { lines: r.stdout.split('\n').filter((l) => l !== ''), out, tsv: () => readFileSync(join(out, 'checks.tsv'), 'utf8') };
  } finally {
    // the caller reads tsv() before this returns; keep dir until then
    setImmediate(() => rmSync(out, { recursive: true, force: true }));
  }
}

test('sourcing for tests has no side effects', () => {
  const { lines } = lib('echo "$INSTALLED:$(trap -p EXIT | wc -l | tr -d " ")"');
  assert.deepEqual(lines, ['0:0']);
});

test('the GOFLAGS merge appends -trimpath unless a -trimpath form is present', () => {
  const { lines } = lib(`for v in "" -mod=mod "-mod=vendor -trimpath" -trimpath=false "-x --trimpath"; do echo "[$(merge_goflags "$v")]"; done`);
  assert.deepEqual(lines, ['[-trimpath]', '[-mod=mod -trimpath]', '[-mod=vendor -trimpath]', '[-trimpath=false]', '[-x --trimpath]']);
});

test('auto mode expects the plan store layout', () => {
  const { lines } = lib('for k in gomod gobuild npm pnpm uv corepack yarnberry; do expect $k 1000 sc; done; expect pip 1000 sc; expect yarn 0 sc; expect cargo 0 sc; expect cargo_lock 0 sc');
  const root = '/var/lib/micropod/caches/scopes/sc';
  assert.deepEqual(lines, [
    `${root}/gomod`, `${root}/gobuild`, `${root}/npm`, `${root}/pnpm`, `${root}/uv`, `${root}/corepack`, `${root}/yarnberry`,
    `${root}/pip/u1000`, `${root}/yarn/u0`, `${root}/cargo/registry`, `${root}/cargo/.package-cache`,
  ]);
});

test('hand wiring expects its named volumes', () => {
  const { lines } = lib('QW=/ws/qual-7; for k in gomod pip yarn yarnberry cargo cargo_lock; do expect $k 1000 sc; done', { QUAL_MANUAL_WIRING: '1' });
  const v = '/var/lib/micropod/engine/volumes';
  assert.deepEqual(lines, [`${v}/qm-sc/gomod`, `${v}/qm-sc/pip/u1000`, `${v}/qm-sc-yarn-u1000`, `${v}/qm-sc-yarnberry`, `${v}/qm-sc-cargo-registry`, '/qual-7/qm/sc/package-cache']);
});

test('auto mode passes only the scope label, user, network and the request env', () => {
  const run = (args) => lib(`build_args ${args}; printf '%s\\n' "\${RUNARGS[@]}"`).lines;
  assert.deepEqual(run('golang:alpine 0 default on -e GOFLAGS=-mod=mod'), ['-e', 'GOFLAGS=-mod=mod']); // guard:guest (guest container env)
  assert.deepEqual(run('golang:alpine 1000 q2-go on'), ['--user', '1000:1000', '--label', 'io.micropod.cache.scope=q2-go']);
  assert.deepEqual(run('node:22-alpine node sc none --label x=y'), ['--user', 'node', '--network', 'none', '--label', 'io.micropod.cache.scope=sc', '--label', 'x=y']);
  assert.deepEqual(run('golang:alpine drop1000 - on'), ['-e', 'QDROP=1000']);
});

test('hand wiring adds exactly the plan mounts and env', () => {
  const env = { QUAL_MANUAL_WIRING: '1' };
  const run = (args) => lib(`manual_prep() { :; }; QW=/ws/q; build_args ${args}; printf '%s\\n' "\${RUNARGS[@]}"`, env).lines;
  const go = run('golang:alpine 1000 sc on -e GOFLAGS=-mod=mod -e QEDIT=x'); // guard:guest (guest container env)
  assert.ok(go.includes('io.micropod.cache=off'), 'a real engine must not attach on top');
  assert.ok(go.includes('qm-sc:/micropod/cache'));
  for (const e of ['GOMODCACHE=/micropod/cache/gomod', 'GOCACHE=/micropod/cache/gobuild', 'GOFLAGS=-mod=mod -trimpath',
    'npm_config_cache=/micropod/cache/npm', 'pnpm_config_store_dir=/micropod/cache/pnpm', 'npm_config_store_dir=/micropod/cache/pnpm',
    'PIP_CACHE_DIR=/micropod/cache/pip/u1000', 'UV_CACHE_DIR=/micropod/cache/uv', 'UV_LINK_MODE=copy', 'COREPACK_HOME=/micropod/cache/corepack', 'QEDIT=x']) {
    assert.ok(go.includes(e), `missing ${e}`);
  }
  assert.equal(go.filter((a) => a.startsWith('GOFLAGS=')).length, 1, 'the request GOFLAGS is merged, not duplicated'); // guard:guest (guest container env)
  assert.ok(!go.some((a) => a.includes('yarn') || a.includes('cargo')), 'no path-mode binds for a golang image');
  const node0 = run('node:22-alpine 0 sc on');
  assert.ok(node0.includes('qm-sc-yarn-u0:/usr/local/share/.cache/yarn'));
  assert.ok(node0.includes('qm-sc-yarnberry:/root/.yarn/berry'));
  const node1000 = run('node:22-alpine 1000 sc on');
  assert.ok(node1000.includes('qm-sc-yarn-u1000:/home/node/.cache/yarn'));
  assert.ok(node1000.includes('qm-sc-yarnberry:/home/node/.yarn/berry'));
  const rust = run('rust:1-alpine 0 sc on');
  for (const m of ['qm-sc-cargo-registry:/usr/local/cargo/registry', 'qm-sc-cargo-git:/usr/local/cargo/git',
    '/ws/q/qm/sc/package-cache:/usr/local/cargo/.package-cache', '/ws/q/qm/sc/package-cache-mutate:/usr/local/cargo/.package-cache-mutate']) {
    assert.ok(rust.includes(m), `missing ${m}`);
  }
  const override = run('python:3.11-alpine 1000 sc on -e PIP_CACHE_DIR=/micropod/cache/pip/u0');
  assert.deepEqual(override.filter((a) => a.startsWith('PIP_CACHE_DIR=')), ['PIP_CACHE_DIR=/micropod/cache/pip/u0'], 'a request variable wins');
  const lease = lib(`manual_prep() { :; }; QW=/ws/q; NO_YARN=1 build_args node:22-alpine 0 sc on; printf '%s\\n' "\${RUNARGS[@]}"`, env).lines;
  assert.ok(!lease.some((a) => a.includes('-yarn-u')), 'NO_YARN stands in for a busy exclusive lease');
  assert.deepEqual(run('golang:alpine 0 - on'), [], 'scope "-" wires nothing');
});

test('checks count, controls collect, and hand wiring skips what it cannot stand in for', () => {
  const r = lib(`SECTION=T9
check auto "a" 1 1; check auto "b" 1 2; checkp engine "c" x y 0
begin_ctx nc; check auto "third run hits" "rc=0 compiles=2" "rc=0 compiles=0"; end_ctx
ctx_failed nc "third run" && echo ctx-failed; echo "got=$(ctx_got nc 'third run')"; echo "$PASS $FAIL $SKIP"`);
  assert.deepEqual(r.lines.slice(-3), ['ctx-failed', 'got=rc=0 compiles=2', '1 2 0']);
  assert.match(r.tsv(), /^pass\tT9\tauto\ta\t/m);
  assert.match(r.tsv(), /^fail\tT9\tengine\tc\tx\ty$/m);
  const m = lib('SECTION=T9; check auto a 1 1; check engine b 1 2; check bundle c 1 2; check buildhit d 1 1; check safety e 1 1; echo "$PASS $FAIL $SKIP"', { QUAL_MANUAL_WIRING: '1' });
  assert.equal(m.lines.at(-1), '3 0 2');
});

test('a store property only counts on the scope store', () => {
  const r = lib(`SECTION=T9; QR=$(mktemp -d)
printf 'store.npm=/var/lib/micropod/caches/scopes/s/npm\nscan.npm.owner_only=0\n' >"$QR/on.res"
printf 'store.npm=rootfs:/root/.npm\nscan.npm.owner_only=0\n' >"$QR/off.res"
check_on auto "on" on npm /var/lib/micropod/caches/scopes/s/npm "$(r on scan.npm.owner_only)" 0
check_on auto "off" off npm /var/lib/micropod/caches/scopes/s/npm "$(r off scan.npm.owner_only)" 0
rm -rf "$QR"; echo "$PASS $FAIL"`);
  assert.equal(r.lines.at(-1), '1 1');
  assert.match(r.tsv(), /^fail\tT9\tauto\toff\tinconclusive, npm is not on the scope store \(store=rootfs:\/root\/.npm\): 0\t/m);
});

test('small predicates', () => {
  const { lines } = lib(`under /a/b/c /a/b && echo 1; under /a/bc /a/b || echo 2; under /a/b /a/b && echo 3
words "-mod=mod -trimpath" -trimpath -mod=mod && echo 4; words "-trimpath=false" -trimpath || echo 5
gt0 3 && echo 6; gt0 0 || echo 7; gt0 missing || echo 8`);
  assert.deepEqual(lines, ['1', '2', '3', '4', '5', '6', '7', '8']);
});
