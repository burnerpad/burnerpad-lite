#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Produce a deterministic archive of one parent commit plus the exact crypto submodule commit it pins.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 OUTPUT_DIR [FULL_REVISION]" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
output_dir=$1
revision=${2:-$(git -C "$repo_dir" rev-parse HEAD)}

if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo "source release requires one full lowercase Git revision" >&2
  exit 1
fi

submodule_path=priv/static/vendor/crypto-js
expected_submodule=$(git -C "$repo_dir" rev-parse "$revision:$submodule_path")
actual_submodule=$(git -C "$repo_dir/$submodule_path" rev-parse HEAD)
if [ "$actual_submodule" != "$expected_submodule" ]; then
  echo "crypto submodule checkout does not match the selected parent revision" >&2
  exit 1
fi

mkdir -p "$output_dir"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/burnerpad-source-release.XXXXXX")

cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT

prefix="burnerpad-lite-$revision"
parent_tar="$scratch/source.tar"
submodule_tar="$scratch/crypto.tar"
archive_name="burnerpad-lite-source-$revision.tar.gz"

git -C "$repo_dir" archive \
  --format=tar \
  --prefix="$prefix/" \
  --output="$parent_tar" \
  "$revision"
git -C "$repo_dir/$submodule_path" archive \
  --format=tar \
  --prefix="$prefix/$submodule_path/" \
  --output="$submodule_tar" \
  "$actual_submodule"

tar --concatenate --file="$parent_tar" "$submodule_tar"
gzip -n "$parent_tar"
mv -- "$parent_tar.gz" "$output_dir/$archive_name"

printf '%s\n' "$output_dir/$archive_name"
