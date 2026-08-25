# Production-readiness implementation status

This file maps the findings in [`PRODUCTION_READINESS_REVIEW.md`](PRODUCTION_READINESS_REVIEW.md) to the
implemented controls. "Implemented" means the repository contains the control and regression gate; it does
not claim that an external dashboard setting or live recovery drill has already happened.

| Finding | Repository implementation |
|---|---|
| BP-P0-01 | Per-source byte **and row** budgets plus a distinct global valid-create ceiling; aggregate admission is O(1), race-safe, and tested. |
| BP-P0-02 | Boot requires `RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING`; invalid relations fail closed. |
| BP-P0-03 | Browser input is exact well-formed Unicode UTF-8 with no normalization; lone surrogates, malformed UTF-8, and over-limit input fail before upload; BOM/emoji/combining/boundary tests exist. |
| BP-P0-04 | Suite `0x02` accepts primitive strings only; coercible/boxed values fail with the canonical error; derived AES keys are non-extractable and transient byte arrays are wiped where possible. |
| BP-P0-05 | README, context, architecture, terms, UI, security policy, crypto spec, CLI, and ADRs distinguish claim/delivery/decryption and document active-origin, destructive-ID, phrase-reuse, and managed-memory limits. |
| BP-P0-06 | Missing TTL uses the default; a supplied invalid TTL is a structured `400`; valid values clamp and the effective TTL is returned/displayed. |
| BP-P0-07 | Parent CI runs the nested repository's exact `npm test`, application/core/browser/image/security-history/ops gates, and rejects any unexpected tracked or untracked test/generator output. |
| BP-P0-08 | CI images contain no release cookie; runtime requires a fresh deploy-generated cookie; successful `main` builds archive an attested SPDX source SBOM and publish public full-SHA GHCR images with image SBOM and provenance. Each exact registry digest must then pass the pinned Trivy HIGH/CRITICAL gate before receiving its digest-bound scan attestation and keyless signature. |
| BP-P0-09 | Ansible deploys an exact digest only after verifying its release-workflow signature, build provenance, and vulnerability-scan attestation; it then waits for readiness, checks the full revision/digest, and runs public edge and encrypted transaction canaries. |
| BP-P0-10 | A documented Cloudflare profile plus executable public contract tests cover redirect/TLS/HSTS/CSP/cache/static bytes/transformation behavior. |
| BP-P0-11 | Deploy and release refuse ambiguous state, but final completion requires the operator to commit the nested repository first, update the parent gitlink, commit the parent, and prove a clean recursive clone. |
| BP-P1-01 | Store/Abuse calls are deadline-bounded; admission/full/ban aggregates are O(1); periodic sweeps replace request-path scans; queue/busy metrics and timeout tests exist. |
| BP-P1-02 | Store validates internal blob/TTL calls and strict canonical decoders enforce management tokens, IDs, and response credentials at boundaries. |
| BP-P1-03 | Browser operations have 12-second aborts, unload cancellation, operation-specific unknown outcomes, burn confirmation, token-discard warning, and exact-or-rejected phrase paste. |
| BP-P1-04 | GET/HEAD-only `/healthz` and dependency-aware `/readyz` are separate; mutation methods are rejected, and public edge rules and monitor uses are explicit. |
| BP-P1-05 | Resident vs live semantics are honest; queue, busy, internal-error, restart/OOM, resource, and privacy-safe aggregate signals are exposed/monitored without capabilities; exact live public aggregates are intentional and their timing tradeoff is documented; hourly operational/resource samples retain approximately 12 months. |
| BP-P1-06 | CPU/memory/swap/PID/core bounds cover app and tunnel; diagnostic resource checks gate heartbeats; exact-label image pruning retains five releases. |
| BP-P1-07 | Recovery SLO/RTO/RPO, credential rotation, quarterly throwaway drill workflow, and compliance drift playbook are documented. |
| BP-P1-08 | Unicode/boundary/browser-matrix, crypto randomness/uniqueness/record-swap, CLI interoperability, malformed-input, history-secret, production-image, and synthetic tests broaden coverage. |
| BP-P1-09 | Exact tool versions, pinned actions/images, Galaxy artifact hash lock, cloudflared source commit/binary metadata, OCI labels, image SBOMs, an archived/attested SPDX source SBOM, and attestations make drift visible. |
| BP-P1-10 | Reusable inventories contain invalid placeholders; trimmed UTF-8/email/HTTPS identity is boot-validated; policy URLs reject literal ASCII whitespace/controls; RFC 9116 output is rendered from operator configuration with a bounded future expiry. |
| BP-P1-11 | Production requires a full 40-character Git SHA and exact OCI digest; stats and deploy verification expose/compare both. |
| BP-P2-01 | Deployment/recovery documents enforce one active instance, all-resident RPO, destructive replacement, no rolling deploy, and no persistence/backup fiction. |
| BP-P2-02 | The nested repository ships a zero-dependency Node CLI with exact text/binary modes, stdin/file-only secrets, no redirects/retries, stable errors, cross-platform CI, frozen package surface, signed checksums, SPDX, and provenance. |
| BP-P2-03 | [`CRYPTO_GOVERNANCE.md`](CRYPTO_GOVERNANCE.md) freezes official creation at `0x02` and requires independent expert review for any new construction; repository settings define solo-maintainer compensating controls. |

