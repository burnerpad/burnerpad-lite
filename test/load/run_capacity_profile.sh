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
test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
host_memory_gib=${LOAD_HOST_MEMORY_GIB:-8}
app_memory_gib=${LOAD_APP_MEMORY_GIB:-6}
rendered_compose=$(mktemp /tmp/burnerpad-load-capacity.XXXXXX.yml)
results_dir=$(mktemp -d /tmp/burnerpad-load-capacity-results.XXXXXX)
compose_project="burnerpad-load-capacity-$$"
node_image=node:24.19.0-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03

case "$compose_project" in
  burnerpad-load-capacity-[0-9]*) ;;
  *)
    echo "refusing unsafe Compose project name: $compose_project" >&2
    exit 1
    ;;
esac

case "$host_memory_gib:$app_memory_gib" in
  4:3) profile_max_secrets=24000 ;;
  8:6) profile_max_secrets=50000 ;;
  12:9) profile_max_secrets=75000 ;;
  16:12) profile_max_secrets=100000 ;;
  *)
    echo "unsupported capacity profile ${host_memory_gib} GiB host / ${app_memory_gib} GiB app" >&2
    exit 2
    ;;
esac

docker_memory=$(docker info --format '{{.MemTotal}}')
required_memory=$((host_memory_gib * 1024 * 1024 * 1024))
test "$docker_memory" -ge "$required_memory" || {
  echo "the Docker host has less than the required ${host_memory_gib} GiB of RAM" >&2
  exit 1
}

ANSIBLE_CONFIG="$repo_dir/ops/ansible.cfg" \
  ansible localhost -i localhost, -c local -m ansible.builtin.template \
  -a "src=$repo_dir/ops/roles/deploy/templates/docker-compose.yml.j2 dest=$rendered_compose mode=0600" \
  -e @"$repo_dir/ops/group_vars/all/vars.yml" >/dev/null

export APP_IMAGE="$app_image"
export CLOUDFLARED_IMAGE="$cloudflared_image"
export RELEASE_COOKIE=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export TUNNEL_TOKEN=dummy
export OPERATOR_NAME="${host_memory_gib} GiB load-test operator"
export ABUSE_EMAIL=ci@example.com
export JURISDICTION=CI
export SECURITY_EMAIL=security@example.com
export SECURITY_POLICY_URL=https://example.com/security
export BURNERPAD_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MAX_SECRETS="${LOAD_MAX_SECRETS:-$profile_max_secrets}"
export GLOBAL_CREATE_CEILING=100000
export LOAD_PER_IP_BUDGET="${LOAD_PER_IP_BUDGET:-13107200}"
export LOAD_PER_IP_ROW_BUDGET="${LOAD_PER_IP_ROW_BUDGET:-200}"
export PER_IP_BUDGET="$LOAD_PER_IP_BUDGET"
export PER_IP_ROW_BUDGET="$LOAD_PER_IP_ROW_BUDGET"
export LOAD_APP_MEMORY_LIMIT="${LOAD_APP_MEMORY_LIMIT:-${app_memory_gib}g}"
export LOAD_CPUS="${LOAD_CPUS:-4.0}"

compose() {
  docker compose --project-name "$compose_project" \
    -f "$rendered_compose" -f "$test_dir/docker-compose.capacity.yml" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "${host_memory_gib} GiB maximum-state load test failed: $*" >&2
  exit 1
}

compose up -d --no-deps app >/dev/null
container_id=$(compose ps -q app)
test -n "$container_id" || fail "Compose did not create the app container"

ready=0
for _ in {1..60}; do
  if docker exec "$container_id" /bin/busybox wget -qO- http://127.0.0.1:4000/readyz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  compose logs app >&2
  fail "app did not become ready"
fi

network_name=$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$container_id")
test -n "$network_name" || fail "app is not attached to the production backend network"

