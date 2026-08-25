# Security-audit PR deep review — 2026-08-25

Review range: `main` (`155b76fa386900f291503e6b981819775d7cd94c`) through
`security_audit` (`a0478b6bf59c92deca21f3c7522453780ba6f31e`).

The pull request contains one commit, 113 changed files, and approximately 10,980 additions / 838
deletions. The PR itself has no description, so the specification used for this review was
`docs/PRODUCTION_READINESS_REVIEW.md`, `docs/PRODUCTION_IMPLEMENTATION.md`, the ADRs, `CONTEXT.md`,
`docs/ARCHITECTURE.md`, and `CONTRIBUTING.md`.

## Verdict

**Repository findings resolved in the reviewed working tree.** DR-01 through DR-12 now have implemented
controls and regression coverage. The branch can become the production baseline after the nested-repository
changes are committed and its parent gitlink is updated. The separately listed external launch gates still
prevent calling a particular live deployment production-ready.

## Finding tracker

| Done | ID | Priority | Area | Finding |
|---|---|---:|---|---|
| [x] | DR-01 | P0 | Abuse control | Global valid-create shedding counts rejected source admissions |
| [x] | DR-02 | P0 | Release trust | Published images are rebuilt after, and differ from, the images scanned by Trivy |
| [x] | DR-03 | P1 | Image CI | Production-image canary requests release identity before startup readiness |
| [x] | DR-04 | P1 | Edge/availability | Public health and static traffic still lacks the required edge protection |
| [x] | DR-05 | P1 | CI hygiene | Clean-tree assertions deliberately ignore untracked output |
| [x] | DR-06 | P1 | Edge/cache | Edge checks omit readiness caching and actual conditional revalidation |
| [x] | DR-07 | P1 | Crypto release | Tag-triggered CLI release is not tied to the mandatory cross-platform gate |
| [x] | DR-08 | P2 | Runtime | Production image boots with a non-UTF-8 native filename encoding |
| [x] | DR-09 | Hard standard | HTTP boundary | `/healthz` and `/readyz` bypass the shared dynamic `no-store` policy |
| [x] | DR-10 | Hard standard | Documentation | `CONTEXT.md` says Abuse owns five ETS tables; the module owns seven |
| [x] | DR-11 | Judgment | Design | `queue_length/0` is duplicated across both state owners |
| [x] | DR-12 | Judgment | Design | The SRI asset registry has two manually synchronized definitions |

## DR-01 — Global valid-create shedding counts rejected source admissions

**Priority:** P0 — release blocker

**Status:** Resolved after the review. Admission now reserves the serialized per-source row/byte budget
before incrementing the global valid-create counter. A global rejection rolls back that exact source
reservation before returning. Regression coverage includes the reproduced ordering and 200 concurrent
admissions constrained by both ceilings.

**Original evidence:** `Burnerpad.Abuse.do_admit_create/3` incremented `@create_global` before checking the
source row, byte, and metadata quotas. Nothing decremented that global counter when the source admission
returned `:over_budget`.

Reproduced with `GLOBAL_CREATE_CEILING=2` and `PER_IP_ROW_BUDGET=1`:

1. First admission from source A succeeds.
2. Second admission from source A returns `{:error, :over_budget}`.
3. First admission from source B incorrectly returns `{:error, {:global_create, retry_ms}}`.

This contradicts the documented distinct global **valid-create admission** ceiling. Exhausted sources can
consume admission capacity without any request reaching Store.

**Recommended change:** Check/reserve the per-source quota first, then consume the global-create counter.
If global admission fails, roll back the per-source reservation. Alternatively, add an exact rollback for
the global counter on every rejected source admission, but ordering the reservations makes the invariant
clearer.

**Acceptance checks:**

- [x] Add the reproduced `success -> over_budget -> different-source success` regression test.
- [x] Verify global rejection rolls back any per-source reservation.
- [x] Verify concurrent admission cannot overshoot either ceiling.
- [x] Preserve the current privacy boundary: no source-to-secret mapping.

## DR-02 — The published image is not the image that passed the vulnerability gate

**Priority:** P0 — release blocker

