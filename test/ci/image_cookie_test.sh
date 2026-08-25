#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 IMAGE" >&2
  exit 2
fi

image=$1
scratch=$(mktemp -d)
archive="$scratch/image.tar"
unpacked="$scratch/unpacked"
members="$scratch/layer-members.txt"

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

fail() {
  echo "public-image cookie test failed: $*" >&2
  exit 1
}

# Inspect as root so an accidentally root-owned credential cannot hide from the image's non-root user.
if ! docker run --rm --user 0 --entrypoint /bin/sh "$image" -c \
  '! find / -xdev \( -name COOKIE -o -name .erlang.cookie \) -print 2>/dev/null | grep -q .'; then
  fail "the final image filesystem contains an Erlang cookie path"
fi

if docker image inspect --format '{{json .Config}}' "$image" | \
  grep -Eqi 'RELEASE_COOKIE|ERL_COOKIE|(^|[^[:alnum:]_])-setcookie([^[:alnum:]_]|$)'; then
  fail "the image configuration contains an Erlang cookie input"
fi

if docker history --no-trunc --format '{{.CreatedBy}}' "$image" | \
  grep -Eqi 'RELEASE_COOKIE|ERL_COOKIE|[.]erlang[.]cookie|(^|[^[:alnum:]_])-setcookie([^[:alnum:]_]|$)'; then
  fail "the final image history contains an Erlang cookie input"
fi

# A final-filesystem check misses credentials added in one layer and deleted in a later layer. Inspect every
# nested layer tar in both Docker archive and OCI archive layouts, including overlay whiteout entries.
mkdir "$unpacked"
docker image save --output "$archive" "$image"
tar -xf "$archive" -C "$unpacked"

while IFS= read -r candidate; do
  if tar -tf "$candidate" > "$members" 2>/dev/null &&
      grep -Eq '(^|/)(COOKIE|[.]erlang[.]cookie|[.]wh[.]COOKIE|[.]wh[.][.]erlang[.]cookie)$' "$members"; then
    grep -E '(^|/)(COOKIE|[.]erlang[.]cookie|[.]wh[.]COOKIE|[.]wh[.][.]erlang[.]cookie)$' \
      "$members" >&2
    fail "an OCI layer contains an Erlang cookie path or deletion whiteout"
  fi
done < <(find "$unpacked" -type f -print)

echo "public image contains no embedded Erlang cookie"
