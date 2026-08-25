#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Keep exactly one open incident while a scheduled workflow is failing and close it after recovery.
set -euo pipefail

case "${INCIDENT_STATUS:-}" in
  cancelled)
    exit 0
    ;;
  failure | success)
    ;;
  *)
    echo "INCIDENT_STATUS must be success, failure, or cancelled" >&2
    exit 2
    ;;
esac

for required_name in GH_TOKEN GITHUB_REPOSITORY INCIDENT_TITLE; do
  if [ -z "${!required_name:-}" ]; then
    echo "$required_name is required" >&2
    exit 2
  fi
done

command -v gh >/dev/null || { echo "gh is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# Search narrows the result set; the parameterized jq comparison is the authoritative exact-title check.
# Never interpolate a title into jq source.
existing=$(
  gh issue list --repo "$GITHUB_REPOSITORY" --state open \
    --search "\"$INCIDENT_TITLE\" in:title" --limit 100 --json number,title |
    jq -r --arg title "$INCIDENT_TITLE" \
      '[.[] | select(.title == $title) | .number] | first // empty'
)

case "$INCIDENT_STATUS" in
  failure)
    if [ -z "${INCIDENT_FAILURE_BODY:-}" ]; then
      echo "INCIDENT_FAILURE_BODY is required after failure" >&2
      exit 2
    fi

    if [ -z "$existing" ]; then
      gh issue create --repo "$GITHUB_REPOSITORY" --title "$INCIDENT_TITLE" \
        --body "$INCIDENT_FAILURE_BODY"
    else
      # Refresh the one durable incident so its stage, release, and run link describe the latest failure.
      gh issue edit --repo "$GITHUB_REPOSITORY" "$existing" --body "$INCIDENT_FAILURE_BODY"
    fi
    ;;
  success)
    if [ -z "${INCIDENT_RECOVERY_COMMENT:-}" ]; then
      echo "INCIDENT_RECOVERY_COMMENT is required after success" >&2
      exit 2
    fi

    if [ -n "$existing" ]; then
      gh issue close --repo "$GITHUB_REPOSITORY" "$existing" \
        --comment "$INCIDENT_RECOVERY_COMMENT"
    fi
    ;;
esac
