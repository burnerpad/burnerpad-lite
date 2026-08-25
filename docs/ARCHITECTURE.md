# Burnerpad — Architecture & How It Works

A minimal, no-accounts, **end-to-end-encrypted one-time-secret sharing** service. The first reveal request
atomically removes a ciphertext row and makes it available to at most one request handler. That does not
guarantee delivery: the response can be lost after removal. The app keeps payloads in RAM and logs only
sanitized route class/method/status/duration/release events. It excludes full paths, client addresses,
secret IDs, capabilities, payloads, and source mappings. Cloudflare edge processing is covered separately.

This document is the complete, self-contained description of the system: the architecture, the
client-side cryptography, how the small amount of JavaScript works, how secrets are stored and destroyed,
the HTTP API, the abuse controls, the security model, configuration, and how to run it.

---

## 1. What it is (and what it promises)

- **At-most-once server claim.** One request handler can atomically take a ciphertext row; every later
  request finds nothing. Claim, HTTP delivery, and successful client decryption are distinct events.
- **No accounts.** No accounts, no sessions, no cookies, no sign-up. Authorization is *possession* of an
  unguessable link (and, optionally, a passphrase).
- **End-to-end encrypted.** Encryption and decryption happen in an official client. The server only holds
  opaque ciphertext. This assumes a trusted endpoint and client; a compromised live web origin can replace
  the browser application for future users.
- **Ephemeral payloads.** Secrets live in RAM with a time-to-live (default 24 h); payloads are never written
  to disk and everything is gone on restart. The deployment retains bounded app and tunnel-error logs.
- **Tiny and self-hostable.** A single Elixir process, one dependency, no database, no Node/JS build
  toolchain. Clone and run.

---

## 2. Design invariants

These five rules explain every decision below:

1. **The server is crypto-agnostic.** It stores and relays one **opaque blob** of bytes and never parses
   it — not the cipher, not the IV, nothing. All format knowledge lives in the browser.
2. **The key never reaches the server.** The passphrase or link-mode fragment remains in the client; the
   fragment is not part of an HTTP request.
3. **Fresh official-client credentials.** Official clients generate a unique phrase or link key for each
   secret. Reusing a suite `0x02` phrase weakens record separation (see §4.2).
4. **Fail closed.** Any authentication failure, unknown format, or malformed input is a hard reject — the
   client never shows partial or unauthenticated plaintext.
