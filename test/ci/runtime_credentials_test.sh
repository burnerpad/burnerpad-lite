#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
playbook="$test_dir/runtime_credentials_test.yml"
scratch=$(mktemp -d)
runtime_dir="$scratch/runtime"
first_output="$scratch/first-ansible.txt"
second_output="$scratch/second-ansible.txt"

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

mkdir "$runtime_dir"
export BURNERPAD_RUNTIME_TEST_DIR="$runtime_dir"
export BURNERPAD_RUNTIME_TEST_OWNER
BURNERPAD_RUNTIME_TEST_OWNER=$(id -un)

run_deploy_artifact() {
  local output=$1

  # fakeroot lets an unprivileged developer exercise and observe root ownership exactly as CI/root would,
  # without weakening the production task or requiring local sudo access.
  # The nested shell, not this test process, deliberately expands its numbered positional parameters.
  # shellcheck disable=SC2016
  fakeroot sh -eu -c '
    ANSIBLE_CONFIG="$1" ansible-playbook "$2" > "$3"
    test "$(stat -c "%U:%G" "$4/.env")" = root:root
    test "$(stat -c "%a" "$4/.env")" = 600
  ' sh "$repo_dir/ops/ansible.cfg" "$playbook" "$output" "$runtime_dir"
}

read_cookie() {
  sed -n 's/^RELEASE_COOKIE="\([A-Za-z0-9]*\)"$/\1/p' "$runtime_dir/.env"
}

run_deploy_artifact "$first_output"
first_cookie=$(read_cookie)
printf '%s\n' "$first_cookie" | grep -Eq '^[A-Za-z0-9]{64}$'
if grep -Fq "$first_cookie" "$first_output"; then
  echo "first runtime cookie leaked into Ansible output" >&2
  exit 1
fi

run_deploy_artifact "$second_output"
second_cookie=$(read_cookie)
printf '%s\n' "$second_cookie" | grep -Eq '^[A-Za-z0-9]{64}$'
if grep -Fq "$second_cookie" "$second_output"; then
  echo "second runtime cookie leaked into Ansible output" >&2
  exit 1
fi

if [ "$first_cookie" = "$second_cookie" ]; then
  echo "consecutive deployments reused the Erlang cookie" >&2
  exit 1
fi

echo "runtime credential artifact tests passed"
