#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_IMAGE CLOUDFLARED_IMAGE" >&2
  exit 2
fi

app_image=$1
cloudflared_image=$2
server_name="cloudflared-healthcheck-$$"
scratch=$(mktemp -d)

case "$server_name" in
  cloudflared-healthcheck-[0-9]*) ;;
  *)
    echo "refusing unsafe healthcheck fixture name" >&2
    exit 1
    ;;
esac

cleanup() {
  docker rm -f "$server_name" >/dev/null 2>&1 || true
  find "$scratch" -depth -delete
}
trap cleanup EXIT

fail() {
  echo "cloudflared image healthcheck test failed: $*" >&2
  exit 1
}

expected='["CMD","cloudflared","tunnel","--metrics","127.0.0.1:20241","ready"]'
actual=$(docker image inspect "$cloudflared_image" --format '{{json .Config.Healthcheck.Test}}')
test "$actual" = "$expected" || fail "image metadata does not probe the configured metrics endpoint"

printf 'ready\n' > "$scratch/ready"
chmod 0755 "$scratch"
chmod 0644 "$scratch/ready"

docker run --detach --rm --name "$server_name" \
  --volume "$scratch:/health:ro" --entrypoint /bin/busybox "$app_image" \
  httpd -f -p 20241 -h /health >/dev/null

ready=0
for _ in {1..20}; do
  if docker run --rm --network "container:$server_name" --entrypoint cloudflared "$cloudflared_image" \
    tunnel --metrics 127.0.0.1:20241 ready >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
test "$ready" -eq 1 || fail "corrected readiness command did not accept a ready loopback endpoint"

if docker run --rm --network "container:$server_name" --entrypoint cloudflared "$cloudflared_image" \
  tunnel ready >/dev/null 2>&1; then
  fail "readiness unexpectedly succeeded without an explicit metrics endpoint"
fi

echo "cloudflared image healthcheck tests passed"
