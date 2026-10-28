#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$test_dir/../.." && pwd)
gate="$repo_dir/.github/scripts/gate-new-findings.sh"
scratch=$(mktemp -d)

cleanup() {
  find "$scratch" -depth -delete
}
trap cleanup EXIT

fail() {
  echo "new-findings gate test failed: $*" >&2
  exit 1
}

# Human `mix hex.audit` output, including an ignored section that must never count as a finding.
cat > "$scratch/audit.txt" <<'EOF'
Retired:
  old_pkg 0.1.0 - (invalid) security issue

Advisories:
  bandit 1.12.5 - EEF-CVE-2026-109584 (HIGH)
    aka: CVE-2026-109584, GHSA-7gfj-7gvq-3xqj
    HTTP/2 cookie crumb join expands a small HPACK header block into an unbounded allocation in Bandit
    https://osv.dev/vulnerability/EEF-CVE-2026-109584

  plug_crypto 2.2.0 - EEF-CVE-2026-105963 (MEDIUM)
    aka: CVE-2026-105963, GHSA-ffw9-w85g-f2vh

Ignored advisories:
  mime 2.0.7 - EEF-CVE-2026-000001 (LOW)

Found retired packages
Found packages with security advisories
EOF
printf 'advisory bandit EEF-CVE-2026-109584\nadvisory plug_crypto EEF-CVE-2026-105963\nretired old_pkg 0.1.0\n' \
  > "$scratch/expected.txt"
"$gate" parse-hex < "$scratch/audit.txt" > "$scratch/parsed.txt"
diff -u "$scratch/expected.txt" "$scratch/parsed.txt" || fail "hex audit output parsed incorrectly"

printf 'advisory bandit EEF-CVE-2026-109584\n' > "$scratch/base.txt"
printf 'advisory bandit EEF-CVE-2026-109584\nvulnerability libssl3 CVE-2026-1\n' > "$scratch/worse.txt"
: > "$scratch/empty.txt"

# A pull request may keep (or reduce) what its base already has.
"$gate" compare "$scratch/base.txt" "$scratch/base.txt" >/dev/null || fail "an unchanged base finding blocked"
"$gate" compare "$scratch/empty.txt" "$scratch/base.txt" >/dev/null || fail "a fix that removes a finding blocked"
# It must not add one, and outside pull requests any finding fails.
if "$gate" compare "$scratch/worse.txt" "$scratch/base.txt" >/dev/null; then
  fail "a pull request adding a finding passed"
fi
if "$gate" compare "$scratch/base.txt" >/dev/null; then
  fail "strict mode accepted an existing finding"
fi
"$gate" compare "$scratch/empty.txt" >/dev/null || fail "strict mode rejected a clean result"

echo "new-findings gate tests passed"
