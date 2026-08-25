# burnerpad-lite — Repository Context

> **Read this first.** A self-contained map of this repository: what it is, how it works end-to-end, how
> to run/test it, and the invariants that must not break. The deep design rationale (crypto, storage,
> security model) lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); this file is the orientation.

---

## 1. What this is

A minimal, no-accounts, **end-to-end-encrypted one-time-secret sharing** service (**AGPL-3.0-or-later**).
You paste a secret (a password, an API key, a `.env` block); the **browser encrypts it**; the server
stores only **opaque ciphertext it cannot read**; the first reveal claim atomically removes that row
(burn-on-read), or it expires on a TTL. Claim is deliberately **at most once**: a response lost after the
atomic take cannot be recovered by retry, and the product does not promise delivery or decryption exactly
once. Clients never retry automatically; a deliberate retry can succeed only if the earlier request did
not complete the atomic take.

It is deliberately **tiny and operationally simple**: **Elixir + [Bandit](https://hex.pm/packages/bandit)**
(one Hex dependency), **no database**, **no Node at runtime**, **no JS framework**. Secrets live in
**RAM only** — secret payloads are never written to disk and everything is gone on restart. Operational
request events retain only route class/method/status/duration/release; they contain no full path, source,
secret ID, capability, or payload. The server is
**crypto-agnostic**: it stores and relays one opaque blob and never parses it.

The browser JavaScript is three small vanilla scripts, all served `self`-only and SRI-pinned: this repo's
own page driver (`crypto-app.js`, §4), the `<head>` theme bootstrap (`theme.js`, sets light/dark before
paint), and the audited crypto **library**, which is vendored as a **pinned git submodule** (§5).

---

## 2. How it works (end-to-end)

All encryption/decryption is **client-side**; the server only ever sees the opaque ciphertext `blob`.

**Create:** the browser encrypts the secret and `POST`s the `blob` to `/api/secrets`. The server stores it
in memory under a random id and returns `{id, mgmt_token}`. The browser builds the share URL.

**One client mode — passphrase (suite `0x02`): a key-less link + a spoken phrase.** The web client always
encrypts under a passphrase, so **no key is in the URL**: the key is derived from the passphrase (PBKDF2),
an ordinary GET-based ticket/chat preview cannot burn it, and the passphrase is shared **out of band**
(said out loud). The link is still a **destructive capability**: anyone who deliberately sends the reveal
POST can retrieve and destroy the ciphertext, although they cannot decrypt it without the phrase.
The passphrase is **generated, not free-typed**: the create form shows a **7-word phrase (~72 bits)** as
**chips inside a single tag field** (an `<input>` with the chips rendered before the cursor), drawn from an
embedded EFF wordlist (in `priv/static/crypto/crypto-app.js`, CC BY 3.0, attributed in-file). There is **no
generated/custom mode toggle**: every chip has a **×** to remove it, an autocomplete **`＋ add a word`**
slot lets you type your own (list-locked), and a **↻ Regenerate words** control redraws the set. Strength
tracks the **random core**: as long as the **7 generated** words remain the phrase is strong — adding your
own words on top only adds entropy. So the live **strength cue** (bottom-left of the field, opposite
Regenerate) reads green "✓ N words · very strong" (pure generated) or "✓ N words · mixed" (you added your
own on top); it turns amber "N words · weaker" — and surfaces the "generated is stronger" warning — only
when you **remove** random words and drop the core below 7; and red "N/7 — add M more" below the minimum.
The submit button is **always active**; its label is an invitation that flips on the first character —
*"Add your secret to continue"* → *"Encrypt & create link"*. Clicking it with no secret just focuses the
textarea; submitting with a present secret but fewer than 7 words surfaces an inline error (so a
weak/empty passphrase still can't be sent). Beneath it a muted, centered **trust line** with a lock icon reads *"Encrypted in your
browser — we store ciphertext we can't read."* The page opens with a header — the logo wordmark plus a
**light/dark theme toggle** — a value-prop headline (*"Securely share one-claim secrets"*), and a 3-card
**trust strip** (end-to-end encrypted · two separate channels · at most one claim) before the form. The
theme choice is persisted in **`localStorage` (key `bp_theme`), not a cookie**, and applied by a tiny
render-blocking `theme.js` in `<head>` **before first paint** (so there is no flash and the strict
`script-src 'self'` — no inline scripts — still holds); the colors are CSS custom properties on `<html>`.

The **success screen** is the load-bearing moment: it confirms ("Encrypted & ready") and reminds — in the
subtitle — that the recipient needs **both** parts kept on **separate channels**. It then presents the
hand-off as two channel-named steps — **Send the link** (with a Copy button) and **Share the passphrase**
(the words shown large, **with their own Copy button**, framed as a *separate channel — a different app, a
text, or a call*). The passphrase Copy button is a **deliberate choice** (see §9 #8): convenience for the
out-of-band channel, at the cost of the stronger "spoken-only" guarantee — it is on the user to keep that
channel apart from where the link was sent. Below the hand-off the same
screen carries two more controls: a **"Burn it now"** early-revoke that `POST`s `/api/secrets/:id/burn` with the
one-time management token (swapping the panel for a "Burned" confirmation only after a `200`; a transport
failure is an unknown outcome), and a **"← Create another secret"** button that warns before discarding a
still-live management token, then resets with a fresh generated phrase.

The web client **never mints link-mode (suite `0x01`) secrets**, and the reveal page is a **list-locked
autocomplete** that **refuses** a URL carrying a `#fragment` (a link-mode link) rather than guessing — so
the web app is a strict *subset* of what the cross-client crypto lib (§5) supports. The lib still
implements both suites; only this UI is narrowed. Reveal needs no transcription tolerance: chips are
already canonical (lowercase words, single spaces), and a wrong phrase/order is fixed and retried locally
(the held blob is reused — no second burn).

**Reveal:** the browser flow uses a **non-burning** `GET /s/:id` interstitial — which warns up front that
the server removes the row before completing its response and an uncertain claim is not reliably
retryable — then
`POST /api/secrets/:id/reveal` which atomically **claims/burns** the row and makes the
blob available to at most one request handler. (Link-preview
bots fetching `GET /s/:id` therefore can't destroy a secret; a gone/expired/unknown id renders the same
`404` page, while a live ID necessarily remains a liveness oracle.) The recipient builds the phrase in the same tag field (Enter/Space/Tab
commits a word); on success the plaintext appears with a **Copy secret** button under a "won't be shown
again" note. Programmatic clients use the same JSON `POST /api/secrets/:id/reveal` endpoint. No endpoint
burns on `GET`.

### Security vocabulary

| Term | Precise meaning |
|---|---|
| **live** | A non-expired ciphertext row exists and can still be claimed. |
| **resident** | A physical ETS row exists; it may already be expired and awaiting access/sweep. |
| **claimed / revealed** | The server's atomic take removed the row and returned the blob to one request handler. |
| **delivered** | The complete HTTP response reached the client. This is not guaranteed after claim. |
| **decrypted** | A client produced authenticated plaintext locally. |
| **burned** | The row was removed by claim, revoke, purge, expiry handling, restart, or deployment. |

The web UI is **well-formed Unicode text encoded as UTF-8**, without normalization; the reusable crypto
library operates on arbitrary bytes. An active origin/CDN can compromise future browser clients because it
controls the HTML trust root; the independently signed CLI narrows that threat but cannot guarantee
server availability or deletion. See [`docs/PRODUCTION_READINESS_REVIEW.md`](docs/PRODUCTION_READINESS_REVIEW.md)
for the accepted-risk register and required production work.

---

## 3. Architecture & processes

`Burnerpad.Application` starts a supervision tree of four children:

- **`Burnerpad.Store`** — a `GenServer` that owns the secrets **ETS** table and the TTL sweep. It is the
  **only** module that touches that table. **Burn-on-read is `:ets.take/2`** (atomic remove-and-return) →
  one successful server claim under concurrency. A retry cannot recover a completed claim after a lost
  response; it can succeed only if the earlier request never completed the take. A non-burning `peek` backs
  the interstitial.
- **`Burnerpad.Abuse`** — owns seven ETS tables for proactive, in-memory abuse control (per-source rate-limit
  windows, global request and create ceilings, escalating bans, aggregate metrics, per-source expiry-slot
  budgets, and per-source budget totals) plus their sweep. Raw IP prefixes are HMAC-tokenized with a random
  RAM-only key before any table write.
- **`Burnerpad.DailyStats`** — owns one aggregate `{UTC day, homepage requests, secrets created}` table.
  It never stores a cookie, IP, fingerprint, secret ID, or visitor/secret record. Homepage figures are
  explicitly request counts rather than unique people; creation counts increment only after insertion.
- **`Bandit`** serving `BurnerpadWeb.Router` over **plain HTTP** (terminate TLS at a reverse proxy).

### Modules (`lib/`)
| Module | Role |
|---|---|
| `burnerpad/application.ex` | OTP application + supervision tree |
| `burnerpad/config.ex` | runtime config, entirely from environment variables |
| `burnerpad/process_metrics.ex` | capability-free process mailbox metrics shared by state owners |
| `burnerpad/store.ex` | in-memory burn-on-read secret store (ETS; `:ets.take` = at-most-one server claim) |
| `burnerpad/abuse.ex` | in-memory rate limiting, global ceilings, bans, metrics, and capacity budgets (7 ETS tables) |
| `burnerpad/daily_stats.ex` | in-memory daily homepage and successful-create totals; no identifiers |
| `burnerpad_web/router.ex` | the entire HTTP surface (`Plug.Router`); see §6 |
| `burnerpad_web/abuse_plug.ex` | rate-limits dynamic routes; static assets and `/healthz` bypass it |
| `burnerpad_web/client_ip.ex` | resolves the abuse key (IPv4 `/32` or IPv6 `/64`), honoring trusted proxies |
| `burnerpad_web/crypto_assets.ex` | boot-verifies served crypto assets against committed SRI hashes |
| `burnerpad_web/layout.ex` | shared page **chrome** — document shell + `<head>` theme bootstrap, icon sprite, header, footer, SRI `<script>` tags (single source of truth) |
| `burnerpad_web/pages.ex` | per-route page **content** (create, reveal, 404, stats, terms) — wrapped by `Layout`, no inline scripts |
| `burnerpad_web/security_headers.ex` | strict response headers + CSP on every response; `no_store/1` is the one shared cache policy for dynamic responses |

Sessionless and CSRF-free by design: authorization is **possession** of an unguessable capability (the id
+ the key/passphrase, or the management token), not a cookie. There is **no `SECRET_KEY_BASE`** and
**no database**.

---

## 4. Repository layout

```
lib/                       the Elixir app (see the module table in §3)
priv/static/crypto/        APP-OWNED page assets (AGPL): crypto-app.js (page driver) + theme.js + crypto.css
priv/static/fonts/         self-hosted WOFF2 web fonts (SIL OFL 1.1 — third-party; see fonts/NOTICE.md)
priv/static/vendor/crypto-js/   the crypto LIBRARY — a pinned git submodule (Apache-2.0); see §5
lib/burnerpad_web/router.ex      dynamically renders RFC 9116 contact from operator configuration
docs/ARCHITECTURE.md       the deep design doc (crypto, storage, security model)
DEPLOYMENT.md               authoritative GHCR/Ansible production and operations runbook
TERMS.template.md          operator Terms / Acceptable-Use template (rendered at /terms from env vars)
Dockerfile                 multi-stage prod build (mix release)
ops/                       Cloudflare profile, signed-artifact deploy, host hardening, monitoring, smoke checks
mix.exs / mix.lock         project + the single dep (:bandit)
test/                      Elixir suite + test/browser/ (Playwright, dev/CI only)
README.md                  project readme / quickstart
SECURITY.md, CONTRIBUTING.md, DCO, LICENSE   governance (AGPL; DCO sign-off, no CLA)
.github/workflows/         tests/DCO, GHCR release, audits, public canary, quarterly recovery drill
```

---

## 5. The crypto library (vendored submodule)

The browser crypto is **`@burnerpad/crypto`** — a separate, Apache-2.0 repo
(`github.com/burnerpad/crypto-js`) vendored here as a **git submodule** at
**`priv/static/vendor/crypto-js`**, released as package **1.4.2** and pinned by the parent repository's
gitlink. The bytes are **never copied** into this repo. The package includes the same zero-dependency
library plus a cross-platform Node CLI; v1.4.2 does not change either frozen wire suite.

- **Serving:** `router.ex` has two `Plug.Static` mounts at `/crypto`: app assets (`crypto-app.js`,
  `crypto.css`) from `priv/static/crypto`, and the library (`burnerpad-crypto.js`) from the submodule. Both
  served at stable paths with `cache_control_for_etags: "no-cache"`.
- **Integrity:** `crypto_assets.ex` holds reviewed, committed **sha384 SRI** values and recomputes every
  served asset at boot. A mismatch refuses to start; the browser independently enforces those committed
  hashes. Run `mix bp.sri` only after an intentional asset change and review the resulting hash diff.
- **After cloning:** run **`mix setup`** (= `git submodule update --init --recursive` + `mix deps.get`), or
  clone with `--recurse-submodules`. If the submodule is missing, the app fails fast (and the Dockerfile
  guards the build).
- **Updating the crypto:** land the change upstream as a signed commit and signed immutable release tag,
  then run `git -C priv/static/vendor/crypto-js fetch --tags` and
  `git -C priv/static/vendor/crypto-js checkout <reviewed-signed-release-tag>` before committing the gitlink.
  Regenerate committed SRI only with `mix bp.sri`; `mix test.crypto` runs the vendored repository's entire
  vector, adversarial, packaging, and CLI suite so a bad pin fails CI.

---

## 6. HTTP surface (`router.ex`)

| Route | Purpose |
|---|---|
| `GET /` | the create page |
| `GET /s/:id` | non-burning reveal interstitial (browser flow); link-preview safe |
| `POST /api/secrets` | create — accepts a base64url ciphertext blob, returns `{id, mgmt_token, ttl}` |
| `POST /api/secrets/:id/reveal` | atomically claims/burns the row for at most one request handler (then indistinguishable 404) |
| `POST /api/secrets/:id/burn` | revoke early with the management token |
| `POST /api/edge/source-check` | match-only public probe for the deployed trusted-proxy source path; never returns an address |
| `GET /stats` + `GET /api/stats` | public transparency page — aggregate lifetime and daily activity numbers plus the non-user application version |
| `GET`/`HEAD` `/healthz` | cheap liveness check above the limiter |
| `GET`/`HEAD` `/readyz` | Store/Abuse process and ETS readiness |
| `GET /terms` | Terms / Acceptable-Use, rendered from env vars (see `TERMS.template.md`) |
| `GET /.well-known/security.txt` | RFC 9116 contact |
| static `/crypto/*` | the SRI-pinned scripts (crypto bundle, `crypto-app.js`, `theme.js`) + CSS (see §5) |
| static `/fonts/*` | self-hosted WOFF2 faces, same-origin (so CSP stays `font-src 'self'`); OFL 1.1 |
| `match _` | 404 |

A request body is capped before buffering (the only body accepted is a ~64 KB ciphertext blob).

---

## 7. Run & test

Pinned toolchain: **Elixir 1.20.3 / Erlang 29.0.5 / Node 24.19.0**.

```sh
# clone with the crypto submodule, or fetch it after:
mix setup                 # git submodule update --init  +  mix deps.get
iex -S mix                # dev; serves http://localhost:4000   (or: mix run --no-halt)

# production: follow DEPLOYMENT.md (signed public GHCR artifacts, exact-digest Ansible deploy)
```

Tests:
```sh
mix test          # the Elixir suite (store, abuse, HTTP/router + SRI, client-IP keying)
mix test.crypto   # runs the VENDORED bundle's own conformance suite under Node (needs Node ≥ 20)
mix test.core     # Node unit tests for crypto-app.js's DOM-free Core (display/canon/paste-cap/strength)
mix test.edge     # deterministic canary readiness/reporting and public Cloudflare contract tests
mix format --check-formatted
mix compile --warnings-as-errors
# optional real-browser click-through (dev/CI only):
cd test/browser && npm ci && npx playwright install chromium firefox webkit && npm test
```

The app serves plain HTTP. The supported production path in root [`DEPLOYMENT.md`](DEPLOYMENT.md) publishes
no host port: the attested cloudflared sidecar reaches the app directly on an internal Compose network and
Cloudflare terminates public TLS. Run with **swap disabled** so in-memory ciphertext is never paged to disk.

---

## 8. Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4000` | HTTP listen port |
| `REAL_IP_HEADER` | `cf-connecting-ip` | header to read the client IP from, behind a trusted proxy |
| `TRUSTED_PROXIES` | empty | CIDRs whose peers may set `REAL_IP_HEADER`; empty ⇒ use the socket peer |
| `MAX_SECRETS` | `10000` | hard cap on resident rows (range `1..100000`; size to available memory) |
| `TTL_SECONDS` | `86400` | default lifetime and per-request ceiling; boot-validated to `60..86400` |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `GLOBAL_CREATE_CEILING` | `1000` | server-wide valid create admissions per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `PER_IP_BUDGET` | 2% of worst-case store bytes | maximum unexpired ciphertext bytes admitted per source |
| `PER_IP_ROW_BUDGET` | 2% of `MAX_SECRETS` | maximum unexpired rows admitted per source |
| `STATE_CALL_TIMEOUT_MS` | `1000` | bounded Store/Abuse call timeout |
| `BURNERPAD_REVISION` / `BURNERPAD_IMAGE_DIGEST` | required exact identities in prod | reported release provenance |
| `OPERATOR_NAME` / `ABUSE_EMAIL` / `JURISDICTION` | required in prod | fill `/terms` |
| `SECURITY_EMAIL` / `SECURITY_POLICY_URL` | required in prod | render RFC 9116 contact; policy URL rejects literal whitespace/controls |

---

## 9. Load-bearing invariants — DO NOT BREAK

1. **The server is crypto-agnostic** — it stores/relays one opaque `blob` and never parses it. Plaintext is
   never written to disk; secrets live in ETS only.
2. **At-most-once claim / atomic burn** — reveal is `:ets.take/2` (atomic). **Never** read-then-delete. `GET /s/:id` must
   **never** burn (link-preview guard); burn only on JSON `POST /api/secrets/:id/reveal`.
3. **The `#fragment` never reaches the server** — it's the link-mode key. `Referrer-Policy: no-referrer`,
   no logging; the reveal POST carries only the id.
4. **All app scripts are SRI-pinned** (the crypto bundle, `crypto-app.js`, and the `<head>` `theme.js`) and
   there are **no inline scripts** on any page, so a strict `script-src 'self'` holds. Web fonts are
   self-hosted (`font-src 'self'`) — no external CDN, so `default-src 'none'` stays otherwise closed.
5. **Strict canonical base64url in the crypto contract** (enforced by the crypto lib) so a mangled key
   fails closed identically across clients. Elixir transport credentials use the same canonical
   decode/re-encode rule and exact decoded lengths.
6. **Trusted-proxy client IP** — `REAL_IP_HEADER` is honored only when the peer is a configured trusted
   proxy; otherwise rate limiting is spoofable. Firewall the origin to the proxy and use authenticated
   origin pulls.
7. **No secret capability is logged** — operational request events retain only allowlisted route class,
   method, status, duration, and release; never paths, sources, IDs, tokens, ciphertext, phrases, or bodies.
   Abuse notices arrive through `/terms`, and takedown is an operator `Store.purge/1` action.
8. **The web client is passphrase-only and generate-by-default** — every secret is suite `0x02` (key-less
   link + phrase); there is **no free-text passphrase field**. The phrase is generated; **removing** random
   words (dropping the generated core below 7) is the **warned** step toward a weaker phrase, which still
   requires **7+ distinct** words to submit — so a weak/empty passphrase can't be produced here. The success
   screen offers a **"Copy passphrase"** button (the phrase goes out on a *separate* channel from the link —
   a different app, a text, or a call; keeping the two channels apart is the user's responsibility). The
   reveal page is list-locked and **refuses** a `#fragment` (link-mode) URL.

---

## 10. Security & governance

- **Threat model** (passphrase mode's adversary is a fully-breached server brute-forcing the stored blob
  offline; PBKDF2 + a unique generated ~72-bit phrase make that infeasible). Active delivery-path compromise
  is outside the browser guarantee; suite `0x02` does not bind a reused phrase to an external record. Disclosure policy and safe harbor
  are in [`SECURITY.md`](SECURITY.md); a machine-readable contact is served at `/.well-known/security.txt`.
- **Licensing:** this repo is **AGPL-3.0-or-later** (the Elixir server *and* the app's page assets
  `crypto-app.js`, `theme.js`, `crypto.css`). The vendored crypto **library** submodule is **Apache-2.0**,
  and the self-hosted web fonts under `priv/static/fonts/` are third-party **SIL OFL-1.1** (see
  `fonts/NOTICE.md` + `fonts/OFL.txt`). Every source file (`.ex` / `.js` / `.css`) carries an
  `SPDX-License-Identifier` header; the WOFF2 fonts are covered by `fonts/NOTICE.md`.
- **Contributions:** DCO sign-off (`git commit -s`), **no CLA**. CI (`.github/workflows/`): `dco` and
  `test` (submodule checkout → compile-warnings-as-errors → `mix test` → `mix test.crypto`).

---

## 11. Gotchas

- **Forgetting the submodule** is the #1 trap: a fresh clone without it has no crypto bundle and the app
  fails to compute SRI. Run `mix setup` (or clone `--recurse-submodules`). The Dockerfile fails the build
  loudly if the submodule isn't checked out.
- **Don't edit files under `priv/static/vendor/crypto-js`** here — that's the pinned library. Crypto changes
  happen in the `@burnerpad/crypto` repo, then you bump the pin (§5).
- **`crypto-app.js` and `crypto.css` are this repo's AGPL code** (the page driver + styles), *not* part of
  the Apache library — the passphrase generator + wordlist live in `crypto-app.js`.
- Run with **swap off**; terminate **TLS at a proxy**; the app emits plain HTTP by design.
- `TERMS.template.md` is a template, **not legal advice** — have a lawyer review before running a public
  instance. The live `/terms` page shows the operator's *filled-in* terms (no template banner), rendered
  from explicit operator configuration. A production build also requires the security contact/policy,
  full Git revision, and OCI digest. Reusable inventories contain unmistakable invalid placeholders.
