import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, symlinkSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('./stage_hvf_base_disk.sh', import.meta.url));
const packageScript = fileURLToPath(new URL('./package_app.sh', import.meta.url));

function withDir(body) {
  const dir = mkdtempSync(join(tmpdir(), 'micropod-base-disk-'));
  try {
    return body(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function ext4(path, marker = 7) {
  const data = Buffer.alloc(4096);
  data[0] = marker;
  data[1024 + 0x38] = 0x53;
  data[1024 + 0x39] = 0xef;
  writeFileSync(path, data);
}

function stage(disk, dir) {
  return spawnSync('bash', [script, disk, join(dir, 'Micropod.app/Contents/Resources'), join(dir, 'dist')], {
    encoding: 'utf8',
  });
}

test('the base disk lands in the app resources and the tarball root', () => withDir((dir) => {
  const disk = join(dir, 'base.ext4');
  ext4(disk);
  const result = stage(disk, dir);
  assert.equal(result.status, 0, result.stderr);
  for (const target of ['Micropod.app/Contents/Resources/hvf-base-disk.ext4', 'dist/hvf-base-disk.ext4']) {
    const copied = readFileSync(join(dir, target));
    assert.equal(copied[0], 7, target);
    assert.equal(statSync(join(dir, target)).mode & 0o777, 0o644, target);
  }
}));

test('a file that is not ext4 is refused and nothing is copied', () => withDir((dir) => {
  const disk = join(dir, 'plain.img');
  writeFileSync(disk, Buffer.alloc(4096));
  const result = stage(disk, dir);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /not an ext4 image/);
  assert.equal(existsSync(join(dir, 'dist/hvf-base-disk.ext4')), false);
}));

test('a missing file or a symlink is refused', () => withDir((dir) => {
  assert.notEqual(stage(join(dir, 'missing.ext4'), dir).status, 0);
  const disk = join(dir, 'base.ext4');
  ext4(disk);
  symlinkSync(disk, join(dir, 'link.ext4'));
  assert.notEqual(stage(join(dir, 'link.ext4'), dir).status, 0);
}));

test('package_app.sh bundles it only when MICROPOD_HVF_BASE_DISK is set, and archives it', () => {
  const source = readFileSync(packageScript, 'utf8');
  assert.match(source, /if \[\[ -n "\$\{MICROPOD_HVF_BASE_DISK:-\}" \]\]; then\n\s+bash scripts\/stage_hvf_base_disk\.sh/);
  assert.match(source, /tar -czf .*\$\{hvf_base_disk\[@\]\+"\$\{hvf_base_disk\[@\]\}"\}/);
});