## Current-tree verification — 2026-08-23

- Elixir formatting and development/production warnings-as-errors compilation passed; **106 application
  tests** and **15 browser-core tests** passed.
- The nested gate passed **47 reproducible vectors/self-tests, 45 bundle conformance checks, 87
  adversarial/property/package checks, and 6 CLI tests**.
- The real-browser suite passed **48 flows**: 12 each on Chromium, Firefox, desktop WebKit, and a mobile
  WebKit viewport. WebKit ran in the exact Playwright 1.62.1 container to avoid changing host packages.
- All production playbooks syntax-check; locked Galaxy artifacts verify; rendered monitor/prune scripts
  pass Bash parsing and ShellCheck; the rendered Compose model passes `docker compose config`.
- All parent/nested workflow files pass YAML parsing and Actionlint. Browser npm and Hex advisory checks,
  unused dependency checks, intended-commit-set and full-history secret scans, and diff/security-claim gates
  are clean.
- Both Dockerfiles pass build checks; both final images build; the app image and every saved OCI layer have
  no baked cookie path or deletion whiteout, the release rejects a weak runtime cookie, exposes BEAM
  distribution only on loopback, supports release RPC, and passes a real
  create/reveal/decrypt/second-claim transaction. Current Trivy data reports zero HIGH/CRITICAL findings in
  either image.
- The isolated deployment-artifact regression renders twice through the production role and requires a
  different 64-character cookie each time, a `root:root` mode-`0600` runtime file, and no cookie value in
  Ansible output.
- The constrained maximum-state matrix passes at 24,000 / 50,000 / 75,000 / 100,000 maximum-size rows for
  the documented 4 / 8 / 12 / 16 GiB VPS profiles, with memory headroom and clean post-load recovery.

## External launch gates still requiring the operator

- Issue fresh Cloudflare tunnel, one-use Tailscale auth, and heartbeat credentials immediately before the
  launch; keep the ignored local secret file mode `0600` (or encrypt it with Ansible Vault).
- Apply `.github/REPOSITORY_SETTINGS.md`, confirm zero-dollar budgets, public GHCR visibility, branch/tag
  rules, signed tags, and notifications.
- Apply the Cloudflare profile and pass the public edge contract against the real hostname.
- Configure Healthchecks.io and UptimeRobot, observe the GitHub scheduled synthetic, and exercise every
  notification path.
- Rerun the checked-in constrained capacity matrix on the intended VPS provider, then run the 60-minute
  recovery/credential-rotation drill on a disposable VPS. The current 4/8/12/16 GiB evidence and
  conservative `MAX_SECRETS` recommendations are recorded in `docs/CAPACITY_PLANNING.md`.
- Obtain the final independent security review required by the readiness definition.

Until those external proofs and a clean committed state exist, describe this as an implemented release
candidate, not a completed production launch.
