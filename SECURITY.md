# Security Policy

Burnerpad shares secrets that self-destruct, so its security *is* the product. We welcome good-faith
research and commit to the safe-harbor terms below.

## Reporting a vulnerability

**Email <security@burnerpad.com>.** Please do **not** open a public GitHub issue or pull request, or
disclose publicly, until we've shipped a fix and agreed on timing.

A useful report includes: the affected commit/version (or the URL on a hosted instance); a clear
description and security impact; step-by-step reproduction (ideally a minimal proof-of-concept); and how
you'd like to be credited (or that you'd prefer to stay anonymous). Don't include real third-party secrets.

## Safe harbor

We consider good-faith research conducted under this policy to be **authorized**: we will not pursue or
support legal action against you (including under computer-misuse laws such as the CFAA or equivalents),
and we waive any anti-circumvention claim, for in-scope research. Good faith means you follow this policy,
test only against your own data or instances you're permitted to test, avoid privacy violations and
degradation of service for others, access only the minimum needed to demonstrate the issue, and give us
reasonable time to remediate before public disclosure.

## Scope

**In scope:**
- Anything that lets the **server, the network, or a passive observer recover plaintext or keys** — any
  break of the zero-knowledge / end-to-end-encryption property.
- The **URL fragment** (the decryption key) reaching the server, logs, referrers, or any backend.
- **Burn-on-read failing to be exactly-once** — a secret revealed twice, read without burning, or a
  revoke that doesn't actually destroy the ciphertext.
- **Client-integrity bypasses** — defeating the CSP or the Subresource-Integrity check, or any way the
  served crypto JavaScript could differ from its published source.
- **Rate-limit / abuse-control bypasses** with demonstrated impact (e.g. spoofing the trusted-proxy client
  IP to evade bans).

**Out of scope** — report elsewhere or outside the threat model:
- The **crypto library itself** — see [`burnerpad/crypto-js`](https://github.com/burnerpad/crypto-js).
- A **compromised user endpoint** (malware, keylogger); **abusive content** sent through the service
  (unscannable by design under E2E — use the in-product report flow); the inherent **"link is the
  credential"** property; volumetric **DoS** without a concrete underlying vulnerability; and missing
  best-practice hardening without demonstrated impact.

## What to expect

- **Acknowledgment within 3 business days**, an initial triage within 7, and regular updates after.
- **Coordinated disclosure** — we agree a public date with you, by default within **90 days**, sooner if a
  fix ships or an issue is actively exploited.
- No paid bug bounty yet (pre-revenue, pre-audit); we offer public credit and our thanks.

See also `/.well-known/security.txt` (RFC 9116) on any running instance.