**Status:** Resolved after the review. Each release matrix image is built and pushed once, then the exact
registry digest returned by that build is pulled and scanned. Only a passing digest receives the custom
Trivy scan attestation and release-workflow Sigstore signature. Deployment requires the signature, build
provenance, and scan attestation for the resolved digest before Compose can run it. The mutable `main`
alias advances only afterward and is checked to resolve to the same approved digest.

**Original evidence:** `.github/workflows/test.yml` built and scanned local `burnerpad:ci` and
`burnerpad-cloudflared:ci` images. `.github/workflows/release.yml` later rebuilt and pushed new images in a
different workflow. Mutable OS package repositories meant the two builds were not guaranteed to produce
the same packages or digest.

**Impact:** The published digest can be signed and attested even though Trivy scanned a different digest.
A package change or newly resolvable vulnerable package between the workflows bypasses the intended
release gate.

**Recommended change:** Prefer one of these designs:

1. Build once, export the exact OCI artifacts/digests from the test workflow, scan them, and publish those
   same artifacts after all gates pass; or
2. Build in the release workflow, scan the exact resulting digest before signing it, and make deployment
   require the signature/attestation that is produced only after the scan succeeds.

Scanning a same-source rebuild is insufficient unless the package inputs are also immutable.

**Acceptance checks:**

- [x] The digest scanned by Trivy equals the digest signed and attested.
- [x] Deployment rejects an unsigned/unscanned digest.
- [x] Both the app and cloudflared artifacts follow the same invariant.

## DR-03 — Production-image canary has a startup race

**Priority:** P1

**Status:** Resolved after the review. The canary now completes bounded readiness polling before release
identity, and each readiness request receives only the remaining startup-time budget. Regression coverage
starts with two `503` responses, then proves identity is not requested until readiness succeeds.

**Original evidence:** `.github/workflows/test.yml:155-164` starts the production container and immediately
invokes `ops/smoke/e2e-canary.mjs`. Before this fix, the canary requested `/api/stats` during
`release_identity`; only afterward did it enter the bounded `/readyz` loop. The corrected order is now
explicit at `ops/smoke/e2e-canary.mjs:41-64`.

The exact committed sequence reproduced:

```text
Burnerpad end_to_end canary failed stage=release_identity ...
```

Waiting for `/readyz` before invoking the same canary made the identical image pass its complete encrypted
create/reveal/decrypt/second-claim transaction.

**Recommended change:** Move the readiness loop ahead of the release-identity request inside the canary.
That keeps the reusable canary self-contained and makes its existing startup comment true. Pass the
remaining readiness budget into each request as well, so an attempt started just before `readyDeadline`
cannot consume a fresh full timeout and almost double the advertised startup bound. A workflow-only sleep
or duplicate polling loop would hide the problem from other fresh-start callers.

**Acceptance checks:**

- [x] Starting the container and immediately invoking the canary passes reliably.
- [x] Startup remains bounded by `BURNERPAD_CANARY_TIMEOUT_MS`.
- [x] A server that never becomes ready fails at the fixed `readiness` stage.
- [x] A ready server with a malformed/mismatched version fails at `release_identity`.
- [x] No capability value or raw error text is logged.

## DR-04 — Public health/static traffic lacks the required edge protection

**Priority:** P1

**Status:** Resolved as a repository control after the review. The exact zone-level rules, monitoring
allowance, thresholds, counting behavior, and 429 failure behavior are committed. A read-only
control-plane audit runs before every deployment and rejects removal, duplication, disabling, bypasses,
or weaker limits. Applying the policy to the real zone remains an explicit external launch gate.

**Evidence:** `lib/burnerpad_web/router.ex:22-59` handles health and static requests before `AbusePlug`.
`/readyz` performs synchronous Store and Abuse GenServer calls at `router.ex:219-225`. The original
requirement at `docs/PRODUCTION_READINESS_REVIEW.md:307-313` explicitly requires protecting public health
and static traffic at Cloudflare. Before this fix, `ops/CLOUDFLARE_PROFILE.md` specified cache behavior but
no explicit rate-limit/WAF rule or executable protection contract.

**Impact:** Public unmetered traffic can consume the application's 100 connection slots. Readiness traffic
also competes with create admission for both state-owner queues.

