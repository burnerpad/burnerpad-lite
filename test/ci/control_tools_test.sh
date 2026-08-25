#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
check_script="$repo_dir/ops/check-control-tools.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

make_toolset() {
  local bin_dir=$1

  mkdir -p "$bin_dir"
  # These test executables, rather than this parent process, must expand their positional parameters.
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'test "${1:-}" = version' > "$bin_dir/docker"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'test "${1:-}" = version' > "$bin_dir/cosign"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-} ${2:-} ${3:-} ${4:-}" in' \
    '  "attestation verify --help ") test "${FAKE_GH_MODE:-valid}" != old ;;' \
    '  "auth status --hostname github.com") test "${FAKE_GH_MODE:-valid}" != unauth ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$bin_dir/gh"
  chmod +x "$bin_dir/docker" "$bin_dir/cosign" "$bin_dir/gh"
}

expect_failure() {
  local label=$1
  local expected=$2
  local bin_dir=$3
  local gh_mode=${4:-valid}
  local output="$scratch/$label.txt"

  if PATH="$bin_dir" FAKE_GH_MODE="$gh_mode" /bin/bash "$check_script" > "$output" 2>&1; then
    echo "control-tool preflight accepted $label" >&2
    exit 1
  fi

  grep -Fq "$expected" "$output"
}

valid_bin="$scratch/valid-bin"
make_toolset "$valid_bin"
PATH="$valid_bin" FAKE_GH_MODE=valid /bin/bash "$check_script"

missing_cosign_bin="$scratch/missing-cosign-bin"
make_toolset "$missing_cosign_bin"
find "$missing_cosign_bin/cosign" -delete
expect_failure missing-cosign 'cosign is required' "$missing_cosign_bin"

expect_failure old-gh 'gh attestation verify' "$valid_bin" old
expect_failure unauthenticated-gh 'gh auth login' "$valid_bin" unauth

echo "control-machine tool preflight tests passed"
