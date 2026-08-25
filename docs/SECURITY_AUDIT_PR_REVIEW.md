# Security-audit PR review

This document tracks the review of `security_audit` for merge into `main`.

- Review base: `155b76fa386900f291503e6b981819775d7cd94c`
- Reviewed head: `48f031ed276ac90c9e8e9e8e254a61eb2729bea8`
- Scope: 104 changed files, including the effective 15-file update to `priv/static/vendor/crypto-js`
- Review date: 2026-08-24
- Remediation status: resolved items are incorporated into the final signed `security_audit` branch head

## Verdict

Do not describe or merge this revision as production-ready until the P1 findings and repository-policy
blockers below are resolved. The underlying design is generally strong: one-time reveal is atomic, ETS
state and admission work are bounded, browser crypto parsing is strict, dependencies and images are pinned,
and the deployment defaults show careful security work. No critical cryptographic defect was found.

This checklist separates source defects from operational release gates so that resolving a code finding is
not mistaken for proving the live service ready.

Priority meanings:

- **P1:** must resolve before treating the PR as production-ready.
- **P2:** should resolve or explicitly accept and document before public launch.
- **Process blocker:** repository policy prevents the reviewed commit from merging as-is.
- **Maintainability:** judgment call, not evidence that behavior is currently broken.

## P1 findings

### [x] PR-1: Browser deadlines do not cover response bodies

**Evidence**

- `priv/static/crypto/crypto-app.js:153-165` clears the request timer when `fetch()` resolves.
- The create response body is read later at `priv/static/crypto/crypto-app.js:508`.
- The destructive reveal response body is read later at `priv/static/crypto/crypto-app.js:753`.

`fetch()` resolves after the response headers arrive, not after the body is complete. A peer can return
`200` headers and then stall the JSON body indefinitely. In the reveal path this leaves the client stuck
instead of moving to the deliberately designed `unknown` outcome.

**Reproduction**

A local server flushed response headers immediately and delayed the JSON body. With a nominal 50 ms
deadline, the body was still pending after 150 ms because `timedFetch` had already cleared its timer.

**Required resolution**

Keep the `AbortController` and timer alive until a bounded response body has been fully read and parsed.
Add browser tests for stalled create and reveal bodies, including the destructive-reveal state transition.

**Resolution notes**

Resolved in the final squashed branch head:

- `timedFetch` keeps its controller and deadline active through an optional response consumer;
- successful create and reveal JSON bodies are read inside that deadline;
- stalled create bodies produce the existing “creation outcome unknown” state without clearing the input;
- stalled destructive-reveal bodies advance the claim state to `unknown`, expose no plaintext, and require
  explicit confirmation before a retry;
- `test/browser/smoke.spec.mjs` covers both behaviors with an abort-aware stalled response stream;
- the complete 68-test Chromium, Firefox, WebKit, and mobile-WebKit matrix passed in the repository's pinned
  Playwright container.

The implementation is included in the signed branch head.

### [x] PR-2: Per-source budget can be smaller than the advertised per-secret size limit

**Evidence**

- `lib/burnerpad/config.ex:43` accepts `PER_IP_BUDGET` values as low as 1.
- `lib/burnerpad/config.ex:266-275` validates its upper bound but not a usable lower bound.
- The accepted maximum blob size is 65,536 bytes.

The configuration `MAX_SECRETS=10 PER_IP_BUDGET=1` boots successfully, but a valid maximum-size request is
necessarily throttled. This contradicts the configuration invariant that a fresh source must be able to
submit any blob size the API advertises as valid.

**Reproduction**

`Burnerpad.Config.load!/0` accepted the configuration above and reported
`MAX_BLOB_BYTES=65536` with `PER_IP_BUDGET=1`.

**Required resolution**

Reject explicit budgets below `MAX_BLOB_BYTES`, or make the accepted request-size limit configurable in a
consistent way. Add boot-validation tests for the boundary below, at, and above the maximum blob size.

**Resolution notes**

Resolved in the final squashed branch head:

- `Burnerpad.Config.load!/0` rejects a source budget below the 65,536-byte maximum blob size;
- the validation error reports the actual maximum blob size;
- the existing whole-store upper bound remains unchanged;
- configuration tests cover 65,535 bytes rejected, 65,536 accepted, and 65,537 accepted when within store
  capacity.