**Recommended change:** Document explicit Cloudflare rate-limiting rules for `/healthz`, `/readyz`, and
cache-busting static requests, and extend the public contract test to prove the expected behavior. Keep
internal Docker health checks reliable and independent of public throttling.

**Acceptance checks:**

- [x] The exact edge rules, thresholds, bypasses, and failure behavior are documented.
- [x] Monitoring traffic has a safe, explicit allowance.
- [x] An executable check detects removal or weakening of the edge rule.

## DR-05 — Clean-tree CI ignores generated untracked files

**Priority:** P1

**Status:** Resolved after the review. Both jobs call one strict helper using
`git status --porcelain --untracked-files=all`. Its isolated regression test proves ignored output passes
while unexpected untracked output and tracked modifications fail.

**Original evidence:** Both post-test assertions used `git status --porcelain --untracked-files=no`.

**Impact:** A generator or test can create a new source, fixture, package, or release artifact without
failing the promised clean-tree gate.

**Recommended change:** Remove `--untracked-files=no`. If specific tool outputs are expected, add narrowly
scoped `.gitignore` entries rather than disabling detection globally.

**Acceptance checks:**

- [x] A test fixture that creates an unexpected untracked file fails CI.
- [x] Normal test output remains clean or is explicitly ignored.

## DR-06 — Edge checks omit readiness caching and actual revalidation

**Priority:** P1

**Status:** Resolved after the review. The public edge contract now checks GET and HEAD for both health
endpoints, requires `no-store`, and rejects `CF-Cache-Status: HIT`. Every SRI-pinned asset is fetched,
byte-verified, then requested again with its actual `If-None-Match`; the response must be `304` with the
same ETag. Focused unit tests cover failure behavior, and the router test proves the origin contract.

**Evidence:** At review time, `/healthz` and `/readyz` omitted the shared `no-store` policy, and the
readiness portion of `ops/smoke/e2e-canary.mjs` checked only status/body. DR-09 has since fixed those two
parts. This finding remains open because `ops/smoke/edge-contract.mjs:88-101` checks static response headers
and bytes but never performs an `If-None-Match` request to prove conditional revalidation.

**Impact:** A Cloudflare change can cache a stale readiness result, or break the intended stable-filename
ETag behavior, without the public contract detecting it.

**Recommended change:** Apply `no-store` to both health responses; assert it and reject `CF-Cache-Status:
HIT` in the public checks. Capture a static ETag, repeat with `If-None-Match`, and require correct
revalidation semantics plus unchanged SRI-pinned bytes.

**Acceptance checks:**

- [x] GET and HEAD health/readiness responses carry `Cache-Control: no-store`.
- [x] Public health/readiness checks reject an edge cache hit.
- [x] The edge contract exercises a real conditional static request.

## DR-07 — CLI release is not tied to the cross-platform mandatory gate

**Priority:** P1

**Status:** Resolved after the review. The nested test workflow is reusable, and tag publication depends
on its exact tagged-SHA Linux/macOS/Windows matrix. A separate gate requires an annotated tag, verifies its
SSH signature against the committed release signer, proves checkout identity, and requires the tagged
commit to be contained in `origin/main`. The packaging job cannot start until both gates pass. The exact
nested package suite, release-policy regressions, signed-tag verification, package-surface check, and
workflow lint all pass.

**Evidence:** `priv/static/vendor/crypto-js/.github/workflows/release.yml:3-36` runs on any `v*` tag and
reruns `npm test` only on Ubuntu. It does not verify that the tag is signed, is descended from protected
`main`, or corresponds to a successful Linux/macOS/Windows conformance run. `gh release create
--verify-tag` verifies that a remote tag exists; it is not a cryptographic tag-signature check.

The current `v1.4.2` tag is correctly signed, but that is an operator action rather than a workflow-enforced
invariant.

**Recommended change:** Make release publication consume a successful workflow result for the exact tagged
SHA, or rerun the mandatory OS matrix as a reusable workflow. Verify signed-tag policy/ancestry before
publication and keep the Ubuntu packaging job dependent on that gate.

**Acceptance checks:**

- [x] A tag on an untested or non-main commit cannot publish.
- [x] Linux, macOS, and Windows gates correspond to the exact tagged SHA.
- [x] The signed-tag invariant is enforced rather than documented only.

