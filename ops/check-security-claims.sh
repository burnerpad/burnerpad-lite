#!/usr/bin/env bash
set -euo pipefail

# Guard active product/security copy against known-overstated promises. Historical audit/review files are
# deliberately excluded because they quote the old claims as evidence.
files=(
  README.md CONTEXT.md SECURITY.md TERMS.template.md
  docs/ARCHITECTURE.md DEPLOYMENT.md docs/RECOVERY.md docs/CRYPTO_GOVERNANCE.md
  lib/burnerpad_web/pages.ex
  priv/static/vendor/crypto-js/README.md
  priv/static/vendor/crypto-js/CONTEXT.md
  priv/static/vendor/crypto-js/SPEC.md
  priv/static/vendor/crypto-js/SECURITY.md
)

pattern='burn-on-read, exactly once|returns? (the )?ciphertext exactly once|secret is revealed exactly once|recipient opens it once|intercepted link is useless|stolen link is useless|swaps blobs between ids merely produces an authentication failure|self-destructs? on first read|SRI (pin )?guarantees.*active origin'
abuse_overstatement='permanent(ly)? (ban|block) (any |a |an )?(user|ip address)|suspend (any |a |an )?user'

if grep -Eni -- "$pattern" "${files[@]}"; then
  echo "Forbidden overstated security claim found; use claim/delivery/decryption and SRI trust-root vocabulary." >&2
  exit 1
fi

if grep -Eni -- "$abuse_overstatement" "${files[@]}"; then
  echo "Forbidden anonymous-abuse overclaim found; network-source controls cannot promise permanent individual exclusion." >&2
  exit 1
fi

terms_files=(TERMS.template.md lib/burnerpad_web/pages.ex)
required_abuse_claims=(
  "per-network-source"
  "temporary bans"
  "shared NAT/CGNAT"
  "distributed actors"
  "do not identify an individual or guarantee permanent exclusion"
  "no source-to-secret mapping"
)

for file in "${terms_files[@]}"; do
  for claim in "${required_abuse_claims[@]}"; do
    if ! grep -Fqi -- "$claim" "$file"; then
      echo "Required anonymous-abuse limitation '$claim' is missing from $file." >&2
      exit 1
    fi
  done
done

echo "active security and anonymous-abuse claims use the bounded production vocabulary"
