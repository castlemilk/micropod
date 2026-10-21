#!/usr/bin/env bash
# Missing optional globs are harmless; syntax errors in existing files are not.
set -euo pipefail
for file in scripts/*.sh ci/*.sh; do
  [[ -f "$file" ]] || continue
  bash -n "$file"
done
