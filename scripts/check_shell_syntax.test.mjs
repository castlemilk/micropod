import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const gate = fileURLToPath(new URL('./check_shell_syntax.sh', import.meta.url));
function check(files) {
  const root = mkdtempSync(join(tmpdir(), 'micropod-shell-gate-'));
  try {
    for (const [name, source] of Object.entries(files)) {
      const path = join(root, name);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, source);
    }
    const result = spawnSync('bash', [gate], { cwd: root, encoding: 'utf8' });
    assert.ifError(result.error);
    return result;
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
test('valid scripts pass without executing their contents', () => {
  assert.equal(check({ 'scripts/good.sh': 'exit 99\n', 'ci/good.sh': 'echo ok\n' }).status, 0);
});
test('absent optional glob groups pass', () => {
  assert.equal(check({ 'scripts/good.sh': 'echo ok\n' }).status, 0);
});
test('invalid scripts fail even when a later script is valid', () => {
  assert.notEqual(check({ 'scripts/a.sh': 'if then\n', 'scripts/z.sh': 'echo ok\n' }).status, 0);
});
test('invalid CI script fails', () => {
  assert.notEqual(check({ 'ci/bad.sh': 'if then\n' }).status, 0);
});
test('filenames containing spaces are checked', () => {
  assert.notEqual(check({ 'scripts/bad name.sh': 'if then\n' }).status, 0);
});
