#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
playbook="$test_dir/deployment_configuration_test.yml"
scratch=$(mktemp -d)
tunnel_marker=TEST_ONLY_TUNNEL_TOKEN_1234567890
rulesets_marker=TEST_ONLY_RULESETS_TOKEN_1234567890
committed_vars="$repo_dir/ops/group_vars/all/vars.yml"

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

run_playbook() {
  ANSIBLE_CONFIG="$repo_dir/ops/ansible.cfg" \
    ansible-playbook -i localhost, "$playbook" "$@"
}

assert_no_test_capabilities() {
  local output=$1

  if grep -Fq "$tunnel_marker" "$output" || grep -Fq "$rulesets_marker" "$output"; then
    echo "deployment preflight leaked test capability material" >&2
    exit 1
  fi
}

expect_public_rejection() {
  local field=$1
  local value=$2
  local output="$scratch/public-$field.txt"

  if run_playbook -e "$field=$value" > "$output" 2>&1; then
    echo "deployment preflight accepted invalid $field" >&2
    exit 1
  fi

  grep -Fq "$field" "$output"
  assert_no_test_capabilities "$output"
}

expect_secret_rejection() {
  local field=$1
  local value=$2
  local output="$scratch/secret-$field.txt"

  if run_playbook -e "$field=$value" > "$output" 2>&1; then
    echo "deployment preflight accepted invalid $field" >&2
    exit 1
  fi

  grep -Fq "$field" "$output"
  grep -Fq 'censored' "$output"
  assert_no_test_capabilities "$output"
}

valid_output="$scratch/valid.txt"

if grep -Eq '^(operator_name|abuse_email|jurisdiction|security_email|security_policy_url|public_origin):' \
  "$committed_vars"; then
  echo "instance-specific operator identity leaked into committed vars.yml" >&2
  exit 1
fi

run_playbook > "$valid_output" 2>&1
assert_no_test_capabilities "$valid_output"

# Every public placeholder shipped by the repository must fail before artifact resolution or replacement.
expect_public_rejection operator_name CHANGE_ME_LEGAL_OPERATOR
expect_public_rejection abuse_email abuse@example.invalid
expect_public_rejection jurisdiction CHANGE_ME_JURISDICTION
expect_public_rejection security_email security@example.invalid
expect_public_rejection security_policy_url https://example.invalid/CHANGE_ME_SECURITY_POLICY
expect_public_rejection public_origin https://CHANGE-ME.invalid

# Omitting any instance-specific field from the local deployment file must also fail with its field name.
expect_public_rejection operator_name ''
expect_public_rejection abuse_email ''
expect_public_rejection jurisdiction ''
expect_public_rejection security_email ''
expect_public_rejection security_policy_url ''
expect_public_rejection public_origin ''

# Match the application's stricter production URL and address rules at the deployment boundary.
expect_public_rejection abuse_email not-an-email-address
expect_public_rejection security_policy_url https://operator@example.com/security
expect_public_rejection security_policy_url 'https://example.com/security#internal'
expect_public_rejection public_origin https://burnerpad.io/

# Capability-bearing inputs stay censored even when their validation fails.
expect_secret_rejection cloudflare_tunnel_token CHANGE_ME
expect_secret_rejection cloudflare_zone_id not-a-zone-id
expect_secret_rejection cloudflare_rulesets_read_token CHANGE_ME
expect_secret_rejection heartbeat_url http://heartbeat.example.com/ping/test-only

echo "deployment configuration preflight tests passed"
