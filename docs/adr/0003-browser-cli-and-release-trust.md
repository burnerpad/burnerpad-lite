# ADR-0003: Separate browser, CLI, and release trust boundaries

- **Status:** Accepted
- **Date:** 2026-08-23
- **Decision-makers:** Burnerpad founder/maintainer

## Context

Committed SRI plus boot verification detects asset drift while the reviewed application and HTML remain
trusted. It cannot protect a future browser visitor when an attacker controls the origin/CDN response and
can replace both a script and its integrity attribute.

The project is public and solo-maintained. GitHub Actions standard runners and public GHCR packages can be
used without a monthly fee. The current local-build deployment cannot prove that the running bytes are the
ones CI reviewed, and the release currently embeds an Erlang RPC cookie at image-build time.

## Decision

Treat active website/origin/CDN compromise as outside the browser client's cryptographic guarantee. Harden
those control planes, but do not claim SRI solves that threat.

Create an independently distributed CLI that encrypts/decrypts locally and talks to the opaque-blob API.
Ship reproducible Linux, macOS, and Windows artifacts with signatures, checksums, SBOMs, and provenance. The
CLI guarantee is trusted local cryptography when the downloaded artifact is authenticated; it does not
guarantee server availability, honest deletion, or one-time delivery.

Use GitHub Actions as the sole normal production builder. Publish public signed/attested GHCR images, move
the Erlang cookie to deployment-time generation, verify artifacts, and deploy immutable image digests.
Protect `main`, require all CI, use signed commits/tags, and require independent expert review before any new
crypto suite/construction.

## Alternatives Considered

- **Continue laptop-only image builds:** rejected because the deployed artifact is not independently tied to
  mandatory CI evidence.
- **Private registry:** rejected because it can introduce quota/cost and the source/image are intended to be
  public; runtime credentials must not be baked into either.
- **Claim browser resistance to active origin compromise:** rejected because same-origin HTML controls the
  SRI trust declaration.
- **Two-person approval for every crypto change:** unavailable in a solo project; replaced with protected CI,
  signatures, deterministic tests, a frozen current suite, and external review before protocol changes.

## Consequences

- Public release jobs need tightly scoped package, identity-token, and attestation permissions.
- Pull-request jobs receive no production deployment credentials.
- Deployment verifies a digest/signature/attestation rather than building or trusting a mutable tag.
- Official clients keep suite `0x02` and generate a fresh phrase per secret; record binding is not retrofitted
  by silently redefining the suite.
- Users needing protection from a compromised web delivery path must install and verify the CLI independently.

## References

- `BurnerpadWeb.CryptoAssets`
- `rel/env.sh.eex`
- `.github/workflows/`
- [`../PRODUCTION_READINESS_REVIEW.md`](../PRODUCTION_READINESS_REVIEW.md)