## DR-08 — Production image uses a non-UTF-8 native filename encoding

**Priority:** P2

**Status:** Resolved after the review. The runtime image pins `LANG` and `LC_ALL` to `C.UTF-8`. The
production hardening test now rejects the BEAM warning, renders and serves non-ASCII operator metadata,
reads it through release RPC, and retains the loopback-only distribution assertions. A rebuilt image
passed the hardening test and immediate-start canary.

**Evidence:** The reviewed production image reports empty `LANG`, `LC_CTYPE=POSIX`, and logs:

```text
warning: the VM is running with native name encoding of latin1 which may cause Elixir to malfunction
```

`rel/env.sh.eex:12` unconditionally sets `ELIXIR_ERL_OPTIONS` for distribution binding without preserving
or adding `+fnu`.

**Recommended change:** Set a verified UTF-8 runtime locale such as `ENV LANG=C.UTF-8`, or add `+fnu` to
the release VM options. Prefer the locale setting if the base image supports it, then keep the warning as a
regression assertion.

**Acceptance checks:**

- [x] Production boot emits no native-name-encoding warning.
- [x] Unicode operator configuration and normal release RPC still work.
- [x] Loopback-only Erlang distribution remains intact.

## DR-09 — Health endpoints bypass the shared dynamic cache policy

**Classification:** Hard standards violation

**Status:** Resolved after the review. Both success and failure responses now use the router's shared
plain-text response helper, and GET/HEAD plus readiness-`503` regressions assert `Cache-Control: no-store`.

**Original evidence:** Before this fix, `lib/burnerpad_web/router.ex` called `send_resp/3` directly for
`/healthz` and `/readyz`. That contradicted the single dynamic-response policy described in
`CONTEXT.md:145`, `lib/burnerpad_web/security_headers.ex:56-65`, and `docs/ARCHITECTURE.md:551-557`.
The corrected handlers use `text/3` at `lib/burnerpad_web/router.ex:214-225`.

**Recommended change:** Route the responses through the existing `text/3` helper, or call
`SecurityHeaders.no_store/1` before sending. The shared helper is preferable because it preserves the
documented shared-policy invariant.

**Acceptance checks:**

- [x] GET/HEAD 200 and readiness 503 variants all carry `no-store`.
- [x] Add router regression assertions for both endpoints and states.

## DR-10 — Abuse ETS ownership documentation is stale

**Classification:** Hard standards violation

**Status:** Resolved after the review. Both stale counts now say seven and name the rate, global-request,
global-create, ban, metric, expiry-slot-budget, and budget-total responsibilities. The new shared process
metrics module is also present in the context module inventory.

**Evidence:** `CONTEXT.md:123-125` and `:137` say `Burnerpad.Abuse` owns five ETS tables.
`lib/burnerpad/abuse.ex:6-35` and its initializer create seven: rate, global, global-create, ban, metrics,
budget-slot, and budget-total tables.

**Recommended change:** Update both `CONTEXT.md` references and name the seven responsibilities consistently.

**Acceptance check:**

- [x] Architecture/context documentation agrees with the actual owner and table count.

## DR-11 — State-owner queue metric code is duplicated

**Classification:** Judgment call — duplicated code / future shotgun surgery

**Status:** Resolved after the review. Store and Abuse now obtain mailbox length through one
`Burnerpad.ProcessMetrics.queue_length/1` helper. Tests cover pid lookup, registered-name lookup, queued
messages, and an absent process while the existing state-owner metric tests remain green.

**Evidence:** Equivalent `queue_length/0` implementations exist at `lib/burnerpad/abuse.ex:406-417` and
`lib/burnerpad/store.ex:354-365`.

**Recommended change:** Extract a small capability-free process metric helper if the metric evolves or a
third state owner needs it. It is acceptable to defer while the two implementations remain byte-for-byte
simple and covered.

**Acceptance checks:**

- [x] Both state owners use one capability-free mailbox-length implementation.
- [x] Missing and live processes retain the documented zero/non-negative behavior.

## DR-12 — SRI registry has two manually synchronized definitions

**Classification:** Judgment call — duplicated knowledge

