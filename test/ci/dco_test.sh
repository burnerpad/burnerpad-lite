#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
checker="$repo_dir/.github/scripts/check-dco.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

# Imported by the checker process as a local adapter for GitHub's commits API.
CASE_HEAD=
MOCK_COMMIT_JSON=
export CASE_HEAD MOCK_COMMIT_JSON
gh() {
  if [ "$1" != api ] || [ "$2" != "repos/example/burnerpad/commits/$CASE_HEAD" ]; then
    return 2
  fi
  printf '%s\n' "$MOCK_COMMIT_JSON"
}
export -f gh

create_case() {
  local name=$1

  case_repo="$scratch/$name"
  git -C "$scratch" init -q "$name"
  git -C "$case_repo" config user.name "DCO policy test"
  git -C "$case_repo" config user.email "policy@example.invalid"
  git -C "$case_repo" -c commit.gpgsign=false commit --allow-empty --no-gpg-sign -qm base
  case_base=$(git -C "$case_repo" rev-parse HEAD)
}

add_commit() {
  local author_name=$1
  local author_email=$2
  local committer_name=$3
  local committer_email=$4
  local signoff_email=${5-}
  local text_after_signoff=${6-}
  local -a commit_args

  printf '%s\n' "$author_name" > "$case_repo/change.txt"
  git -C "$case_repo" add change.txt
  if [ -n "$signoff_email" ]; then
    commit_args=(-qm change -m "Signed-off-by: $author_name <$signoff_email>")
    if [ -n "$text_after_signoff" ]; then
      commit_args+=(-m "$text_after_signoff")
    fi
    GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
      GIT_COMMITTER_NAME="$committer_name" GIT_COMMITTER_EMAIL="$committer_email" \
      git -C "$case_repo" -c commit.gpgsign=false commit --no-gpg-sign "${commit_args[@]}"
  else
    GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
      GIT_COMMITTER_NAME="$committer_name" GIT_COMMITTER_EMAIL="$committer_email" \
      git -C "$case_repo" -c commit.gpgsign=false commit --no-gpg-sign -qm change
  fi
  case_head=$(git -C "$case_repo" rev-parse HEAD)
}

run_checker() {
  local pr_author=$1
  local commit_json=${2-'{}'}

  (
    cd "$case_repo"
    env \
      BASE="$case_base" \
      HEAD="$case_head" \
      PR_AUTHOR="$pr_author" \
      GITHUB_REPOSITORY=example/burnerpad \
      GH_TOKEN=test-token \
      CASE_HEAD="$case_head" \
      MOCK_COMMIT_JSON="$commit_json" \
      "$checker"
  )
}

expect_pass() {
  local label=$1
  local output
  shift

  if ! output=$(run_checker "$@" 2>&1); then
    printf 'expected %s to pass:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

expect_fail() {
  local label=$1
  local output
  shift

  if output=$(run_checker "$@" 2>&1); then
    printf 'expected %s to fail:\n%s\n' "$label" "$output" >&2
    exit 1
  fi
}

create_case human-match
add_commit Alice alice@example.com Alice alice@example.com alice@example.com
expect_pass "matching human sign-off" alice

create_case human-mismatch
add_commit Alice alice@example.com Alice alice@example.com mallory@example.com
expect_fail "mismatched human sign-off" alice

create_case body-only-signoff
add_commit Alice alice@example.com Alice alice@example.com alice@example.com \
  'This paragraph means the preceding line is body text, not a trailer.'
expect_fail "Signed-off-by outside the trailer block" alice

dependabot_json='{
  "author": {"login": "dependabot[bot]"},
  "committer": {"login": "web-flow"},
  "commit": {"verification": {"verified": true, "reason": "valid"}}
}'

create_case verified-dependabot
add_commit 'dependabot[bot]' \
  '49699333+dependabot[bot]@users.noreply.github.com' \
  GitHub noreply@github.com support@github.com
expect_pass "verified canonical Dependabot commit" 'dependabot[bot]' "$dependabot_json"
expect_fail "Dependabot commit on a non-Dependabot PR" alice "$dependabot_json"

unverified_dependabot_json='{
  "author": {"login": "dependabot[bot]"},
  "committer": {"login": "web-flow"},
  "commit": {"verification": {"verified": false, "reason": "unsigned"}}
}'
expect_fail "unverified Dependabot commit" 'dependabot[bot]' "$unverified_dependabot_json"

wrong_api_identity_json='{
  "author": {"login": "renovate[bot]"},
  "committer": {"login": "web-flow"},
  "commit": {"verification": {"verified": true, "reason": "valid"}}
}'
expect_fail "mismatched GitHub API identity" 'dependabot[bot]' "$wrong_api_identity_json"

create_case missing-signoff
add_commit Alice alice@example.com Alice alice@example.com
expect_fail "missing sign-off" alice

echo "DCO policy tests passed"
