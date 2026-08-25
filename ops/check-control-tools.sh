#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

failures=0

report_failure() {
  printf 'ERROR: %s\n' "$1" >&2
  failures=$((failures + 1))
}

if ! command -v docker >/dev/null 2>&1; then
  report_failure 'docker is required on the control machine; follow DEPLOYMENT.md → Prepare the repository and laptop.'
elif ! docker version >/dev/null 2>&1; then
  report_failure 'docker is installed but the daemon is unavailable to this user.'
fi

if ! command -v cosign >/dev/null 2>&1; then
  report_failure 'cosign is required on the control machine; follow DEPLOYMENT.md → Prepare the repository and laptop.'
elif ! cosign version >/dev/null 2>&1; then
  report_failure 'cosign is installed but cannot run successfully.'
fi

if ! command -v gh >/dev/null 2>&1; then
  report_failure 'gh is required on the control machine; install the current upstream GitHub CLI from DEPLOYMENT.md.'
elif ! gh attestation verify --help >/dev/null 2>&1; then
  report_failure 'gh does not provide gh attestation verify; install the current upstream GitHub CLI, not Ubuntu 26.04 gh 2.46.0.'
elif ! gh auth status --hostname github.com >/dev/null 2>&1; then
  report_failure 'gh is not authenticated to github.com; run gh auth login --hostname github.com --web.'
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi
