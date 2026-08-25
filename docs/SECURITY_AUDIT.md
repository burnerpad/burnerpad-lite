# Security Audit & Fix Guide

**Audited:** `main` @ `155b76f` · **Date:** 2026‑08‑21 · **Reviewer:** automated multi‑agent audit, findings hand‑verified against a running build.

> **Snapshot, not current-state documentation.** The findings below describe the audited `main` commit and
> intentionally preserve the vulnerable paths/reproduction steps. Remediation status lives in
> the historical [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md); the current architecture lives in
> [`ARCHITECTURE.md`](ARCHITECTURE.md).

> **Who this is for.** You don't need to be a security specialist to use this document. Every
> finding below is written to answer four questions: *what's wrong, why it matters, how you can see it
> for yourself,* and *exactly what to change.* Scary‑looking terms (EPMD, HPACK, SRI…) are defined in
> the [Glossary](#glossary). If you read nothing else, read [Start here](#1-start-here) and
> [The fix plan](#7-the-fix-plan).

---

## Table of contents

1. [Start here: what this service promises](#1-start-here)
2. [How to read this report](#2-how-to-read-this-report)
3. [At a glance](#3-at-a-glance)
4. [Glossary](#glossary)
5. [The findings](#5-the-findings)
   - [Critical](#critical)
   - [High](#high)
   - [Medium](#medium)
   - [Low & hardening](#low--hardening)
6. [What the codebase already gets right](#6-what-the-codebase-already-gets-right)
7. [The fix plan](#7-the-fix-plan)
8. [Appendix: how to re‑verify everything yourself](#8-appendix)

---

## 1. Start here

Burnerpad shares **one‑time secrets**. You paste a secret, your **browser encrypts it**, and the server
only ever stores an unreadable blob. The recipient opens it **once**, and it's destroyed. The whole point
is that **the server never sees your plaintext** and **nothing is kept after it's read**.

So a security audit here is really asking: *do the promises hold?* Concretely —

| The promise | What would break it |
|---|---|
| The server can't read your secret | Anyone getting code execution on the server, or the plaintext/keys touching the server |
| A secret is read exactly **once** | Something reading or destroying it that isn't the intended recipient |
| **Nothing is written to disk** | A secret id, ciphertext, or IP ending up in a log file or crash dump |
| You can't be linked to a secret | Logs, stats, or timing that connect *who* to *which secret* |
| The page's crypto code is trustworthy | A tampered script running in the browser |
| Abuse is rate‑limited | Any request path that skips the rate limiter |

Most of the findings below are a promise from that table not quite holding. The good news: the design is
solid and most fixes are small. The bad news: a couple of defaults (one from Elixir's own tooling, one
old dependency) quietly punch through several promises at once.

---

## 2. How to read this report

**Severity** — how much you should care, in plain terms:

| Badge | Means | Rule of thumb |
|---|---|---|
| 🔴 **Critical** | Someone can fully break the core promise (read every secret / run code on the server) | Fix before the next deploy |
| 🟠 **High** | A real, reachable attack or a broken promise, but needs a condition (a guessed id, log access, a specific deploy) | Fix this week |
| 🟡 **Medium** | Weakens a defense, or a claim in the docs isn't true | Plan it in |
| ⚪ **Low / hardening** | Best‑practice gap, small blast radius, or defense‑in‑depth | Backlog |

**Each finding has the same shape:**

- **What's wrong** — the plain‑English version.
- **Why it matters** — a short "here's how it actually goes wrong" story.
- **See it yourself** — a command you can run to watch it happen (where practical).
- **The fix** — the exact change, ready to copy.

You do **not** fix these top‑to‑bottom. Use [The fix plan](#7-the-fix-plan) — it's ordered by priority and
grouped so related edits happen together.

---

## 3. At a glance

| # | Sev | Issue (plain language) | File |
|---|-----|------------------------|------|
| C1 | 🔴 | The production build quietly opens a remote‑control back door into the server | `Dockerfile` |
| H1 | 🟠 | An old web‑server library has two known denial‑of‑service bugs, and the vulnerable path skips our rate limiter | `mix.lock` |
| M1 | 🟡 | Nothing independent proves the browser crypto code wasn't tampered with (the integrity check checks the file against itself) | `crypto_assets.ex` |
| M2 | 🟡 | Any website can silently make a visitor's browser burn/destroy a secret | `router.ex:23` |
| M3 | 🟡 | The reverse proxy lets a client fake its own IP address, defeating bans | `nginx.conf:24` |
| M4 | 🟡 | The production image is built without the lock file, so what ships isn't what was tested | `Dockerfile:14` |
| M5 | 🟡 | Bad configuration values (like `0` or negative) are silently accepted | `config.ex:63` |
| M6 | 🟡 | The docs/legal page claim privacy properties the code doesn't actually provide | `ARCHITECTURE.md`, `pages.ex` |
| M7 | 🟡 | A fork that forgets to set env vars publishes **someone else's** company name and abuse email | `config.ex:59` |
| M8 | 🟡 | Request logging runs before the rate limiter and can be spammed to bury evidence | `router.ex:19` |
| M9 | 🟡 | CI has no advisory gate and no daily scan — a new CVE against existing deps goes unnoticed | `test.yml` |
| M10 | 🟡 | GitHub Actions use movable tags and broad permissions | `test.yml` |
| M11 | 🟡 | The secret textarea allows spellcheck/autofill, which can send the plaintext to third parties | `pages.ex:45` |
| M12 | 🟡 | Secret ids in the on-disk log break the "nothing on disk" promise and let a log-reader destroy (not read) secrets | `router.ex:19` |
| M13 | 🟡 | One IP can fill the store and block all creation; the clean fix must avoid an IP↔secret link | `store.ex:32` |
| L1–L12 | ⚪ | Twelve smaller hardening items — see [Low & hardening](#low--hardening) | various |

Full count: **1 critical, 1 high, 13 medium, 12 low/hardening.** (This guide merges the raw audit's 27
findings where several described the same root cause.)

---

## Glossary

Read this once and the findings stop looking intimidating.

- **BEAM / "the node"** — the running Erlang virtual machine; the single OS process that *is* the app.
- **ETS** — Erlang's built‑in in‑memory table store. Burnerpad keeps all live secrets in an ETS table
  called `:bp_secrets`. It lives in RAM only.
- **Erlang distribution** — a built‑in feature that lets two BEAM nodes connect over the network and
  **run code inside each other**. It's gated by a single shared password called the *cookie*. If you have
  the cookie and can reach the node, you can do *anything* the app can do.
- **EPMD (Erlang Port Mapper Daemon)** — a tiny directory service (TCP **4369**) that tells callers which
  port a named node is listening on. If EPMD is running, distribution is on.
- **cookie** — the shared secret for distribution. Same cookie + network reach = full remote control.
  It's a **256‑bit cryptographically random token** — `Base.encode32(:crypto.strong_rand_bytes(32))`, 56
  uppercase characters (`mix/lib/mix/release.ex`). Mix **mints a fresh one on `mix release` whenever no
  `releases/COOKIE` file exists yet**, and reuses the existing file on later builds — so a clean build
  (and every Docker image built from scratch, since `_build` doesn't persist) gets a **new** random
  cookie, and every container started from a single image shares that one. Being random makes it
  unguessable over the network, but in C1 that doesn't help: it's stored as a **readable file** in the
  image, so its randomness protects against *guessing*, not against *reading*. (This is separate from the
  auto‑generated `~/.erlang.cookie` the VM writes when you start distribution *without* a release — that
  older, weaker one is what "weak Erlang cookie" warnings usually refer to; it is **not** what a
  `mix release` uses.)
- **release** — the self‑contained production build that `mix release` produces (what the Docker image
  runs).
- **the Plug pipeline** — the ordered list of steps every HTTP request passes through, written as
  `plug(...)` lines in `router.ex`. **Order matters:** a request only reaches step 5 after passing
  steps 1–4.
- **rate limiter / `AbusePlug`** — the step that counts requests per IP and blocks abusers. It's a plug,
  so anything that happens *below* the plug pipeline never gets counted.
- **HTTP/2 & h2c** — a newer, faster version of HTTP. "h2c" means HTTP/2 without TLS (plain text).
  "Prior knowledge" means a client just starts speaking HTTP/2 without negotiating first.
- **HPACK** — the header‑compression format HTTP/2 uses. Decoding it happens deep in the web‑server
  library, *before* our pipeline runs.
- **SRI (Subresource Integrity)** — an `integrity="sha384-…"` attribute on a `<script>` tag. The browser
  computes the hash of the downloaded file and **refuses to run it** if it doesn't match. It protects you
  from a script that got swapped out (e.g. by a CDN or a hacked server) — *but only if the expected hash
  comes from a trustworthy place.*
- **CSRF (Cross‑Site Request Forgery)** — tricking a visitor's browser into making a request to *our*
  site from *someone else's* page. Classic CSRF abuses login cookies; Burnerpad has no cookies, but as M2
  shows, it still has a CSRF‑shaped problem.
- **CSP (Content‑Security‑Policy)** — a response header that tells the browser exactly what it's allowed
  to load and run. A strict CSP is what stops an injected `<script>` from doing anything.
- **burn‑on‑read** — the secret is deleted the moment it's successfully read. Burnerpad does this
  correctly with an atomic operation (`:ets.take/2`).
- **"the id is the credential"** — there's no separate password protecting a secret *on the server*.
  Whoever knows the secret's id can consume or destroy it. That's by design — but it's why leaking ids
  (M12) is serious.

---

## 5. The findings

### Critical

<a name="c1"></a>
#### C1 🔴 The production build opens a remote‑control back door by default

**Where:** `Dockerfile` (the `CMD` line), plus the absence of any distribution override.
**Root promise broken:** *the server can't read your secret*, *code can't run on the server*,
*nothing to seize*.

**What's wrong.** When you build the app with `mix release` and start it with `bin/burnerpad start`,
Elixir's tooling turns on **Erlang distribution by default** and bakes a **cookie** (the distribution
password) into the image. The running node then listens for other nodes on the network — EPMD on port
4369 plus a data port — bound to `0.0.0.0` (all network interfaces). Nobody asked for this; it's just the
default nobody turned off.

**Why it matters.** Distribution isn't "an API" — it's "run any code on this node." Here's the story:

1. The cookie is the same in every container built from a given image, and it sits in a layer of that
   image. Anyone who can pull the image, or who lands on a neighbouring container (like the nginx
   sidecar), can read it.
2. With the cookie and network reach, they connect a node of their own and ask the Burnerpad node to run
   code for them.
3. That code can read the **entire live secrets table straight out of RAM** — every ciphertext blob —
   **without burning any of them**, so the recipients never even know. It can also run shell commands as
   the app user.

This single default defeats *three* promises at once: burn‑on‑read, "the server can't read secrets," and
"there's nothing on disk to seize." It also contradicts the compose file's own comment that "NO inbound
ports are opened."

> ⚠️ This was reproduced end‑to‑end during the audit on a real production build: a separate hostile node,
> using only the baked cookie, dumped a live ciphertext row without burning it and executed a shell
> command on the app node.

**See it yourself.**

```bash
MIX_ENV=prod mix release --overwrite
# 1) There's a baked-in cookie:
cat _build/prod/rel/burnerpad/releases/COOKIE ; echo
# 2) Distribution is on by default:
grep RELEASE_DISTRIBUTION _build/prod/rel/burnerpad/bin/burnerpad
#    -> RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"sname"}"   (sname = ON)
# 3) Start it, then look for the EPMD listener on 4369:
PORT=4901 _build/prod/rel/burnerpad/bin/burnerpad start &
sleep 5 ; ss -lntp | grep 4369     # <- EPMD listening = distribution open
```

**The fix (chosen here: loopback distribution).** Takedowns use
`bin/burnerpad rpc 'Burnerpad.Store.purge("ID")'` (`ARCHITECTURE.md §9`), and `rpc` needs Erlang
distribution — so rather than turn it off, **bind it to loopback**: `rpc` still works from inside the
container, but EPMD and the dist port vanish from every other interface. Create `rel/env.sh.eex`:

```sh
export RELEASE_DISTRIBUTION=sname
export ERL_EPMD_ADDRESS=127.0.0.1
export ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {127,0,0,1}"
```

and register a release in `mix.exs`:

```elixir
def project do
  [
    # ...existing keys...
    releases: [burnerpad: [include_executables_for: [:unix]]]
  ]
end
```

Verify after: `bin/burnerpad rpc "IO.puts(node())"` works inside the container, while `ss -lntp` shows 4369
and the dist port on `127.0.0.1` only.

*Simpler alternative — if a deployment never uses `rpc`* (takedowns by full restart, accepting that a
restart nukes every live secret): one line, `ENV RELEASE_DISTRIBUTION=none` in the `Dockerfile`, opens
**no** EPMD and **no** dist port at all. This instance keeps targeted purges, so it uses loopback.

> **Don't** try to fix this by making the ETS table "private." The attacker runs code *on the node*, so
> table visibility makes no difference. The fix is closing distribution, full stop.

##### Does this affect *my* deployment? — C1 in general vs. C1 behind a Cloudflare tunnel

C1 is **deployment‑conditional.** The 🔴 above is the *worst case*. Whether it applies to **you** comes
down to one question: *can anything an attacker controls actually reach port 4369 (EPMD) or the
distribution port on the node?* In a locked‑down tunnel deployment, the answer is **no** — and the finding
drops from "remote back door" to "defense‑in‑depth."

**Reachability by deployment mode:**

| How you run it | Can a *remote* attacker reach the Erlang node? | What C1 means for you |
|---|---|---|
| **Cloudflare tunnel + closed inbound ports** (this repo's `docker-compose.yml`) | **No** | 🟡 Defense‑in‑depth only — see residual risk below |
| **`docker run -p 4000:4000`** (README quick‑start) | **No** — only 4000 is published, not 4369 (a *host‑local* user still can) | 🟡 Fine — until someone adds `--network host` or `-p 4369:4369` |
| **Bare‑metal `mix release` on a public host** (README) | **Yes — if the host firewall doesn't block 4369** | 🔴 Remote RCE — this is the genuinely dangerous case |

**Why the tunnel setup is safe.** Three things all have to be true for someone to reach the node, and in
the tunnel deployment none of them are:

- **The tunnel is HTTP‑only and outbound.** `cloudflared` dials *out* to Cloudflare and only forwards your
  hostname to nginx (`127.0.0.1:4024`). It never forwards 4369 or the distribution port — they aren't in
  its ingress rules at all.
- **The app container publishes no port.** In `docker-compose.yml` the app has `expose: 4000`
  (intra‑network only) and **no `ports:` mapping**, so the node isn't on the host's public interface at
  all — only nginx can reach it, over the internal bridge.
- **`0.0.0.0` here means *the container*, not the world.** EPMD binds `0.0.0.0` *inside the container* —
  that's the container's loopback plus the `172.28.0.0/16` internal bridge, not your box's public IP.
  (When the audit first observed `0.0.0.0:4369`, that was a **bare‑metal** run, where `0.0.0.0` really is
  the host's interfaces — which is exactly why the bare‑metal row above is the dangerous one.)

**The residual risk that remains even with every inbound port closed** — and why the one‑line fix is still
worth applying:

1. **Lateral movement from a compromised nginx.** nginx is your one internet‑facing component (behind
   Cloudflare, but still parsing attacker traffic) and it sits on the same bridge as the node. If nginx is
   ever compromised, distribution turns *"attacker controls nginx"* into *"attacker runs code on the BEAM
   and reads every live ciphertext row straight out of RAM, without burning any of them."* With
   distribution **off**, a popped nginx can only speak HTTP to the app — it can't touch the runtime or the
   secrets table. For a zero‑knowledge product, keeping that blast radius small **is** the point.
2. **The cookie ships inside the image.** Harmless while the image stays on your box, but it travels with
   the image the moment it's pushed to a registry or shared.
3. **The bridge is not a security boundary.** Any container you add to that compose network later (metrics,
   a debug shell, a future service) can reach the node with the cookie.

**Bottom line for a hardened deployment.** C1 is **not** a "you're already owned" emergency for the tunnel
setup — it's defense‑in‑depth, and for you it's really a 🟡. Apply `ENV RELEASE_DISTRIBUTION=none` anyway:
it costs nothing (the app never uses distribution), it shrinks the blast radius of an nginx compromise, and
it protects anyone who follows the **bare‑metal** instructions, where C1 is a real remote‑RCE 🔴.

---

### High

<a name="h1"></a>
#### H1 🟠 Outdated web‑server libraries with known DoS bugs — on a path the rate limiter can't see

**Where:** `mix.lock` (pins `bandit 1.12.0`, `hpax 1.0.3`, `plug 1.20.1`), plus
`application.ex:18`.
**Root promise broken:** *abuse is rate‑limited* / availability.

**What's wrong.** The lock file pins old versions of three libraries. Running the standard audit tool
reports **six** advisories and exits with an error:

```
bandit 1.12.0 — CVE-2026-74836 (HIGH)  HTTP/2 window starvation pins processes forever
bandit 1.12.0 — CVE-2026-75484 (MED)   HTTP/2 headers with CR/LF/NUL passed through unchecked
hpax   1.0.3  — CVE-2026-58226 (HIGH)  unbounded HPACK decoding → CPU blow-up
plug   1.20.1 — RETIRED, + 2 lower advisories (not reachable in this app)
```

Two of these are **HIGH‑severity, unauthenticated denial‑of‑service** bugs in HTTP/2 handling.

**Why it matters.** Two things line up badly:

1. **HTTP/2 is switched on by default**, even on the plain‑HTTP listener. A client can just start speaking
   it ("h2c prior knowledge") and the server accepts.
2. HTTP/2 framing and header decoding (where these bugs live) happen **inside the web‑server library,
   before the Plug pipeline runs.** That means `AbusePlug` — the rate limiter and ban system this project
   carefully built — **never sees this traffic.** Per‑IP limits, bans, and the global ceiling give *zero*
   protection.

So an attacker can hold open a single connection and pin the server's processes or spin its CPU until it
falls over — and **when the node dies, every secret in RAM dies with it.**

> Reachability depends on deployment. The shipped `docker compose` setup accidentally shields it (nginx
> talks HTTP/1.1 to the app), but `docker run -p 4000:4000` from the README, a bare‑metal release, dev
> mode, and any container reaching the app directly are all exposed.

**See it yourself.**

```bash
# HTTP/2 is accepted on the cleartext port:
curl --http2-prior-knowledge -o /dev/null -w "%{http_version}\n" http://127.0.0.1:4000/
#   -> 2

# The audit tool flags the advisories and exits non-zero:
mix deps.get && mix hex.audit ; echo "exit: $?"
```

**The fix — do both halves.**

*Update the libraries* (the existing `{:bandit, "~> 1.5"}` requirement already allows the fix; only the
lock is stale):

```bash
mix deps.update bandit      # -> bandit 1.12.5, hpax 1.0.4, plug 1.20.3, plug_crypto 2.2.0
mix hex.audit               # must now exit 0
```

*And close the door permanently* — this app has no HTTP/2 or WebSocket feature, so turn both off in
`application.ex:18`:

```elixir
{Bandit,
 plug: BurnerpadWeb.Router,
 scheme: :http,
 port: Burnerpad.Config.get(:port),
 # HTTP/1.1 only behind the proxy; there is no WebSocket route. This removes the
 # entire HTTP/2 + HPACK attack surface regardless of library version.
 http_2_options: [enabled: false],
 websocket_options: [enabled: false]}
```

Updating alone fixes today's CVEs; disabling HTTP/2 protects you from the *next* one too.

---

### Medium

These weaken a defense or make a documented claim untrue. None is a one‑step catastrophe, but together
they're where the model frays.

<a name="m1"></a>
#### M1 🟡 The script‑integrity check verifies the file against itself

**Where:** `crypto_assets.ex`.
**What's wrong.** SRI is supposed to guarantee the browser only runs the *exact* crypto code you
published. But here the "expected" hash is **computed at runtime from the very file being served.** If an
attacker can change the served file, the app just hashes the changed file and emits a matching
`integrity=` attribute — so the browser happily runs the tampered script. The check always passes, which
means it proves nothing about *authenticity*.

**Why it matters.** The docs claim "a host that tampered with a script would be refused by the browser."
That's only true if the expected hash comes from somewhere the attacker *can't* also change. Right now it
doesn't.

**The fix.** Commit the expected hashes to the repo and check them at boot (fail to start on mismatch):

```elixir
# crypto_assets.ex
@expected %{
  "vendor/crypto-js/burnerpad-crypto.js" => "sha384-…",  # from the trusted source, committed here
  "crypto/crypto-app.js"                 => "sha384-…",
  "crypto/theme.js"                      => "sha384-…"
}

def verify! do
  for {rel, want} <- @expected, sri(rel) != want do
    raise "SRI mismatch for #{rel}: served file does not match committed hash"
  end
  :ok
end
```

Call `CryptoAssets.verify!()` from `application.ex` on startup. Now the pin lives in version control, and
tampering with a served file makes the app refuse to boot instead of silently re‑blessing it. (Also pin
`crypto.css`, which currently has no integrity check at all.)

<a name="m2"></a>
#### M2 🟡 Any website can make a visitor's browser destroy a secret

**Where:** `router.ex:23` and the reveal/burn routes — there's no `Origin`/`Sec-Fetch-Site` check.
**What's wrong.** `GET /api/secrets/:id` burns the secret, and `POST /s/:id/reveal` is a CORS "simple
request." Neither checks *where the request came from.* So a page the victim visits can embed
`<img src="https://burnerpad/api/secrets/KNOWN_ID">` (or a cross‑origin `fetch`) and the victim's browser
will happily burn that secret. The attacker can't *read* the response, but destroying it — or running id
guesses from many victims' IPs to dodge the rate limiter — is the damage.

> Reproduced in the audit: a cross‑origin `GET /api/secrets/<id>` returned 200 and the secret was gone
> afterwards.

**The fix — primary gate: require `application/json` on the mutating endpoints.** The cross-site burn is
possible only because a request can reach a burning route as a CORS "simple request." Two moves close it:

**1. Remove the burning GET and move every JSON endpoint under `/api`** — so no endpoint burns on a GET
(a burning GET is what makes `<img>`/prefetch dangerous), and `/s/:id` is left as the HTML page people paste:

| now | after |
|-----|-------|
| `POST /api/secrets` | keep — create |
| `GET  /api/secrets/:id` | **removed** (duplicate burning GET) |
| `POST /s/:id/reveal` | `POST /api/secrets/:id/reveal` |
| `POST /s/:id/burn` | `POST /api/secrets/:id/burn` |
| `POST /s/:id/report` | `POST /api/secrets/:id/report` |
| `GET  /stats.json` | `GET /api/stats` (no alias) |
| `GET  /s/:id` | keep — **HTML interstitial**, non-burning |

**2. Require `Content-Type: application/json` on the mutating endpoints.** Tighten `Plug.Parsers` to
`pass: []` so a non-JSON body gets a clean `415` (that's L3), and have `crypto-app.js` send the content-type
on the reveal fetch (create and burn already do). A cross-site `<form>` can't set `application/json`, and a
cross-site `fetch` with it triggers a CORS preflight the server never approves — so a forged burn is
rejected **before it runs, on every browser.** This is the load-bearing gate. (I verified the current
exposure: `burn`/`create` already send `application/json` and are safe today; only `reveal` — which sends
*no* content-type — is the forgeable one, alongside the burning GET we're deleting.)

Update `crypto-app.js` (the reveal/burn/report fetch paths + the reveal content-type), the README curl
examples, and repoint the compose healthcheck to a new `GET /healthz` so it stops hitting `/stats`.

**Optional defense-in-depth — a GET-exempt `Sec-Fetch-Site` plug.** For a second layer, reject cross-site
*unsafe* methods only. It **must** exempt GET/HEAD, or it 403s a legitimate cross-site link-open — clicking
a `/s/:id` link from Slack sends `Sec-Fetch-Site: cross-site`, and blocking that breaks the whole product:

```elixir
defmodule BurnerpadWeb.CrossSite do
  import Plug.Conn
  @behaviour Plug
  def init(o), do: o
  def call(%{method: m} = conn, _) when m in ["GET", "HEAD", "OPTIONS"], do: conn  # link-opens, assets
  def call(conn, _) do
    case get_req_header(conn, "sec-fetch-site") do
      [s] when s in ["same-origin", "none"] -> conn
      [] -> conn                          # non-browser clients (curl); the content-type gate still applies
      _  -> conn |> send_resp(403, ~s({"error":"cross-site"})) |> halt()
    end
  end
end
```

---

<a name="m3"></a>
#### M3 🟡 The reverse proxy lets clients fake their IP address

> **Superseded by the no-nginx deploy** (see IMPLEMENTATION_PLAN.md Part B): cloudflared talks to the app
> directly and sets `CF-Connecting-IP`; the app trusts only the cloudflared bridge subnet
> (`TRUSTED_PROXIES`). The nginx fix below applies only if you keep an nginx hop.

**Where:** `nginx.conf:24`.
**What's wrong.** nginx forwards whatever the client *sent* in the `CF-Connecting-IP` header
(`proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;`) rather than overwriting it with the real
source. The app trusts that header from a whole `/16` subnet. So anyone who can reach nginx directly can
set `CF-Connecting-IP` to any value.

**Why it matters.** The abuse key *is* that IP. An attacker can pick a fresh fake IP for every request to
evade bans and rate limits entirely, or set it to a **victim's** IP to get that victim banned.

**The fix.** Have nginx set the header from the real, verified peer and trust only Cloudflare's ranges:

```nginx
# devops/nginx.conf — trust only real Cloudflare edges, then set the header from the verified peer.
set_real_ip_from 173.245.48.0/20;   # ... full published Cloudflare list ...
real_ip_header CF-Connecting-IP;
proxy_set_header CF-Connecting-IP $remote_addr;   # overwrite, don't pass through
```

Also narrow the app's `TRUSTED_PROXIES` from the whole `/16` to nginx's single `/32`.

---

<a name="m4"></a>
#### M4 🟡 The production image is built without the lock file

**Where:** `Dockerfile:14` (`COPY mix.exs ./` — no `mix.lock`).
**What's wrong.** The build copies `mix.exs` but not `mix.lock`, then runs `mix deps.get`. Without the
lock, dependency resolution can pick **different versions than were tested**, and there's no checksum
attestation of what shipped. Ironically it also means the H1 fix (updating the lock) wouldn't even reach
the image.
**The fix.** `COPY mix.exs mix.lock ./`, and add `mix hex.audit` as a build step so a vulnerable image
fails to build.

---

<a name="m5"></a>
#### M5 🟡 Bad configuration values are silently accepted

**Where:** `config.ex:63` (`int/2`).
**What's wrong.** The env‑var parser accepts `0`, negatives, and absurd values without complaint, and
silently ignores anything unparseable (falling back to the default). `MAX_SECRETS=0` disables the service;
`RATE_LIMIT=0` bans everyone; a typo in `PORT` is silently ignored. Misconfiguration becomes a silent
outage or a silent loss of protection.
**The fix.** Validate ranges and fail closed on start‑up:

```elixir
defp int(key, env, min, max) do
  case System.get_env(env) do
    nil -> :ok
    v ->
      case Integer.parse(v) do
        {n, ""} when n >= min and n <= max -> Application.put_env(:burnerpad, key, n)
        _ -> raise "Invalid #{env}=#{inspect(v)} (expected integer in #{min}..#{max})"
      end
  end
end
```

---

<a name="m6"></a>
#### M6 🟡 The docs and legal page claim privacy the code doesn't deliver

**Where:** `docs/ARCHITECTURE.md`, `pages.ex` (`/terms` §9), README.
**What's wrong.** Several statements are no longer true given M12 and C1: "nothing on disk to seize or
subpoena," "we keep no persistent IP‑to‑secret log," and "operational logs are rotated within a short,
bounded window." Because the app logs secret ids to disk (M12), these are **false claims on a published
legal/privacy page** — which is itself a risk (trust, and potentially regulatory).
**The fix.** Fix M12 first, then reconcile the wording. A commit already walked back some over‑claims
(`689af52`); this finding is that the walk‑back was incomplete. After M12 is fixed, the "nothing on disk"
statements become defensible again.

---

<a name="m7"></a>
#### M7 🟡 A fork publishes someone else's company name and abuse contact by default

**Where:** `config.ex:59‑61`.
**What's wrong.** `OPERATOR_NAME`, `ABUSE_EMAIL`, and `JURISDICTION` default to a **real legal entity**
(Impulsa SLU / `abuse@burnerpad.io` / Andorra). A self‑hoster who forgets to override them publishes that
company's terms as their own and **routes real abuse/GDPR/DSA notices to a third party.**
**The fix.** Refuse to boot (or render a clear placeholder) when these aren't set for a non‑canonical
deployment:

```elixir
def operator_name do
  Application.get_env(:burnerpad, :operator_name) ||
    raise "Set OPERATOR_NAME (and ABUSE_EMAIL, JURISDICTION) before serving /terms"
end
```

---

<a name="m8"></a>
#### M8 🟡 Request logging runs before the rate limiter and can be spammed

**Where:** `router.ex:19` (`Plug.Logger` sits above `AbusePlug`).
**What's wrong.** Logging happens *before* the abuse check, and it logs the raw path. A banned attacker's
requests are still logged, so they can flood the log (the audit measured ~1.2 KB/request) and **evict the
30 MB of history** — including the very evidence of their abuse — within seconds.
**The fix.** Fold into M12: use the redacting `RequestLogger` and place it **below** `AbusePlug`, so banned
traffic is rejected before it can write anything.

---

<a name="m9"></a>
#### M9 🟡 CI doesn't fail on vulnerable dependencies

**Where:** `.github/workflows/test.yml` — and the absence of any *scheduled* audit.
**What's wrong.** Two gaps. **(1)** On a push/PR, `mix deps.get` prints all six advisories (H1) and
**exits 0**, so CI stays green — exactly why H1 went unnoticed. **(2)** Even with a PR gate, advisories are
usually disclosed against dependencies you **already** have; with no PR that day, nothing re-checks them, so
you'd learn about a fresh CVE only the next time someone happens to open a PR.

**The fix — three parts.**

*1. Fail the normal build on any advisory* (add to `test.yml`):

```yaml
- run: mix hex.audit       # non-zero exit fails the build
```

*2. Run the audit on a schedule, so a newly-disclosed CVE against unchanged code pages you.* Add
`.github/workflows/deps-audit.yml`:

```yaml
name: deps-audit
on:
  schedule:
    - cron: '17 6 * * *'    # every day at 06:17 UTC
  workflow_dispatch: {}     # ...and on demand
permissions:
  contents: read
  issues: write             # only for the optional issue-on-failure step
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4          # pin to a commit SHA — see M10
        with: { submodules: recursive }
      - uses: erlef/setup-beam@v1          # pin to a commit SHA — see M10
        with: { otp-version: '29.0.5', elixir-version: '1.20.2' }
      - run: mix deps.get
      - run: mix hex.audit                 # fails the scheduled run on any advisory
      - if: failure()                      # optional: open a tracking issue (first-party gh, no secrets)
        env: { GH_TOKEN: ${{ github.token }} }
        run: |
          gh issue create \
            --title "Dependency advisory ($(date -u +%F))" \
            --body  "Scheduled mix hex.audit failed — see the run logs." \
            --label security || true
```

**Getting the email.** You don't need a third-party SMTP action (which would add exactly the kind of
dependency this audit warns about). GitHub already emails you when a **scheduled workflow fails** — turn on
*Settings → Notifications → Actions → "Send notifications for failed workflows only"* on your account. The
optional `gh issue create` step also emails everyone watching the repo and leaves a durable record.

*3. Propose updates automatically.* Add `.github/dependabot.yml` for `mix` (and the `test/browser` npm
project) so version bumps arrive as PRs — which then hit the gate from part 1.

---

<a name="m10"></a>
#### M10 🟡 GitHub Actions use movable tags and broad permissions

**Where:** `.github/workflows/test.yml`, `dco.yml`.
**What's wrong.** Actions are pinned to movable tags (`actions/checkout@v4`) rather than commit SHAs, and
there's no top‑level `permissions:` block, so the default token is broader than needed. The workflow also
documents feeding a `CRYPTO_JS_PAT` secret into a job triggered by pull requests.
**The fix.** Add `permissions: contents: read` at the top, pin actions to SHAs, set
`persist-credentials: false`, and never expose the PAT to fork PRs.

*(The `dco.yml` shell that interpolates `github.event…` was checked and is safe — it uses `env:`
variables, not direct expansion into the shell.)*

---

<a name="m11"></a>
#### M11 🟡 The secret textarea allows spellcheck and autofill

**Where:** `pages.ex:45`.
**What's wrong.** The plaintext‑secret `<textarea>` is the one editable field without
`spellcheck="false"`/`autocomplete="off"`. Browser spellcheckers and some password managers can send field
contents to third‑party servers — meaning your plaintext secret could leave the browser before it's even
encrypted, defeating the entire point.
**The fix.**

```html
<textarea id="bp-input" spellcheck="false" autocomplete="off"
          autocapitalize="off" autocorrect="off" ...></textarea>
```

Also add `translate="no"` to the *revealed* secret block (`pages.ex`), so online translators don't ship
the decrypted text out.

---

<a name="m12"></a>
#### M12 🟡 Secret ids are written to a disk log — breaking the "nothing on disk" promise and letting a log-reader destroy (not read) secrets

**Where:** `router.ex:19` (`plug(Plug.Logger)`), and `docker-compose.yml` (json-file logging).
**Promise broken:** *nothing is written to disk* (and the `/terms §9` "no persistent IP-to-secret log" claim).
**Re-rated:** this was 🟠 High in an earlier draft. Corrected to 🟡 Medium after review — the id does **not** let anyone read a secret; see *What an attacker actually gets*.

**What's wrong.** `Plug.Logger` prints a line for every request, including the **path**. For this app the
path *contains the secret id*, so the app writes lines like:

```
[info] GET /s/ZQ86QMJT
[info] POST /s/ZQ86QMJT/reveal
```

to standard output. In the documented Docker deployment, stdout is captured by the `json-file` log driver
and **written to the host's disk** (up to 30 MB retained). The README, `ARCHITECTURE.md`, and `/terms §9`
all promise nothing is written to disk — so this makes a **published claim untrue**. It also undoes the
*deliberate* `access_log off` in the nginx config one hop away, which was turned off for exactly this
reason.

**What an attacker actually gets — the important nuance.**

- **They do NOT get your secret.** The id only names the *ciphertext*. Decryption needs the passphrase,
  which never touches the server. A **generated** 7-word phrase is ~72 bits; run through PBKDF2 at 600,000
  iterations, an offline crack is on the order of 2⁹¹ operations — infeasible. A log-reader steals
  unreadable bytes. *(Caveat: the UI lets a sender delete the generated words and hand-pick 7 weak ones
  with no enforcement — see [L4](#low--hardening). A blob sealed under a weak, guessable phrase is
  offline-crackable, so "7 words from the list" is the strong **default**, not a guaranteed floor.)*
- **What they CAN do is destroy it.** `POST /s/:id/reveal` and `GET /api/secrets/:id` **burn** the secret
  and need only the id — no passphrase, no token. So a log-reader can consume a secret so the intended
  recipient later gets "already read / gone." That's a griefing/denial break of one-time delivery, and it
  needs no cryptography at all. **This is the real harm**, and it's why "the ciphertext is just garbage"
  doesn't make the finding go away.
- **No who-↔-which link in the app log.** `Plug.Logger` records the method and path but **not** the client
  IP — the project deliberately stopped co-logging the IP next to the id (commits `6715406`, `906c683`).
  So the app's own log alone can't tie a person to a secret. (Cloudflare's edge logs are a separate system,
  outside this repo.)

**Why the rate limiter matters here — and why *logging* the ids is the specific problem.** The abuse
limiter (`AbusePlug`: 240 req/min/IP, escalating bans, a global ceiling) makes **blind id guessing
infeasible.** Ids are 40 bits over a 32-character alphabet, and at 240/min with bans an attacker cannot
enumerate live secrets — that's *by design* and it's a genuine strength (`ARCHITECTURE.md §8`). The limiter
is exactly why short, semi-public ids are safe **as long as they stay unguessed.** The log leak matters
because it hands an attacker a *known-live* id directly, **skipping the guessing barrier the limiter
enforces.** The limiter still caps how *many* logged ids an attacker can act on per minute, and still shuts
down enumeration entirely — but destroying one *specific, already-known* secret is a single request, and no
rate limiter blocks a single request. So the honest one-liner is: **if these ids were never written to
disk, the rate limiter would keep them safe; writing them down is what removes that protection.**

**See it yourself.**

```bash
PORT=4000 mix run --no-halt &        # start the app
# create a secret, then request it, and watch the console:
curl -s localhost:4000/s/SOMEID > /dev/null
#   -> the console prints:  [info] GET /s/SOMEID
```

**The fix.** Replace `Plug.Logger` with a small logger that **redacts the id** and doesn't log the secret
routes verbatim. Create `lib/burnerpad_web/request_logger.ex`:

```elixir
defmodule BurnerpadWeb.RequestLogger do
  @moduledoc "Request logging that never writes a secret id to disk."
  require Logger
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Log the *route shape*, not the concrete id. "/s/ABC123" -> "/s/:id"
    path =
      case conn.path_info do
        ["s", _id | rest] -> Enum.join(["/s/:id" | rest], "/")
        ["api", "secrets", _id] -> "/api/secrets/:id"
        _ -> conn.request_path
      end

    Logger.info("#{conn.method} #{path}")
    conn
  end
end
```

Then in `router.ex`, swap the plug and move it **below** `AbusePlug` — the same edit that fixes
[M8](#m8) (banned traffic is rejected before it can write anything):

```elixir
plug(BurnerpadWeb.SecurityHeaders)   # first, so assets + errors carry the CSP (L6)
plug(Plug.RequestId)
# ...the four Plug.Static blocks go HERE — served BEFORE AbusePlug, so a page load's
#    ~8 asset requests don't burn the per-IP rate limit (L12); Cloudflare edge-caches them.
plug(BurnerpadWeb.AbusePlug)         # now counts only dynamic / secret routes
plug(BurnerpadWeb.RequestLogger)     # redacting, below the limiter
```

---

<a name="m13"></a>
#### M13 🟡 One well-behaved user can fill memory and block everyone from creating secrets

**Where:** `store.ex:32` (the only cap is the global `max_secrets`).
**Impact:** **availability only** — no secret is read, altered, or exposed; the worst case is "service full."
**Re-rated:** was 🟠 High in an earlier draft. Dropped to 🟡 Medium because the *complete* fix (a refunded per-IP quota) would break a core privacy promise (see the ⚠️ below), the honest fix is a modest rate-style cap, and the residual is availability-only with existing backstops.

**What's wrong.** The only limit on stored secrets is a single global cap (`max_secrets`, default 100,000;
the compose file lowers it to 20,000). There's **no per-IP or per-source quota.** A single IP that stays
*under* the request rate limit can keep creating secrets until the global cap is hit.

**Why it matters.** At the default rate limit (240 requests/min), one IP creates 240 secrets/min and fills
100,000 slots in about **7 hours** (or the compose's 20,000 in ~83 minutes). Once full, every other user's
`POST /api/secrets` gets `503 service full`. The attacker keeps topping up as their own secrets expire,
holding the service full indefinitely — all while looking like a single, rate-limit-compliant user. Each
secret can be up to 64 KB, so it's a memory-pressure lever too.

> ⚠️ **Do NOT fix this with a *refunded* per-source quota.** The "obvious" fix — track bytes per IP and
> give them back when a secret is read/expires — requires storing the creator's IP (or a keyed hash) **on
> each secret row**, so removal knows whose counter to credit. That recreates the exact **`IP ↔ secret`
> link the design forbids** (see [M12](#m12), `/terms §9`): a memory dump — or the C1 RCE — would then
> reveal "IP X created secret Y." Trading a privacy invariant for an availability one is the wrong trade
> for this product.

**The fix — a link-free, expiry-bucketed byte budget.** You don't need to refund, and you don't need to
know which secret is whose. Give each IP a **byte budget** (default **2 % of `MAX_SECRETS × max_blob`**,
configurable via `PER_IP_BUDGET`) and file each create's bytes into a bucket keyed by that secret's
**expiry** (`now + ttl`), in ~15-minute slots — **count/bytes only, never a secret id.** `creation_allowed?`
sums the buckets still in the future; the sweep drops past buckets, so a secret stops counting **the moment
its TTL elapses.** Keep it in `Burnerpad.Abuse` (keyed by IP + window, swept, id-free) and gate `create` on
the abuse key the router already computes (`ClientIP.get(conn)`), so `Store` stays IP-free — no
`IP ↔ secret` link ever exists. Over budget ⇒ `429`.

```elixir
# Abuse: bytes filed by EXPIRY slot, per IP. Count-only, NO secret ids, NO refund.
# "bytes whose declared lifetime hasn't run out yet" ~= bytes this IP currently holds.
def creation_allowed?(key, bytes) do
  live = sum_future_buckets(key)                # buckets whose slot is still in the future
  live + bytes <= Config.get(:per_ip_budget)    # default 2% of MAX_SECRETS x max_blob
end
```

Why bucket by *expiry* rather than by a flat create-time window: it **frees budget as each secret's own TTL
passes** — exactly the frequent-CLI-user case. Someone reading in minutes sets `ttl=300`, so their budget
recycles in minutes and their throughput is effectively unlimited. It's a fair, self-selecting deal: you
earn more headroom by honestly declaring a short lifetime, which also costs the server less memory. (Worked
examples live in `ARCHITECTURE.md §9`.)

The one **irreducible** trade-off: a user who sets a *long* TTL but whose secret is read early over-counts
until that long TTL elapses — we can't detect the early read without the forbidden `IP ↔ secret` link. It's
self-correcting (use a shorter TTL), and the operator can raise `PER_IP_BUDGET`. Shared NAT/CGNAT users
share one budget, the same limitation as the existing per-IP rate limiter.

**Backstops that cost no privacy** (lean on these regardless): the global `max_secrets` cap already limits
the worst case to "service full, temporarily" rather than data loss, and a container **`mem_limit`** (see
L9) keeps memory from being the failure mode. With those in place this is close to the volumetric-DoS case
the project already declares out of scope.

---

### Low & hardening

Small blast radius or defense‑in‑depth. Worth doing, not worth blocking a release.

| # | Issue | File | Fix in one line |
|---|-------|------|-----------------|
| L1 | Rate‑limit counter increments before the decision, so a boundary lets ~2× through for one window | `abuse.ex:89` | Check the ceiling *before* counting, or use a sliding window |
| L2 | `/api/stats` is an exact live-activity gauge; the old implementation also full-scanned the ban table per request | `router.ex:166` | Exact capability-free aggregates are accepted by design; active bans are now O(1), and `/healthz` and `/readyz` are separate |
| L3 | A non‑JSON POST body returns `500` instead of `415`; the stack trace goes to the **log** (not the client) | `router.ex:64,128` | Set `pass: []` so unparseable types get a clean `415` |
| L4 | The UI computes a passphrase‑strength "floor" it never actually enforces — 7 self‑chosen words still submit | `crypto-app.js:299` | Gate submit on the number of *generated* words remaining |
| L5 | The reveal POST burns the secret *before* the client has safely stored the blob; a truncated response or reload can lose it | `crypto-app.js:486` | Commit `heldBlob` only after it parses; guard double‑submit |
| L6 | `SecurityHeaders` isn't first in the pipeline, so an error raised in step 1–2 would lack CSP/nosniff headers (narrow: the common 500 path *does* keep them) | `router.ex:18` | Move `plug(SecurityHeaders)` to the top |
| L7 | Decrypted plaintext is left in the DOM after reveal | `crypto-app.js:496`, `pages.ex:174` | `translate="no"`; clear on navigate/pagehide |
| L8 | "Create another" throws away the only copy of the management token | `crypto-app.js:373` | Keep prior `{id, mgmt}` in a session‑scoped list |
| L9 | `erl_crash.dump` isn't disabled and the container filesystem is writable — a crash could spill live ciphertext to disk | `docker-compose.yml` | `ERL_CRASH_DUMP_SECONDS=0`, `read_only: true`, `tmpfs`, `mem_limit`, `pids_limit`, `no-new-privileges`, `cap_drop: [ALL]` |
| L10 | Unicode case‑folding lets different‑looking ids map to the same secret (e.g. dotless‑ı) | `store.ex:135` | Reject non‑ASCII before `String.upcase/1` |
| L11 | Base bases pinned by tag not digest; no `.dockerignore` (so `.git` history enters the build context); OTP drift between dev (29) and image (27) | `Dockerfile` | Digest‑pin bases; add `.dockerignore`; align OTP versions |
| L12 | `AbusePlug` runs *before* `Plug.Static`, so a cold page load's ~8 asset requests all count against the per‑IP rate limit + global ceiling — a NAT/CGNAT population self‑DoSes on legit first visits | `router.ex:22` | Serve `Plug.Static` **above** `AbusePlug` (assets stop counting); edge‑cache `/crypto` + `/fonts` at Cloudflare so they rarely hit origin |

*(Two more nits from the raw audit: the vendored crypto's `SECURITY.md` points reports at a domain with no
mail server, and one store test is effectively a no‑op because `normalize/1` rewrites its fixture id.
Both are in the backlog.)*

---

## 6. What the codebase already gets right

This is a **carefully built** project. An honest audit says so, and knowing what's *good* helps you avoid
"fixing" it.

- **The cryptography is correct in the details most people get wrong.** The id and passphrase random
  number generation are provably unbiased (verified: `rem(b, 32)` is unbiased because 256 = 8 × 32; the
  passphrase rejection sampling is exact). A generated 7‑word passphrase is ~72 bits of entropy.
- **Burn‑on‑read is genuinely atomic.** It uses `:ets.take/2` (remove‑and‑return in one operation), so a
  secret can't be read twice even under concurrent requests. This is the right tool, used correctly.
- **The Content‑Security‑Policy is strict *and* actually enforceable** — `default-src 'none'` with **zero
  inline scripts**, so it never needed the usual `'unsafe-inline'` escape hatch. `Referrer-Policy:
  no-referrer` correctly keeps the URL fragment out of the `Referer` header.
- **Only JSON is parsed** (`parsers: [:json]`), which is precisely why one of the `plug` CVEs (a multipart
  file‑upload bug) doesn't apply here. Minimising the surface paid off.
- **The non‑burning `GET /s/:id` + separate `POST /s/:id/reveal`** is real threat modelling: it exists so
  link‑preview bots can't destroy a shared secret by fetching the URL.
- **nginx access logging is deliberately turned off**, with a comment explaining the IP↔id linkage risk.
  The instinct was exactly right — M12 is just the app's own logger quietly undoing it.
- **`Store.purge/1` has its own `:purged` metric** so operator takedowns don't skew the public "revealed"
  count — a thoughtful transparency detail.
- **The docs are unusually honest**, and the git history shows the maintainer *actively retracting*
  over‑claims. Several findings here are "the walk‑back was incomplete," not "the instinct was missing."

---

## 7. The fix plan

Work top‑down. Each box names the file(s) to touch.

### P0 — before the next deploy

- [ ] **C1** — `Dockerfile`: add `ENV RELEASE_DISTRIBUTION=none` (or the loopback `rel/env.sh.eex` if
  `rpc` is needed).
- [ ] **H1** — `mix deps.update bandit`; then `application.ex:18`: `http_2_options: [enabled: false],
  websocket_options: [enabled: false]`. Confirm `mix hex.audit` exits 0.
- [ ] **M4** — `Dockerfile:14`: `COPY mix.exs mix.lock ./` and add a `mix hex.audit` build step.

### P1 — this week

- [ ] **M13** — `store.ex` / `abuse.ex`: count-only per-IP create budget (NO IP↔secret link), plus the container `mem_limit`.
- [ ] **M12 + M8** — add `RequestLogger` (redacts the id), swap out `Plug.Logger`, and place it below `AbusePlug` in `router.ex`.
- [ ] **M2 + L6** — add the `CrossSite` plug and reorder so `SecurityHeaders` is first; move all JSON endpoints under `/api` (`POST /api/secrets/:id/{reveal,burn,report}`, `GET /api/stats`) and remove the burning `GET /api/secrets/:id`; update `crypto-app.js`, README, the compose healthcheck, and M12's logger.
- [ ] **M3** — `nginx.conf`: `set_real_ip_from` + overwrite `CF-Connecting-IP`; narrow `TRUSTED_PROXIES`.
- [ ] **M5 + M7** — `config.ex`: range‑validated, fail‑closed config; require operator identity.
- [ ] **M1** — `crypto_assets.ex`: committed expected hashes + `verify!/0` at boot.
- [ ] **M9 + M10** — `test.yml`: `mix hex.audit` gate + a daily scheduled `deps-audit.yml` (fails the run + emails you), a `permissions:` block, SHA-pin actions; add `dependabot.yml`.
- [ ] **M11** — `pages.ex`: `spellcheck/autocomplete/translate` opt‑outs.
- [ ] **M6** — reconcile the "nothing on disk" claims in the docs once M12 lands.

### P2 — hardening backlog

- [ ] **L1–L12** — abuse-counter ordering, the accepted exact-stats policy and O(1) active-ban count, `415` handling, passphrase-floor enforcement,
  reveal‑commit ordering, DOM cleanup, management‑token history, container hardening
  (`read_only`/`mem_limit`/`ERL_CRASH_DUMP_SECONDS=0`), Unicode‑id rejection, and the Docker/base‑image
  pinning. Group them into a couple of PRs.

---

## 8. Appendix

**How this audit was done.** Eight independent reviewers each took one slice of the system (server core,
HTTP surface, browser JS, cryptography, deployment, dependencies, privacy/logging, docs‑vs‑code). Every
finding was then handed to a separate adversarial reviewer whose job was to *disprove* it, and the
survivors were verified by hand against a running build. Three findings were refuted and dropped.

**How to re‑verify the big ones yourself** (safe to run locally):

```bash
# --- H1: dependency advisories ---
mix deps.get && mix hex.audit ; echo "exit: $?"          # non-zero = advisories present
mix hex.outdated                                          # shows bandit 1.12.0 -> 1.12.5

# --- H1: HTTP/2 is on ---
PORT=4000 mix run --no-halt &
curl --http2-prior-knowledge -o /dev/null -w "%{http_version}\n" http://127.0.0.1:4000/   # -> 2

# --- M12: secret ids in the log ---
curl -s localhost:4000/s/TESTID > /dev/null              # console prints: [info] GET /s/TESTID

# --- M2: cross-site burn ---
# create a secret, note its id, then:
curl -s -H 'Sec-Fetch-Site: cross-site' localhost:4000/api/secrets/THEID   # returns it; now it's gone

# --- C1: distribution + baked cookie (production build) ---
MIX_ENV=prod mix release --overwrite
grep RELEASE_DISTRIBUTION _build/prod/rel/burnerpad/bin/burnerpad    # default: sname (ON)
cat _build/prod/rel/burnerpad/releases/COOKIE ; echo                 # a baked-in cookie exists
```

**Two clarifications** the audit corrected while verifying, so nobody re‑files them wrongly:

- **L3** — the `500` from a non‑JSON body sends the stack trace to the *server log only*; the client still
  gets a generic `{"error":"request failed"}`. It's a wrong‑status‑code issue, not a client‑facing leak.
- **L6** — the *common* `500` path (an error during dispatch) **does** carry the full security‑header set,
  because `SecurityHeaders` already ran. The header‑less window is limited to an error raised in the first
  two pipeline steps, which is hard to trigger. Still worth reordering; just not as broad as it sounds.
