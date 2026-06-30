# Burnerpad — Architecture & How It Works

A minimal, anonymous, **end-to-end-encrypted one-time-secret sharing** service. You paste a secret, get a
link, the recipient opens it **once**, and it is destroyed. The server never sees your plaintext, stores
nothing on disk, and keeps every secret in memory only.

This document is the complete, self-contained description of the system: the architecture, the
client-side cryptography, how the small amount of JavaScript works, how secrets are stored and destroyed,
the HTTP API, the abuse controls, the security model, configuration, and how to run it.

---

## 1. What it is (and what it promises)

- **One-time secrets.** A secret is revealed exactly once. The first successful read destroys it; a second
  read finds nothing.
- **Anonymous.** No accounts, no sessions, no cookies, no sign-up. Authorization is *possession* of an
  unguessable link (and, optionally, a passphrase).
- **End-to-end encrypted (zero-knowledge).** Encryption and decryption happen **in the browser**. The
  server only ever holds opaque ciphertext and can never read a secret — even while it is alive.
- **Ephemeral.** Secrets live in RAM with a time-to-live (default 24 h). Nothing is written to disk;
  everything is gone on restart.
- **Tiny and self-hostable.** A single Elixir process, one dependency, no database, no Node/JS build
  toolchain. Clone and run.

---

## 2. Design invariants

These five rules explain every decision below:

1. **The server is crypto-agnostic.** It stores and relays one **opaque blob** of bytes and never parses
   it — not the cipher, not the IV, nothing. All format knowledge lives in the browser.
2. **The key never reaches the server.** The decryption key (or the passphrase it is derived from) lives
   only in the browser / the URL fragment, which browsers never transmit.
3. **Single-use keys.** Every secret is encrypted with a fresh key, used for exactly one message. This is
   what makes a random nonce safe.
4. **Fail closed.** Any authentication failure, unknown format, or malformed input is a hard reject — the
   client never shows partial or unauthenticated plaintext.
5. **Store as little as possible, in RAM only.** No plaintext, no keys, no passphrases, nothing on disk.
   The only browser JavaScript is small, same-origin, SRI-pinned code — the audited crypto library, this
   app's page driver, and a tiny theme bootstrap — with no inline scripts.

---

## 3. High-level architecture

```
            browser (the only place plaintext & keys exist)
        ┌───────────────────────────────────────────────┐
        │  static page  +  audited crypto bundle (WebCrypto)│
        │  encrypt / decrypt;  key lives in URL #fragment  │
        └───────────────▲───────────────────┬─────────────┘
                        │ ciphertext only    │ ciphertext only
                        │ (GET pages)        │ (POST /api/secrets, POST /s/:id/reveal)
        ┌───────────────┴────────────────────▼─────────────┐
        │  Elixir app  (Plug + Bandit, no framework)        │
        │  ┌─────────────┐  ┌──────────┐  ┌──────────────┐  │
        │  │  Router      │  │  Store    │  │  Abuse        │  │
        │  │ (HTTP + SRI  │  │ (ETS, in- │  │ (rate limit + │  │
        │  │  pages + API)│  │  memory)  │  │  bans, ETS)   │  │
        │  └─────────────┘  └──────────┘  └──────────────┘  │
        └───────────────────────────────────────────────────┘
                  RAM only — nothing touches disk
```

