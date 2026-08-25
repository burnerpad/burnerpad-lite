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
rendered_compose=$(mktemp /tmp/burnerpad-runtime-hardening.XXXXXX.yml)
compose_project="burnerpad-runtime-hardening-$$"

case "$compose_project" in
  burnerpad-runtime-hardening-[0-9]*) ;;
  *)
    echo "refusing unsafe Compose project name: $compose_project" >&2
    exit 1
    ;;
esac

ANSIBLE_CONFIG="$repo_dir/ops/ansible.cfg" \
  ansible localhost -i localhost, -c local -m ansible.builtin.template \
  -a "src=$repo_dir/ops/roles/deploy/templates/docker-compose.yml.j2 dest=$rendered_compose mode=0600" \
  -e @"$repo_dir/ops/group_vars/all/vars.yml" >/dev/null

export APP_IMAGE="$app_image"
export CLOUDFLARED_IMAGE="$cloudflared_image"
export RELEASE_COOKIE=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export TUNNEL_TOKEN=dummy
export OPERATOR_NAME='Operadora Ñandú'
export ABUSE_EMAIL=ci@example.com
export JURISDICTION='Andorra – Pirineus'
export SECURITY_EMAIL=security@example.com
export SECURITY_POLICY_URL=https://example.com/security
export BURNERPAD_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MAX_SECRETS=10000
export GLOBAL_CREATE_CEILING=1000
export PER_IP_BUDGET=13107200
export PER_IP_ROW_BUDGET=200

compose() {
  docker compose --project-name "$compose_project" -f "$rendered_compose" "$@"
}

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "production runtime hardening test failed: $*" >&2
  exit 1
}

compose up -d --no-deps app >/dev/null
container_id=$(compose ps -q app)
test -n "$container_id" || fail "Compose did not create the app container"

# The JavaScript process, not this shell, expands its template literal.
# shellcheck disable=SC2016
network_plan=$(compose config --format json | node -e '
  let input = "";
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    const config = JSON.parse(input);
    process.stdout.write(`${config.networks.backend.name} ${config.networks.backend.ipam.config[0].subnet}`);
  });
')
read -r backend_network backend_subnet <<< "$network_plan"
test -n "$backend_network" && test -n "$backend_subnet" || fail "backend network plan is incomplete"

allocated_backend_subnet=$(docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$backend_network")
trusted_proxy_subnet=$(
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" |
    sed -n 's/^TRUSTED_PROXIES=//p'
)
test "$allocated_backend_subnet" = "$backend_subnet" || fail "Docker allocated an unexpected backend subnet"
test "$trusted_proxy_subnet" = "$backend_subnet" || fail "TRUSTED_PROXIES drifted from the backend subnet"

ready=0
for _ in {1..30}; do
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

docker exec "$container_id" /bin/sh -c \
  'test "$LANG" = C.UTF-8 && test "$LC_ALL" = C.UTF-8' || \
  fail "runtime locale is not pinned to UTF-8"

runtime_logs=$(compose logs --no-color app 2>&1)
if printf '%s\n' "$runtime_logs" | grep -Fqi 'native name encoding of latin1'; then
  printf '%s\n' "$runtime_logs" >&2
  fail "BEAM started with a non-UTF-8 native filename encoding"
fi

terms=$(docker exec "$container_id" /bin/busybox wget -qO- http://127.0.0.1:4000/terms)
case "$terms" in
  *"$OPERATOR_NAME"*"$JURISDICTION"*) ;;
  *) fail "Unicode operator metadata did not survive runtime configuration and HTTP rendering" ;;
esac

readonly_root=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container_id")
test "$readonly_root" = true || fail "root filesystem is writable"

if docker exec "$container_id" /bin/busybox touch /app/runtime-hardening-write-probe >/dev/null 2>&1; then
  fail "a write to the read-only application filesystem succeeded"
fi
docker exec "$container_id" /bin/busybox touch /tmp/runtime-hardening-write-probe
docker exec "$container_id" /bin/busybox rm /tmp/runtime-hardening-write-probe

memory_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$container_id")
memory_swap_limit=$(docker inspect --format '{{.HostConfig.MemorySwap}}' "$container_id")
test "$memory_limit" -gt 0 || fail "memory limit is disabled"
test "$memory_swap_limit" = "$memory_limit" || fail "swap allowance exceeds the memory limit"

tmp_options=$(docker inspect --format '{{index .HostConfig.Tmpfs "/tmp"}}' "$container_id")
for option in noexec nosuid nodev size=64m; do
  case ",$tmp_options," in
    *",$option,"*) ;;
    *) fail "/tmp tmpfs is missing $option" ;;
  esac
done

security_options=$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$container_id")
capability_drops=$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$container_id")
printf '%s\n' "$security_options" | grep -Fq 'no-new-privileges' || fail "no-new-privileges is disabled"
printf '%s\n' "$capability_drops" | grep -Fq 'ALL' || fail "Linux capabilities were not all dropped"
test "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$container_id")" = 512 || fail "PID limit drifted"
test -z "$(docker port "$container_id")" || fail "the app publishes a host port"

listeners=$(docker exec "$container_id" /bin/busybox netstat -ltn)
epmd_names=$(docker exec "$container_id" /bin/sh -c '/app/erts-*/bin/epmd -names')
distribution_port=$(printf '%s\n' "$epmd_names" | sed -n 's/^name burnerpad at port \([0-9][0-9]*\)$/\1/p')
test -n "$distribution_port" || fail "EPMD did not report the burnerpad distribution port"

assert_loopback_only() {
  local port=$1
  local label=$2

  if ! printf '%s\n' "$listeners" | awk -v port="$port" '
    $6 == "LISTEN" && $4 ~ (":" port "$") {
      found = 1
      if ($4 != "127.0.0.1:" port && $4 != "::1:" port) bad = 1
    }
    END { exit !(found && !bad) }
  '; then
    printf '%s\n' "$listeners" >&2
    fail "$label is absent or listens outside loopback"
  fi
}

assert_loopback_only 4369 EPMD
assert_loopback_only "$distribution_port" "Erlang distribution"

release_node=$(docker exec "$container_id" bin/burnerpad rpc 'IO.puts(Node.self())' 2>/dev/null | tail -n 1)
test "$release_node" = burnerpad@127.0.0.1 || fail "release RPC is not pinned to the loopback node"

release_operator=$(docker exec "$container_id" bin/burnerpad rpc 'IO.puts(Burnerpad.Config.operator_name())' 2>/dev/null | tail -n 1)
test "$release_operator" = "$OPERATOR_NAME" || fail "release RPC did not preserve Unicode configuration"

echo "production runtime hardening tests passed"