docker run --rm --network "$network_name" --user "$(id -u):$(id -g)" \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  -v "$test_dir:/load:ro" -v "$results_dir:/results" \
  -e LOAD_BASE_URL=http://app:4000 \
  -e LOAD_MAX_SECRETS="$MAX_SECRETS" \
  -e LOAD_HOST_MEMORY_GIB="$host_memory_gib" \
  -e LOAD_APP_MEMORY_GIB="$app_memory_gib" \
  -e LOAD_CPUS="${LOAD_CPUS:-4}" \
  -e LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-64}" \
  -e LOAD_CYCLE_SECRETS="${LOAD_CYCLE_SECRETS:-2000}" \
  -e LOAD_REJECTION_REQUESTS="${LOAD_REJECTION_REQUESTS:-256}" \
  -e LOAD_PROBE_REQUESTS="${LOAD_PROBE_REQUESTS:-256}" \
  -e LOAD_MUTATION_P99_LIMIT_MS="${LOAD_MUTATION_P99_LIMIT_MS:-2000}" \
  -e LOAD_PROBE_P99_LIMIT_MS="${LOAD_PROBE_P99_LIMIT_MS:-1000}" \
  "$node_image" node /load/maximum_state.mjs /results/report.json

memory_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$container_id")
memory_current=$(docker exec "$container_id" /bin/busybox cat /sys/fs/cgroup/memory.current)
if docker exec "$container_id" /bin/busybox test -r /sys/fs/cgroup/memory.peak; then
  memory_peak=$(docker exec "$container_id" /bin/busybox cat /sys/fs/cgroup/memory.peak)
else
  memory_peak=$memory_current
fi
beam_memory=$(docker exec "$container_id" bin/burnerpad rpc 'IO.puts(:erlang.memory(:total))' 2>/dev/null | tail -n 1)
store_memory=$(docker exec "$container_id" bin/burnerpad rpc \
  'IO.puts(:ets.info(:bp_secrets, :memory) * :erlang.system_info(:wordsize))' 2>/dev/null | tail -n 1)
resident=$(docker exec "$container_id" bin/burnerpad rpc 'IO.puts(:ets.info(:bp_secrets, :size))' 2>/dev/null | tail -n 1)

max_memory_percent=${LOAD_MAX_MEMORY_PERCENT:-85}
case "$max_memory_percent" in
  ''|*[!0-9]*) fail "LOAD_MAX_MEMORY_PERCENT must be an integer from 1 through 100" ;;
esac
test "$max_memory_percent" -ge 1 && test "$max_memory_percent" -le 100 ||
  fail "LOAD_MAX_MEMORY_PERCENT must be an integer from 1 through 100"
peak_percent=$((memory_peak * 100 / memory_limit))
echo "runtime_memory limit=$memory_limit current=$memory_current peak=$memory_peak peak_percent=$peak_percent beam=$beam_memory store_ets=$store_memory resident=$resident"
echo "load_report=$results_dir/report.json"

runtime_report="$results_dir/runtime.env"
{
  echo "host_memory_gib=$host_memory_gib"
  echo "app_memory_limit_bytes=$memory_limit"
  echo "container_memory_current_bytes=$memory_current"
  echo "container_memory_peak_bytes=$memory_peak"
  echo "container_memory_peak_percent=$peak_percent"
  echo "beam_memory_bytes=$beam_memory"
  echo "store_ets_memory_bytes=$store_memory"
  echo "resident=$resident"
} >"$runtime_report"
echo "runtime_report=$runtime_report"

if [ -n "${LOAD_REPORT_PATH:-}" ]; then
  cp "$results_dir/report.json" "$LOAD_REPORT_PATH"
  copied_runtime_report="${LOAD_REPORT_PATH%.json}.runtime.env"
  cp "$runtime_report" "$copied_runtime_report"
  echo "copied_load_report=$LOAD_REPORT_PATH"
  echo "copied_runtime_report=$copied_runtime_report"
fi

test "$((memory_peak * 100))" -le "$((memory_limit * max_memory_percent))" || fail \
  "container peak memory exceeded ${max_memory_percent}% of its limit (${memory_peak}/${memory_limit} bytes)"
test "$resident" = "$MAX_SECRETS" || fail "final resident count is $resident, expected $MAX_SECRETS"

echo "${host_memory_gib} GiB maximum-state load tests passed"
