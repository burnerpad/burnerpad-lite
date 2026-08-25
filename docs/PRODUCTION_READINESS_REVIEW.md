# Burnerpad Production-Readiness Review

Implementation mapping: [`PRODUCTION_IMPLEMENTATION.md`](PRODUCTION_IMPLEMENTATION.md). The findings below
remain the review record; that status document separates repository controls from external launch proofs.

- **Status:** Action required before production
- **Review date:** 2026-08-23
- **Application baseline:** branch `security_audit`, `HEAD` `59f06a2b905eaa4daf870036becc96d0fd208770`, plus the complete current working tree
- **Crypto baseline:** `priv/static/vendor/crypto-js` at `c54c25400666e0319aab8eb365240f5fd04de318` (`v1.3.1`)
- **Review scope:** application code, browser client, nested JavaScript crypto repository, tests, container images, GitHub Actions, Ansible, Cloudflare/Tailscale deployment assumptions, monitoring, recovery, documentation, and supply chain

## Executive verdict

The current tree is a strong security-hardening draft, but it is **not yet ready for a top-quality public production release**. The cryptographic primitives and the most important architectural choices are sound: plaintext encryption is client-side, AES-GCM inputs are generated with Web Crypto, the server stores opaque RAM-only ciphertext, reveal is an atomic ETS take, client-IP headers are trust-gated, dynamic responses are non-cacheable, scripts are CSP/SRI-pinned, and the containers have a good least-privilege baseline.

No critical cryptographic-primitive failure or currently known high/critical dependency vulnerability was found. That positive result must not be confused with production readiness. The release is blocked by exploitable capacity accounting, an unreachable-ban configuration, lossy text handling, an unsafe public library type contract, inaccurate security claims, incomplete parent CI coverage of the crypto repository, and a deployment path that can report success without proving the public encrypted flow works.

The implementation order should be:

1. Fix the release blockers in **P0** below.
2. Add the GitHub Actions → public GHCR signed release path and deploy immutable digests.
3. Make the deployment wait for health and run the public synthetic transaction.
4. Close the **P1** reliability, performance, observability, and supply-chain gaps.
5. Run the complete release-candidate gate and an independent security review before announcing production readiness.

## Severity and status vocabulary

| Label | Meaning |
|---|---|
| **P0 — release blocker** | Fix before the first public production release. The issue can cause security-contract failure, data corruption, practical denial of service, or an unverifiable deployment. |
| **P1 — production hardening** | Fix immediately after, or in the same hardening release. Material reliability, operability, or defense-in-depth gap. |
| **P2 — maturity** | Needed for “top of the line” operation, but not a reason by itself to hold the first release once P0/P1 controls are in place. |
| **Accepted risk** | Deliberate product or operating trade-off confirmed by the maintainer. It still requires precise documentation and monitoring. |

`live`, `resident`, `claimed`, `delivered`, `decrypted`, and `burned` are not synonyms:

- **live** — a non-expired ciphertext row exists and may still be claimed;
- **resident** — a row physically exists in ETS, including an expired row awaiting access or sweep;
- **claimed/revealed** — the server atomically removed and returned the ciphertext to one request handler;
- **delivered** — the complete response reached the client;
- **decrypted** — an authenticated plaintext was produced locally;
- **burned** — the server row was removed, whether by reveal, management-token revoke, expiry handling, purge, restart, or deployment.

The product guarantees an **at-most-once server claim**, not delivery or decryption exactly once.

## Review limits

This was a source, configuration, build, local runtime, and container review. It did not include authenticated access to the live VPS, Cloudflare account, Tailscale account, GitHub branch settings, DNS registrar, or a third-party penetration test. Manual edge settings described in documentation were therefore assessed as requirements, not verified live state. The planned CLI does not exist in this baseline and was reviewed only as an architectural requirement.

## Evidence collected

The following gates passed against the reviewed working tree:

| Gate | Result |
|---|---|
| `mix format --check-formatted` | Passed |
| development compile with warnings as errors | Passed |
| production compile with warnings as errors | Passed |
| Elixir tests | 82 passed |
| vendored crypto conformance | 45 passed |
| browser-core tests | 8 passed |
| complete nested `npm test` | vector reproducibility, 47 self-tests, 45 conformance checks, and 66 edge/fuzz/package checks passed |
| Playwright | 11 Chromium tests passed |
| `mix hex.audit` | No advisories |
| browser `npm audit --audit-level=high` | No vulnerabilities |
| Dockerfile checks | App and cloudflared Dockerfiles passed |
| Ansible syntax | Both playbooks passed syntax checking |
| Trivy 0.74.0 with a current 2026-08-23 database | No HIGH/CRITICAL findings in either locally built production image |
| `git diff --check` and unused dependency lock check | Passed |

Additional manual reproductions:

- With `RATE_LIMIT=1`, `BAN_THRESHOLD=2`, and `GLOBAL_CEILING=2`, requests reached the global rejection first and never created a ban. The boot validator currently permits this equality.
- With `MAX_SECRETS=10` and a 1,000-byte source budget, ten 1-byte admissions from one source all succeeded. The byte budget therefore permits one source to consume every store row with tiny blobs.
- A supplied JSON TTL of `"one minute"` was accepted and silently received the default 24-hour TTL.
- Suite `0x02` ciphertexts created with `encryptPsk(undefined, ...)` decrypted successfully with the empty string.
- Two suite `0x02` blobs encrypted with the same phrase but different random salts could be swapped between records and still decrypt as authenticated plaintext.
- Invalid plaintext bytes were silently replaced during browser decoding and a leading UTF-8 BOM was stripped.
- Canonical `AQ`, trailing-bit-dirty `AR`, and padded `AQ==` transport strings decoded to the same byte on the pinned OTP version.

## Prioritized findings

### Summary

| ID | Priority | Area | Finding |
|---|---|---|---|
| BP-P0-01 | P0 | Abuse/capacity | The byte-only source budget lets one source fill every store row with tiny blobs. |
| BP-P0-02 | P0 | Abuse/config | `BAN_THRESHOLD == GLOBAL_CEILING` is accepted, which makes the ban path unreachable. |
| BP-P0-03 | P0 | Browser/data | The text-only UI can silently corrupt authenticated plaintext and encrypts oversized input before rejecting it. |
| BP-P0-04 | P0 | Crypto API | Non-string passphrases are silently coerced, including `undefined` to an empty password. |
| BP-P0-05 | P0 | Security contract | Documentation overstates delivery, link safety, record binding, privacy, and SRI guarantees. |
| BP-P0-06 | P0 | API/lifetime | A supplied invalid TTL silently becomes the maximum/default TTL. |
| BP-P0-07 | P0 | CI/supply chain | Parent CI skips most nested crypto security gates and its “full history” secret scan is shallow. |
| BP-P0-08 | P0 | Release | Public GHCR publishing would expose the image-baked Erlang cookie; releases lack signatures, attestations, and immutable deployment by digest. |
| BP-P0-09 | P0 | Deployment | Deploy completion does not wait for health or prove the public create/reveal/decrypt path. |
| BP-P0-10 | P0 | Edge | Public HTTPS, cache, transformation, and post-deploy requirements are manual and insufficiently testable. |
| BP-P0-11 | P0 | Release hygiene | Two release-essential files are untracked, so a clean checkout cannot reproduce the reviewed candidate. |
| BP-P1-01 | P1 | Performance | Public hot paths contain state-sized scans and serialized infinite-timeout calls. |
| BP-P1-02 | P1 | Invariants | Core storage and capability APIs do not enforce all boundary invariants themselves. |
| BP-P1-03 | P1 | Browser/reliability | Network calls have no deadline; burn errors are hidden; “Create another” discards the prior revoke capability. |
| BP-P1-04 | P1 | Health/limits | Health and static routes bypass abuse control; any HTTP method to `/healthz` returns `200`; liveness is not readiness. |
| BP-P1-05 | P1 | Metrics | Counts can include expired resident rows, and error/abuse visibility is too coarse for diagnosis. |
| BP-P1-06 | P1 | Container/host | CPU, image-disk growth, hardening drift, and secret-bearing Ansible diffs are not controlled. |
| BP-P1-07 | P1 | Recovery | Recovery has no tested RTO drill or explicit compromise-time credential rotation checklist. |
| BP-P1-08 | P1 | Test matrix | Browser/platform, RNG freshness, wordlist, load, fault, production-image, and deployment tests are incomplete. |
| BP-P1-09 | P1 | Reproducibility | Base images are pinned, but OS packages, Galaxy artifacts, and cloudflared tag-to-commit identity are not fully reproducible. |
| BP-P1-10 | P1 | Operator identity | Committed canonical operator values and a static `security.txt` can misidentify a forked deployment. |
| BP-P1-11 | P1 | Provenance | Production accepts `dev`, `unknown`, and short revisions. |
| BP-P2-01 | P2 | Architecture | The single-node ETS design has no horizontal-scaling or high-availability story. |
| BP-P2-02 | P2 | Client trust | The independently distributed CLI needs a signed, reproducible, cross-platform release design. |
| BP-P2-03 | P2 | Assurance | Crypto/protocol changes need an independent expert review under the solo-maintainer model. |

## P0 — release blockers

### BP-P0-01 — Byte-only admission does not bound row consumption

**Evidence:** `Burnerpad.Abuse.do_admit_create/3` sums only ciphertext bytes and reserves one byte count per source/expiry slot. `Burnerpad.Store` independently caps rows at `MAX_SECRETS`. A tiny ciphertext consumes almost no source budget but one full store row.

**Impact:** A single source can pace tiny creates below the request-rate threshold and eventually occupy the complete default 10,000-row store. At 240 accepted requests/minute this takes about 42 minutes. The service then returns `503` to every legitimate creator. A distributed actor needs even less care. The existing budget was intended to limit a source to about 2% of capacity, but it limits only worst-case bytes, not the scarce row resource.

**Required change:**

1. Track both `bytes` and `row_count` in the expiry-bucketed, purpose-separated source budget.
2. Default the row allowance to a small fraction of `MAX_SECRETS` (2%, with a documented minimum/maximum), while preserving configuration overrides.
3. Keep the counter keyed only by source token and expiry bucket; never store a source-to-secret mapping.
4. Add a separate global **creation** rate/row admission ceiling rather than relying only on the all-request global ceiling.
5. Preserve conservative accounting after early reveal, as already chosen for privacy.

