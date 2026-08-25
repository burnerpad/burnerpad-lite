#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 CLEAN_BASE_IMAGE" >&2
  exit 2
fi

base_image=$1
test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
scanner="$test_dir/image_cookie_test.sh"
fixture_image="burnerpad:cookie-layer-negative-control-$$"
scratch=$(mktemp -d)
scanner_output="$scratch/scanner.txt"

cleanup() {
  docker image rm "$fixture_image" >/dev/null 2>&1 || true
  find "$scratch" -depth -delete
}
trap cleanup EXIT

docker build --quiet --build-arg BASE_IMAGE="$base_image" \
  -f "$test_dir/fixtures/deleted-cookie.Dockerfile" -t "$fixture_image" "$repo_dir" >/dev/null

# The final filesystem is clean; only a historical OCI-layer inspection can catch this fixture.
docker run --rm --user 0 --entrypoint /bin/sh "$fixture_image" \
  -c 'test ! -e /cookie-layer-negative-control/COOKIE'

if "$scanner" "$fixture_image" > "$scanner_output" 2>&1; then
  echo "public-image cookie scanner accepted a cookie deleted in a later layer" >&2
  exit 1
fi

if ! grep -Fq 'an OCI layer contains an Erlang cookie path or deletion whiteout' "$scanner_output"; then
  sed -n '1,80p' "$scanner_output" >&2
  echo "public-image cookie scanner failed for an unexpected reason" >&2
  exit 1
fi

echo "public-image cookie scanner negative control passed"