**Status:** Resolved after the review. `BurnerpadWeb.CryptoAssets.expected/0` is the only asset registry.
Both boot verification and `mix bp.sri` consume it, and the generator also delegates byte hashing to the
runtime implementation. Tests prove every committed hash matches the served bytes and that regeneration
is idempotent.

**Evidence:** Asset names/hashes are repeated in `lib/burnerpad_web/crypto_assets.ex:23` and
`lib/mix/tasks/bp.sri.ex:9`.

**Impact:** Adding or renaming an asset requires synchronized edits, and a partial change can make the
generator and boot verifier disagree.

**Recommended change:** Define one data source consumed by both the Mix task and runtime verifier, while
ensuring the runtime still contains committed expected hashes rather than trusting generated asset bytes.

**Acceptance checks:**

- [x] Adding or removing a pinned asset changes one registry consumed by both code paths.
- [x] Runtime verification still compares served bytes with committed expected hashes.
- [x] The registry-driven generator is deterministic and idempotent.

## External launch gates

These are not code defects, but `docs/PRODUCTION_IMPLEMENTATION.md:55-70` explicitly says the application
remains a release candidate until they are completed:

- [ ] Issue fresh Cloudflare tunnel, one-use Tailscale auth, and heartbeat credentials.
- [ ] Apply and record the required GitHub repository/tag rules, budgets, visibility, and notifications.
- [ ] Apply the Cloudflare profile and pass the public contract against the real hostname.
- [ ] Observe Healthchecks.io, UptimeRobot, and GitHub canary notifications end to end.
- [ ] Rerun capacity on the intended VPS provider.
- [ ] Complete the 60-minute recovery and credential-rotation drill on a disposable VPS.
- [ ] Obtain the final independent security review.

## Verification evidence

The following passed across the review and the resulting working tree:

- Elixir formatting, unused-lock and Hex advisory checks, warning-free development/production compile,
  and 126 tests.
- 35 parent JavaScript tests plus the release-image policy and isolated clean-tree tests.
- Exact nested `npm test`: 47 self-tests, 45 conformance checks, 87 edge/package checks, 7 CLI tests, and
  2 release-policy tests.
- 68 real-browser tests across Chromium, Firefox, desktop WebKit, and mobile WebKit.
- Browser `npm ci` and audit with zero reported vulnerabilities.
- Both Docker builds and Dockerfile build checks.
- Production read-only/capability/swap/PID/distribution/cookie/UTF-8 hardening test, including non-ASCII
  HTTP rendering and release RPC.
- Current Trivy database: zero HIGH/CRITICAL findings in both rebuilt images.
- Admission regressions prove rejected sources do not consume global capacity, global rejection rolls back
  source capacity, and concurrent calls remain within both ceilings.
- Release workflow policy tests and Actionlint prove the same matrix digest flows through scan,
  scan-attestation, provenance, signature, and deployment verification for both images.
- Cloudflare policy tests reject removed, disabled, bypassed, origin-only, or weakened health/static rules;
  all production playbooks pass syntax checks with the checksum-locked Galaxy dependencies.
- The isolated clean-tree test proves ignored outputs pass and unexpected tracked or untracked outputs fail.
- Rebuilt production image passed the exact CI order: container start followed immediately by the canary;
  the canary polled readiness before identity and completed create/reveal/decrypt/second-claim.
- Live production-image `GET /healthz` and `GET /readyz` responses both carried `Cache-Control: no-store`.
- Edge-cache regressions enforce GET/HEAD `no-store`, reject public health/readiness cache hits, and require
  a real matching-ETag `304` for every pinned static asset.
- The nested release workflow requires the exact tagged-SHA OS matrix, a trusted annotated signature, and
  containment in protected `main`; parent and nested workflows pass Actionlint from their respective roots.
- Full 4/8/12/16 GiB maximum-state matrix through 100,000 maximum-size resident rows.
- Actionlint, ShellCheck, full-history Gitleaks scans, source packaging, locked Galaxy installation,
  Compose identity, and durable-issue tests.
- Clean recursive clone with the exact parent SHA and signed `@burnerpad/crypto` v1.4.2 gitlink.

After the review, DR-01 through DR-12 were implemented with the regression coverage recorded above. The
external launch gates remain deliberately open until they are exercised against real production accounts
and infrastructure.