**Acceptance criteria:**

- One source cannot consume more than its configured live row or byte share with 1-byte blobs.
- Concurrent admissions cannot race past either quota.
- A rejected store insert rolls back both reservations.
- Budgets expire with the TTL bucket and remain unlinkable to secret IDs.
- Shared-NAT collateral behavior and distributed-abuse limitations are documented as accepted trade-offs.

### BP-P0-02 — Valid configuration can make bans unreachable

**Evidence:** `Config.validate_relations!/0` requires `RATE_LIMIT < BAN_THRESHOLD <= GLOBAL_CEILING`. `Abuse.count_and_decide/3` evaluates the global ceiling before allocating/incrementing the per-source counter. At equality, the global branch wins before the per-source weighted count can exceed the ban threshold.

**Impact:** An operator can boot a configuration that claims to ban abusive sources but never does so. This directly conflicts with the chosen challenge-free abuse model, where automatic refusal and banning are primary controls.

**Required change:** Require `RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING`. Add a test that reaches a ban under the smallest valid thresholds, not only tests that invalid values raise.

**Acceptance criteria:** Equality is rejected at boot; the ban path is demonstrated reachable; error text and all configuration tables use the same strict relation.

### BP-P0-03 — The text-only browser contract is not lossless

**Evidence:** The browser uses a default `TextDecoder`. Default decoding replaces malformed UTF-8 rather than rejecting it and strips a leading BOM. The library legitimately operates on arbitrary bytes, so a web recipient can receive authenticated bytes and then display different text. The create page computes the UTF-8 size and displays an over-limit warning but does not stop submission before PBKDF2 and encryption.

**Impact:** Authenticated content can be silently changed after successful decryption. Oversized pasted input performs expensive client cryptography and request serialization before the server rejects it, which can freeze a mobile browser. “Authenticated plaintext” is not enough if the display layer corrupts it.

**Required change:**

- Define the browser product as **well-formed Unicode text encoded as UTF-8**, with no Unicode normalization.
- Reject ill-formed JavaScript strings before encryption rather than allowing `TextEncoder` replacement.
- Decode with fatal UTF-8 behavior and preserve a leading U+FEFF/BOM rather than silently removing it.
- Enforce `65_536 - 45` UTF-8 bytes before PBKDF2/AES work.
- Retain the crypto library's arbitrary-byte API for CLI/SDK consumers, but do not imply binary support in the web UI.

**Acceptance criteria:** Exact round trips cover emoji, CJK, RTL text, combining characters, NFC/NFD as distinct inputs, a leading U+FEFF, newlines, the exact size boundary, one byte over, and malformed surrogate input. Decryption never shows replacement characters produced by decoder error recovery.

### BP-P0-04 — PSK APIs coerce invalid passphrase types

**Evidence:** `pbkdf2/2` passes `passphrase` directly to `TextEncoder.encode`. JavaScript coercion maps `undefined` and `[]` to an empty string, `null` to `"null"`, numbers to decimal text, and objects to `"[object Object]"`.

**Impact:** A caller bug can silently create ciphertext under a trivial, predictable password. Different client languages may also disagree about coercion, breaking the normative cross-client contract.

**Required change:** Both `encryptPsk` and `decryptPsk` must require `typeof passphrase === "string"` and throw a stable documented error for any other type. Add hostile typed-input cases to vectors/edge tests and the independent reference. Prefer deriving a non-extractable AES key directly with `deriveKey`; if raw derived bytes remain unavoidable, wipe them in `finally`.

**Acceptance criteria:** `undefined`, `null`, arrays, boxed strings, objects, symbols, numbers, and booleans fail before KDF work. Valid strings, including the deliberately supported empty string at library level if retained, remain cross-backend conformant.

### BP-P0-05 — Published security promises exceed the implementation

Several independent statements must be corrected before release:

1. **Claim is not delivery.** `:ets.take/2` removes the row before the HTTP response reaches the client. A reset between take and `res.json()` permanently loses the secret. This is the accepted at-most-once design, not an implementation bug to replace with an acknowledgement lease.
2. **The ID is a destructive capability.** The non-burning GET correctly protects ordinary WhatsApp/Slack/email previews. Anyone who deliberately POSTs with an observed ID can still retrieve and destroy the ciphertext without the phrase, then attempt the phrase offline. The generated phrase makes that guessing infeasible; the 130-bit ID prevents blind discovery, and rate limiting is not either cryptographic protection.
3. **Suite `0x02` is not record-bound.** Its AAD binds suite, salt, and IV, but no external record context. When a phrase is reused, swapping a different valid blob under that same phrase returns different authenticated plaintext. `SPEC.md` currently claims the swap must fail.
4. **SRI is drift detection, not active-origin protection.** A party controlling both HTML and script can replace the integrity attribute. The planned independently signed CLI is the stronger client-integrity option.
5. **Privacy is about retention.** The application transiently processes a source and request together; Cloudflare can process IP plus a URL containing an ID. The accurate promise is no retained app-side source-to-secret mapping and no normal request log, not an absolute “never link.”
6. **Server deletion is operationally trusted.** A malicious server can copy ciphertext before reporting a burn. “Cryptographic deletion” is not provided.
7. **The abuse HMAC key is node-global RAM state.** It is stored in `persistent_term`, not scoped to one process as some module comments claim. It still disappears on VM restart.

