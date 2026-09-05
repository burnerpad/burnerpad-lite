#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Return the release already naming REVISION, or the next patch after its newest reachable release.
set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [REVISION]" >&2
  exit 2
fi

repo_dir=$(git rev-parse --show-toplevel)
revision=${1:-HEAD}

if ! revision=$(git -C "$repo_dir" rev-parse --verify "$revision^{commit}" 2>/dev/null); then
  echo "release revision is not a commit" >&2
  exit 1
fi

mapfile -t release_tags < <(
  git -C "$repo_dir" tag --list \
    | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    | sort -V
)

exact_tag=
latest_reachable=
for tag in "${release_tags[@]}"; do
  target=$(git -C "$repo_dir" rev-parse "$tag^{}")
  if [ "$target" = "$revision" ]; then
    if [ -n "$exact_tag" ]; then
      echo "release revision has more than one semantic version tag" >&2
      exit 1
    fi
    exact_tag=$tag
  fi
  if git -C "$repo_dir" merge-base --is-ancestor "$target" "$revision"; then
    latest_reachable=$tag
  fi
done

if [ -n "$exact_tag" ]; then
  printf '%s\n' "${exact_tag#v}"
  exit 0
fi

if [ -z "$latest_reachable" ]; then
  echo "release revision has no reachable vX.Y.Z baseline tag" >&2
  exit 1
fi

version=${latest_reachable#v}
IFS=. read -r major minor patch <<< "$version"
printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
