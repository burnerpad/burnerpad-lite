#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Print the cloudflared release pinned by the literal FROM line in ops/cloudflared.Dockerfile, or the
# upstream commit its release tag peels to. The FROM line is the single source of truth, so a Dependabot
# update of its tag and digest needs no second hand-edited version or revision.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
dockerfile=${CLOUDFLARED_DOCKERFILE:-"$script_dir/../../ops/cloudflared.Dockerfile"}

version=$(sed -nE \
  's|^FROM[[:space:]]+cloudflare/cloudflared:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$|\1|p' \
  "$dockerfile")
if [ "$(printf '%s\n' "$version" | grep -c .)" -ne 1 ]; then
  echo "$dockerfile must have exactly one 'FROM cloudflare/cloudflared:X.Y.Z@sha256:<digest>' line" >&2
  exit 1
fi

case "${1:-version}" in
  version)
    echo "$version"
    ;;
  revision)
    revision=$(gh api "repos/cloudflare/cloudflared/commits/$version" --jq .sha)
    if [[ ! $revision =~ ^[0-9a-f]{40}$ ]]; then
      echo "could not resolve cloudflared $version to an upstream commit" >&2
      exit 1
    fi
    echo "$revision"
    ;;
  *)
    echo "usage: $0 [version|revision]" >&2
    exit 2
    ;;
esac
