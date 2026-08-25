#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
submodule_path=priv/static/vendor/crypto-js
submodule_dir="$repo_dir/$submodule_path"
allowed_signers="$repo_dir/.github/crypto-release-allowed-signers"

expected_commit=$(git -C "$repo_dir" rev-parse "HEAD:$submodule_path")
actual_commit=$(git -C "$submodule_dir" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
  echo "crypto checkout does not match the parent gitlink" >&2
  exit 1
fi

package_version=$(node -p "require('$submodule_dir/package.json').version")
release_tag="v$package_version"
if ! printf '%s\n' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "crypto package version is not an X.Y.Z release" >&2
  exit 1
fi

if [ "$(git -C "$submodule_dir" cat-file -t "refs/tags/$release_tag" 2>/dev/null || true)" != tag ]; then
  echo "crypto gitlink is not named by annotated release tag $release_tag" >&2
  exit 1
fi

tagged_commit=$(git -C "$submodule_dir" rev-parse "refs/tags/$release_tag^{}")
if [ "$tagged_commit" != "$actual_commit" ]; then
  echo "crypto release tag $release_tag does not name the pinned gitlink" >&2
  exit 1
fi

git -C "$submodule_dir" \
  -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile="$allowed_signers" \
  verify-tag "$release_tag"

echo "crypto pin verified: $release_tag ($actual_commit)"