- **Language/runtime:** Elixir on the BEAM (OTP).
- **HTTP server:** [Bandit](https://hex.pm/packages/bandit) driven by a single `Plug.Router`. **No web
  framework** (no Phoenix/LiveView), so the only browser JavaScript is the small, SRI-pinned crypto
  library, the page driver, and a tiny theme bootstrap (§5).
- **Storage:** an in-memory [ETS](https://www.erlang.org/doc/man/ets) table. **No database.**
- **Dependencies:** essentially just `bandit`. JSON uses the Elixir standard-library `JSON` module
  (Elixir ≥ 1.18); cryptography on the server is limited to hashing/random via the Erlang `:crypto`
  standard library.

**Supervision tree** (`Burnerpad.Application`):

```elixir
children = [
  Burnerpad.Store,   # owns the secrets ETS table + runs the TTL sweep
  Burnerpad.Abuse,   # owns the rate-limit / ban / stats ETS tables + sweeps them
  {Bandit, plug: Burnerpad.Router, scheme: :http, port: port()}
]
```

---

## 4. Cryptography (client-side, end-to-end)

All cryptography happens in the browser using the native **WebCrypto** API (`crypto.subtle`). The cipher
is **AES-256-GCM** (a 256-bit key, a 96-bit nonce/IV, and a 128-bit authentication tag). The server only
ever receives and stores the resulting ciphertext blob.

The crypto library defines two **modes**, distinguished by a one-byte `suite` discriminator at the front
of the blob. **The web app uses only suite `0x02` (passphrase);** suite `0x01` (link mode) remains in the
library for cross-client interoperability but is **never minted by this web client, and the reveal page
refuses a `#fragment` link** (see §5). The library is the superset; the web UI is a deliberate subset.

### 4.1 Suite `0x01` — random key in the link (library-only; not minted by the web app)

A client generates a fresh random 256-bit key, encrypts, and puts the **key in the URL fragment**
(everything after `#`). The fragment is never sent to the server, so the link itself *is* the credential.
This is the strongest mode (a 256-bit key the server can never brute-force), but it puts the key *in the
URL*; this web app instead standardizes on the two-channel passphrase mode below. The CLI/library keep it.

**Blob layout (what the server stores):**
```
+--------+------------------+-----------------------------+
| suite  |       iv         |   ciphertext ‖ GCM tag      |
| 1 byte |     12 bytes     |   (plaintext length + 16)   |
+--------+------------------+-----------------------------+
  0x01      random nonce       AES-256-GCM output
```

**URL:**
```
https://<host>/s/<id>#<fragment>
fragment = base64url_unpadded( key[32] )       # the 32-byte key, URL-safe, no padding
```

**Additional Authenticated Data (AAD):** `suite ‖ spec_version` = `0x01 0x01`. Binding these bytes into
the GCM tag prevents a blob from being reinterpreted under a different format without the authentication
failing.

**Encrypt:**
```
key = CSPRNG(32); iv = CSPRNG(12)
ct_tag = AES-256-GCM-Encrypt(key, iv, plaintext, aad = 0x01 0x01)
blob = 0x01 ‖ iv ‖ ct_tag
fragment = base64url(key)
```

**Decrypt:**
```
suite = blob[0]                       # must be 0x01
iv = blob[1..13]; ct_tag = blob[13..]
key = base64url_decode(fragment)      # must be exactly 32 bytes, strict base64url
plaintext = AES-256-GCM-Decrypt(key, iv, ct_tag, aad = 0x01 0x01)   # auth failure -> reject
```

### 4.2 Suite `0x02` — passphrase (PSK) mode (the web app's only mode)

The key is derived from a **passphrase** that the two parties agree on **out of band** (spoken, or sent
over a separate channel). The link carries **only the id** — no key in the fragment — so an intercepted
link is useless without the passphrase. This is the **only** mode the web client mints: the passphrase is
**generated** (7 distinct words from an embedded EFF wordlist, ~72 bits) and shown as chips in a tag field;
editing toward your own words (7+ distinct) is a warned, deliberate step. See §5 for the UI.

The key is derived with **PBKDF2-HMAC-SHA-256** (600,000 iterations, 32-byte output) over the passphrase
and a per-secret random 16-byte salt. PBKDF2 is used because it is available natively in WebCrypto (no
extra shipped code, no relaxation of the strict script policy). A **fresh random salt per secret** means
the derived key is unique even for an identical passphrase, preserving the single-use-key invariant.

**Blob layout:**
```
+--------+-----------+-----------+-----------------------------+
| suite  |   salt    |    iv     |   ciphertext ‖ GCM tag      |
| 1 byte |  16 bytes |  12 bytes |   (plaintext length + 16)   |
+--------+-----------+-----------+-----------------------------+
  0x02      random      random        AES-256-GCM output
```

- `key = PBKDF2-HMAC-SHA256(passphrase, salt, iterations = 600000, length = 32)`
- **AAD:** `suite ‖ spec_version ‖ salt ‖ iv` (the whole header is authenticated; tampering with the salt
  is a hard auth-failure, not a silent wrong key).
- **Fragment:** empty. The recipient supplies the passphrase.

### 4.3 Encoding & strictness rules (so independent clients agree)

- The blob is transported as **base64url, unpadded** when carried in JSON (the API); the canonical form
  is the raw byte layout.
- A decoder **must** validate the key length (exactly 32 bytes) and reject any fragment that is not strict
  base64url (no `=` padding, no `+`/`/`, no whitespace, nothing outside `[A-Za-z0-9_-]`).
- Decrypt reject precedence: **truncated → unknown suite → bad key length → authentication failure.**

### 4.4 Why this is safe

- The server, the network, and any proxy in between only ever see ciphertext; the key/passphrase never
  leaves the browser. A full compromise of the server yields nothing but opaque blobs.
- Single-use keys + a random nonce make the catastrophic GCM (key, nonce)-reuse failure structurally
  impossible.
- GCM authentication + AAD binding means tampering or a wrong key yields a hard reject, never
  wrong-but-accepted plaintext.
- **Ceiling for passphrase mode:** security equals passphrase entropy. If a link leaks *and* someone
  reveals (burns) the secret, they can attempt the passphrase offline; PBKDF2 raises the per-guess cost,
  but a weak passphrase is still weak. The web UI never lets a weak phrase be minted: the default is a
  **generated** 7-word phrase (~72 bits, uniformly random; Regenerate redraws a fresh random set), and
  editing toward your own words requires **7+ distinct** words and warns that generated is stronger.

---

## 5. The browser side (how the JavaScript works)

There is **no JavaScript framework** and **no build/bundler toolchain**. The pages are plain static HTML
with **no inline scripts**. Every page loads **three** small scripts, all pinned with **Subresource
Integrity (SRI)** and served same-origin:

1. **`theme.js`** — a tiny theme bootstrap, loaded **render-blocking in `<head>`** (no `defer`) so it
   stamps the saved light/dark choice onto `<html data-theme>` **before first paint** (no flash). It reads
   `localStorage["bp_theme"]` — only the literals `"light"`/`"dark"` are ever written, so there is **no
   cookie and nothing is sent to the server** — and wires the theme toggle. It is the only theme logic
   (colors are CSS custom properties), and it loads on **every** page, including the script-light
   status/stats/terms/404 pages.
2. **`burnerpad-crypto.js`** — the audited crypto library: a thin, dependency-free wrapper over
   WebCrypto implementing §4 (encrypt, decrypt, base64url, build-link, read-fragment). Exposed as a
   global `BurnerpadCrypto`. Loaded at the end of `<body>` on the crypto pages.
3. **`crypto-app.js`** — the page driver: reads inputs, calls the crypto library, talks to the JSON API,
   on the reveal page **refuses** any URL bearing a `#fragment` as an unsupported (link-mode) link, derives
   the key from the recipient's passphrase chips (`decryptPsk`), and writes plaintext to the page. Vanilla
   JS, no dependencies.

The load order is **load-bearing**: `theme.js` (head, before paint) → `burnerpad-crypto.js` → `crypto-app.js`
(which reads `window.BurnerpadCrypto` at init). The structural split (`<head>` vs end-of-`<body>`) enforces it.

**Integrity & isolation:**

- All three scripts carry an `integrity="sha384-…"` attribute computed from the exact bytes on disk at boot
  (memoized in `crypto_assets.ex`), so a tampered file is refused by the browser.
- A **strict Content-Security-Policy** allows scripts only from the same origin and **forbids inline
  scripts** (`script-src 'self'`), so an injected `<script>` cannot run. (Full header list in §10.)
- `Referrer-Policy: no-referrer` keeps the `#fragment` (the key) out of the `Referer` header.

**Create-page flow (passphrase-only, suite 0x02):**
1. A header (logo wordmark + a **light/dark theme toggle**), a value-prop headline, and a 3-card **trust
   strip** (end-to-end encrypted · two separate channels · one read, then gone) set the frame. The driver
   generates a **7-word phrase** (distinct, uniformly random) and shows it as **chips inside one tag field**.
   There is no mode toggle: each chip has a **×**, an autocomplete **`+ add a word`** slot accepts your own
   (list-locked), and **↻ Regenerate** redraws the set. Strength tracks the **random core**: while the 7
   generated words remain, the cue is green — "✓ N words · very strong" (pure) or "✓ N words · mixed" (you
   added your own on top, which only *adds* entropy). **Removing** a random word drops the core below 7 →
   amber "N words · weaker" plus the "generated is stronger" warning; below 7 total → red "add N more".
   A live meter shows the secret's line/byte size against the ~64 KB blob cap.
2. The submit button is **always active**; its label flips on whether a secret is present
   ("Add your secret to continue" → "Encrypt & create link"). Clicking with no secret nudges focus to the
   textarea; submitting with a present secret but **fewer than 7 words** surfaces an inline error — so a
   weak/empty passphrase still cannot be sent. A muted **trust line** with a lock icon sits beneath
   ("Encrypted in your browser — we store ciphertext we can't read."). The driver calls
   `BurnerpadCrypto.encryptPsk(phrase, …)` → `{ blob, fragment: "" }`.
3. `POST /api/secrets { blob }` → `{ id, mgmt_token }`.
4. The driver builds the **key-less** share link `origin + "/s/" + id` and shows the **success screen**
   (the hero + trust strip are hidden): *Send the link* (shown **without its `http(s)://`/`www.` prefix**,
   with a **Copy** button that copies the *full* URL) and *Share the passphrase* (the words as chips,
   framed as a **separate channel** — a different app, a text, or a call — with its **own Copy button**).
   The passphrase Copy button is a **deliberate convenience/​isolation trade-off**: it is on the user to
   keep that channel apart from where the link was sent, and the subtitle reminds that the recipient needs
   **both**, on **separate** channels.
5. The same success screen carries two more controls. **Burn it now** (`#bp-burn`) is an early revoke: it
   `POST`s `/s/:id/burn` with the one-time `mgmt_token` and swaps the share block for a centered **"Burned"**
   confirmation; it treats only a **5xx** as an unknown outcome (never claiming "burned" when the secret may
   still be live), so `200` and a `403` (already revealed/expired) both render as burned. **Create another
   secret** (`#bp-again`) soft-resets the form **in place** — no reload, no network — with a fresh generated
   phrase and the hero/trust strip restored.

**Reveal-page flow (purist):**
1. `GET /s/:id` renders a **non-burning** page (so link-preview bots that prefetch the URL do not destroy
   the secret). It warns up front that the secret opens **once** — "revealing destroys it on the server…
   don't reload afterward: this page then holds the only copy" (the warning that motivates the local retry
   in step 4). If the URL carries a `#fragment` (a link-mode link), the driver shows an **"unsupported
   link"** notice and stops — this client only opens key-less passphrase secrets.
2. Otherwise the recipient rebuilds the phrase in the same tag field. They can **type** each word via
   **list-locked autocomplete** — Enter/Space/Tab commits the highlighted word (Space never types a literal
   space; Backspace on an empty input removes the last chip) — **or paste the whole space-separated phrase
   at once**, which splits on whitespace and turns every token into a chip (including the last, no trailing
   space needed; tokens are lowercased to the canonical form). A live count pill reads "N / 7" (amber)
   until complete, then "✓ N" (green). The **Reveal & decrypt** button is **always active**: with fewer
   than 7 words it nudges focus instead of revealing, and its label/icon flip once 7 words are present.
   *(The paste path is intentionally permissive — it does not list-lock pasted tokens — so a non-list/typo
   word yields the same fail-closed "didn't open it" result as any wrong phrase; no plaintext leaks.)*
3. `POST /s/:id/reveal` performs the single, atomic burn and returns the ciphertext exactly once.
4. The driver derives the key from the phrase (`decryptPsk`), decrypts locally, and shows the plaintext in a
   scrollable **code block** — a line/byte meta header plus a **Copy** button (`#bp-copy-secret`) — under a
   "Decrypted · copy it now, you won't see it again" heading. The plaintext is written with `textContent`
   only (never `innerHTML`). A wrong phrase (or wrong word order) can be fixed and retried **locally**
   against the already-fetched blob — **no second network read or burn** — because the one network reveal
   already happened.

---

## 6. Storage (in-memory; what is kept, and where)

Secrets are held in a single named **ETS table** owned by the `Store` process. **Nothing is persisted to
disk and nothing is written to a database** — the table lives entirely in RAM.

**Each row holds only:**

| Field | What it is |
|---|---|
| `id` | the short public identifier (see §8) |
| `blob` | the **opaque ciphertext** envelope from §4 (never parsed) |
| `mgmt_token_hash` | `SHA-256` of a one-time management token (used to revoke; see §7) |
| `expires_at` | absolute expiry time (unix seconds) |

**What is never stored, anywhere:** plaintext, the encryption key, the passphrase, the raw management
token, IP addresses of senders/recipients tied to a secret, or any access log of who read what. The only
identifiers retained are abuse counters keyed by IP prefix (§9), also in RAM. Aggregate lifetime tallies
(created / read / revoked / expired) are kept as plain integer counters for the public stats page (§7) —
they record *how many*, never *which* or *what*.

**Burn-on-read is a single atomic operation.** Reveal uses `:ets.take/2`, which removes and returns the
row in one indivisible step. Under a concurrent stampede, exactly one caller receives the row and all
others receive nothing — so a secret can never be revealed twice. (A non-atomic read-then-delete would
double-reveal; this design avoids that by construction.)

```elixir
def reveal(id) do
  case :ets.take(:secrets, id) do
    [{^id, blob, _hash, exp}] when exp > now() -> {:ok, blob}
    _ -> :gone           # already taken, or expired
  end
end
```

**Other storage behaviors:**

- **Non-burning peek.** `GET /s/:id` uses `:ets.lookup` (read-only) to decide whether to show the
  interstitial — it does **not** consume the secret.
- **TTL sweep.** The `Store` process deletes expired rows every 60 s (a backstop for never-read secrets).
- **Burned ⇒ gone.** Because reveal deletes the row, a consumed secret and one that never existed are
  indistinguishable to a later request (one "gone" state; no existence oracle).
- **Memory cap.** Creation is rejected (HTTP `503`) once the table reaches `MAX_SECRETS`; existing secrets
  are never evicted to make room. Worst-case memory ≈ `MAX_SECRETS × max-blob-size`.
- **Everything is lost on restart.** A deploy, crash, or reboot empties the table. This is intentional;
  the service is a transient pipe, not a vault. Senders simply re-send.

The storage API is the only code that touches ETS; the rest of the app calls `Store.create/peek/reveal/
burn`. A different backend (e.g. a database) could later be substituted behind this same boundary without
touching the HTTP or crypto layers.

---

## 7. HTTP surface

A single `Plug.Router`. All endpoints are anonymous; there is no session and no CSRF token (see §10 for
why that is correct here).

| Method | Path | Purpose | Response |
|---|---|---|---|
| `GET` | `/` | the create page (static HTML + the three SRI scripts) | `200` HTML |
| `GET` | `/s/:id` | non-burning reveal interstitial | `200` HTML (live) or `404` HTML "Not found" |
| `POST` | `/s/:id/reveal` | atomic burn; return ciphertext **once** | `200 {blob}` or `410 {status:"gone"}` |
| `POST` | `/s/:id/burn` | revoke early using the management token | `200` or `403` |
| `POST` | `/s/:id/report` | flag for operator review (non-destructive) | `200` |
| `POST` | `/api/secrets` | store a ciphertext blob | `200 {id, mgmt_token}` or `400`/`413`/`503` |
| `GET` | `/api/secrets/:id` | **programmatic take** — atomic burn; return ciphertext **once** | `200 {blob}` or `410 {status:"gone"}` |
| `GET` | `/stats` · `/stats.json` | **public** aggregate transparency (counts only) | `200` HTML / JSON |
| `GET` | `/terms` | **public** Terms / Acceptable-Use (template rendered from config) | `200` HTML |
| `GET` | `/.well-known/security.txt` | RFC 9116 security contact (machine-readable; see SECURITY.md) | `200` |
| `*` | _any unmatched_ | catch-all (`match _`) | `404 {"error":"not found"}` |

A **gone, expired, or unknown** id behaves differently on the two kinds of endpoint: the non-burning
interstitial `GET /s/:id` returns a **`404` HTML "Not found"** page (a never-existed id and a consumed one
look identical — no existence oracle), while the burning consume endpoints (`POST /s/:id/reveal`,
`GET /api/secrets/:id`) return **`410 {status:"gone"}`**. Same single "gone" state, different status by
endpoint kind.

**Create** accepts `{ "blob": "<base64url>", "ttl": <seconds, optional> }`. The server decodes the blob,
enforces a size limit (default 64 KB → `400` if exceeded or empty/undecodable), clamps the TTL to
`[60 s, TTL_SECONDS]` (TTL_SECONDS is both the default lifetime and the per-request ceiling — see §11),
generates a random 32-byte **management token**, stores `{id, blob, sha256(token), expires_at}`, and
returns the `id` plus the base64url management token. The token is shown **once** and only its hash is
kept. A *raw request body* over ~100 KB is rejected even earlier with `413` by `Plug.Parsers` (below),
before the route runs — distinct from the `400` for a body-level oversized/empty blob.

**Take (reveal).** There are two paths to the same atomic single-consume:
- the **browser** flow — non-burning `GET /s/:id` (interstitial) then `POST /s/:id/reveal` — so a
  link-preview bot prefetching a shared URL cannot destroy the secret;
- a **programmatic** `GET /api/secrets/:id` for CLI/scripts, where preview-prefetch is not a concern.

Both return `{ "blob": "<base64url>" }` to exactly one caller and `410` to everyone after.

**Burn** accepts `{ "mgmt_token": "<base64url>" }`; it succeeds only if the SHA-256 of the supplied token
matches the stored hash.

**Stats** (`/stats` HTML, `/stats.json` JSON) is a **public** transparency page: live secrets stored,
lifetime counts (created / read / revoked / expired), capacity, uptime, and abuse totals (requests
throttled, bans issued, sources currently blocked). It is **aggregate-only** — it contains no secret
contents, ids, IPs, or any per-user data, and the lifetime counters reset on restart (they live in RAM).

**Report** always returns `200` (even for unknown ids, so it can't be used to probe existence) and only
records a warning for a human operator; it never destroys a secret (so a stranger who has merely seen the
URL cannot delete an in-flight secret).

**Pipeline order:** `Plug.RequestId` → `Plug.Logger` (request logging) → **SecurityHeaders** (§10) →
**Abuse** (ban short-circuit + counting, §9) → `Plug.Static` ×3 → `Plug.Parsers` (`:json` only, raw body
capped at ~100 KB *before* buffering — a larger body is rejected with `413` before any route runs) →
`:match` → `:dispatch`. **SecurityHeaders runs first on purpose** (before Abuse and Static), so that even a
short-circuited abuse response (`429`/`503`) and every static-asset response still carry the full security
headers. The three `Plug.Static` mounts each have an `only:` allowlist: the app assets (`crypto-app.js` +
`crypto.css`), the vendored `burnerpad-crypto.js` (from the submodule), and `/.well-known/security.txt`.
The router is wrapped in an error handler that returns a generic `500` with **no stack trace** in
production (and maps `Plug.Parsers.RequestTooLargeError` → `413`).

---

## 8. Identifiers

Public ids are short, random, and easy to read aloud or type:

- **Alphabet:** Crockford base32 (digits + uppercase letters, excluding the ambiguous `I L O U`),
  case-insensitive.
- **Length:** 8 characters ≈ 40 bits of randomness (configurable).
- **Generation:** cryptographically random bytes, base32-encoded; inserted with `:ets.insert_new`, which
  also gives a free collision check (regenerate on the astronomically rare clash).
- **Normalization on lookup:** upper-case, fold the Crockford aliases (`I`/`L` → `1`, `O` → `0`), strip
  separators, then a cheap format check rejects obviously-invalid ids before any table lookup.

**Why short ids are safe:** the id is not a confidentiality control — content is protected by the
key/passphrase, so a short id never leaks plaintext. The only effects of a short id are existence
enumeration and "burn-griefing" (guessing a live id and consuming it). Both are bounded by the rate
limiter and bans (§9): at 40 bits, with per-IP throttling, blindly hitting a live secret is impractical.

---

## 9. Abuse controls (in-memory, proactive)

Anonymous one-time-secret services attract phishing, malware, and griefing, so abuse handling is built in
and entirely in RAM. Everything is keyed by client IP aggregated to **IPv4 `/32`** and **IPv6 `/64`** (a
single host owns a whole `/64`, so per-address keying would let it rotate freely to evade).

1. **Per-IP rate limit.** A flat ceiling (default **240 requests / minute / IP**, counting every request)
   via an ETS fixed-window counter. Over `RATE_LIMIT` → **`429` with `Retry-After`**.
2. **Global aggregate ceiling.** A single server-wide request ceiling that sheds load once exceeded,
   regardless of source IP. This is the on-box defense against a *distributed* flood (many IPs each under
   the per-IP limit), where per-IP counters are useless. Over `GLOBAL_CEILING` → **`503` "service busy"
   with `Retry-After`**. (Note: `503` has **two distinct origins** — this global shed, *and* the
   `MAX_SECRETS` "service full" from `POST /api/secrets` in §6, which carries **no** `Retry-After`.)
3. **Escalating temp-bans.** An IP whose count in a single fixed window exceeds `BAN_THRESHOLD` (default
   **600**, ≈ 2.5× `RATE_LIMIT`) is **banned** and short-circuited at the top of the pipeline (a cheap
   reject → **`429` with `Retry-After`**, no work done). The per-window counter resets each window and does
   **not** accumulate across windows — only a single over-`BAN_THRESHOLD` window triggers a ban. The ban
   duration escalates across *repeat bans* (strikes from a prior ban row: e.g. 15 m → 1 h → 6 h → 24 h),
   and strikes reset once the expired ban row is swept. The ban table self-expires.
4. **Visibility.** Each violation/ban emits a structured warning log, and the public `/stats` page exposes
   privacy-safe **aggregate** counters (throttled/banned totals + active bans) — no IPs, no keys, nothing
   per-offender.

All abuse tables are capped and swept, so IP rotation cannot grow memory without bound; the `MAX_SECRETS`
cap (§6) is the final backstop.

**Resolving the real client IP.** Behind a reverse proxy, the client IP comes from a configurable header
(`REAL_IP_HEADER`, default `cf-connecting-ip`), but **only when the socket peer is a configured trusted
proxy** — otherwise the header is ignored and the raw socket peer is used. This prevents an attacker who
reaches the origin directly from spoofing the header to forge bans on victims or evade their own. When
running with no proxy, trust no header and key on the socket peer directly (no spoofable header — the most
trustworthy setup). A proxied deployment should additionally firewall the app so it only accepts traffic
from the proxy.

---

## 10. Security model

**Authorization is capability-based.** There are no accounts, sessions, or cookies. Being able to act on
a secret means *possessing* something unguessable:

| Action | Requires |
|---|---|
| read/decrypt | the id **and** the key (in the link) or the passphrase |
| reveal/burn (consume) | the id |
| revoke early | the management token |

**No CSRF protection is needed — and that is correct, not an oversight.** CSRF attacks abuse *ambient
credentials* (a session cookie the browser sends automatically). This service has none: every
state-changing request is authorized by possession of an unguessable capability, not by a cookie. An
attacker who could forge a request would already need the id (and could just call the endpoint directly).
There is nothing to forge.

**Response security headers** (set on responses by the `SecurityHeaders` plug):

```
content-security-policy: default-src 'none'; script-src 'self'; style-src 'self';
                         font-src 'self'; connect-src 'self'; img-src 'self';
                         base-uri 'none'; form-action 'none'; frame-ancestors 'none'
referrer-policy: no-referrer
x-content-type-options: nosniff
x-permitted-cross-domain-policies: none
strict-transport-security: max-age=63072000; includeSubDomains; preload
cross-origin-resource-policy: same-origin
cross-origin-opener-policy: same-origin
permissions-policy: (deny all features)
```

`frame-ancestors 'none'` supersedes `X-Frame-Options`. `font-src 'self'` permits the self-hosted WOFF2
fonts (served same-origin from `/fonts`), so there is **no external font CDN** and `default-src 'none'`
stays otherwise closed. The `SecurityHeaders` plug runs before dispatch (and
before the abuse short-circuit), so it `merge_resp_headers` the **entire** set — CSP included — uniformly
onto **every** response: HTML pages, JSON (`200`/`400`/`410`/`413`/`429`/`503`), static assets, and
short-circuited error responses alike. The headers are applied unconditionally, not content-negotiated; the
CSP is simply only *operative* on the HTML documents (it is inert on a JSON body).

**Dynamic responses are non-cacheable.** Every dynamic send routes through **one shared policy** —
`SecurityHeaders.no_store/1` — which stamps `cache-control: no-store`: the router's `html`/`json` helpers,
the error handler, **and** the abuse `429`/`503` short-circuit all call it. That keeps the one-time reveal
ciphertext (`POST /s/:id/reveal`, `GET /api/secrets/:id`) and the single-use `mgmt_token` (the create
response) out of browser and proxy caches, from one place. (The SRI-pinned static crypto assets never call
it, so they keep **ETag revalidation** — `cache_control_for_etags: "no-cache"` — and the browser gets a
`304` when unchanged; their integrity is pinned by hash regardless.)

**What the design protects against:** a fully compromised server or a network/proxy observer recovers only
ciphertext (never plaintext or keys); a secret cannot be read twice; a stolen/forwarded link is single-use
(and, in passphrase mode, useless without the passphrase); a tampered crypto script is refused by SRI; and
the server stores nothing on disk to seize or subpoena.

**Out of scope (be honest about the limits):**

- A **compromised endpoint** (malware or a keylogger on the sender's or recipient's own device) — the
  service encrypts/decrypts on machines it does not control.
- **Malicious content** sent through the service — under end-to-end encryption it is unscannable by
  design; the `report` flow + operator takedown is the mitigation, not content inspection.
- **Volumetric / large distributed denial-of-service** beyond what the on-box ceiling and the host's
  network can absorb — an external edge/CDN is the answer if that threat matters.

---

## 11. Configuration

All configuration is environment variables; there is **no secret key base** (no signed cookies) and **no
database path** (no database).

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `4000` | HTTP listen port |
| `REAL_IP_HEADER` | `cf-connecting-ip` | header to read the client IP from, when behind a trusted proxy |
| `TRUSTED_PROXIES` | empty | CIDRs whose socket peers may set `REAL_IP_HEADER`; empty = trust none, use the socket peer |
| `MAX_SECRETS` | `100000` | hard cap on live secrets (memory bound) |
| `TTL_SECONDS` | `86400` | default secret lifetime **and** the per-request ceiling: a client-supplied `ttl` is clamped to `[60, TTL_SECONDS]` (lowering this lowers the max a client may request) |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `OPERATOR_NAME` | `Impulsa SLU` | shown on `/terms` (default = this instance's operator; **a fork must override**) |
| `ABUSE_EMAIL` | `abuse@burnerpad.com` | abuse/removal contact on `/terms` |
| `JURISDICTION` | `Andorra` | governing law on `/terms` |

**Terms / Acceptable-Use.** The `/terms` page renders the operator's terms from the three variables above,
which **default to this instance's operator** (Impulsa SLU / Andorra / abuse@burnerpad.com) so the live
page is filled in — there is no "template" banner on the page. **A fork must override `OPERATOR_NAME` /
`ABUSE_EMAIL` / `JURISDICTION`** or it will publish Impulsa SLU's terms as its own. The repo ships
[`TERMS.template.md`](../TERMS.template.md) with the same wording plus operator legal notes. This is a
content/operator concern, not a security control, and is **not legal advice** — a public-instance operator
should have it reviewed. It pairs with the existing reactive
moderation (report → operator purge-by-id) and per-IP banning (§9), which is the only moderation possible
under E2E.

---

## 12. Running & deploying

The app serves plain HTTP and expects **TLS to be terminated by a reverse proxy** (e.g. Caddy for
automatic certificates, or a CDN). It needs no database, no migrations, and no asset build step.

- **Development:** `mix deps.get && iex -S mix` (or `mix run --no-halt`).
- **Container:** `docker run -p 4000:4000 <image>` — a small multi-stage image (`mix release` into a slim
  runtime).
- **Bare metal:** `mix release` produces a self-contained tarball (bundles the Erlang runtime); copy it,
  set `PORT`, and run `bin/burnerpad start`. No Erlang/Elixir install required on the host.

For TLS, front the app with Caddy (auto-HTTPS) or any reverse proxy/CDN; set `REAL_IP_HEADER` /
`TRUSTED_PROXIES` accordingly and, if behind a proxy, firewall the app to accept only the proxy's traffic.
Run with swap disabled on the host so in-memory ciphertext is not paged to disk.

---

## 13. Project layout

```
mix.exs                          # project + deps ({:bandit, ...}); elixir ">= 1.18"
mix.lock
lib/burnerpad/
  application.ex                 # OTP application + supervision tree
  config.ex                      # runtime config from env vars (see §11): load!/0 + getters/defaults
  store.ex                       # in-memory ETS secrets: create/peek/reveal/burn/sweep + cap
  abuse.ex                       # ETS rate-limit counter + global ceiling + escalating bans + aggregate metrics
lib/burnerpad_web/
  router.ex                      # Plug.Router: the routes in §7 + the plug pipeline
  abuse_plug.ex                  # ban short-circuit + counting (runs before static, so every request counts)
  client_ip.ex                   # resolve real client IP (REAL_IP_HEADER / trusted proxies) -> /32 & /64
  security_headers.ex            # the response headers in §10 + the no_store/1 cache policy (one seam)
  crypto_assets.ex               # compute the SRI hashes of the three scripts at boot
  layout.ex                      # shared page CHROME: document shell + <head> theme bootstrap, icon
                                 #   sprite, header, footer, and the SRI <script> tags (single source)
  pages.ex                       # per-route page CONTENT (create / reveal / 404 / stats / terms)
priv/static/crypto/
  crypto-app.js                  # the page driver (vanilla JS); a DOM-free `Core` (link display, word
                                 #   canonicalization, paste parse/cap, strength) is unit-tested by mix test.core
  theme.js                       # render-blocking <head> light/dark bootstrap (localStorage; SRI-pinned)
  crypto.css                     # styling for all pages (light/dark tokens, self-hosted @font-face)
priv/static/fonts/               # self-hosted WOFF2 web fonts, SIL OFL-1.1 (NOTICE.md + OFL.txt)
priv/static/vendor/crypto-js/    # @burnerpad/crypto — pinned git submodule (Apache-2.0):
  burnerpad-crypto.js            #   the audited, dependency-free WebCrypto bundle; mounted via a
                                 #   separate Plug.Static at /crypto, served as-is and SRI-pinned
priv/static/.well-known/
  security.txt                   # RFC 9116 security contact (see SECURITY.md)
test/
  burnerpad/                     # Store + Abuse unit tests (ExUnit)
  burnerpad_web/                 # router_test.exs (HTTP surface) + client_ip_test.exs (trusted-proxy keying)
  crypto/core_test.cjs           # Node unit tests for the crypto-app.js DOM-free Core (mix test.core)
  support/                       # test helpers
  browser/                       # optional Playwright smoke suite (real Chromium; dev/CI only)
docs/ARCHITECTURE.md             # this document
CONTEXT.md                       # self-contained repository handoff doc
README.md                        # project readme / quickstart
SECURITY.md  CONTRIBUTING.md  DCO  LICENSE  TERMS.template.md   # governance / legal
.github/workflows/               # CI: dco.yml (sign-off check) + test.yml (compile-warnings-as-errors + tests)
Dockerfile
```

---

## 14. End-to-end lifecycle (what exists, and where)

```
CREATE
  browser: plaintext -> encrypt (key/passphrase never leave the browser) -> blob
  POST /api/secrets {blob}
  server: store {id, blob(ciphertext), sha256(mgmt_token), expires_at} IN RAM
          return {id, mgmt_token}
  browser: build link  /s/<id>#<key>   (or /s/<id> for passphrase mode)

SHARE
  link travels however the sender chooses; the key rides in the # fragment
  (or the passphrase is shared out of band)

REVEAL (once)
  GET  /s/:id            -> non-burning interstitial (preview-bot safe)
  POST /s/:id/reveal     -> :ets.take removes the row atomically; returns ciphertext exactly once
  browser: decrypt locally with the fragment key / derived passphrase key -> plaintext shown
  the row no longer exists; a second reveal returns 410

DESTROY (any of)
  - reveal consumes it
  - the owner calls POST /s/:id/burn with the management token
  - the TTL sweep deletes it after expiry
  - a restart empties all of RAM

At no point does plaintext, a key, or a passphrase exist on the server, on disk, or in any log.
```

---

## 15. Implementation status & verification

The server is fully implemented (Elixir + Bandit; the modules in §13) with an automated test suite and
live HTTP verification.

**Automated tests** (`mix test`) cover:
- **Store** — id format/uniqueness, non-burning peek, atomic burn-on-read, **exactly-once under a
  100-way concurrent stampede**, management-token revoke, id normalization (case/dash/Crockford folding),
  the `MAX_SECRETS` cap, TTL clamping, and expiry sweeping.
- **Abuse** — per-IP rate limiting, escalating bans (incl. strike escalation), the global aggregate
  ceiling, and the aggregate metrics.
- **Browser (headless, optional)** — a Playwright suite (7 specs) drives real Chromium through the
  passphrase-only UI: passphrase create → key-less link → chip reveal with a wrong-order-then-correct retry
  (a single network burn, retried locally); **pasting the whole phrase at once** (every word chipped,
  including the last); the tag field (Regenerate, remove-a-word warning, write-your-own); Space/Tab
  committing a word; the always-active create button + create→burn→reset UX; a `#fragment` (link-mode)
  reveal URL refused as unsupported; and the strict CSP + SRI holding with **no console errors**. Kept
  isolated under `test/browser/`; not a runtime dependency.
- **Router** — the create page (three SRI scripts, **no inline scripts**, the full CSP + hardening
  headers), create→peek→reveal→`410`, revoke, non-destructive report, the input limits (oversized blob
  `400`, over-cap body rejected before buffering, empty `400`), `MAX_SECRETS` `503`, per-IP `429`,
  static-asset serving with SRI matching, and JSON `404`s.

**Live-verified over HTTP** (dev server and a packaged `mix release`): the full create→share→reveal→burn
lifecycle; second-reveal `410`; the oversized-blob `400`, over-body `413`, and empty `400` limits; the
`MAX_SECRETS` `503`; the per-IP `429`; an **escalating ban** (first strike 15 min, `Retry-After: 900`)
that left a separate clean IP unaffected (confirming the trusted-proxy `REAL_IP_HEADER` resolution keyed
the ban to the right IP); and the production release booting and serving the same flow.

**Crypto modes — library implements both; the web app mints only `0x02`.** The crypto library
(`burnerpad-crypto.js`) implements **link mode (suite `0x01`)** and **passphrase mode (suite `0x02`)**, and
its own conformance suite covers both. **This web app is passphrase-only:** the driver generates the phrase
(an editable tag field — Regenerate / remove-with-warning / write-your-own) on the create page and uses a
**list-locked autocomplete** reveal that refuses a `#fragment` (link-mode) URL; local retry without
re-burning is preserved. The crypto is verified
two ways: the vendored bundle's harness round-trips both suites and **cross-checks them against
`node:crypto`** (independent AES-256-GCM and PBKDF2-HMAC-SHA256/600k), with negatives (truncation, unknown
suite, tampered tag, bad encoding, wrong passphrase) failing closed; and a **live end-to-end run drives the
real bundle against the running server** — the browser suite covers the passphrase create→reveal flow, and
`GET /api/secrets/:id` covers the programmatic take — confirming create → take → decrypt and exactly-once
`410` on re-take. The server remains fully crypto-agnostic (stores/relays any envelope verbatim).
