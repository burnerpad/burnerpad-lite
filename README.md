# Burnerpad

A minimal, no-accounts, **end-to-end-encrypted one-time-secret sharing** service. The browser encrypts
well-formed Unicode text, the server keeps only opaque ciphertext in RAM, and the first reveal request
atomically removes the row. That is an **at-most-once server claim**, not a delivery guarantee: a response
can be lost after removal, and a restart or deployment removes every resident ciphertext.

- **End-to-end encrypted** — the browser encrypts; the key never reaches the server.
- **At-most-once claim** — one request handler can take the ciphertext; the operation is intentionally
  not automatically or reliably retryable after an uncertain response.
- **Ephemeral** — ciphertext rows live in RAM with a TTL; every resident row is gone on restart/deploy.
- **Tiny** — Elixir + [Bandit](https://hex.pm/packages/bandit), one dependency, no database, no Node, no
  JS framework. The browser JavaScript is three small vanilla scripts — this repo's page driver
  (`priv/static/crypto/crypto-app.js`), a tiny `<head>` theme bootstrap (`theme.js`, light/dark via
  `localStorage`, no cookies), and the audited
  [`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js) library — all served `self`-only and
  SRI-pinned; the library is vendored as a pinned git submodule.

This guarantee assumes the sender's and recipient's devices and the served browser application are
trusted. SRI detects static-asset drift while trusted HTML names the expected hashes; an attacker who
controls the live origin/CDN can replace both HTML and scripts. The independently released CLI narrows
that delivery-path risk. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the complete threat model.

## Run it

The application version is **1.0.1**, sourced from `VERSION`; a deployed instance reports it together with
its immutable Git revision as `1.0.1+<revision>`. The pinned toolchain is **Elixir 1.20.3 / Erlang 29.0.5 /
Node 24.19.0** (`.tool-versions`). The browser crypto is a git submodule, so pull it too:

```bash
git clone --recurse-submodules https://github.com/burnerpad/burnerpad-lite
# already cloned without it? run:  mix setup   (git submodule update --init + mix deps.get)

mix setup               # fetch the crypto submodule + deps
iex -S mix              # dev; serves http://localhost:4000
# or
mix run --no-halt
```

Production artifacts are built only after the full GitHub test workflow succeeds. The release archives an
attested SPDX source SBOM, publishes both GHCR images with image SBOM/provenance and keyless signatures,
and deploys by exact digest. The Ansible deploy verifies both image trust records before replacement,
generates a fresh runtime Erlang cookie, waits for readiness, and runs an independent public
create/reveal/decrypt canary. Follow
[`DEPLOYMENT.md`](DEPLOYMENT.md); do not improvise a bare-metal or mutable-tag production path.

## API

```bash
# create — POST a base64url ciphertext blob; returns the id + a one-time management token
curl -s localhost:4000/api/secrets -H 'content-type: application/json' \
  -d '{"blob":"<base64url>","ttl":3600}'
# => {"id":"K7P2Q9RX4D6F8HJKMNPQRSTVWX","mgmt_token":"<base64url>"}

# claim — POST atomically removes the row and returns the blob to at most one request handler.
# Delivery can still fail after removal, so clients must not automatically retry an uncertain response.
# A deliberate retry succeeds only if the earlier request did not complete the atomic claim.
# `content-type: application/json` is REQUIRED (it's the CSRF gate — a cross-site simple POST can't set it).
# `ttl` also controls how fast your per-IP volume budget recycles — use a short ttl for high-frequency use.
curl -s -X POST localhost:4000/api/secrets/K7P2Q9RX4D6F8HJKMNPQRSTVWX/reveal \
  -H 'content-type: application/json' -d '{}'          # => {"blob":"<base64url>"}  (then 404)

# revoke early with the management token
curl -s -X POST localhost:4000/api/secrets/K7P2Q9RX4D6F8HJKMNPQRSTVWX/burn \
  -H 'content-type: application/json' -d '{"mgmt_token":"..."}'
```

The browser flow uses the non-burning `GET /s/:id` interstitial (an HTML page) that then calls
`POST /api/secrets/:id/reveal`, so a link-preview bot fetching the shared URL can't destroy the secret.
No endpoint burns on a GET. Encryption/decryption is client-side — the API only ever sees the opaque
ciphertext `blob`.

The public delivery gate uses JSON `POST /api/edge/source-check` to compare a caller-supplied edge
observation with the source key resolved by the deployed trusted-proxy path. It returns only `204` (match),
`409` (mismatch), or a generic `400`; it never returns, retains, or logs either address. The scheduled
contract checks both the normal request and a forged `CF-Connecting-IP` header.

## Independently signed CLI

The nested [`@burnerpad/crypto`](priv/static/vendor/crypto-js/README.md) release ships a zero-dependency
Node CLI for Linux, macOS, and Windows. It supports exact UTF-8 text and explicit arbitrary-byte mode,
reads plaintext from standard input and capabilities from files, refuses redirects, and never automatically
retries an uncertain at-most-once claim. Its universal package, SPDX manifest, checksums, GitHub provenance,
and keyless Sigstore bundle are published independently of the website; follow the nested README's
verification commands before installation. This narrows live-web-origin compromise risk but cannot make a
malicious server available or prove that it forgot ciphertext.

A **public** transparency page lives at **`/stats`** (JSON at **`/api/stats`**): resident ciphertext rows,
lifetime counts, capacity, uptime, abuse totals, and 14 days of in-memory homepage request and successful
secret-creation counts. The activity chart does **not** claim unique people: doing that would require a
cookie, fingerprint, or retained network identifier, and Burnerpad keeps none. It stores only
`{UTC day, homepage count, creation count}` and resets on restart. The same page reports the running
application version plus its deployed Git revision.

Those public aggregates are intentionally exact and live: they are read directly from bounded in-memory
counters, without a database, analytics service, delay, cache, or quantization layer. Polling can therefore
show aggregate activity timing, volume, restarts, and some operational state—particularly on a quiet
instance—but the endpoint contains no identifier or capability with which to attribute an event or access a
secret. Burnerpad accepts that limited traffic-pattern visibility in exchange for immediate, inexpensive
public transparency.

A **Terms / Acceptable-Use** page lives at **`/terms`**, rendered from `OPERATOR_NAME` / `ABUSE_EMAIL` /
`JURISDICTION`. Those values plus `SECURITY_EMAIL` and `SECURITY_POLICY_URL` are **required in a
production build**; the app refuses to boot without them so
a fork cannot accidentally publish another operator's identity. The wording lives in
[`TERMS.template.md`](TERMS.template.md); it's a template, **not legal advice** — have a lawyer review it
before running a public instance.

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4000` | HTTP listen port |
| `REAL_IP_HEADER` | `cf-connecting-ip` | header to read the client IP from, when behind a trusted proxy |
| `TRUSTED_PROXIES` | empty | CIDRs whose peers may set `REAL_IP_HEADER`; empty ⇒ use the socket peer |
| `MAX_SECRETS` | `10000` | hard cap on resident rows (range `1..100000`; size to available memory) |
| `TTL_SECONDS` | `86400` | default secret lifetime and ceiling, boot-validated to `[60, 86400]` |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `GLOBAL_CREATE_CEILING` | `1000` | server-wide valid create admissions per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `PER_IP_BUDGET` | 2% of worst-case store bytes | maximum unexpired ciphertext bytes admitted per source |
| `PER_IP_ROW_BUDGET` | 2% of `MAX_SECRETS` | maximum unexpired ciphertext rows admitted per source |
| `STATE_CALL_TIMEOUT_MS` | `1000` | bounded Store/Abuse admission-call timeout (`100..10000`) |
| `BURNERPAD_REVISION` | `dev`; full SHA in prod | source revision reported by `/api/stats` |
| `BURNERPAD_IMAGE_DIGEST` | required in prod | exact deployed `sha256:` OCI digest reported by `/api/stats` |
| `RELEASE_COOKIE` | required at runtime | fresh per-deploy Erlang distribution cookie; never embedded in the image |
| `OPERATOR_NAME` | required in prod | operator/data-controller name shown on `/terms` |
| `ABUSE_EMAIL` | required in prod | abuse/removal contact on `/terms` |
| `JURISDICTION` | required in prod | governing law on `/terms` |
| `SECURITY_EMAIL` | required in prod | RFC 9116 vulnerability-report contact |
| `SECURITY_POLICY_URL` | required in prod | HTTPS disclosure-policy URL without literal whitespace/control characters |

There is **no `SECRET_KEY_BASE`** (no sessions/cookies) and **no database**.

## Capacity planning

For worst-case 65,536-byte ciphertexts, use these measured starting points. Each profile limits the app
container to 75% of total VPS RAM, leaves 25% for the OS/Docker/tunnel/monitoring, and keeps measured peak
app memory below 85% of its own limit.

| Total VPS RAM | App memory limit | Recommended `MAX_SECRETS` | Worst-case resident ciphertext | Measured app peak |
|---:|---:|---:|---:|---:|
| 4 GiB | 3 GiB | 24,000 | 1.465 GiB | 2.458 GiB (81.94%) |
| 8 GiB | 6 GiB | 50,000 | 3.052 GiB | 4.930 GiB (82.17%) |
| 12 GiB | 9 GiB | 75,000 | 4.578 GiB | 7.304 GiB (81.16%) |
| 16 GiB | 12 GiB | 100,000 | 6.104 GiB | 9.649 GiB (80.41%) |

These are conservative capacity estimates, not traffic guarantees. The tests used the production image
and Compose runtime under cgroup limits on a larger host; CPU, kernel, OTP version, monitoring agents, and
real secret-size distribution will affect a deployment. The 16 GiB tier reaches Burnerpad's boot-validated
100,000-row configuration ceiling. See [`docs/CAPACITY_PLANNING.md`](docs/CAPACITY_PLANNING.md) for the
method, latency and queue results, rejected calibrations, and reproducible commands.

## Test

```bash
mix test          # the Elixir suite (store, abuse, HTTP, client-IP keying)
mix test.crypto   # the browser crypto bundle, cross-checked against node:crypto (needs Node ≥ 20)
mix test.core     # unit tests for crypto-app.js's DOM-free Core (display/canon/paste-cap/strength)
mix test.edge     # deterministic canary readiness/reporting and public Cloudflare contract tests
```

Optional headless-browser click-through (Playwright — dev/CI only, isolated in
`test/browser/`, never a runtime dependency):

```bash
cd test/browser && npm ci && npx playwright install --with-deps chromium firefox webkit && npm test
```

CI boots the server, then drives the passphrase-only flow (suite `0x02`) in Chromium, Firefox, WebKit, and
a mobile-WebKit profile: create → a
key-less link → a chip/autocomplete reveal with a wrong-order-then-correct retry (a single network
reveal/burn, the wrong order retried **locally** with no second burn); **pasting the whole phrase at once**
(every word chipped, including the last); the tag field (Regenerate, the remove-a-word warning, writing a
custom 7+ word phrase, Space/Tab to commit); the always-active create button + create/burn/reset UX; a
transport-failure outcome that requires confirmation before a deliberate retry (covering both an
unclaimed first request and a claimed response that was lost); rapid repeat clicks held to one request by
the disabled in-flight state; a `#fragment` (link-mode) reveal URL refused as unsupported; and the strict CSP (`script-src 'self'`) +
SRI-pinned scripts holding with no console errors.

## License

Copyright (C) 2026 Impulsa SLU.

**This repository's original code and configuration are licensed
[AGPL-3.0-or-later](LICENSE) unless otherwise noted** — including the Elixir server, the page driver
(`priv/static/crypto/crypto-app.js`), the theme bootstrap (`theme.js`), and the styles (`crypto.css`). Some
files include `SPDX-License-Identifier` headers. The self-hosted web fonts under `priv/static/fonts/` are
third-party **SIL OFL-1.1** (see `priv/static/fonts/NOTICE.md`). Contributions are under the [DCO](DCO)
(`git commit -s`); no CLA.

The browser **crypto library** is a separate project — **[`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js)**,
licensed **Apache-2.0** — vendored here as a pinned git submodule under `priv/static/vendor/crypto-js`
(never copied into this repo). Keeping the trust-critical crypto permissive and standalone makes it
independently auditable and reusable.
