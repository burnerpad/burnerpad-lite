#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=${1:-$(cd "$script_dir/../.." && pwd)}
status=$(git -C "$repo_dir" status --porcelain --untracked-files=all)

if [[ -n "$status" ]]; then
  echo "tests or generators left the repository dirty:" >&2
  printf '%s\n' "$status" >&2
  exit 1
fi
