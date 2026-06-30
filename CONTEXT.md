# burnerpad-lite — Repository Context

> **Read this first.** A self-contained map of this repository: what it is, how it works end-to-end, how
> to run/test it, and the invariants that must not break. The deep design rationale (crypto, storage,
> security model) lives in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); this file is the orientation.

---

## 1. What this is

A minimal, no-accounts, **end-to-end-encrypted one-time-secret sharing** service (**AGPL-3.0-or-later**).
You paste a secret (a password, an API key, a `.env` block); the **browser encrypts it**; the server
stores only **opaque ciphertext it cannot read**; the recipient opens it **once** and it is destroyed
(burn-on-read), or it expires on a TTL.

It is deliberately **tiny and operationally simple**: **Elixir + [Bandit](https://hex.pm/packages/bandit)**
(one Hex dependency), **no database**, **no Node at runtime**, **no JS framework**. Secrets live in
**RAM only** — nothing is written to disk, and everything is gone on restart. The server is
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
the link is safe to post in a ticket/chat, and the passphrase is shared **out of band** (said out loud).
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
**light/dark theme toggle** — a value-prop headline (*"Securely share one-read secrets"*), and a 3-card
**trust strip** (end-to-end encrypted · two separate channels · one read, then gone) before the form. The
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
screen carries two more controls: a **"Burn it now"** early-revoke that `POST`s `/s/:id/burn` with the
one-time management token (swapping the panel for a "Burned" confirmation, before anyone opens it — only a
5xx is treated as failure), and a **"← Create another secret"** button that soft-resets the form in place
(no reload, no network) with a fresh generated phrase.

The web client **never mints link-mode (suite `0x01`) secrets**, and the reveal page is a **list-locked
autocomplete** that **refuses** a URL carrying a `#fragment` (a link-mode link) rather than guessing — so
the web app is a strict *subset* of what the cross-client crypto lib (§5) supports. The lib still
implements both suites; only this UI is narrowed. Reveal needs no transcription tolerance: chips are
already canonical (lowercase words, single spaces), and a wrong phrase/order is fixed and retried locally
(the held blob is reused — no second burn).

**Reveal:** the browser flow uses a **non-burning** `GET /s/:id` interstitial — which warns up front that
the secret opens **once** and *must not be reloaded after revealing* (the page then holds the only copy of
the plaintext) — then `POST /s/:id/reveal` which **burns** and returns the blob exactly once. (Link-preview
bots fetching `GET /s/:id` therefore can't destroy a secret; a gone/expired/unknown id renders a `404` "Not
found" page — no existence oracle.) The recipient builds the phrase in the same tag field (Enter/Space/Tab
commits a word); on success the plaintext appears with a **Copy secret** button under a "won't be shown
again" note. Programmatic clients can use `GET /api/secrets/:id`, which burns on read (`410` after).

---

## 3. Architecture & processes

`Burnerpad.Application` starts a supervision tree of three children:

- **`Burnerpad.Store`** — a `GenServer` that owns the secrets **ETS** table and the TTL sweep. It is the
  **only** module that touches that table. **Burn-on-read is `:ets.take/2`** (atomic remove-and-return) →
  exactly-once under concurrency. A non-burning `peek` backs the interstitial.
- **`Burnerpad.Abuse`** — owns five ETS tables for proactive, in-memory abuse control (per-IP rate-limit
  windows, the global ceiling, escalating bans, aggregate stats, and abuse metrics) plus their sweep.
- **`Bandit`** serving `BurnerpadWeb.Router` over **plain HTTP** (terminate TLS at a reverse proxy).

### Modules (`lib/`)
| Module | Role |
|---|---|
| `burnerpad/application.ex` | OTP application + supervision tree |
| `burnerpad/config.ex` | runtime config, entirely from environment variables |
| `burnerpad/store.ex` | in-memory burn-on-read secret store (ETS; `:ets.take` = exactly-once) |
| `burnerpad/abuse.ex` | in-memory rate limiting, global ceiling, bans, stats, metrics (5 ETS tables) |
| `burnerpad_web/router.ex` | the entire HTTP surface (`Plug.Router`); see §6 |
| `burnerpad_web/abuse_plug.ex` | runs early (before static) so every request counts toward limits |
| `burnerpad_web/client_ip.ex` | resolves the abuse key (IPv4 `/32` or IPv6 `/64`), honoring trusted proxies |
| `burnerpad_web/crypto_assets.ex` | computes the SRI hashes for the crypto scripts from the bytes on disk |
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
priv/static/.well-known/security.txt   RFC 9116 security contact (served)
docs/ARCHITECTURE.md       the deep design doc (crypto, storage, security model)
TERMS.template.md          operator Terms / Acceptable-Use template (rendered at /terms from env vars)
Dockerfile                 multi-stage prod build (mix release)
mix.exs / mix.lock         project + the single dep (:bandit)
test/                      Elixir suite + test/browser/ (Playwright, dev/CI only)
README.md                  project readme / quickstart
SECURITY.md, CONTRIBUTING.md, DCO, LICENSE   governance (AGPL; DCO sign-off, no CLA)
.github/workflows/         dco.yml, test.yml
```

---

## 5. The crypto library (vendored submodule)

The browser crypto is **`@burnerpad/crypto`** — a separate, Apache-2.0 repo
(`github.com/burnerpad/crypto-js`) vendored here as a **git submodule** at
**`priv/static/vendor/crypto-js`**, pinned to a tag (currently **v1.3.0**). The bytes are **never copied**
into this repo — the submodule is a pinned pointer.

- **Serving:** `router.ex` has two `Plug.Static` mounts at `/crypto`: app assets (`crypto-app.js`,
  `crypto.css`) from `priv/static/crypto`, and the library (`burnerpad-crypto.js`) from the submodule. Both
  served at stable paths with `cache_control_for_etags: "no-cache"`.
- **Integrity:** `crypto_assets.ex` computes a **sha384 SRI** for each crypto script from the exact bytes
  on disk (memoized) and `pages.ex` pins it on the `<script integrity>` tags. A host serving a tampered
  script is refused by the browser. Both crypto-page scripts are SRI-pinned.
- **After cloning:** run **`mix setup`** (= `git submodule update --init --recursive` + `mix deps.get`), or
  clone with `--recurse-submodules`. If the submodule is missing, the app fails fast (and the Dockerfile
  guards the build).
- **Updating the crypto:** bump the submodule pin —
  `cd priv/static/vendor/crypto-js && git fetch && git checkout <new-tag>`, then commit the moved gitlink.
  The SRI recomputes automatically at runtime; `mix test.crypto` re-runs the vendored bundle's conformance
  suite so a bad pin fails CI.

---

## 6. HTTP surface (`router.ex`)

| Route | Purpose |
|---|---|
| `GET /` | the create page |
| `GET /s/:id` | non-burning reveal interstitial (browser flow); link-preview safe |
| `POST /s/:id/reveal` | burns and returns the blob exactly once (browser flow) |
| `POST /s/:id/burn` | revoke early with the management token |
| `POST /s/:id/report` | **non-destructive** abuse report (logs/flags; does NOT delete) |
| `POST /api/secrets` | create — accepts a base64url ciphertext blob, returns `{id, mgmt_token}` |
| `GET /api/secrets/:id` | programmatic take — burns and returns the blob once (then 410) |
| `GET /stats` + `GET /stats.json` | public transparency page — aggregate numbers only |
| `GET /terms` | Terms / Acceptable-Use, rendered from env vars (see `TERMS.template.md`) |
| `GET /.well-known/security.txt` | RFC 9116 contact |
| static `/crypto/*` | the SRI-pinned scripts (crypto bundle, `crypto-app.js`, `theme.js`) + CSS (see §5) |
| static `/fonts/*` | self-hosted WOFF2 faces, same-origin (so CSP stays `font-src 'self'`); OFL 1.1 |
| `match _` | 404 |

A request body is capped before buffering (the only body accepted is a ~64 KB ciphertext blob).

---

## 7. Run & test

Requires **Elixir ≥ 1.18** (Erlang/OTP ≥ 27).

```sh
# clone with the crypto submodule, or fetch it after:
mix setup                 # git submodule update --init  +  mix deps.get
iex -S mix                # dev; serves http://localhost:4000   (or: mix run --no-halt)

# production (bare metal):
MIX_ENV=prod mix release
PORT=4000 _build/prod/rel/burnerpad/bin/burnerpad start

# Docker (initialize the submodule first):
docker build -t burnerpad .
docker run -p 4000:4000 burnerpad
```

Tests:
```sh
mix test          # the Elixir suite (store, abuse, HTTP/router + SRI, client-IP keying) — 48 tests
mix test.crypto   # runs the VENDORED bundle's own conformance suite under Node (needs Node ≥ 20)
mix test.core     # Node unit tests for crypto-app.js's DOM-free Core (display/canon/paste-cap/strength)
mix format --check-formatted
mix compile --warnings-as-errors
# optional real-browser click-through (dev/CI only; needs Chromium):
cd test/browser && npm install && npx playwright install chromium && npx playwright test
```

The app serves plain HTTP — **terminate TLS at a reverse proxy** (e.g. Caddy). Run with **swap disabled**
so in-memory ciphertext is never paged to disk.

---

## 8. Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4000` | HTTP listen port |
| `REAL_IP_HEADER` | `cf-connecting-ip` | header to read the client IP from, behind a trusted proxy |
| `TRUSTED_PROXIES` | empty | CIDRs whose peers may set `REAL_IP_HEADER`; empty ⇒ use the socket peer |
| `MAX_SECRETS` | `100000` | hard cap on live secrets (memory bound) |
| `TTL_SECONDS` | `86400` | default secret lifetime **and** per-request ceiling: a client `ttl` is clamped to `[60, TTL_SECONDS]` |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `OPERATOR_NAME` / `ABUSE_EMAIL` / `JURISDICTION` | `Impulsa SLU` / `abuse@burnerpad.io` / `Andorra` | fill the `/terms` page (defaults to this instance's operator; a **fork must override**) |

---

## 9. Load-bearing invariants — DO NOT BREAK

1. **The server is crypto-agnostic** — it stores/relays one opaque `blob` and never parses it. Plaintext is
   never written to disk; secrets live in ETS only.
2. **Exactly-once burn** — reveal is `:ets.take/2` (atomic). **Never** read-then-delete. `GET /s/:id` must
   **never** burn (link-preview guard); burn only on `POST /reveal` (and the programmatic `GET /api/secrets/:id`).
3. **The `#fragment` never reaches the server** — it's the link-mode key. `Referrer-Policy: no-referrer`,
   no logging; the reveal POST carries only the id.
4. **All app scripts are SRI-pinned** (the crypto bundle, `crypto-app.js`, and the `<head>` `theme.js`) and
   there are **no inline scripts** on any page, so a strict `script-src 'self'` holds. Web fonts are
   self-hosted (`font-src 'self'`) — no external CDN, so `default-src 'none'` stays otherwise closed.
5. **Strict canonical base64url everywhere** (enforced by the crypto lib) so a mangled link fails closed
   identically across clients.
6. **Trusted-proxy client IP** — `REAL_IP_HEADER` is honored only when the peer is a configured trusted
   proxy; otherwise rate limiting is spoofable. Firewall the origin to the proxy and use authenticated
   origin pulls.
7. **Report is non-destructive** — `POST /s/:id/report` only logs/flags (anyone can learn the id from the
   URL); takedown is an operator action that purges by id.
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
  offline; PBKDF2 + the generated ~72-bit phrase make that infeasible). Disclosure policy and safe harbor
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
  from `OPERATOR_NAME` / `ABUSE_EMAIL` / `JURISDICTION`, which default to this instance's operator
  (Impulsa SLU / Andorra). **A fork must override these env vars** so it doesn't publish Impulsa SLU's terms.