5. **Store as little as possible.** No plaintext, keys, passphrases, or secret IDs reach persistent storage.
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
                        │ (GET pages)        │ (JSON POST /api/secrets/*)
        ┌───────────────┴────────────────────▼─────────────┐
        │  Elixir app  (Plug + Bandit, no framework)        │
        │  ┌─────────────┐  ┌──────────┐  ┌──────────────┐  │
        │  │  Router      │  │  Store    │  │  Abuse        │  │
        │  │ (HTTP + SRI  │  │ (ETS, in- │  │ (rate limit + │  │
        │  │  pages + API)│  │  memory)  │  │  bans, ETS)   │  │
        │  └─────────────┘  └──────────┘  └──────────────┘  │
        └───────────────────────────────────────────────────┘
          secret payloads + privacy counters live in RAM only
```

- **Language/runtime:** Elixir on the BEAM (OTP).
- **HTTP server:** [Bandit](https://hex.pm/packages/bandit) driven by a single `Plug.Router`. **No web
  framework** (no Phoenix/LiveView), so the only browser JavaScript is the small, SRI-pinned crypto
  library, the page driver, and a tiny theme bootstrap (§5).
- **Storage:** an in-memory [ETS](https://www.erlang.org/doc/man/ets) table. **No database.**
- **Dependencies:** essentially just `bandit`. JSON uses the Elixir standard-library `JSON` module
  (the repository pins Elixir 1.20.3 / OTP 29.0.5); cryptography on the server is limited to hashing/random via the Erlang `:crypto`
  standard library.

**Supervision tree** (`Burnerpad.Application`):

```elixir
children = [
  Burnerpad.Store,   # owns the secrets ETS table + runs the TTL sweep
  Burnerpad.Abuse,   # owns the rate-limit / ban / stats ETS tables + sweeps them
  Burnerpad.DailyStats, # aggregate {UTC day, homepage requests, secrets created}; no identifiers
  {Bandit, plug: BurnerpadWeb.Router, scheme: :http, port: port(),
   http_2_options: [enabled: false], websocket_options: [enabled: false]}
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
URL*; this web app instead standardizes on the two-channel passphrase mode below. The library keeps it.

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
link cannot decrypt the ciphertext without the passphrase. It remains a destructive bearer capability:
its holder can claim and copy the ciphertext. This is the **only** mode the web client mints: the passphrase is
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

- For an already-trusted client session, the server and delivery path receive ciphertext, not the
  passphrase. A server/RAM compromise can copy ciphertext and mount offline guesses, deny service, or swap
  records; it does not directly reveal a strong generated phrase.
- Fresh official-client phrases plus random salt/IV avoid accidental `(key, nonce)` reuse.
- GCM authentication + AAD binding means tampering or a wrong key yields a hard reject, never
  wrong-but-accepted plaintext.
- Suite `0x02` does not bind an external server ID. If a caller reuses one phrase, a malicious server can
  substitute another valid blob created with that phrase and obtain the other authenticated plaintext.
  Official clients therefore generate a fresh seven-word phrase for every secret.
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

- All three scripts and the stylesheet carry committed `integrity="sha384-…"` values. The application
  recomputes and verifies those pins at boot, and the browser verifies them again while trusted HTML names
  the expected hash.
- A **strict Content-Security-Policy** allows scripts only from the same origin and **forbids inline
  scripts** (`script-src 'self'`), so an injected `<script>` cannot run. (Full header list in §10.)
- `Referrer-Policy: no-referrer` keeps the `#fragment` (the key) out of the `Referer` header.

**Create-page flow (passphrase-only, suite 0x02):**
1. A header (logo wordmark + a **light/dark theme toggle**), a value-prop headline, and a 3-card **trust
   strip** (end-to-end encrypted · two separate channels · at most one claim) set the frame. The driver
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
3. `POST /api/secrets { blob }` → `{ id, mgmt_token, ttl }`; `ttl` is the server's effective, clamped
   lifetime.
4. The driver builds the **key-less** share link `origin + "/s/" + id` and shows the **success screen**
   (the hero + trust strip are hidden): *Send the link* (shown **without its `http(s)://`/`www.` prefix**,
   with a **Copy** button that copies the *full* URL) and *Share the passphrase* (the words as chips,
   framed as a **separate channel** — a different app, a text, or a call — with its **own Copy button**).
   The passphrase Copy button is a **deliberate convenience/​isolation trade-off**: it is on the user to
   keep that channel apart from where the link was sent, and the subtitle reminds that the recipient needs
   **both**, on **separate** channels.
5. The same success screen carries two more controls. **Burn it now** (`#bp-burn`) is an early revoke: it
   `POST`s `/api/secrets/:id/burn` with the one-time `mgmt_token` and swaps the share block for a centered **"Burned"**
   confirmation only after a token-matched `200`. A timeout or lost response is shown as an unknown
   outcome; absence cannot prove whether this client performed the burn. **Create another secret**
   (`#bp-again`) warns before discarding the only in-page copy of a still-live management token, then
   resets the form with a fresh phrase.

**Reveal-page flow (purist):**
1. `GET /s/:id` renders a **non-burning** page (so ordinary preview bots that only fetch the URL do not
   claim the ciphertext). It warns that the claim is at most once and a lost response is not reliably
   recoverable. The client never retries automatically; after an unknown outcome it requires confirmation
   before a deliberate resubmission, which can succeed only if the earlier request did not complete the take.
   If the URL carries a `#fragment` (a link-mode link), the driver shows an **"unsupported
   link"** notice and stops — this client only opens key-less passphrase secrets.
2. Otherwise the recipient rebuilds the phrase in the same tag field. They can **type** each word via
   **list-locked autocomplete** — Enter/Space/Tab commits the highlighted word (Space never types a literal
   space; Backspace on an empty input removes the last chip) — **or paste the whole space-separated phrase
   at once**. Pasted input is accepted only when every complete token is a canonical wordlist member,
   within the word/byte limits, with no duplicates; invalid input is rejected as a whole and is never
   silently truncated. A live count pill reads "N / 7" (amber)
   until complete, then "✓ N" (green). The **Reveal & decrypt** button is **always active**: with fewer
   than 7 words it nudges focus instead of revealing, and its label/icon flip once 7 words are present.
3. JSON `POST /api/secrets/:id/reveal` performs the atomic take. The ciphertext is available to at most one
   request handler; HTTP delivery can still fail afterward.
4. The driver derives the key from the phrase (`decryptPsk`), decrypts locally, and shows the plaintext in a
   scrollable **code block** — a line/byte meta header plus a **Copy** button (`#bp-copy-secret`) — under a
   "Decrypted · copy it now, you won't see it again" heading. The plaintext is written with `textContent`
   only (never `innerHTML`). A wrong phrase (or wrong word order) can be fixed and retried **locally**
   against the already-fetched blob — **no second network read or burn** — because the one network reveal
   already happened.

---

## 6. Storage (in-memory; what is kept, and where)

Secrets are held in a single named **ETS table** owned by the `Store` process. **Nothing is persisted to
disk and nothing is written to a database** — the table lives entirely in RAM. Production Compose also
sets each container's combined RAM-plus-swap allowance equal to its RAM limit, preventing secret or
credential pages from spilling into the host's swap partition.

**Each row holds only:**

| Field | What it is |
|---|---|
| `id` | the short public identifier (see §8) |
| `blob` | the **opaque ciphertext** envelope from §4 (never parsed) |
| `mgmt_token_hash` | `SHA-256` of a one-time management token (used to revoke; see §7) |
| `expires_at` | process-local monotonic expiry deadline |

**What is never stored:** plaintext, the encryption key, the passphrase, the raw management token, raw IP
addresses, IP addresses tied to a secret, or any access log of who read what. In-memory abuse counters use
keyed HMAC tokens derived from IP prefixes (§9), never the raw prefix and never a secret id. Aggregate
lifetime tallies plus daily homepage-request and successful-create counts are plain integers for `/stats`;
the activity metric stores only `{UTC day, homepage count, creation count}` and intentionally does not try
to identify unique people or retain any per-secret record.

**Burn-on-read is a single atomic operation.** Reveal uses `:ets.take/2`, which removes and returns the
row in one indivisible step. Under a concurrent stampede, at most one request handler receives the row and
all others receive nothing. The winning response may still be interrupted before the client receives or
decrypts it.

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
- **Burned ⇒ gone.** Because reveal deletes the row, a consumed secret and one that never existed return
  the same `gone` result from mutating API calls. The non-burning HTML interstitial still exposes liveness
  (`200` live vs `404` gone), which is harmless only because IDs carry 130 random bits (§8).
- **Memory cap.** Creation is rejected (HTTP `503`) once the table reaches `MAX_SECRETS`; existing secrets
  are never evicted to make room. Creates are serialized through the table owner, so this remains a hard
  cap under concurrency. Worst-case memory ≈ `MAX_SECRETS × max-blob-size`.
- **Everything is lost on restart.** A deploy, crash, or reboot empties the table. This is intentional;
  the service is a transient pipe, not a vault. Senders simply re-send.
- **Managed-runtime erasure limit.** Removing an ETS row makes it unreachable immediately, but the BEAM
  allocator cannot promise physical zeroization of freed RAM. Swap, native core dumps, and Erlang crash
  dumps are disabled in the production recipe so allocator residue is never deliberately persisted.

The storage API is the only code that touches ETS; the rest of the app calls `Store.create/peek/reveal/
burn`. A different backend (e.g. a database) could later be substituted behind this same boundary without
touching the HTTP or crypto layers.

---

## 7. HTTP surface

A single `Plug.Router`. All endpoints are anonymous; there is no session and no CSRF token (see §10 for
why that is correct here).

| Method | Path | Purpose | Response |
|---|---|---|---|
| `GET` | `/` | the create page (SRI-pinned CSS + three scripts) | `200` HTML |
| `GET` | `/s/:id` | non-burning reveal interstitial | `200` HTML (live) or `404` HTML "Not found" |
| `POST` | `/api/secrets` | store a ciphertext blob | `200 {id, mgmt_token}` or `400`/`413`/`503` |
| `POST` | `/api/secrets/:id/reveal` | atomic claim for at most one handler | `200 {blob}` or generic `404` |
| `POST` | `/api/secrets/:id/burn` | revoke early using the management token | `200` or generic `404` |
| `POST` | `/api/edge/source-check` | compare edge-observed IP with deployed source resolution, returning no identifier | `204`, `409`, or `400` |
| `GET` | `/stats` · `/api/stats` | **public** aggregate transparency (counts only) | `200` HTML / JSON |
| `GET` · `HEAD` | `/healthz` | process liveness, handled above the limiter | `200` text |
| `GET` · `HEAD` | `/readyz` | Store/Abuse process and ETS readiness | `200` or `503` text |
| `GET` | `/terms` | **public** Terms / Acceptable-Use (template rendered from config) | `200` HTML |
| `GET` | `/.well-known/security.txt` | RFC 9116 security contact (machine-readable; see SECURITY.md) | `200` |
| `*` | _any unmatched_ | catch-all (`match _`) | `404 {"error":"not found"}` |

A **gone, expired, or unknown** id behaves differently on the two kinds of endpoint: the non-burning
interstitial `GET /s/:id` returns a **`404` HTML "Not found"** page (a never-existed id and a consumed one
look identical), while a live ID returns `200`; this is a liveness oracle, not a content oracle. The
130-bit ID makes blind discovery infeasible. `POST /api/secrets/:id/reveal` returns
**Generic `404` for every unavailable state.** The service knows only that no row is present now; it does
not retain enough history to distinguish read, expired, purged, restarted-away, malformed, or never-created
IDs. Burn likewise returns the same `404` for a wrong token and an absent row, avoiding a live-ID oracle.

**Create** accepts `{ "blob": "<base64url>", "ttl": <seconds, optional> }`. The server decodes the blob,
enforces a size limit (default 64 KB → `400` if exceeded or empty/undecodable), clamps the TTL to
`[60 s, TTL_SECONDS]` (TTL_SECONDS is both the default lifetime and the per-request ceiling — see §11),
generates a random 32-byte **management token**, stores `{id, blob, sha256(token), expires_at}`, and
returns the `id`, base64url management token, and effective TTL. The token is shown **once** and only its
hash is kept. A *raw request body* over ~100 KB is rejected even earlier with `413` by `Plug.Parsers` (below),
before the route runs — distinct from the `400` for a body-level oversized/empty blob.

**Take (reveal).** Browser and programmatic clients use non-burning `GET /s/:id` where an interstitial is
needed, then JSON `POST /api/secrets/:id/reveal`. No `GET` destroys state. The POST returns
`{ "blob": "<base64url>" }` to at most one request handler and the same generic `404` as any unavailable
ID afterward. An interrupted winning response is an unknown outcome and cannot be recovered: clients must
not retry automatically, and a deliberate resubmission returns `404` if the first request completed the take.

**Burn** accepts `{ "mgmt_token": "<base64url>" }`; it succeeds only if the SHA-256 of the supplied token
matches the stored hash.

**Stats** (`/stats` HTML, `/api/stats` JSON) is a **public** transparency page: resident ciphertext rows,
lifetime counts (created / read / revoked / expired), capacity, uptime, and abuse totals (requests
throttled, bans issued, sources currently blocked), plus 14 UTC days of homepage request counts and
successful secret-creation counts. It is **capability-free and aggregate-only** — no secret contents, ids,
IPs, cookies,
fingerprints, or visitor/secret records. It explicitly reports page views rather than “unique people,”
and all counts reset on restart. A creation enters the daily aggregate only after Store successfully
inserts it; rejected, throttled, invalid, and over-capacity attempts do not count.
The counters are intentionally exact and live. They are O(1) reads from bounded in-memory state, so Burnerpad
does not delay, cache, or quantize them. Repeated polling can reveal aggregate event timing and volume,
restarts, and some operational state, but cannot attribute an event or operate on a secret from the endpoint
alone. That limited traffic-pattern exposure is accepted in exchange for immediate public transparency.
It also reports the non-user application version and deployed Git revision so an operator can verify the
running release without host access.

**Pipeline order:** **SecurityHeaders** (§10) → `Plug.RequestId` → `/healthz` → `Plug.Static` ×4 →
**Abuse** (dynamic-route ban/counting, §9) → privacy-safe **RequestLogger** → `Plug.Parsers` (`:json` only, `pass: []`, raw body capped at
~100 KB) → `:match` → `:dispatch`. Static assets do not consume rate-limit capacity. The request logger
records only allowlisted route/method/status/duration/release fields. A non-JSON mutating request is
rejected with `415` before dispatch; this content-type
boundary is also the CSRF gate.
The router is wrapped in an error handler that returns a generic `500` with **no stack trace** in
production (and maps `Plug.Parsers.RequestTooLargeError` → `413`).

---

## 8. Identifiers

Public ids are random capabilities:

- **Alphabet:** Crockford base32 (digits + uppercase letters, excluding the ambiguous `I L O U`),
  case-insensitive.
- **Length:** 26 characters = 130 bits of randomness (fixed so configuration cannot weaken it).
- **Generation:** cryptographically random bytes, base32-encoded; inserted with `:ets.insert_new`, which
  also gives a free collision check (regenerate on the astronomically rare clash).
- **Normalization on lookup:** upper-case, fold the Crockford aliases (`I`/`L` → `1`, `O` → `0`), strip
  separators, then a cheap format check rejects obviously-invalid ids before any table lookup.

The ID is not a plaintext-confidentiality control (the passphrase is), but it **is** a destructive
capability because the reveal endpoint burns before client-side decryption. At 130 bits, blind discovery
remains infeasible even at full capacity and does not rely on rate limiting for cryptographic safety.

---

## 9. Abuse controls (in-memory, proactive)

No-account one-time-secret services attract phishing, malware, and griefing, so abuse handling is built in
and entirely in RAM. The transient client IP is aggregated to **IPv4 `/32`** or **IPv6 `/64`**, then
immediately converted to purpose-separated keyed HMAC tokens using a random key that exists only in this
VM's RAM. Rate, ban, and capacity-budget tokens cannot be joined from an ETS snapshot; no table retains the
raw prefix.

1. **Per-IP rate limit.** A ceiling (default **240 dynamic requests / minute / IP**) uses the current and
   previous ETS buckets with a sliding weight, preventing the ~2x burst at a fixed-window boundary. Static
   assets and `/healthz` do not consume it. Over `RATE_LIMIT` → **`429` with `Retry-After`**.
2. **Global aggregate ceiling.** A single server-wide request ceiling that sheds load once exceeded,
   regardless of source IP. This is the on-box defense against a *distributed* flood (many IPs each under
   the per-IP limit), where per-IP counters are useless. Over `GLOBAL_CEILING` → **`503` "service busy"
   with `Retry-After`**. (Note: `503` has **two distinct origins** — this global shed, *and* the
   `MAX_SECRETS` "service full" from `POST /api/secrets` in §6, which carries **no** `Retry-After`.) The
   global check runs before per-source row allocation, so rejected distributed traffic cannot grow the
   rate table without bound.
3. **Global valid-create ceiling.** A separate sliding ceiling (default **1,000/minute**) is consumed only
   after a create body and ciphertext pass validation, before Store work. It bounds distributed row churn
   even when each source remains below its own quota. Excess returns `503` with a conservative retry time.
4. **Escalating temp-bans.** An IP whose weighted request count exceeds `BAN_THRESHOLD` (default
   **600**, ≈ 2.5× `RATE_LIMIT`) is **banned** and short-circuited at the top of the pipeline (a cheap
   reject → **`429` with `Retry-After`**, no work done). The per-window counter resets each window and does
   **not** accumulate across windows — only a single over-`BAN_THRESHOLD` window triggers a ban. The ban
   duration escalates across *repeat bans* (strikes from a retained token: e.g. 15 m → 1 h → 6 h → 24 h).
   A strike token is forgotten 24 hours after its ban ends; the ban table self-expires.
5. **Per-source row/byte budget.** Each create reserves row and byte counts in an expiry bucket keyed by the
   source token — never by secret ID. Both defaults are 2% of store capacity; they recycle as TTLs elapse.
   Admission is serialized, so concurrent creates cannot race past either budget; a failed
   capacity write rolls its reservation back. The auxiliary table is hard-capped at `MAX_SECRETS` rows, so
   rapid create/reveal churn cannot grow metadata without bound.
6. **Visibility.** A newly-issued ban emits one warning without the IP; individual rate/global rejections
   are deliberately not logged. `/stats` exposes
   privacy-safe **aggregate** counters (throttled/banned totals + active bans) — no IPs, no keys, nothing
   per-offender.

Abuse tables are time-bounded and swept: a rate token lasts at most about three minutes (two windows plus
the sweep delay), a ban/strike token about 48 hours under the current schedule, and a byte-budget token
at most the configured secret TTL plus about 16 minutes. The byte-budget table additionally has a hard
`MAX_SECRETS` row cap. The store's own `MAX_SECRETS` cap (§6) is the final ciphertext backstop.

These anonymous controls deliberately impose shared-NAT collateral: unrelated people behind one source
prefix share its rate and capacity budget. Conversely, a distributed actor can spread below per-source
limits until the global ceilings or Cloudflare controls engage. No challenge, account, fingerprint, or
source-to-secret mapping is added to distinguish them.

**Operator takedown (notice-and-action).** On a valid abuse / illegal-content notice (sent to the abuse
contact on `/terms`), extract the secret id from the reported `/s/:id` or `/api/secrets/:id` URL and purge
it: `bin/burnerpad rpc 'Burnerpad.Store.purge("THEID")'` (or `Burnerpad.Store.purge/1` from an attached
`iex`). It deletes by id **without** the management token and counts under the `:purged` stat (not
`:revealed`, so transparency numbers stay honest). Because secrets are burn-on-read and expire after 24 h
by default, a reported secret is usually already gone by the time a notice arrives.

**Resolving the real client IP.** Behind a reverse proxy, the client IP comes from a configurable header
(`REAL_IP_HEADER`, default `cf-connecting-ip`), but **only when the socket peer is a configured trusted
proxy** — otherwise the header is ignored and the raw socket peer is used. This prevents an attacker who
reaches the origin directly from spoofing the header to forge bans on victims or evade their own. When
running with no proxy, trust no header and key on the socket peer directly (no spoofable header — the most
trustworthy setup). A proxied deployment should additionally firewall the app so it only accepts traffic
from the proxy.

**Public source-path verification.** `POST /api/edge/source-check` accepts an independently edge-observed
address and returns only match (`204`), mismatch (`409`), or invalid (`400`); it never returns or retains a
source identifier. `ops/smoke/edge-contract.mjs` obtains the observation from Cloudflare's managed
`/cdn-cgi/trace`, then checks both a normal request and one carrying a forged `CF-Connecting-IP`. The
baseline fails if the tunnel peer leaves `TRUSTED_PROXIES` or the visitor header disappears; the forged
request fails if caller-controlled source data reaches the trusted resolver.

---

## 10. Security model

**Authorization is capability-based.** There are no accounts, sessions, or cookies. Being able to act on
a secret means *possessing* something unguessable:

| Action | Requires |
|---|---|
| read/decrypt | the id **and** the key (in the link) or the passphrase |
| reveal/burn (consume) | the id |
| revoke early | the management token |

**Mutating requests have a content-type CSRF gate.** Burnerpad has no ambient session cookie, but an ID is
a capability that may appear in another site's DOM or URL. Every state-changing route therefore lives
under `/api` and requires `Content-Type: application/json`; `Plug.Parsers` uses `pass: []`, so a browser's
cross-site “simple” form/text POST is rejected with `415` before it can burn anything. No endpoint burns on
`GET`, and a cross-origin JSON request would require a CORS preflight that the app does not allow.

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
onto **every** response: HTML pages, JSON (`200`/`400`/`404`/`413`/`429`/`503`), static assets, and
short-circuited error responses alike. The headers are applied unconditionally, not content-negotiated; the
CSP is simply only *operative* on the HTML documents (it is inert on a JSON body).

**Dynamic responses are non-cacheable.** Every dynamic send routes through **one shared policy** —
`SecurityHeaders.no_store/1` — which stamps `cache-control: no-store`: the router's `html`/`json` helpers,
the error handler, **and** the abuse `429`/`503` short-circuit all call it. That keeps the one-time reveal
ciphertext (`POST /api/secrets/:id/reveal`) and the single-use `mgmt_token` (the create
response) out of browser and proxy caches, from one place. (The SRI-pinned static crypto assets never call
it, so they keep **ETag revalidation** — `cache_control_for_etags: "no-cache"` — and the browser gets a
`304` when unchanged; their integrity is pinned by hash regardless.)

**What the design protects against:** the application has no database or payload access log; a passive
network observer sees ciphertext; at most one request handler claims a row; and an ID/link alone does not
decrypt a strong suite-`0x02` ciphertext (although it can destructively claim and copy it). Committed SRI
plus boot verification detects asset drift and static-file tampering as
long as the reviewed application/HTML remains trusted. A live origin compromise can still serve malicious
HTML to future visitors; SRI cannot defend when the attacker controls both a script and the page naming its
expected hash.

**Out of scope (be honest about the limits):**

- A **compromised endpoint** (malware or a keylogger on the sender's or recipient's own device) — the
  service encrypts/decrypts on machines it does not control.
- A compromised **live web origin, HTML response, or CDN control plane**. It can replace the application
  and expected SRI hashes for future browser sessions. Use the independently signed CLI when this risk
  matters.
- **Malicious content** sent through the service — under end-to-end encryption it is unscannable by
  design; notice by email to the `/terms` contact plus operator purge-by-id is the mitigation.
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
| `MAX_SECRETS` | `10000` | hard cap on resident rows (range `1..100000`; size to available memory) |
| `TTL_SECONDS` | `86400` | default lifetime and per-request ceiling, boot-validated to `60..86400`; callers may request less but never more than 24h |
| `RATE_LIMIT` | `240` | per-IP requests per minute |
| `GLOBAL_CEILING` | `30000` | server-wide requests per minute |
| `GLOBAL_CREATE_CEILING` | `1000` | server-wide valid create admissions per minute |
| `BAN_THRESHOLD` | `600` | per-IP requests/min that trigger an escalating ban |
| `PER_IP_BUDGET` | 2% of worst-case store bytes | maximum unexpired ciphertext bytes admitted per source |
| `PER_IP_ROW_BUDGET` | 2% of `MAX_SECRETS` | maximum unexpired rows admitted per source |
| `STATE_CALL_TIMEOUT_MS` | `1000` | bounded state-owner call timeout (`100..10000`) |
| `OPERATOR_NAME` | required in prod | operator/data-controller name on `/terms` |
| `ABUSE_EMAIL` | required in prod | abuse/removal contact on `/terms` |
| `JURISDICTION` | required in prod | governing law on `/terms` |
| `SECURITY_EMAIL` | required in prod | vulnerability contact in RFC 9116 output |
| `SECURITY_POLICY_URL` | required in prod | HTTPS disclosure-policy URL without literal whitespace/control characters |
| `BURNERPAD_REVISION` | full 40-char SHA in prod | source identity reported by `/api/stats` |
| `BURNERPAD_IMAGE_DIGEST` | exact `sha256:` digest in prod | immutable OCI identity reported by `/api/stats` |
| `RELEASE_COOKIE` | required at runtime | fresh per-deployment Erlang distribution cookie |

**Terms / Acceptable-Use.** The `/terms` page renders the operator's terms from the three variables above,
which are **required in a production build**. The app refuses to boot if any are missing, preventing a
fork from publishing another operator's identity by accident. The repo ships
[`TERMS.template.md`](../TERMS.template.md) with the same wording plus operator legal notes. This is a
content/operator concern, not a security control, and is **not legal advice** — a public-instance operator
should have it reviewed. It pairs with reactive notice-by-email → operator purge-by-id and temporary
per-network-source limits/bans (§9), which is the only moderation possible
under E2E.

---

## 12. Running & deploying

The app serves plain HTTP. The production recipe in [`DEPLOYMENT.md`](../DEPLOYMENT.md) exposes **zero inbound
ports**: cloudflared dials out and forwards HTTP over a private Compose bridge; Cloudflare terminates TLS.
Administration is over Tailscale SSH. The app needs no database, migrations, or asset build step.

- **Development:** `mix deps.get && iex -S mix` (or `mix run --no-halt`).
- **Production:** GitHub Actions archives the exact parent+nested source with an attested SPDX SBOM and
  publishes public, signed/attested, SBOM-equipped GHCR images only after the complete test workflow
  succeeds. Ansible resolves and verifies an exact image digest before deployment.

For production, use the Ansible recipe under `ops/`: read-only/cap-dropped containers, bounded memory and
PIDs, disabled core/crash dumps, loopback-only Erlang distribution, deny-all inbound UFW, Tailscale admin,
Cloudflare Tunnel ingress, an app network with no internet egress, automatic security updates, bounded
logs, an `error`-only local tunnel log, and an external heartbeat. The root-only hourly diagnostic keeps
approximately 12 months of capability-free operational counters and resource samples; application/tunnel
logs remain size-bounded.
Run with swap disabled so in-memory ciphertext is not paged to disk. Cloudflare still processes edge
connection metadata; disable unneeded log export, exclude PII where available, and choose the shortest
suitable vendor retention.

---

## 13. Project layout

```
mix.exs                          # project + deps ({:bandit, ...}); elixir ">= 1.18"
mix.lock
lib/burnerpad/
  application.ex                 # OTP application + supervision tree
  config.ex                      # runtime config from env vars (see §11): load!/0 + getters/defaults
  process_metrics.ex             # shared capability-free process mailbox metrics
  store.ex                       # in-memory ETS secrets: create/peek/reveal/burn/sweep + cap
  abuse.ex                       # weighted rate limits + byte budget + bans + aggregate metrics
  daily_stats.ex                # {UTC day, homepage requests, secrets created}; no identifiers
lib/burnerpad_web/
  router.ex                      # Plug.Router: the routes in §7 + the plug pipeline
  abuse_plug.ex                  # ban short-circuit + dynamic-route counting (static/health bypass)
  client_ip.ex                   # resolve real client IP (REAL_IP_HEADER / trusted proxies) -> /32 & /64
  security_headers.ex            # the response headers in §10 + the no_store/1 cache policy (one seam)
  crypto_assets.ex               # boot-verify all served crypto assets against committed SRI hashes
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
lib/burnerpad_web/router.ex      # dynamically renders RFC 9116 contact from operator configuration
test/
  burnerpad/                     # Store + Abuse unit tests (ExUnit)
  burnerpad_web/                 # router_test.exs (HTTP surface) + client_ip_test.exs (trusted-proxy keying)
  crypto/core_test.cjs           # Node unit tests for the crypto-app.js DOM-free Core (mix test.core)
  smoke/                         # Node tests for privacy-safe canary reports + public edge source contract
  support/                       # test helpers
  browser/                       # optional Playwright smoke suite (real Chromium; dev/CI only)
docs/ARCHITECTURE.md             # this document
CONTEXT.md                       # self-contained repository handoff doc
README.md                        # project readme / quickstart
DEPLOYMENT.md                    # root production runbook: GHCR artifacts + Ansible + operations
SECURITY.md  CONTRIBUTING.md  DCO  LICENSE  TERMS.template.md   # governance / legal
.github/workflows/               # tests/DCO, GHCR release, audits, public canary, recovery drill
Dockerfile
ops/                              # Ansible bootstrap/harden/deploy/monitor recipe; see root DEPLOYMENT.md
```

---

## 14. End-to-end lifecycle (what exists, and where)

```
CREATE
  browser: plaintext -> encrypt (key/passphrase never leave the browser) -> blob
  POST /api/secrets {blob}
  server: store {id, blob(ciphertext), sha256(mgmt_token), expires_at} IN RAM
          return {id, mgmt_token}
  browser: build key-less link /s/<id>; passphrase is shared separately

SHARE
  link and passphrase travel over separate channels

CLAIM (at most once)
  GET  /s/:id            -> non-burning interstitial (preview-bot safe)
  POST /api/secrets/:id/reveal (JSON) -> :ets.take removes the row atomically for at most one handler
  browser: decrypt locally with the derived passphrase key -> plaintext shown
  the row no longer exists; a second reveal returns the generic 404
  if the first response is lost, delivery/decryption is unknown; no automatic retry occurs
  a deliberate retry may claim only if the first request did not complete the atomic take

DESTROY (any of)
  - reveal consumes it
  - the owner calls POST /api/secrets/:id/burn with the management token
  - the TTL sweep deletes it after expiry
  - a restart empties all of RAM

In an uncompromised official client flow, plaintext, keys, and passphrases do not reach the server. The
server handles IDs, ciphertext, and management tokens transiently but excludes them from operational logs.
```

---

## 15. Implementation status & verification

The server is fully implemented (Elixir + Bandit; the modules in §13) with an automated test suite and
live HTTP verification.

**Automated tests** (`mix test`) cover:
- **Store** — id format/uniqueness, non-burning peek, atomic burn-on-read, **at-most-one winner under a
  100-way concurrent stampede**, management-token revoke, id normalization (case/dash/Crockford folding),
  the concurrent hard `MAX_SECRETS` cap, TTL clamping, and expiry sweeping.
- **Abuse** — weighted per-IP rate limiting, race-free per-source byte budgets, escalating bans (incl.
  strike escalation), the global aggregate ceiling, and aggregate metrics.
- **Browser (headless, optional)** — Playwright drives Chromium, Firefox, WebKit, and mobile WebKit through the
  passphrase-only UI: passphrase create → key-less link → chip reveal with a wrong-order-then-correct retry
  (a single network burn, retried locally); **pasting the whole phrase at once** (every word chipped,
  including the last); the tag field (Regenerate, remove-a-word warning, write-your-own); Space/Tab
  committing a word; the always-active create button + create→burn→reset UX; a `#fragment` (link-mode)
  reveal URL refused as unsupported; and the strict CSP + SRI holding with **no console errors**. Kept
  isolated under `test/browser/`; not a runtime dependency.
- **Router** — the create page (three SRI scripts, **no inline scripts**, the full CSP + hardening
  headers), create→peek→reveal→`404`, revoke, daily aggregate activity transparency, the input limits (oversized blob
  `400`, over-cap body rejected before buffering, empty `400`), `MAX_SECRETS` `503`, per-IP `429`,
  static-asset serving with SRI matching, and JSON `404`s.

**Live-verified over HTTP** (dev server and a packaged `mix release`): the full create→share→reveal→burn
lifecycle; second-reveal `404`; the oversized-blob `400`, over-body `413`, and empty `400` limits; the
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
`POST /api/secrets/:id/reveal` covers the programmatic take — confirming create → claim → decrypt and at-most-once
the same generic `404` as every unavailable ID on re-take. The server remains fully crypto-agnostic
(stores/relays any envelope verbatim).