The implementation is included in the signed branch head.

### [x] PR-3: Production runtime hardening is not protected by a regression test

**Evidence**

`.github/workflows/test.yml:139-172` checks:

- absence of a baked release cookie;
- rejection of a weak runtime cookie;
- a production-image create/reveal/decrypt transaction;
- high and critical image vulnerabilities.

It does not execute or inspect the rendered production deployment to verify the claimed read-only root
filesystem, disabled swap, and loopback-only Erlang distribution/EPMD exposure. Those are important runtime
properties rather than image-content properties.

**Required resolution**

Launch or render the production runtime in CI and assert the effective container/runtime configuration.
Inspect the running listeners and fail if EPMD or distribution is reachable outside loopback. Keep these
checks alongside the existing image transaction.

**Resolution notes**

Resolved in the final squashed branch head:

- `test/ci/production_runtime_hardening_test.sh` renders the real Ansible Compose template and starts only
  its app service from the production image;
- Docker inspection plus active write probes verify a read-only application filesystem and a writable
  `/tmp` tmpfs with `noexec`, `nosuid`, `nodev`, and a 64 MiB limit;
- the test requires a nonzero memory limit with an equal memory+swap limit, which gives the container no
  additional swap allowance;
- it verifies no published host port, all Linux capabilities dropped, `no-new-privileges`, and the 512 PID
  limit;
- it discovers the dynamic Erlang distribution port from EPMD and proves both that listener and EPMD are
  confined to IPv4/IPv6 loopback;
- release RPC must succeed as `burnerpad@127.0.0.1`, proving the injected runtime cookie and loopback node
  remain operational under the hardening controls;
- the image CI job installs the same pinned Ansible Core version as the ops job and runs this regression
  against the images it just built;
- the current working-tree image passed the complete runtime test locally.

The implementation is included in the signed branch head.

### [x] PR-4: Maximum-state behavior has not been load-tested

**Evidence**

`test/burnerpad/maximum_state_test.exs:14-43` inserts 10,000 ETS rows and performs two serial operations.
This is useful functional evidence that the paths do not scan the entire table, but it does not measure:

- concurrent create, reveal, burn, and admission traffic;
- latency or timeout distributions at capacity;
- process mailbox growth;
- BEAM and container memory headroom;
- expiry sweeping under simultaneous traffic.

`docs/PRODUCTION_IMPLEMENTATION.md:62-64` also records representative-hardware load testing as outstanding.

**Required resolution**

Run a reproducible maximum-state workload on representative production hardware. Record concurrency,
throughput, p50/p95/p99 latency, timeouts, mailbox peaks, BEAM/container memory, and recovery after the load
stops. This is a release gate; it need not become an expensive per-commit CI test.

**Resolution notes**

Resolved in the final squashed branch head:

- `test/load/maximum_state.mjs` drives the production container exclusively through public HTTP APIs with
  64 concurrent workers and maximum-size 65,536-byte ciphertexts. It fills to capacity, verifies bounded
  `503` rejection while full, mixes reveal and management-token burn traffic, refills freed slots, samples
  queue/busy/error metrics every 100 ms, and proves readiness/stats plus both queues recover after load;
- `test/load/run_capacity_profile.sh` renders the real Ansible production Compose template, applies the
  same no-swap runtime constraint, captures cgroup peak/current memory plus BEAM/ETS memory, rejects peak
  use above an exact 85% limit, and preserves the JSON phase report;
- `test/load/run_capacity_matrix.sh` reproduces the accepted 4/8/12/16 GiB self-hosting profiles. A manual
  `capacity.yml` workflow makes the expensive release gate repeatable without adding it to every commit;
- `docs/CAPACITY_PLANNING.md` and the README record the workload, limitations, p50/p95/p99/maximum latency,
  throughput, queue peaks, recovery, memory, exact revision, and recommended `MAX_SECRETS` values;
- the final matrix passed at 24,000 / 50,000 / 75,000 / 100,000 resident maximum-size secrets. Container
  peaks were 81.94% / 82.17% / 81.16% / 80.41% of the respective 3 / 6 / 9 / 12 GiB app limits. There were
  no timeouts, unexpected statuses, busy responses, throttles, or internal errors, and final queues were
  zero in every profile;
