import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const source = fileURLToPath(new URL('./gen-sdk.sh', import.meta.url));
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'micropod-sdk-drift-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const env = { ...process.env };
  for (const key of ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX']) delete env[key];
  const run = (command, args) => {
    const result = spawnSync(command, args, { cwd: root, env, encoding: 'utf8' });
    assert.ifError(result.error);
    return result;
  };
  const git = (...args) => {
    const result = run('git', args);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  };
  const write = (name, text = 'generated content\n') => {
    const path = join(root, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  };
  write('scripts/gen-sdk.sh', readFileSync(source));
  write('sdk/go/gen/existing.go');
  write('Sources/MicropodCore/Generated/Existing.swift');
  write('api/existing.go');
  write('.gitignore', 'sdk/ts/node_modules/\n');
  const bin = join(root, 'fixture-bin');
  write('fixture-bin/go', '#!/bin/sh\nexit 0\n');
  write('fixture-bin/buf', '#!/bin/sh\nif [ -n "$FIXTURE_BUF_FAILURE" ]; then exit 23; fi\nif [ -n "$FIXTURE_NEW_OUTPUT" ]; then mkdir -p "$(dirname "$FIXTURE_NEW_OUTPUT")"; printf "new generated output\\n" > "$FIXTURE_NEW_OUTPUT"; fi\n');
  chmodSync(join(bin, 'go'), 0o700);
  chmodSync(join(bin, 'buf'), 0o700);
  env.PATH = `${bin}:${env.PATH}`;
  git('init', '-q'); git('add', '.');
  git('-c', 'user.name=SDK Fixture', '-c', 'user.email=sdk@example.test', 'commit', '-qm', 'baseline');
  return { root, env, git, write, check: (args = ['--check']) => run('bash', ['scripts/gen-sdk.sh', ...args]) };
}

test('clean generation passes', (t) => {
  assert.equal(fixture(t).check().status, 0);
});

for (const output of ['sdk/go/gen/new.go', 'Sources/MicropodCore/Generated/New.swift', 'api/new.go', 'sdk/ts/src/gen/nested space/new file.ts']) {
  test(`new generated file fails and is preserved: ${output}`, (t) => {
    const f = fixture(t);
    f.env.FIXTURE_NEW_OUTPUT = output;
    const result = f.check();
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /generated code out of sync/);
    assert.match(result.stdout, /\?\?/);
    assert.equal(readFileSync(join(f.root, output), 'utf8'), 'new generated output\n');
    assert.match(f.git('status', '--porcelain', '--untracked-files=all'), /\?\?/);
  });
}

for (const staged of [false, true]) {
  for (const change of ['modify', 'delete', 'add']) {
    test(`${staged ? 'staged' : 'unstaged'} ${change} is detected without changing index`, (t) => {
      const f = fixture(t);
      if (change === 'delete') rmSync(join(f.root, 'sdk/go/gen/existing.go'));
      else f.write(`sdk/go/gen/${change === 'add' ? 'added' : 'existing'}.go`, 'changed\n');
      if (staged) f.git('add', '-A', '--', 'sdk/');
      const before = f.git('status', '--porcelain', '--untracked-files=all');
      const result = f.check();
      assert.equal(result.status, 1, result.stderr);
      assert.equal(f.git('status', '--porcelain', '--untracked-files=all'), before);
    });
  }
}

test('unrelated edits and ignored dependency artifacts do not fail the generated guard', (t) => {
  const f = fixture(t);
  f.write('README.md', 'unrelated work\n');
  f.write('sdk/ts/node_modules/package/index.js', 'ignored dependency\n');
  assert.equal(f.check().status, 0);
  assert.equal(readFileSync(join(f.root, 'README.md'), 'utf8'), 'unrelated work\n');
});

test('generator failure propagates before drift checking', (t) => {
  const f = fixture(t);
  f.env.FIXTURE_BUF_FAILURE = '1';
  assert.equal(f.check().status, 23);
});

test('regeneration without --check leaves new files available without rejecting them', (t) => {
  const f = fixture(t);
  f.env.FIXTURE_NEW_OUTPUT = 'sdk/go/gen/new.go';
  assert.equal(f.check([]).status, 0);
  assert.equal(readFileSync(join(f.root, 'sdk/go/gen/new.go'), 'utf8'), 'new generated output\n');
});