**Required change:** Align `README.md`, `CONTEXT.md`, `SECURITY.md`, `TERMS.template.md`, rendered pages, `ARCHITECTURE.md`, and the nested `SPEC.md`/`CONTEXT.md`. Require official clients to generate a fresh phrase for every secret. Phrase reuse remains supported by the format but must be documented as forfeiting record-context separation.

**Acceptance criteria:** A single terminology/security-contract test or documentation checklist prevents “exactly once delivered,” “stolen link is useless,” “server swap always fails,” “zero-log,” “active-origin protected by SRI,” and “cryptographic deletion” from returning.

### BP-P0-06 — Invalid supplied TTL silently extends retention

**Evidence:** The router distinguishes only integer from non-integer TTL. Any supplied string, float, object, or boolean falls through to the default TTL; the default is also the maximum 24 hours.

**Impact:** A client intending short retention can unknowingly create a 24-hour secret after a serialization or typing error. This violates fail-closed configuration and data-minimization expectations.

**Required change:** Distinguish an absent `ttl` from a present invalid value. Absence uses the default; a present non-integer returns a structured `400`. Continue clamping valid integers if that is the documented API, and return the effective TTL or expiry in the create response.

**Acceptance criteria:** Missing, minimum, maximum, below-minimum, above-maximum, string, float, boolean, object, and null cases are explicit; the UI displays the actual effective expiry returned by the server.

### BP-P0-07 — Parent CI does not exercise the complete crypto trust boundary

**Evidence:** `mix test.crypto` runs only `test/conformance.mjs`; `.github/workflows/test.yml` invokes that alias. It skips deterministic vector regeneration, the independent two-backend reference self-test, edge/fuzz/type/package checks, and zero-dependency/tarball invariants. The Gitleaks job says it scans history, but checkout does not use `fetch-depth: 0`; nested repository history is not separately scanned.

**Impact:** A bad submodule update can pass parent CI despite failing security-relevant tests in the repository that owns the crypto contract. A historical secret can also evade the stated full-history control.

**Required change:**

- Run the nested repository's exact `npm test` in parent CI.
- Fetch full parent and submodule history for the secret scan and scan both repositories deliberately.
- Add `mix format --check-formatted`, `git diff --check`, unused dependency checks, and a clean-tree post-test assertion.
- Test the built production image by starting it with production configuration and completing a local create/reveal/decrypt flow.
- Protect `main`; require every mandatory check; prohibit force pushes and deletion.

**Acceptance criteria:** Removing any nested test stage, altering vectors, introducing a dependency/build script, or adding a secret to reachable parent/submodule history makes the parent pipeline fail.

### BP-P0-08 — The selected public release model needs runtime secrets and verifiable artifacts

**Evidence:** `mix release` produces an Erlang cookie inside the built release, and the current monitor uses `bin/burnerpad rpc`. Loopback-only distribution substantially limits exposure, but a public image must not embed a reusable RPC credential. The current workflow builds and scans images without publishing, signing, attesting, producing an SBOM, or deploying by digest. The crypto `v1.3.1` tag and reviewed parent commit are unsigned.

**Impact:** Publishing the current image would publish an operational credential. Local tag-based deployment cannot prove that the running bytes are the CI-reviewed bytes, and a compromised maintainer/GitHub account has fewer independent artifacts to defeat.

**Required change:**

1. Generate the Erlang cookie at deployment time, store it only in the root-readable runtime configuration, and pass it to both the app and local RPC invocation. Rotate on every deployment or host rebuild.
2. Build application and cloudflared images in GitHub Actions only after all gates pass.
3. Publish public GHCR images with OCI source/revision/version labels, SBOMs, GitHub artifact attestations, and keyless signatures.
4. Grant the release job only `packages: write`, `id-token: write`, and attestation permissions it actually needs; do not expose production Cloudflare/Tailscale/VPS credentials to pull-request jobs.
5. Deploy an exact `ghcr.io/...@sha256:...` digest and verify its signature/attestation before Compose starts it.
6. Set GitHub's metered-product budget to stop at zero dollars; public standard Actions and public packages are the chosen no-monthly-fee model.

**Acceptance criteria:** No release cookie exists in the image; a fresh runtime receives a unique cookie; the deployed digest is traceable to a full commit and passing workflow; unsigned/unattested images are rejected; rollback uses a prior verified digest.

### BP-P0-09 — Deployment success is not service success

**Evidence:** Ansible calls `docker_compose_v2 state: present` without waiting for healthy services. Compose uses a simple `depends_on`; the monitoring heartbeat calls local BEAM RPC. None proves DNS, public HTTPS, Cloudflare routing, current HTML/SRI assets, create admission, one-time reveal, or decryption.

**Impact:** A deployment can be reported green while the container is crash-looping, the tunnel is broken, Cloudflare serves stale assets, SRI bricks the UI, or the public crypto transaction fails.

**Required change:**