- calibration deliberately rejected 60,000 rows on the 8 GiB profile (97% of its 6 GiB app limit) and
  25,000 rows on the 4 GiB profile (85.27% of its 3 GiB app limit).

The runs used cgroup-constrained production containers on a larger 64 GiB/32-CPU host with the app capped
at 4 CPUs. This proves the application memory envelope but is not a substitute for rerunning the matrix on
the intended VPS provider when provider-specific CPU/kernel contention matters.

The implementation is included in the signed branch head.

## P2 findings

### [x] PR-5: Diagnostic retention policy was inconsistent

**Evidence**

- `ops/roles/monitor/templates/bp-diag.sh.j2:7-55` records health, memory, ETS, queue, error, resource,
  restart, and OOM samples.
- At review time, `ops/roles/monitor/tasks/main.yml:48-60` retained the entire log for 57 weekly rotations.
- At review time, the readiness specification reserved thirteen-month retention for daily aggregates and
  limited detailed operational/error information to 90 days.

**Original recommendation**

Retain detailed diagnostic samples for no more than 90 days. Store only the deliberately selected daily
aggregates in the longer-lived dataset. Update the task description, which currently calls the complete
diagnostic log “aggregate-only.”

**Resolution notes**

Resolved by an explicit operator retention decision in the final squashed branch head:

- capability-free hourly operational metrics are intentionally retained for approximately 12 months;
- log rotation is reduced from 57 to 52 weekly archives and adds a 365-day maximum age;
- Ansible task names and the deployment, architecture, readiness, implementation, and review documents now
  describe the data accurately instead of calling the complete diagnostic stream “aggregate-only”;
- the retained stream remains root-only and excludes secret IDs, management tokens, ciphertext, plaintext,
  phrases, concrete request paths, raw or pseudonymous source identifiers, and source-to-secret mappings;
- the policy explicitly prohibits turning these metrics into request logs or adding high-cardinality
  identifiers. Grafana-compatible collection remains a separate future observability enhancement.

This accepts the modest operational-pattern exposure in exchange for year-over-year capacity, incident,
and slow-leak analysis. The implementation is included in the signed branch head.

### [x] PR-6: Exact live public statistics are intentionally retained

**Evidence**

- `lib/burnerpad_web/router.ex:166-172` serves the current `stats_map/0` directly.
- `lib/burnerpad/store.ex:155-160` includes the precise resident count.
- `docs/SECURITY_AUDIT.md` records public activity fingerprinting as a residual concern.

An observer can sample the endpoint and correlate exact changes with suspected secret creation or removal.
This does not reveal a secret, but it exposes more real-time activity information than is necessary for
public transparency.

**Original recommendation**

Publish delayed, cached, and quantized values—for example coarse resident ranges and daily counters—rather
than precise live state. If exact statistics are intentionally retained, record that as an accepted privacy
tradeoff.

**Resolution notes**

Accepted by design. `/stats` and `/api/stats` continue to publish exact, live, in-memory aggregate counters.
Reading the counters is O(1) and adds no persistence or analytics dependency (ordinary HTTP request work still
applies). The response contains no secret content, capability, secret id, network address, source token,
cookie, fingerprint, session, or source-to-secret mapping.

The accepted residual tradeoff is that repeated polling—especially on a quiet instance—can reveal aggregate
event timing and volume, restarts, and some capacity or abuse-control state. An observer may correlate those
changes with facts learned elsewhere or use them to tune traffic, but the endpoint alone cannot attribute an
event to a person or recover or operate on a secret. Immediate, inexpensive public transparency is preferred
to delayed, cached, or quantized reporting for this application.

The former performance concern is resolved independently: active-ban reporting is maintained as an O(1)
counter, and liveness/readiness use `/healthz` and `/readyz` rather than the public stats endpoint. No runtime
behavior changed for this resolution.

### [x] PR-7: The CLI rejects IPv6 loopback development origins

**Evidence**

`priv/static/vendor/crypto-js/bin/burnerpad.mjs:48-54` compares the parsed hostname with `::1`. WHATWG URL
parsing returns `[::1]` for `http://[::1]:4000`, so the comparison cannot succeed. `localhost` and
`127.0.0.1` work as intended.

