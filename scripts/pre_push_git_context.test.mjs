import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';

test('pre-push keeps dependency Git operations out of the worktree repository', () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'micropod-hook-context-')));
  try {
    const repo = join(root, 'repo');
    const worktree = join(root, 'worktree');
    const dependency = join(root, 'dependency');
    const bin = join(root, 'bin');
    for (const path of [repo, dependency, bin]) mkdirSync(path);
    const git = (cwd, args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    git(repo, ['init']);
    git(dependency, ['init']);
    git(repo, ['-c', 'user.name=Hook Test', '-c', 'user.email=hook@example.invalid', 'commit', '--allow-empty', '-m', 'fixture']);
    git(repo, ['worktree', 'add', '-b', 'test-hook', worktree]);
    const gitDir = git(worktree, ['rev-parse', '--absolute-git-dir']);
    writeFileSync(join(bin, 'swift'), `#!/bin/sh
set -eu
[ -z "\${GIT_DIR:-}" ]
[ -z "\${GIT_WORK_TREE:-}" ]
[ -z "\${GIT_INDEX_FILE:-}" ]
[ -z "\${GIT_PREFIX:-}" ]
[ "$CACHE_POLICY_SENTINEL" = retained ]
[ "$(git -C "$DEPENDENCY_FIXTURE" rev-parse --show-toplevel)" = "$DEPENDENCY_FIXTURE" ]
printf 'qualified swift %s\\n' "$1"
`, { mode: 0o755 });
    const result = spawnSync('bash', [resolve('.githooks/pre-push')], {
      cwd: worktree,
      input: 'refs/heads/test-hook a refs/heads/test-hook b\n',
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GIT_DIR: gitDir,
        GIT_WORK_TREE: worktree,
        GIT_INDEX_FILE: join(gitDir, 'index'),
        GIT_PREFIX: '',
        CACHE_POLICY_SENTINEL: 'retained',
        DEPENDENCY_FIXTURE: dependency,
      },
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /qualified swift build/);
    assert.match(result.stdout, /qualified swift test/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