- Make deployment wait for both services to become healthy with a bounded timeout.
- Verify the running `/api/stats` full revision and image digest match the requested release.
- Run an immediate external post-deploy synthetic transaction.
- Add a scheduled GitHub Actions canary every 15 minutes: create short-TTL random Unicode text, retrieve through the public API, decrypt locally using the pinned library/CLI, compare exact text, verify the second reveal is `404`, and suppress all capability material from logs.
- Keep Healthchecks.io as the VPS dead-man switch and UptimeRobot as the independent five-minute public HTTPS/content monitor. The GitHub synthetic is complementary because scheduled runs may be delayed or disabled after prolonged repository inactivity.

**Acceptance criteria:** Ansible fails and rolls back or clearly halts when health, revision, public TLS, assets, or the synthetic flow fails. Canary alerts identify stage and release without logging the temporary ID, phrase, blob, or full path.

### BP-P0-10 — The Cloudflare edge contract is manual and can break confidentiality delivery or availability

**Evidence:** The application is HTTP behind a Cloudflare Tunnel. Documentation requests a cache rule for stable `/crypto/*` paths but does not fully specify origin revalidation, `no-transform`, Rocket Loader/script rewriting, HTML/API caching exclusions, forced HTTPS, minimum TLS, or a machine-verifiable configuration snapshot.

**Impact:** A first HTTP visit can be downgraded before HSTS is learned if the edge does not force HTTPS. A stale stable-path script combined with fresh HTML/SRI can brick the page. Script transformation can invalidate reviewed behavior. Caching a reveal or management-token response would be catastrophic; origin headers are correct, but the edge configuration must preserve them.

**Required change:** Document and validate a Cloudflare production profile:

- force HTTP → HTTPS at the edge and set an appropriate minimum TLS version;
- retain the confirmed domain-wide HSTS `includeSubDomains; preload` policy and verify preload registration separately;
- never cache HTML or `/api/*`; honor `Cache-Control: no-store`;
- for stable crypto scripts, cache only with origin-respecting revalidation/ETag behavior rather than immutable override;
- disable Rocket Loader, email rewriting, Auto Minify, and other script/HTML transformations for the site, or explicitly exclude every trusted script;
- preserve `CF-Connecting-IP` only from the authenticated tunnel and verify the trusted proxy CIDR after every network change;
- export/document the manual zone settings and test them after deployment.

**Acceptance criteria:** A public test verifies redirect, TLS, headers, cache behavior, SRI, no transformations, no reveal caching, and correct client-IP handling. Changing the Cloudflare configuration cannot silently bypass the release checklist.

### BP-P0-11 — The reviewed release candidate is not a reproducible Git state

**Evidence:** `ops/cloudflared.Dockerfile` and `test/browser/package-lock.json` are untracked, while the Docker and browser workflows depend on them. The rest of the candidate contains substantial unstaged hardening.

**Impact:** A clean checkout of the named commit cannot build or test what was reviewed. CI and future implementers may unknowingly operate on a different candidate.

**Required change:** Commit all intended files, including the submodule gitlink; remove accidental files; then record the resulting full commit as the new audit baseline. The production deploy must continue refusing a dirty tree.

**Acceptance criteria:** A new `git clone --recurse-submodules` at the reviewed commit passes the complete release gate without local-only files.

## P1 — production hardening

### BP-P1-01 — State-sized scans and infinite calls create avoidable stall/DoS modes

**Evidence:**

- Every source-budget admission uses an ETS `select` and sum over budget state.
- Reclaiming budget room can scan/delete expired budget rows.
- `/api/stats` scans the ban table for active bans.
- Every create is serialized through `Burnerpad.Store`.
- Once the store is full, every refused create can invoke a full expiry sweep.
- Store and abuse admission calls use `GenServer.call(..., :infinity)`.

**Impact:** Work per request grows with attacker-controlled state. One busy or stalled owner can pin request processes indefinitely while `/healthz` remains green. The current default limits make this survivable in ordinary use, but “top of the line” requires bounded work and explicit overload behavior.

**Required change:** Maintain O(1) per-source aggregate row/byte counters, an O(1) active-ban gauge, and a capacity state updated by the periodic sweep. Use bounded calls with safe `503` failure, instrument queue length/latency, and load-test maximum supported state. Avoid synchronous full scans on every full-store rejection.

### BP-P1-02 — Boundary invariants are enforced only in the router

**Evidence:** `Store.create/2` accepts any binary size, while only the HTTP route enforces `max_blob`. Management-token transport decoding is permissive and does not require exactly 32 decoded bytes or canonical unpadded base64url. Create blob transport is similarly permissive. `MAX_SECRETS=1` is valid, but the default 2% byte budget becomes 1,310 bytes, so a valid maximum-size first secret cannot be admitted.

**Impact:** Future callers, maintenance code, or the CLI can bypass assumptions that appear to be store invariants. Noncanonical capability strings weaken cross-client contracts even where they do not currently bypass authentication.

**Required change:** Enforce non-empty/max blob and TTL contracts in `Store`; canonical re-encode/compare all capability/transport values; require a 32-byte management token; return distinct internal errors but preserve nondisclosing public responses. Define a per-source budget floor of at least one maximum-size blob or reject incompatible small-capacity configurations.

### BP-P1-03 — Browser network and destructive-action handling is fragile

