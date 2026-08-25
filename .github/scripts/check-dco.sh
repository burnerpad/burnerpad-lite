#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

# Require a DCO sign-off from every non-merge commit. Human sign-offs must match the commit author or
# committer. Dependabot's canonical support@github.com sign-off is accepted only when both the PR event
# and GitHub's signed-commit metadata independently identify the canonical Dependabot service.
set -uo pipefail

: "${BASE:?BASE must identify the pull request base commit}"
: "${HEAD:?HEAD must identify the pull request head commit}"

verified_dependabot_commit() {
  local sha=$1
  local author_email=$2
  local committer_email=$3
  local commit_json

  [ "${PR_AUTHOR:-}" = 'dependabot[bot]' ] || return 1
  [ "$author_email" = '49699333+dependabot[bot]@users.noreply.github.com' ] || return 1
  [ "$committer_email" = 'noreply@github.com' ] || return 1
  [ -n "${GITHUB_REPOSITORY:-}" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1

  if ! commit_json=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha"); then
    return 1
  fi

  jq -e '
    .author.login == "dependabot[bot]" and
    .committer.login == "web-flow" and
    .verification.verified == true and
    .verification.reason == "valid"
  ' >/dev/null <<< "$commit_json"
}

ok=1
while read -r sha; do
  # Merge commits do not represent a new contributor assertion.
  if [ "$(git rev-list --parents -n1 "$sha" | wc -w)" -gt 2 ]; then
    continue
  fi

  author_email=$(git show -s --format='%ae' "$sha" | tr '[:upper:]' '[:lower:]')
  committer_email=$(git show -s --format='%ce' "$sha" | tr '[:upper:]' '[:lower:]')
  mapfile -t signoff_emails < <(
    git show -s --format='%B' "$sha" \
      | awk '
          { line[NR] = $0 }
          END {
            last = NR
            while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
            first = last
            while (first > 0 && line[first] !~ /^[[:space:]]*$/) first--
            for (i = first + 1; i <= last; i++) print line[i]
          }
        ' \
      | grep -iE '^Signed-off-by:[[:space:]]*.+<[^>]+>[[:space:]]*$' \
      | grep -ioE '<[^>]+>' \
      | tr -d '<>' \
      | tr '[:upper:]' '[:lower:]'
  )

  if [ "${#signoff_emails[@]}" -eq 0 ]; then
    echo "::error::commit ${sha:0:8} has no Signed-off-by — run: git commit --amend -s --no-edit"
    ok=0
    continue
  fi

  email_match=0
  canonical_dependabot_signoff=0
  for email in "${signoff_emails[@]}"; do
    if [ "$email" = "$author_email" ] || [ "$email" = "$committer_email" ]; then
      email_match=1
    fi
    if [ "$email" = 'support@github.com' ]; then
      canonical_dependabot_signoff=1
    fi
  done

  if [ "$email_match" -eq 1 ]; then
    continue
  fi
  if [ "$canonical_dependabot_signoff" -eq 1 ] \
    && verified_dependabot_commit "$sha" "$author_email" "$committer_email"; then
    continue
  fi

  echo "::error::commit ${sha:0:8} has no sign-off matching author <$author_email> or committer <$committer_email>"
  ok=0
done < <(git rev-list "$BASE..$HEAD")

if [ "$ok" -eq 1 ]; then
  echo "✅ DCO: all commits signed off"
else
  exit 1
fi
