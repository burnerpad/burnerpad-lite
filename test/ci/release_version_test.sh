#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
resolver="$repo_dir/.github/scripts/next-release-version.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

git -C "$scratch" init -q release-history
history="$scratch/release-history"
git -C "$history" config user.name "Release policy test"
git -C "$history" config user.email "release@example.invalid"
git -C "$history" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm initial
main_branch=$(git -C "$history" symbolic-ref --short HEAD)
git -C "$history" tag -a v1.0.0 -m v1.0.0

run_resolver() {
  (
    cd "$history"
    "$resolver" "$@"
  )
}

test "$(run_resolver HEAD)" = 1.0.0
git -C "$history" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm dependency-update
test "$(run_resolver HEAD)" = 1.0.1
git -C "$history" tag -a v1.0.1 -m v1.0.1
test "$(run_resolver HEAD)" = 1.0.1

git -C "$history" switch -qc unrelated v1.0.0
git -C "$history" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm unrelated
git -C "$history" tag -a v9.0.0 -m v9.0.0
git -C "$history" switch -q "$main_branch"
git -C "$history" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm application-fix
test "$(run_resolver HEAD)" = 1.0.2

git -C "$scratch" init -q no-release
git -C "$scratch/no-release" config user.name "Release policy test"
git -C "$scratch/no-release" config user.email "release@example.invalid"
git -C "$scratch/no-release" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm initial
if (cd "$scratch/no-release" && "$resolver" HEAD >/dev/null 2>&1); then
  echo "resolver accepted a history without a release baseline" >&2
  exit 1
fi

git -C "$history" tag -a v1.0.3 -m v1.0.3
git -C "$history" tag -a v1.0.4 -m v1.0.4
if run_resolver HEAD >/dev/null 2>&1; then
  echo "resolver accepted two release tags on one revision" >&2
  exit 1
fi

echo "automatic release version tests passed"
