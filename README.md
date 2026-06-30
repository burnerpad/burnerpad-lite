# Burnerpad

A minimal, anonymous, **end-to-end-encrypted one-time-secret sharing** service. Paste a secret, get a
link, the recipient opens it **once**, and it's destroyed. The server never sees your plaintext, stores
nothing on disk, and keeps every secret in memory only.

- **End-to-end encrypted** — the browser encrypts; the key never reaches the server.
- **One-time** — burn-on-read, exactly once.
- **Ephemeral** — secrets live in RAM with a TTL; nothing is persisted, everything is gone on restart.
- **Tiny** — Elixir + [Bandit](https://hex.pm/packages/bandit), one dependency, no database, no Node, no
  JS framework. The browser JavaScript is three small vanilla scripts — this repo's page driver
  (`priv/static/crypto/crypto-app.js`), a tiny `<head>` theme bootstrap (`theme.js`, light/dark via
  `localStorage`, no cookies), and the audited
  [`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js) library — all served `self`-only and
  SRI-pinned; the library is vendored as a pinned git submodule.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design (crypto, storage, security model).

## Run it

Requires **Elixir ≥ 1.18** (Erlang/OTP ≥ 27). The browser crypto is a git submodule, so pull it too:

```bash
git clone --recurse-submodules https://github.com/burnerpad/burnerpad-lite
# already cloned without it? run:  mix setup   (git submodule update --init + mix deps.get)

mix setup               # fetch the crypto submodule + deps
iex -S mix              # dev; serves http://localhost:4000
# or
mix run --no-halt
```

**Production (bare metal):**

```bash
MIX_ENV=prod mix release
PORT=4000 _build/prod/rel/burnerpad/bin/burnerpad start
```

**Docker:**

```bash
docker build -t burnerpad .
docker run -p 4000:4000 burnerpad
```

The app serves plain HTTP — **terminate TLS at a reverse proxy** (e.g. Caddy for automatic HTTPS, or a
CDN). Run with swap disabled on the host so in-memory ciphertext is never paged to disk.

## API

```bash
# create — POST a base64url ciphertext blob; returns the id + a one-time management token
curl -s localhost:4000/api/secrets -H 'content-type: application/json' \
  -d '{"blob":"<base64url>","ttl":3600}'
# => {"id":"K7P2Q9RX","mgmt_token":"<base64url>"}

# take — GET burns and returns the blob exactly once (programmatic; for CLI/scripts)
curl -s localhost:4000/api/secrets/K7P2Q9RX        # => {"blob":"<base64url>"}  (then 410)

# revoke early with the management token
curl -s localhost:4000/s/K7P2Q9RX/burn -H 'content-type: application/json' -d '{"mgmt_token":"..."}'
```

The browser flow instead uses the non-burning `GET /s/:id` interstitial + `POST /s/:id/reveal`, so
link-preview bots can't destroy a shared secret. Encryption/decryption is client-side — the API only ever
sees the opaque ciphertext `blob`.

A **public** transparency page lives at **`/stats`** (and `/stats.json`): live secrets stored, lifetime
counts, capacity, uptime, and abuse totals — aggregate numbers only, nothing about any secret or user.

A **Terms / Acceptable-Use** page lives at **`/terms`**, rendered from `OPERATOR_NAME` / `ABUSE_EMAIL` /
`JURISDICTION` — which **default to this instance's operator** (Impulsa SLU / Andorra), so the live page is
filled in. **A fork must override those env vars** or it will publish Impulsa SLU's terms as its own. The
wording lives in [`TERMS.template.md`](TERMS.template.md); it's a template, **not legal advice** — have a
lawyer review it before running a public instance.

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4000` | HTTP listen port |
| `REAL_IP_HEADER` | `cf-connecting-ip` | header to read the client IP from, when behind a trusted proxy |
| `TRUSTED_PROXIES` | empty | CIDRs whose peers may set `REAL_IP_HEADER`; empty ⇒ use the socket peer |
| `MAX_SECRETS` | `100000` | hard cap on live secrets (memory bound) |
| `TTL_SECONDS` | `86400` | default secret lifetime, clamped to `[60, 86400]` |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `OPERATOR_NAME` | `Impulsa SLU` | shown on `/terms` (default is this instance's operator; **a fork must override**) |
| `ABUSE_EMAIL` | `abuse@burnerpad.com` | abuse/removal contact on `/terms` |
| `JURISDICTION` | `Andorra` | governing law on `/terms` |

There is **no `SECRET_KEY_BASE`** (no sessions/cookies) and **no database**.

## Test

```bash
mix test          # the Elixir suite (store, abuse, HTTP, client-IP keying)
mix test.crypto   # the browser crypto bundle, cross-checked against node:crypto (needs Node ≥ 20)
mix test.core     # unit tests for crypto-app.js's DOM-free Core (display/canon/paste-cap/strength)
```

Optional headless-browser click-through (real Chromium via Playwright — dev/CI only, isolated in
`test/browser/`, never a runtime dependency):

```bash
cd test/browser && npm install && npx playwright install chromium && npx playwright test
```

It boots the server, then drives the passphrase-only flow (suite `0x02`) in a real browser: create → a
key-less link → a chip/autocomplete reveal with a wrong-order-then-correct retry (a single network
reveal/burn, the wrong order retried **locally** with no second burn); **pasting the whole phrase at once**
(every word chipped, including the last); the tag field (Regenerate, the remove-a-word warning, writing a
custom 7+ word phrase, Space/Tab to commit); the always-active create button + create/burn/reset UX; a
`#fragment` (link-mode) reveal URL refused as unsupported; and the strict CSP (`script-src 'self'`) +
SRI-pinned scripts holding with no console errors.

## License

Copyright (C) 2026 Impulsa SLU.

**This repository is licensed [AGPL-3.0-or-later](LICENSE)** — the Elixir server, the page driver
(`priv/static/crypto/crypto-app.js`), the theme bootstrap (`theme.js`), and the styles (`crypto.css`).
Every source file carries an `SPDX-License-Identifier` header. The self-hosted web fonts under
`priv/static/fonts/` are third-party **SIL OFL-1.1** (see `priv/static/fonts/NOTICE.md`). Contributions are
under the [DCO](DCO) (`git commit -s`); no CLA.

The browser **crypto library** is a separate project — **[`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js)**,
licensed **Apache-2.0** — vendored here as a pinned git submodule under `priv/static/vendor/crypto-js`
(never copied into this repo). Keeping the trust-critical crypto permissive and standalone makes it
independently auditable and reusable.