**Evidence:** Create, reveal, and burn fetches have no abort deadline. Burn has no confirmation and suppresses its error message. “Create another” clears the only in-page management token for the previous still-live secret. Reveal paste caps token count but not total bytes/token length, accepts pasted words that are not in the supposedly list-locked wordlist, and silently truncates after 64 tokens. A connection can therefore hang the UI, a revoke can fail silently, or a user can abandon their revoke capability unintentionally.

**Required change:** Use `AbortController` deadlines; show operation-specific safe errors and an “outcome unknown” state after timeouts; require confirmation for burn; retain a bounded local list of current-session revoke capabilities or explicitly require confirmation before discarding one. Validate pasted words against the wordlist, bound total paste bytes and individual token length, and report truncation/rejection rather than silently changing the phrase. Never persist capabilities to localStorage/sessionStorage.

### BP-P1-04 — Liveness and limiter bypasses need an explicit edge/internal split

**Evidence:** `/healthz` is handled before routing and checks only `request_path`, so any method receives `200`. Health and all static files bypass the application limiter. Health does not test whether Store/Abuse can answer within a deadline.

**Impact:** Public unmetered routes remain origin work during an edge misconfiguration, and a stalled state owner can remain “healthy.” Accepting `POST /healthz` also violates the narrow route contract.

**Required change:** Restrict liveness to `GET`/`HEAD`; add a bounded readiness endpoint that checks critical processes and queue/response thresholds; keep container liveness internal where practical; protect public health/static traffic at Cloudflare; test method handling and stalled-owner behavior.

### BP-P1-05 — Metrics are not precise enough for incident response

**Evidence:** `Store.count/0` reports resident ETS rows, including expired rows awaiting access/sweep, while labeling the number “live.” Burn/purge counters do not consistently distinguish expired removals. Every internal server error logs the same text. Rate-limit `Retry-After` reports the current boundary even when a weighted previous window may keep the caller above threshold after that time.

**Required change:** Expose and name resident/live counts separately or sweep before reporting; make terminal-state metrics mutually exclusive; calculate a conservative retry time; emit privacy-safe structured event classes, route shapes, release, latency, queue, memory, restart, OOM, and error counters. Preserve the agreed exclusions: no IDs, management tokens, ciphertext, phrases, full paths, raw/pseudonymous source mappings, or normal request logs.

**Retention target:** Up to 12 months for capability-free operational/error metrics and daily aggregate
counts, subject to provider privacy configuration and a final legal review. Retained metrics must preserve
the exclusions above and must not become request logs or acquire high-cardinality identifiers.

### BP-P1-06 — Host/container lifecycle controls are incomplete

**Evidence:** Compose bounds memory and PIDs but not CPU. Revision-tagged images are intentionally retained for rollback with no retention policy. OS/SSH hardening runs only during initial setup. The monitor template contains the bearer-like heartbeat URL but its Ansible template task does not set `no_log: true`/`diff: false`.

**Required change:** Add tested CPU reservations/limits; prune only Burnerpad-labeled images under a documented “retain last N verified releases” rule; add a periodic/routine hardening compliance play; suppress secret-bearing Ansible task output and diffs; alert on disk, inode, memory, CPU, restart, and OOM thresholds.

### BP-P1-07 — Recovery must be drilled, not merely described

**Evidence:** Recovery is a manual rebuild and may reuse a named tunnel or existing credentials. There is no timestamped drill proving the solo operator can restore service within the selected target.

**Required change:** Set SLO 99.9% monthly, RTO 60 minutes, and the accepted RPO of all live secrets. Create a quarterly throwaway-VPS drill that verifies fresh Tailscale, Cloudflare tunnel, GHCR digest verification, deployment, public synthetic, alerting, and teardown. A suspected compromise requires new Tailscale auth, tunnel, heartbeat, deploy cookie, GitHub/VPS tokens, and removal of the old node/session; do not reuse potentially exposed credentials.

### BP-P1-08 — Security test coverage is deep but not broad enough

Add the following mandatory tests:

- Firefox and WebKit desktop plus a mobile WebKit viewport for Web Crypto, clipboard, page lifecycle, and UTF-8 behavior;
- repeated encryption uniqueness checks for keys/IVs/salts and instrumentation of expected `getRandomValues` sizes;
- a pinned invariant that the phrase list has exactly 1,296 distinct words and distinct three-character prefixes;
- phrase typed-input rejection and record-swap documentation vectors;
- malformed Unicode and exact UTF-8 round trips;
- source row-count quotas, ban reachability, distributed/global creation shedding, and shared-NAT behavior;
- full-capacity, owner-stall, request-timeout, response-truncation, restart, OOM, and load tests;
- production-container boot, read-only filesystem, no swap, loopback-only distribution, runtime cookie, revision, and public synthetic tests;
- Ansible syntax/lint, rendered Compose validation, and a disposable-host integration test before automation upgrades.

### BP-P1-09 — Reproducibility and source identity stop short of the full build

**Evidence:** Base images and key build tools are strongly pinned, but `apk add` resolves mutable package versions/repositories; Ubuntu apt installs Tailscale/Docker packages by current repository state; Galaxy roles/collections are version-pinned without a committed integrity lock; the custom cloudflared version and commit are independent build arguments; deployment uses a short SHA. The repository declares a broad Elixir range and CI pins one exact Elixir/OTP pair, but it has no committed asdf/mise toolchain file and does not test the stated minimum.

