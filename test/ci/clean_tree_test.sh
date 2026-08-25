#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
checker="$repo_dir/.github/scripts/check-clean-tree.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

git -C "$scratch" init -q
git -C "$scratch" config user.name "Clean tree test"
git -C "$scratch" config user.email "clean-tree@example.invalid"
printf '/_build/\n' > "$scratch/.gitignore"
printf 'tracked\n' > "$scratch/tracked.txt"
git -C "$scratch" add .gitignore tracked.txt
git -C "$scratch" commit -qm initial

bash "$checker" "$scratch"

mkdir "$scratch/_build"
printf 'expected generated output\n' > "$scratch/_build/output.txt"
bash "$checker" "$scratch"

printf 'unexpected generated output\n' > "$scratch/unexpected.txt"
if bash "$checker" "$scratch" >/dev/null 2>&1; then
  echo "clean-tree check accepted an unexpected untracked file" >&2
  exit 1
fi
find "$scratch" -maxdepth 1 -name unexpected.txt -delete

printf 'modified\n' >> "$scratch/tracked.txt"
if bash "$checker" "$scratch" >/dev/null 2>&1; then
  echo "clean-tree check accepted a tracked modification" >&2
  exit 1
fi

echo "clean-tree tests passed"
