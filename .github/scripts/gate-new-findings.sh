#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Pull-request dependency and image gate. With BASE_SHA set (pull requests) it fails only on findings the
# base commit does not already have, so one fix can merge while an unrelated advisory is still open. Without
# BASE_SHA (pushes to main) it fails on any finding. The release build and the daily audit never use this
# script: they always reject every finding.
#
#   gate-new-findings.sh hex                      retired or advisory-listed Hex packages in mix.lock
#   gate-new-findings.sh npm DIR                  high/critical npm advisories in DIR/package-lock.json
#   gate-new-findings.sh trivy IMAGE DOCKERFILE   HIGH/CRITICAL Trivy findings, honoring ops/trivyignore.yaml
#   gate-new-findings.sh compare HEAD [BASE]      compare two sorted finding lists (no BASE = strict)
#   gate-new-findings.sh parse-hex                turn `mix hex.audit` output on stdin into finding keys
set -euo pipefail
shopt -s inherit_errexit

trivy_image=aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)

usage() {
  sed -n 's/^#   //p' "$0" >&2
  exit 2
}

# Keys: "retired <package> <version>" and "advisory <package> <advisory-id>"; "Ignored ..." sections are
# skipped. An advisory key omits the version, so moving to a still-affected version is not a new finding.
parse_hex() {
  sed 's/\x1b\[[0-9;]*m//g' | awk '
    /^[^ ]/ { section = $0; next }
    section == "Retired:" && /^  [^ ]+ [^ ]+ - / { print "retired", $1, $2 }
    section == "Advisories:" && /^  [^ ]+ [^ ]+ - / { print "advisory", $1, $4 }
  ' | sort -u
}

hex_findings() {
  local output status=0 findings
  (cd "$1" && mix deps.get >/dev/null)
  output=$(cd "$1" && mix hex.audit 2>&1) || status=$?
  findings=$(parse_hex <<<"$output")
  if [ "$status" -ne 0 ] && [ -z "$findings" ]; then
    printf 'mix hex.audit failed without a parseable finding:\n%s\n' "$output" >&2
    return 1
  fi
  [ -z "$findings" ] || printf '%s\n' "$findings"
}

npm_findings() {
  local report
  report=$(cd "$1" && npm audit --json --package-lock-only 2>/dev/null) || true
  if ! jq -e 'has("vulnerabilities")' >/dev/null 2>&1 <<<"$report"; then
    printf 'npm audit returned no report for %s:\n%s\n' "$1" "$report" >&2
    return 1
  fi
  jq -r '.vulnerabilities[].via[] | objects
    | select(.severity == "high" or .severity == "critical")
    | "advisory \(.name) \(.url)"' <<<"$report" | sort -u
}

trivy_findings() {
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$2/ops/trivyignore.yaml:/trivyignore.yaml:ro" "$trivy_image" \
    image --scanners vuln --severity HIGH,CRITICAL --ignorefile /trivyignore.yaml \
    --skip-version-check --quiet --format json "$1" \
    | jq -r '.Results[]? | .Vulnerabilities[]? | "vulnerability \(.PkgName) \(.VulnerabilityID)"' \
    | sort -u
}

report() {
  local label=$1 head=$2 base=${3:-} new existing=
  if [ -n "$base" ]; then
    new=$(comm -23 "$head" "$base")
    existing=$(comm -12 "$head" "$base")
  else
    new=$(cat "$head")
  fi
  if [ -n "$existing" ]; then
    echo "$label: already on the base commit, so not blocking this pull request:"
    awk '{ print "  " $0 }' <<<"$existing"
  fi
  if [ -n "$new" ]; then
    if [ -n "$base" ]; then
      echo "::error::$label: this change adds findings the base commit does not have"
    else
      echo "::error::$label: findings present (outside pull requests every finding fails)"
    fi
    awk '{ print "  " $0 }' <<<"$new"
    return 1
  fi
  echo "$label: no new findings"
}

kind=${1:-}
case $kind in
  hex) label="Hex dependencies" ;;
  npm) [ $# -eq 2 ] || usage; label="npm ($2)"; target=$2 ;;
  trivy) [ $# -eq 3 ] || usage; label="image $2"; image=$2; dockerfile=$3 ;;
  compare) [ $# -ge 2 ] || usage; report findings "$2" "${3:-}"; exit ;;
  parse-hex) parse_hex; exit ;;
  *) usage ;;
esac

collect() {
  case $kind in
    hex) hex_findings "$1" ;;
    npm) npm_findings "$1/$target" ;;
    trivy) trivy_findings "$2" "$1" ;;
  esac
}

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gate-findings.XXXXXX")
cleanup() {
  if [ -d "$work/base" ]; then
    git -C "$repo_dir" worktree remove --force "$work/base" || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

collect "$repo_dir" "${image:-}" >"$work/head"
if [ -z "${BASE_SHA:-}" ]; then
  report "$label" "$work/head"
  exit
fi

git -C "$repo_dir" worktree add --quiet --detach "$work/base" "$BASE_SHA"
base_image=
if [ "$kind" = trivy ]; then
  # The base image is only ever scanned. Its own lock may carry the very advisory being fixed, so it skips
  # the build-time Hex audit; the head image is gated by the separate Hex step.
  git -C "$work/base" submodule update --quiet --init --recursive
  base_image="${image%:*}:gate-base"
  docker build --quiet --build-arg BURNERPAD_HEX_AUDIT=skip \
    -f "$work/base/$dockerfile" -t "$base_image" "$work/base" >/dev/null
fi
collect "$work/base" "$base_image" >"$work/base-findings"
report "$label" "$work/head" "$work/base-findings"
