// Guard for the shared Go build cache on the Macs (see the user's global
// rules and docs/runbooks/go-build-cache.md in sfh-next): one shared GOCACHE,
// -trimpath kept whenever GOFLAGS is set, and nobody cleans the caches.
//
//   node --test scripts/e2e_hvf_caches_guard.test.mjs
//
// It fails when a script under scripts/ or ci/
//   - sets GOCACHE to a mktemp, $TMPDIR or /tmp path (a per-task cache),
//   - runs `go clean -cache` or `go clean -modcache`, or rm -rf's
//     ~/Library/Caches/go-build* or ~/go/pkg/mod,
//   - sets GOFLAGS without -trimpath (an environment GOFLAGS replaces the
//     machine-wide `go env -w GOFLAGS=-trimpath`), unless the same command
//     passes -trimpath to go itself.
// A static scan cannot tell the Mac from a Linux guest or container, so a
// line that only configures a guest (a container's env, a guest-side job)
// says so with a `guard:guest` comment, and pre-existing guest-side lines
// are listed in ALLOWED with the reason they are not Mac-side.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = fileURLToPath(new URL('..', import.meta.url));
const SELF = fileURLToPath(import.meta.url);
// The one shared fallback the runbook allows for sandboxes that cannot write
// ~/Library/Caches/go-build (never a per-task directory).
const SHARED_FALLBACK = '/private/tmp/go-build-agents';

const TEMP = /mktemp|\$\{?TMPDIR\b|(^|[\s"'`=:(,\-])\/(private\/)?tmp(\/|\b)|tempfile\.|mkdtemp|tmpdir\(|TemporaryDirectory|os\.tmpdir/;
// NAME = …, NAME: … (YAML, JSON, JS and Python dicts), env["NAME"] = …
const assignment = (name) => new RegExp(`\\b${name}\\b(?:["'\`]\\])?["'\`]?\\s*(=(?!=)|:(?=[\\s"'\`])|:[-=])\\s*(.*)$`);
const GOCACHE_SET = assignment('GOCACHE');
const GOFLAGS_SET = new RegExp(`\\bGOFLAGS\\b(?:["'\`]\\])?["'\`]?\\s*(=(?!=)|:(?=[\\s"'\`]))\\s*(.*)$`);
const GO_CLEAN = /\bgo\s+clean\b[^;&|\n]*\s-(?:cache|modcache)\b/;
const RM_CACHE = /\brm\s+[^;&|\n]*(Library\/Caches\/go-build|(~|\$HOME|\$\{HOME\})\/go\/pkg\/mod)/;
const EXPLICIT_TRIMPATH = /\bgo\s+(?:build|test|install|run|vet|list|generate)\b[^\n]*\s-trimpath(?!=)/;

// The first value token after the operator: a quoted string, or up to a space.
function valueToken(rest) {
  const s = rest.trimStart();
  const q = s[0];
  if (q === '"' || q === "'" || q === '`') {
    const end = s.indexOf(q, 1);
    return end > 0 ? s.slice(1, end) : s.slice(1);
  }
  return s.split(/[\s;]/)[0];
}

// Physical lines joined at trailing backslashes, with the first line number.
function logicalLines(text) {
  const out = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const start = i;
    let line = lines[i];
    while (/\\\s*$/.test(line) && i + 1 < lines.length) {
      line = line.replace(/\\\s*$/, ' ') + lines[++i];
    }
    out.push({ line: start + 1, text: line });
  }
  return out;
}

export function findViolations(text) {
  const found = [];
  for (const { line, text: l } of logicalLines(text)) {
    const t = l.trim();
    if (t.startsWith('#') || t.startsWith('//')) continue; // comments, shebangs
    if (l.includes('guard:guest')) continue;
    const add = (rule) => found.push({ line, rule, text: t.slice(0, 200) });
    const c = l.match(GOCACHE_SET);
    if (c && TEMP.test(c[2].split(SHARED_FALLBACK).join(''))) add('per-task GOCACHE');
    if (GO_CLEAN.test(l)) add('go clean -cache/-modcache');
    if (RM_CACHE.test(l)) add('rm of a shared Go cache');
    const f = l.match(GOFLAGS_SET);
    if (f) {
      // Inside a string literal ("GOFLAGS=-a -b") the value runs to its closing quote.
      // (Not when only the name is quoted, as in env["GOFLAGS"] = "…".)
      const before = l[f.index - 1];
      const inString = ['"', "'", '`'].includes(before) && l[f.index + 'GOFLAGS'.length] === '=';
      const v = inString ? f[2].split(before)[0] : valueToken(f[2]);
      const keeps = /(^|[\s"'`])-trimpath(=true)?(?![\w=-])/.test(v);
      if (!keeps && !EXPLICIT_TRIMPATH.test(l)) add('GOFLAGS without -trimpath');
    }
  }
  return found;
}

// Pre-existing guest-side settings (none runs Go on the Mac with these values).
const ALLOWED = [
  { file: 'scripts/bench_runtimes.py', includes: 'GOCACHE=$(mktemp -d)',
    reason: 'GO_JOB is the command of a Linux container (micropod/docker run); a cold GOCACHE inside the container is the measured variable' },
  { file: 'scripts/bench_package_caches.py', includes: 'GOFLAGS="-p=2"',
    reason: 'the environment of the Go client the benchmark runs inside a fresh offline OCI container (container_job) against its named cache volumes' },
  { file: 'scripts/bench_runtimes.py', includes: '"-e", "GOFLAGS=-modcacherw"',
    reason: 'the -e environment of a `micropod sandbox run golang:1 -- go mod download` Linux sandbox, not the Mac' },
  { file: 'scripts/bench_fresh_go.py', includes: 'GOFLAGS=env["GOFLAGS"] + " -tags=micropod_prepare_control"',
    reason: 'extends GO_ENV, whose GOFLAGS already carries -trimpath (line 31), for a guest job' },
];

function* scriptFiles(dir) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const path = join(dir, e.name);
    if (e.isDirectory()) {
      if (['node_modules', '__pycache__', '.git', '.build', 'target'].includes(e.name)) continue;
      yield* scriptFiles(path);
    } else if (e.isFile()) {
      if (path === SELF) continue;
      if (['.md', '.txt', '.zip', '.tgz', '.gz', '.png', '.jpg', '.icns', '.pyc', '.ext4', '.cpio', '.lock'].includes(extname(e.name))) continue;
      if (statSync(path).size > 2 << 20) continue;
      const buf = readFileSync(path);
      if (buf.subarray(0, 8192).includes(0)) continue; // binary
      yield { path, text: buf.toString('utf8') };
    }
  }
}

function treeViolations(root) {
  const out = [];
  for (const top of ['scripts', 'ci']) {
    for (const { path, text } of scriptFiles(join(root, top))) {
      const file = relative(root, path);
      for (const v of findViolations(text)) {
        const allowed = ALLOWED.find((a) => a.file === file && v.text.includes(a.includes));
        if (!allowed) out.push(`${file}:${v.line}: ${v.rule}: ${v.text}`);
      }
    }
  }
  return out;
}

const rules = (text) => findViolations(text).map((v) => v.rule);

test('per-task GOCACHE values are flagged', () => {
  assert.deepEqual(rules('export GOCACHE=$(mktemp -d)\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('GOCACHE="$TMPDIR/gocache" go build ./...\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('GOCACHE=${TMPDIR}/x go vet\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('docker run -e GOCACHE=/tmp/x golang true\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('env["GOCACHE"] = tempfile.mkdtemp()\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('    GOCACHE: /private/tmp/job-42/cache\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('  "GOCACHE": mkdtempSync(join(tmpdir(), "x")),\n'), ['per-task GOCACHE']);
  assert.deepEqual(rules('go build "${GOCACHE:-/tmp/gc}"\n'), ['per-task GOCACHE']);
});
test('shared GOCACHE uses and reads pass', () => {
  assert.deepEqual(rules('GOCACHE=/private/tmp/go-build-agents go build ./...\n'), []);
  assert.deepEqual(rules('echo "$GOCACHE"\nfor k in GOFLAGS GOCACHE; do :; done\nln -s "$GOCACHE" /x\n'), []);
  assert.deepEqual(rules('GOCACHE="$HOME/Library/Caches/go-build-sfh-next" make\n'), []);
  assert.deepEqual(rules('# GOCACHE=$(mktemp -d) is forbidden\n'), []);
  assert.deepEqual(rules('("gobuild", "GOCACHE", "go-build-cache"),\n'), []);
});
test('cleaning the shared caches is flagged', () => {
  assert.deepEqual(rules('go clean -cache\n'), ['go clean -cache/-modcache']);
  assert.deepEqual(rules('go clean -x -modcache && true\n'), ['go clean -cache/-modcache']);
  assert.deepEqual(rules('rm -rf ~/Library/Caches/go-build\n'), ['rm of a shared Go cache']);
  assert.deepEqual(rules('rm -rf "$HOME/go/pkg/mod"\n'), ['rm of a shared Go cache']);
  assert.deepEqual(rules('go clean -testcache\nrm -rf /tmp/w-$$\n'), []);
});
test('GOFLAGS without -trimpath is flagged', () => {
  assert.deepEqual(rules('GOFLAGS=-mod=mod go test ./...\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(rules('export GOFLAGS="-p=2"\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(rules('  "GOFLAGS": "-tags=x",\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(rules('GOFLAGS=-trimpath=false go build\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(rules('go env -w GOFLAGS=-mod=mod\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(findViolations('x=1\nGOFLAGS=-mod=mod \\\n  go build ./...\n').map((v) => v.line), [2]);
});
test('GOFLAGS that keeps -trimpath passes', () => {
  assert.deepEqual(rules('GOFLAGS="-trimpath -p=2" go test ./...\n'), []);
  assert.deepEqual(rules("envs=(GOENV=off 'GOFLAGS=-trimpath -p=2')\n"), []);
  assert.deepEqual(rules('ENV GOFLAGS=-trimpath GOTOOLCHAIN=local\n'), []);
  assert.deepEqual(rules('(cd guest && GOFLAGS=-buildvcs=false \\\n    go build -trimpath -o out .)\n'), []);
  assert.deepEqual(rules('v="${GOFLAGS:-}"\n'), []);
  assert.deepEqual(rules('check "GOFLAGS=-trimpath" "$x"\n'), []);
  assert.deepEqual(rules(`docker run -e "GOFLAGS=-mod=mod -trimpath" img\n`), []);
  assert.deepEqual(rules('env["GOFLAGS"] = "-trimpath -p=2"\n'), []);
  assert.deepEqual(rules('env["GOFLAGS"] = "-p=2"\n'), ['GOFLAGS without -trimpath']);
  assert.deepEqual(rules(`docker run -e "GOFLAGS=-mod=mod" -e X=-trimpath img\n`), ['GOFLAGS without -trimpath']);
});
test('guest-only lines say so', () => {
  assert.deepEqual(rules('docker run -e GOFLAGS=-mod=mod -e GOCACHE=/tmp/x img # guard:guest\n'), []);
});
test('scripts/ and ci/ follow the shared Go cache rules', () => {
  const bad = treeViolations(REPO);
  assert.deepEqual(bad, [], `violations (fix them, mark a guest-only line with "guard:guest", or allow-list a pre-existing guest-side line with its reason):\n${bad.join('\n')}`);
});
test('every allow-list entry gives its reason and still matches a line', () => {
  for (const a of ALLOWED) {
    assert.ok(a.reason.length > 20, a.file);
    let text = '';
    try {
      text = readFileSync(join(REPO, a.file), 'utf8');
    } catch {}
    const hit = findViolations(text).some((v) => v.text.includes(a.includes));
    assert.ok(hit, `stale allow-list entry (remove it): ${a.file}: ${a.includes}`);
  }
});
