#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
packager="$repo_dir/.github/scripts/package-source.sh"
revision=$(git -C "$repo_dir" rev-parse HEAD)
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

first="$scratch/first"
second="$scratch/second"
"$packager" "$first" "$revision"
"$packager" "$second" "$revision"

archive_name="burnerpad-lite-source-$revision.tar.gz"
cmp "$first/$archive_name" "$second/$archive_name"

contents="$scratch/contents.txt"
tar -tzf "$first/$archive_name" > "$contents"
prefix="burnerpad-lite-$revision"
grep -Fxq "$prefix/README.md" "$contents"
grep -Fxq "$prefix/priv/static/vendor/crypto-js/package.json" "$contents"
if grep -Eq '(^|/)[.]git(/|$)|(^|/)diff[.]diff$' "$contents"; then
  echo "source archive contains repository metadata or an untracked review input" >&2
  exit 1
fi

echo "source release packaging tests passed"