**Required change:** Record package repositories and exact package versions or use snapshot repositories where maintainable; verify downloaded Galaxy artifacts against committed checksums; bind cloudflared tag, peeled commit, Go build metadata, and resulting binary hash; use full SHAs and OCI digests everywhere; generate CycloneDX/SPDX SBOMs for both images and the release source. Commit the supported local toolchain versions and either test the documented minimum Elixir/OTP pair or narrow the declared support range.

Absolute bit-for-bit reproducibility across mutable distro repositories may be an explicit non-goal, but source/version provenance must still be complete and rebuild drift detectable.

### BP-P1-10 — Fork/operator identity protections are internally inconsistent

**Evidence:** Production requires operator values, but `.env.example` and committed Ansible defaults contain the canonical Impulsa identity, so a fork following the documented path can publish it unchanged. `security.txt` is static, contains the canonical domain/contact, and has a manually maintained expiry. Operator text accepts whitespace-only values; `ABUSE_EMAIL` is not validated as an email/contact URI.

**Required change:** Use unmistakable placeholders in reusable examples; keep instance-specific values in an explicitly named production inventory if desired; validate trimmed text and contact syntax; render `security.txt` from operator configuration or require an instance-owned file; add CI that ensures its expiry remains 30–365 days ahead and the policy URL matches the deployed project.

### BP-P1-11 — Production provenance can be `dev` or `unknown`

**Evidence:** `BURNERPAD_REVISION` defaults to `dev` and accepts `unknown` or a 7-character SHA even in a production build.

**Impact:** A running service can pass health while its exact source is not identifiable, weakening incident response and rollback assurance.

**Required change:** In production require a full 40-character lowercase commit SHA plus the verified image digest; reserve `dev`/`unknown` for development/test only. Surface both on an operator endpoint and a safe public version field.

## P2 — maturity roadmap

### BP-P2-01 — Keep single-node ETS honest; do not accidentally “scale” it

The accepted architecture deliberately loses all live secrets on restart/deploy and has no HA requirement. Multiple replicas behind Cloudflare would be incorrect: create, peek, reveal, and burn could hit different private ETS stores. Do not add replicas until a new design provides deterministic ownership/routing or a reviewed shared ephemeral store with atomic consume semantics.

For the selected model, document one active instance, all-live-secret RPO, no rolling deploy, no persistence, no snapshots as recovery, and the fact that VPS/RAM access can copy ciphertext. A deployment may destroy secrets immediately, but it should show the live/resident count and require an explicit production confirmation.

### BP-P2-02 — Independently distributed CLI requirements

The CLI should:

- encrypt/decrypt locally and communicate only opaque blobs/passphrases with the existing API contract;
- default to a new random seven-word phrase for every suite `0x02` secret and warn against reuse;
- support exact UTF-8 text and explicit binary-file modes without conflating them;
- enforce canonical transport encodings and stable typed errors;
- use bounded network calls and clearly report “claim outcome unknown” after reveal transport failure;
- ship reproducible Linux, macOS, and Windows artifacts, signed checksums, SBOM, provenance, and verification instructions;
- pin/verify the server origin and never claim to guarantee availability, deletion, or honest server behavior.

The CLI narrows the active-web-origin threat: a trusted installed CLI can preserve local cryptography even when the website is compromised. It cannot make a malicious server forget ciphertext or stop it denying/swapping service.

### BP-P2-03 — Solo-maintainer cryptographic governance

Two-person approval is unavailable. Compensating policy:

- protected `main`, mandatory CI, signed commits/tags, no force pushes;
- separately versioned and exact-pinned crypto repository;
- complete vector/reference/conformance/edge/fuzz/RNG/package gates in both repositories;
- CI-generated signed releases, GHCR images, CLI artifacts, SBOMs, checksums, and provenance;
- no home-grown primitives;
- freeze the wire construction at suite `0x02` for official clients;
- require an independent expert review before adding or changing a suite/KDF/AAD construction.

Format-compatible implementation fixes—typed inputs, byte wiping, test coverage, timeouts—do not require a new cryptographic audit, but still require all gates and a signed patch release.

## Accepted-risk register

These are deliberate decisions, not forgotten findings:

The hardest-to-reverse choices are recorded in
[`ADR-0001`](adr/0001-at-most-once-reveal.md),
[`ADR-0002`](adr/0002-challenge-free-anonymous-abuse-control.md), and
[`ADR-0003`](adr/0003-browser-cli-and-release-trust.md).

