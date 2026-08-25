#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
reconciler="$repo_dir/.github/scripts/reconcile-durable-issue.sh"

# Imported by each child Bash process as a local adapter for the external GitHub CLI.
gh() {
  if [ "$1" = issue ] && [ "$2" = list ]; then
    printf '%s\n' "$GH_FAKE_LIST_JSON"
  else
    printf '%s\n' "$*" >> "$GH_FAKE_CALLS"
  fi
}
export -f gh

run_reconciler() {
  local status=$1
  local list_json=$2
  local calls_file=$3

  GH_FAKE_LIST_JSON="$list_json" GH_FAKE_CALLS="$calls_file" \
    GH_TOKEN=test-token GITHUB_REPOSITORY=example/burnerpad \
    INCIDENT_STATUS="$status" INCIDENT_TITLE="Scheduled check failed" \
    INCIDENT_FAILURE_BODY="Review the failed run." \
    INCIDENT_RECOVERY_COMMENT="The check is green again." \
    "$reconciler"
}

failure_calls=$(mktemp)
run_reconciler failure '[]' "$failure_calls"
grep -Fq \
  'issue create --repo example/burnerpad --title Scheduled check failed --body Review the failed run.' \
  "$failure_calls"

existing_failure_calls=$(mktemp)
run_reconciler failure '[{"number":42,"title":"Scheduled check failed"}]' "$existing_failure_calls"
grep -Fq \
  'issue edit --repo example/burnerpad 42 --body Review the failed run.' \
  "$existing_failure_calls"

recovery_calls=$(mktemp)
run_reconciler success '[{"number":42,"title":"Scheduled check failed"}]' "$recovery_calls"
grep -Fq \
  'issue close --repo example/burnerpad 42 --comment The check is green again.' \
  "$recovery_calls"

healthy_calls=$(mktemp)
run_reconciler success '[]' "$healthy_calls"
test ! -s "$healthy_calls"

cancelled_calls=$(mktemp)
run_reconciler cancelled 'not consulted' "$cancelled_calls"
test ! -s "$cancelled_calls"

invalid_calls=$(mktemp)
if run_reconciler unknown '[]' "$invalid_calls" 2>/dev/null; then
  echo "invalid incident status was accepted" >&2
  exit 1
fi

echo "durable-issue reconciliation tests passed"