**Required resolution**

Normalize the parsed hostname or recognize its bracketed representation. Add CLI tests covering HTTPS,
IPv4 loopback, hostname loopback, IPv6 loopback, credentials, paths, queries, and fragments.

**Resolution notes**

Resolved in the independently signed
[`@burnerpad/crypto` v1.4.2 release](https://github.com/burnerpad/crypto-js/releases/tag/v1.4.2), commit
`5c16b50ca07832f803d94bb3643c6a9247077746`, now pinned by the parent gitlink:

- `validateOrigin` recognizes the bracketed `[::1]` hostname returned by the WHATWG URL parser while
  preserving the existing unbracketed form for runtime compatibility;
- the regression was reproduced before the implementation change: the public CLI origin contract returned
  `invalid_origin` for `http://[::1]:4000`;
- process-boundary CLI tests now accept HTTPS plus IPv4, hostname, and IPv6 loopback HTTP origins, while
  rejecting non-loopback HTTP, lookalike hostnames, credentials, paths, queries, fragments, and malformed
  URLs;
- the complete pinned nested gate passes: 47 vector/self-tests, 45 conformance tests, 87 edge tests, and 7
  CLI tests under Node 24.19.0. The crypto bundle and wire format are unchanged;
- the release commit and annotated `v1.4.2` tag are signed with the maintainer's account-associated noreply
  identity, and the release workflow published the universal package, SPDX manifest, checksums, Sigstore
  bundle, and GitHub build-provenance attestation successfully.

## Repository-policy blockers

### [x] PR-8: DCO policy unnecessarily required a public contact address

At review time, `CONTRIBUTING.md:39-44` required a real name and reachable email. Commit `48f031e` uses
`1019893+Cinderella-Man@users.noreply.github.com` in its `Signed-off-by` trailer.

Resolved by an explicit privacy-preserving policy decision in the final squashed branch head:

- `CONTRIBUTING.md` accepts a GitHub-provided noreply address associated with the contributor's account;
- contributors are not required to publish a private contact address to certify the DCO;
- the DCO workflow still requires every trailer email to match the commit author email;
- the final squashed commit retains the account-associated noreply identity and is cryptographically signed
  with the contributor's GitHub signing key.

### [x] PR-9: The reviewed root commit is not cryptographically signed

`git verify-commit 48f031e` fails and the commit object contains no `gpgsig`. This conflicts with the signed
commit rule documented in `.github/REPOSITORY_SETTINGS.md:17-24`.

Resolved by squashing the current remediation into the root PR commit and signing the rewritten commit with
the contributor's ED25519 GitHub signing key. Verify the final branch head locally with `git verify-commit
HEAD` and confirm GitHub reports the pushed commit as verified.

## Maintainability review

These observations are deliberately separated from correctness and release blockers.

### [x] M-1: Repeated bounded-call mechanics — no change recommended for this PR

The initial review noted three repeated patterns:

- readiness probes in `lib/burnerpad/abuse.ex:87-91` and `lib/burnerpad/store.ex:204-208`;
- mailbox-length inspection in `lib/burnerpad/abuse.ex:395-405` and
  `lib/burnerpad/store.ex:354-365`;
- guarded `GenServer.call` wrappers in `lib/burnerpad/abuse.ex:408-414` and
  `lib/burnerpad/store.ex:367-373`.

On follow-up, this was downgraded. The implementations are short and readable, and the failure wrappers
intentionally update different metrics. A shared abstraction would introduce indirection into sensitive
state-owner code without a clear present benefit. Reconsider only if a third state owner appears or the
implementations begin to evolve together.

### [x] M-2: Admission reservations are opaque

`Abuse.admit_create/3` returns a bare slot while the source key, slot, and byte count must later be supplied
consistently to `release_create/3`. An opaque reservation value such as
`%Reservation{token: ..., slot: ..., bytes: ...}` accepted by `release/1` would make invalid combinations
harder to construct.

This is not evidence of a current exploit. Decide whether the stronger interface is worth changing now; if
not, document the invariant and close this item as accepted.

Resolved in the final squashed branch head. `Abuse.admit_create/3` now returns an `@opaque` reservation
containing the already-HMAC-tokenized source, expiry slot, and exact byte count. A caller can only pass that
handle to `rollback_create/1`; it no longer repeats or reconstructs any accounting field. The Router
therefore knows only that a failed Store insertion requires rollback, while the reservation representation
and accounting invariant remain local to `Abuse`.

This deliberately does not add unique references or an outstanding-reservation table. The handle prevents
accidental mismatches at the module interface, but it is not an unforgeable or single-use security
capability. Tests cover exact byte rollback, row rollback, source isolation, and the capacity-rejection path.

### [x] M-3: Rename `ametric` and `actr`

`lib/burnerpad/abuse.ex:383-390` uses names that do not communicate whether they increment or read a metric.
Names such as `increment_metric/2` and `metric_value/1` would make review easier. This is safe cleanup, not a
release requirement.

Resolved in the final squashed branch head by renaming the private helpers and all call sites to
`increment_metric/2` and `metric_value/1`.

### [x] M-4: Keep the centralized Router

`lib/burnerpad_web/router.ex` owns static/dynamic routing, secret operations, admission integration,
transparency and operational endpoints, and response shaping. Splitting cohesive route groups may make
future security reviews easier, but a broad refactor during hardening could itself add risk. Defer unless a
concrete change is already forcing the seam.

Reassessed after the correctness work; no split is recommended. The Router is a compact HTTP adapter whose
single ordered pipeline makes security headers, health/static bypasses, abuse control, privacy-safe logging,
bounded parsing, dispatch, and error handling reviewable in one place. Stateful implementation remains in
the deeper `Store` and `Abuse` modules, rendering remains in `Pages`, and M-2 reduced create admission to an
opaque rollback handle. Reconsider only if route groups need genuinely different pipelines, a second caller
needs the create workflow, or creation gains another stateful rollback step.

## External release gates

The following cannot be proved solely by merging source code:

- [ ] Required GitHub checks and branch rules are enabled and passing.
- [x] The complete Playwright browser matrix passes in the pinned Playwright container.
- [ ] Production Docker images and the effective runtime configuration pass inspection.
- [ ] Cloudflare HTTPS, caching, transformation, privacy, and source-identity checks pass against the real
      hostname.
- [ ] VPS firewall, Tailscale administration, tunnel ingress, unattended updates, swap state, and listener
      exposure are verified on the deployed host.
- [ ] Alert delivery is tested, not merely configured.
- [ ] The 60-minute rebuild and credential-rotation drill passes on a disposable VPS.
- [x] Representative maximum-state/load evidence is reviewed and accepted for the constrained production
      profiles; rerun it on the intended VPS provider before raising `MAX_SECRETS`.
- [ ] A final independent security review reports no unresolved P0/high-severity issue.

See `docs/PRODUCTION_READINESS_REVIEW.md:457-464` and `docs/PRODUCTION_IMPLEMENTATION.md:55-64` for the
repository's corresponding readiness definition.

## Validation completed during this review

The following passed against the reviewed head:

- 119 Elixir tests (115 at the reviewed head plus three PR-2 boundary regressions and one M-2
  source-isolation regression);
- formatting and unused-dependency checks;
- development and production compilation with warnings treated as errors;
- Hex advisory audit and whitespace validation;
- toolchain-pin and documented-security-claim checks;
- 17 root crypto core tests and 10 root smoke tests;
- vendored crypto package: 47 vector/self-tests, 45 conformance tests, 87 edge tests, and 7 CLI tests;
- Compose project identity, durable-issue reconciliation, source-release packaging, and locked Ansible
  requirements checks.

The non-containerized JavaScript tests were run with locally installed Node 26.7.0 because the pinned Node
24.19.0 runtime was not installed on the review host. The complete Playwright matrix was subsequently run
in the exact pinned container from `.github/workflows/test.yml` and passed all 68 cases. Production Docker
runtime and the four constrained maximum-state/load profiles were subsequently reproduced locally and
passed. Live edge/VPS and the 60-minute rebuild/credential-rotation checks remain explicit gates above.

## Review resolution log

When resolving an item, record:

1. the commit or pull-request revision containing the change;
2. the new or changed test that protects it;
3. the command or external evidence used to verify it;
4. whether the item was fixed, accepted with rationale, or superseded.

Do not close P1 or external release gates solely because the implementation appears correct on inspection.
