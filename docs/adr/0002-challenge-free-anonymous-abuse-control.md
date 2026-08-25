# ADR-0002: Keep abuse control anonymous and challenge-free

- **Status:** Accepted
- **Date:** 2026-08-23
- **Decision-makers:** Burnerpad founder/maintainer

## Context

Burnerpad has no accounts, sessions, cookies, CAPTCHA, proof-of-work, or user identity. The application
converts transient IPv4 `/32` and IPv6 `/64` sources into purpose-separated HMAC tokens under a RAM-only key.
It deliberately retains no source-to-secret mapping.

Without identity or a challenge, the server cannot reliably distinguish a distributed attacker from many
legitimate visitors. Source limits also affect users behind a shared NAT/CGNAT, and a source ban cannot be
used to find and remove that source's already accepted secret rows.

## Decision

Keep the public service anonymous and do not introduce accounts, CAPTCHA, proof-of-work, or adaptive
challenges. Enforce availability with:

- per-source request limits and escalating temporary bans;
- per-source expiry-bucketed **row and byte** admission quotas;
- global creation and request ceilings;
- a hard store/memory cap and fail-closed overload behavior;
- Cloudflare edge controls and operator monitoring.

Budget state may contain a purpose-separated source token, expiry bucket, row count, and byte count, but
never a secret ID. Early reveal does not refund a source budget; it ages out conservatively with the
original TTL bucket.

## Alternatives Considered

- **Accounts or API keys:** rejected to preserve the no-account product and avoid identity storage.
- **CAPTCHA/Turnstile:** rejected because the maintainer wants no interactive challenge, including under
  attack.
- **Proof-of-work:** rejected because it adds client complexity, accessibility/device inequality, and an
  attacker can distribute work.
- **Source-to-secret mapping:** rejected because it weakens the privacy boundary even though it would permit
  source-based purge/refund.

## Consequences

- Shared NAT/CGNAT users can be throttled together.
- Distributed actors can exhaust global capacity and make the service fail closed.
- Already accepted rows cannot be purged by source and expire naturally.
- The source row quota is required; a byte-only quota does not protect scarce ETS rows.
- Terms and security documentation must state these limitations rather than promising that every abuser is
  individually identifiable or permanently excluded.

## References

- `Burnerpad.Abuse`
- `BurnerpadWeb.ClientIP`
- [`../PRODUCTION_READINESS_REVIEW.md`](../PRODUCTION_READINESS_REVIEW.md)