| Risk | Decision and required guardrail |
|---|---|
| Reveal response may be lost after atomic take | Accepted. Promise at-most-once claim, not delivery. No lease/ack protocol. Explain before reveal and in API/CLI errors. |
| Restart/deploy destroys all live secrets | Accepted. RPO is all live secrets; no persistence/HA. Monitor and make production deployment destruction explicit. |
| No CAPTCHA, proof-of-work, accounts, or adaptive challenges | Accepted. Use source row+byte+rate quotas, global creation/load shedding, bans, and Cloudflare; accept shared-NAT collateral and distributed-abuse limits. |
| No source-to-secret mapping | Accepted. Cannot purge an abuser's already accepted rows by source; budget accounting remains conservative until TTL. |
| ID alone can retrieve/destroy ciphertext | Accepted. Non-burning GET protects ordinary previews; ID entropy prevents guessing; copy must describe destructive bearer power. |
| Suite `0x02` lacks external record binding | Accepted for the existing protocol. Official clients generate unique phrases; correct the false swap claim; do not silently change the suite. |
| Active website/origin/CDN compromise | Out of browser threat model. Harden control planes and provide an independently signed CLI. SRI only detects drift while HTML trust remains intact. |
| AES-GCM is not key-committing against malicious-sender equivocation | Out of current scope. Revisit only with a new independently reviewed suite if receiver binding/moderation evidence becomes a requirement. |
| Bootstrap uses first-seen SSH host key with no out-of-band fingerprint | Accepted one-time operational risk. Keep target count validation, never disable checking globally, rotate bootstrap credentials immediately, and use provider console as break-glass. |
| Tailscale `autogroup:member` has root-equivalent production access | Accepted while the tailnet's only member is the solo founder/operator. Adding/inviting any member or shared user must trigger an access-policy review first. |
| Cloudflare/Tailscale configuration is manually administered | Accepted. The deployment runbook and public release verification must capture/test the required settings even without full IaC. |
| HSTS `includeSubDomains; preload` | Accepted because domain-wide HTTPS ownership is confirmed. Maintain HTTPS for every current/future subdomain and verify preload status. |

## Positive controls to preserve

Do not lose these strengths while implementing the roadmap:

- 130-bit fixed-format IDs generated with CSPRNG and collision-safe insertion;
- atomic ETS take for at-most-once claim under concurrency;
- non-burning GET interstitial and JSON-only mutating API;
- client-side AES-256-GCM, 128-bit tags, fresh 96-bit IVs, 16-byte PSK salt, PBKDF2-HMAC-SHA256 at 600,000 iterations, and authenticated suite/header data;
- zero runtime JavaScript dependencies and no crypto build step;
- independent static vectors plus WebCrypto and Node/OpenSSL reference backends;
- committed SRI values verified at boot, strict CSP, no inline scripts, `no-referrer`, and `no-store` dynamic responses;
- trusted-proxy gating before accepting `CF-Connecting-IP` and IPv6 `/64` abuse keys;
- purpose-separated RAM-keyed source tokens and no retained source-to-secret record;
- bounded request body/headers/connections, disabled HTTP/2/WebSocket/compression, and generic client errors;
- RAM-only ETS payloads, disabled swap/core/crash dumps, read-only/cap-dropped containers, internal app network, and no published host port;
- pinned base-image digests, SHA-pinned Actions, lockfiles, advisory scans, and current clean image scans;
- Cloudflare Tunnel outbound ingress, deny-inbound host firewall, Tailscale administration, and unattended security updates.

## Definition of production-ready

Do not label the project production-ready until all of the following are true:

- [ ] Every P0 item has an implementation, regression test, and accurate documentation.
- [ ] All intended working-tree files are committed and a clean recursive clone reproduces every gate.
- [ ] Parent CI runs the complete application, nested crypto, browser, production-image, secret-history, and deployment-static checks.
- [ ] CI publishes signed/attested/SBOM-equipped public GHCR images with no embedded runtime cookie.
- [ ] Ansible verifies and deploys an immutable digest, waits for health, checks revision, and runs the public synthetic.
- [ ] Healthchecks.io, UptimeRobot, and the GitHub synthetic all alert the operator; their failure paths have been exercised.
- [ ] Cloudflare public HTTPS/cache/transformation/privacy settings pass the release checklist.
- [ ] P1 performance behavior is load-tested at configured maximum state and has bounded failure/timeout behavior.
- [ ] The 60-minute rebuild drill and credential-rotation procedure have passed on a disposable VPS.
- [ ] `README`, context, architecture, terms, security policy, crypto spec, and UI copy use the agreed security vocabulary.
- [ ] Branch protection, signed releases, zero-dollar budget guardrails, and the solo crypto-change policy are enabled.
- [ ] A final independent security review finds no unresolved P0/high-severity issue.

## External primary references

- [Cloudflare request headers (`CF-Connecting-IP`)](https://developers.cloudflare.com/fundamentals/reference/http-headers/)
- [Cloudflare cache-rule settings](https://developers.cloudflare.com/cache/how-to/cache-rules/settings/)
- [Cloudflare Rocket Loader exclusions](https://developers.cloudflare.com/speed/optimization/content/rocket-loader/ignore-javascripts/)
- [Cloudflare SSL/TLS modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Docker packet filtering and UFW interaction](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [GitHub Packages billing](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages)
- [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
- [GitHub scheduled-workflow limitations](https://docs.github.com/en/actions/how-tos/troubleshoot-workflows)
- [Tailscale targets and `autogroup:member`](https://tailscale.com/docs/reference/targets-and-selectors)
- [Tailscale SSH policy](https://tailscale.com/docs/features/tailscale-ssh)
- [OWASP password-storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [NIST SP 800-132](https://csrc.nist.gov/pubs/sp/800/132/final)
- [RFC 9771, Properties of AEAD Algorithms](https://www.ietf.org/rfc/rfc9771.html)
