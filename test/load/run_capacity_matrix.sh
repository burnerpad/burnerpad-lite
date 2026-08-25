#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_IMAGE CLOUDFLARED_IMAGE" >&2
  exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
report_dir=${LOAD_MATRIX_REPORT_DIR:-$(mktemp -d /tmp/burnerpad-load-capacity-matrix.XXXXXX)}
mkdir -p "$report_dir"

run_profile() {
  host_memory_gib=$1
  app_memory_gib=$2
  max_secrets=$3
  shift 3

  echo "running_capacity_profile host=${host_memory_gib}GiB app=${app_memory_gib}GiB max_secrets=$max_secrets"
  LOAD_HOST_MEMORY_GIB="$host_memory_gib" \
    LOAD_APP_MEMORY_GIB="$app_memory_gib" \
    LOAD_MAX_SECRETS="$max_secrets" \
    LOAD_REPORT_PATH="$report_dir/${host_memory_gib}g.json" \
    "$script_dir/run_capacity_profile.sh" "$@"
}

run_profile 4 3 24000 "$@"
run_profile 8 6 50000 "$@"
run_profile 12 9 75000 "$@"
run_profile 16 12 100000 "$@"

echo "capacity_matrix_reports=$report_dir"
echo "all maximum-state capacity profiles passed"
