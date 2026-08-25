# Implementation Plan — Burnerpad to production

> **Historical implementation snapshot (2026-08-21).** This preserves the original remediation sequence
> and is not the current go-live checklist. Use [`ARCHITECTURE.md`](ARCHITECTURE.md) for current behavior
> and [`DEPLOYMENT.md`](../DEPLOYMENT.md) for the maintained deployment and verification procedure.

**This is the single, do-it-top-to-bottom task list.** Finish everything here and you have a super-secure,
single-developer, production-grade Burnerpad — deployable from a **fresh Ubuntu VPS to a live server in a
few Ansible commands.**

- **Every task lives in this file.** ([`SECURITY_AUDIT.md`](SECURITY_AUDIT.md) is the *why* behind each code
  change; [`DEPLOYMENT.md`](../DEPLOYMENT.md) is the ops runbook detail. Neither adds tasks not listed here.)
- The work splits in two: **Part A — code** (make the *image* secure) and **Part B — deploy** (make it
  *run* safely, from a fresh box). Do Part A first (at least Batches 1–2 + M12) so the image you ship isn't
  vulnerable; Part B can be set up in parallel on a throwaway box.

---

## Definition of done — "production-grade" means all of these

- [x] **Image is secure:** `mix hex.audit` exits 0; Erlang distribution is loopback-only (C1); no secret id
      reaches a log (M12); config fails closed; SRI is boot-verified (M1). *(Part A — DONE, verified)*
- [ ] **Fresh VPS → live in a few commands**, lockout-safe, no manual host fiddling. *(Part B)*
- [ ] **Zero public ports.** Ingress only via the Cloudflare tunnel (outbound); admin only via Tailscale;
      `ufw` denies all inbound; system `sshd` is key-only and firewalled shut (admin via Tailscale SSH).
- [ ] **Container is bounded & self-healing:** `read_only`, `mem_limit`, no swap, `cap_drop`, `no-new-privileges`;
      an OOM restarts the container, not the box.
- [ ] **You get paged on downtime:** an external monitor + the dead-man's-switch heartbeat.
- [x] **You can't leak a secret into git:** `.gitignore` + the pre-commit guard; the whole `ops/` recipe is
      secret-free and safe to publish. *(DONE)*
- [ ] **Re-runnable:** every deploy is `ansible-playbook step_2_deploy.yml`; the automated setup/hardening
      playbook is one-time per host, and the box is cattle, not a pet.

---

## Part A — Code (make the image secure)

Ship **one PR per batch, in order** (each carries its own tests). Batch 1 lands the CI advisory gate first,
so every later PR is auto-checked.

| # | Batch | Findings | Risk | Breaking? |
|---|-------|----------|------|-----------|
| 1 | Supply-chain & build | H1, M4, M9, M10, L11 | low | no |
| 2 | Runtime / boot hardening | C1, M3, M5, M7, L9 | med | no (deploy only) |
| 3 | Router pipeline + `/api` restructure | M2, M8, M12, L2ᵃ, L3, L6, L12 | **high** | **yes (API)** |
| 4 | Store / Abuse | M13, L1, L2ᵇ, L10 | med | no |
| 5 | Client UX & residue | M11, L4, L5, L7, L8 | low | no |
| 6 | Docs + integrity finalize | M1, M6 | low | no |

ᵃ `/healthz` route · ᵇ public-stats policy and active-ban cost. **M1 is last** — the committed SRI hashes can only be finalized after
every `crypto-app.js` edit (Batches 3 and 5).

### Settled decisions (assumed below)

1. **Subsystem batches**, not strict severity order (findings share files).
2. **Newest runtime:** pin `hexpm/elixir:1.20.2-erlang-29.0.5-alpine-3.24.1` (runtime `alpine:3.24.1`) —
   matches the dev toolchain, so prod runs what tests validate. Own commit in Batch 1.
3. **C1 → loopback**, not `none` (keeps `bin/burnerpad rpc` takedowns working; nothing reachable off-box).
4. **Config fail-closed:** missing operator identity and out-of-range numerics both raise at boot.
5. **`/api` clean break:** no `/api/v1`, no aliases; `/stats.json` → `/api/stats`. Shared `/s/:id` links
   (HTML) are unaffected.
6. **CSRF gate is content-type-based** (`Parsers pass: []` → `415`), not the Sec-Fetch plug (which would
   break cross-site link-opens). Sec-Fetch plug is optional GET-exempt defense-in-depth.
7. **M13 is an expiry-bucketed, count-only byte budget** (2 % default) — see Batch 4.
8. **No nginx** — cloudflared talks to the app directly (see Part B); M3 becomes "trust only cloudflared".

### ✅ Batch 1 — Supply-chain & build  *(DONE — verified)*

> **Done:** `mix hex.audit` → 0 (six advisories cleared); bandit 1.12.5/hpax 1.0.4/plug 1.20.3/plug_crypto
> 2.2.0; HTTP/2 + WebSocket disabled (h2c now refused, live-tested); Dockerfile on
> `elixir 1.20.2 / erlang 29.0.5 / alpine 3.24.1` **digest-pinned**, image builds + boots read-only + crypto
> NIF works; `mix.lock` copied + `hex.audit` build gate; `test.yml` (hex.audit gate, `permissions`,
> SHA-pinned actions, `persist-credentials: false`, Node 24 LTS / OTP 29.0.5); `dco.yml` pinned;
> `deps-audit.yml` (daily), `dependabot.yml`, `.dockerignore` added. `mix test` 49✓, `test.core` 8✓,
> conformance 45✓.

**Commit A — dependency patch (H1)**
- `mix deps.update bandit` → bandit 1.12.5 / hpax 1.0.4 / plug 1.20.3 / plug_crypto 2.2.0.
- `application.ex`: add `http_2_options: [enabled: false], websocket_options: [enabled: false]` to the
  Bandit child (verified valid; no WebSocket route). Removes the HTTP/2 + HPACK CVE class permanently.
- **Done when** `mix hex.audit` exits 0.

**Commit B — runtime bump (own commit + full test run)**
- Dockerfile `FROM` (build) → `hexpm/elixir:1.20.2-erlang-29.0.5-alpine-3.24.1`; runtime → `alpine:3.24.1`.
  **Digest-pin both** (L11).
- CI `erlef/setup-beam` → `otp-version: 29.0.5`, `elixir-version: 1.20.2`.

**Commit C — build & CI hardening (M4, M9, M10, L11)**
- Dockerfile: `COPY mix.exs mix.lock ./` + `RUN mix hex.audit` build step.
- `test.yml`: add `mix hex.audit`; `permissions: contents: read`; SHA-pin actions; `persist-credentials: false`.
- New `.github/workflows/deps-audit.yml`: daily `cron`, `mix deps.get && mix hex.audit`, optional
  `gh issue create` on failure (native failed-workflow email).
- New `.github/dependabot.yml` (`mix` + `test/browser` npm). New `.dockerignore`.

### ✅ Batch 2 — Runtime / boot hardening  *(DONE — verified)*

> **Done:** **C1** — `rel/env.sh.eex` (`name@127.0.0.1`, loopback EPMD/dist) + `mix.exs` release +
> `Dockerfile COPY rel` (the missing copy would have shipped C1 **unfixed** — caught by a container test).
> Verified in a clean container: node `burnerpad@127.0.0.1`, **EPMD + dist on `127.0.0.1` only** (was
> `0.0.0.0`), `rpc` takedowns still work. **M5/M7** — `config.ex` raises at boot on an out-of-range numeric
> and (prod build) on missing operator identity; dev/test get a fake placeholder (4 new `config_test`
> cases). **M3/L9** live in the ops compose (`TRUSTED_PROXIES`, `read_only`/`mem_limit`/caps). `mix test`
> 53✓, `hex.audit` 0.

**Batch 2 detail —**

- **C1 — loopback distribution:** `rel/env.sh.eex`:
  ```sh
  export RELEASE_DISTRIBUTION=sname
  export ERL_EPMD_ADDRESS=127.0.0.1
  export ELIXIR_ERL_OPTIONS="-kernel inet_dist_use_interface {127,0,0,1}"
  ```
  and `mix.exs`: `releases: [burnerpad: [include_executables_for: [:unix]]]`.
  **Verify:** in-container `bin/burnerpad rpc "IO.puts(node())"` works; `ss -lntp` shows EPMD/dist on
  `127.0.0.1` only.
- **M3 — trusted proxy (no nginx):** cloudflared talks to the app directly and forwards `CF-Connecting-IP`,
  so set `TRUSTED_PROXIES` to the cloudflared bridge subnet. **The ops compose template already does this**
  (`TRUSTED_PROXIES: 172.28.0.0/16`) — this task is just to confirm the app reads it. *(No nginx config to
  change; nginx is dropped in Part B.)*
- **L9 — container hardening:** applied by the ops compose template (`read_only`, `tmpfs [/tmp]`,
  `ERL_CRASH_DUMP_SECONDS=0`, `no-new-privileges`, `cap_drop [ALL]`, `pids_limit`, `mem_limit`, no
  container swap), while the host hardening role disables swap persistently as defense in depth.
  `mem_limit`/`MAX_SECRETS` are Ansible **vars** (`ops/group_vars/all/vars.yml`), sized to the box's RAM so
  `MAX_SECRETS×64KB < mem_limit < box RAM`. **`read_only` is tested-good** — `bin/burnerpad start` writes
  nothing under `/app`, so it boots read-only; `RELEASE_TMP=/tmp` is set as harmless future-proofing.
- **M5 + M7 — config fail-closed:** `config.ex` **raises at boot** if `OPERATOR_NAME`/`ABUSE_EMAIL`/
  `JURISDICTION` are unset (drop the Impulsa defaults from the serving path), and range-validates numerics
  (`PORT`/`MAX_SECRETS`/`TTL_SECONDS`/`RATE_LIMIT`/…): reject non-integer, negative, or zero-where-positive.

**Tests:** boot raises on a missing operator var and on an invalid numeric; a valid env boots clean.

### ✅ Batch 3 — Router pipeline + `/api` restructure  *(DONE — verified end-to-end)*

> **Done & verified against a running server:** pipeline reordered (SecurityHeaders first / Static above
> AbusePlug / redacting `RequestLogger` below it, `Plug.Logger` removed); routes moved to
> `POST /api/secrets/:id/{reveal,burn}`, the burning `GET /api/secrets/:id` **removed** (now 404),
> `/stats.json` → `/api/stats`; `Plug.Parsers pass: []` CSRF gate (a `text/plain` forged POST → **415**, the
> secret left intact); `GET /healthz` above the limiter; `crypto-app.js` + README updated in lockstep.
> **Live checks:** reveal 200→410, healthz `ok`, old GET 404, `/api/stats` 200, and the log shows
> `POST /api/secrets/:id/reveal` — **id redacted** (M12). `router_test` rewritten + CSRF/healthz tests;
> `mix test` **55✓**, warnings-as-errors clean.

**Batch 3 detail —**

**Pipeline order** (assets served before the limiter, headers first, logging below the limiter):
```
SecurityHeaders → RequestId → Static×4 → AbusePlug → RequestLogger(redacting)
→ [CrossSite, optional DiD] → Parsers(pass: []) → match → dispatch
```
- **L6:** `SecurityHeaders` first, so even a 429/500 carries the CSP.
- **L12:** the four `Plug.Static` blocks go **above** `AbusePlug` so a page load's ~8 asset requests don't
  burn the per-IP limit; the limiter guards only dynamic/secret routes (Cloudflare edge-caches the assets).
- **M8 + M12:** new `BurnerpadWeb.RequestLogger` that logs the **route shape** (`/s/:id`,
  `/api/secrets/:id/reveal`), never the concrete id, placed **below** `AbusePlug`; remove `Plug.Logger`.

**Routes (M2):** add `POST /api/secrets/:id/{reveal,burn}`; remove `GET /api/secrets/:id` and
`POST /s/:id/{reveal,burn,report}`; the unused report-to-log endpoint was removed during merge review;
`GET /stats.json` → `GET /api/stats` (no alias); `GET /s/:id` stays the
HTML interstitial.

**CSRF gate (L3):** `Plug.Parsers` → `pass: []` (non-JSON body ⇒ `415`); `crypto-app.js` sends
`content-type: application/json` on the reveal fetch. A cross-site simple-request POST can't be
`application/json`, so it's rejected before it can burn — on every browser.

**L2ᵃ:** add `GET /healthz` (plain `200`) **above `AbusePlug`** (the 30 s healthcheck shouldn't count);
the ops healthcheck targets it (`healthcheck_path` var).

**Lockstep:** update `crypto-app.js` (fetch paths + reveal content-type), README curl examples.

**Tests:** rewrite `router_test.exs` for `/api/secrets/:id/*`; add a `415`-on-non-JSON test and a
cross-site-POST-rejected test; Playwright smoke stays green.

### ✅ Batch 4 — Store / Abuse  *(DONE — core; L1/L2b resolved)*

> **Done & verified:** **M13** — `Abuse.admit_create/3` (expiry-bucketed, count-only per-source byte budget,
> `Config.per_ip_budget` = `PER_IP_BUDGET` env or 2 % of `MAX_SECRETS×max_blob`), gated in the router
> create handler (over budget ⇒ **429**; `Store` stays source-free); HMAC-tokenized, swept per-slot, and
> hard-capped against metadata churn. **L10** — `normalize/1`
> rejects non-ASCII before `String.upcase/1` (Unicode aliasing). Fixed the **vacuous expired-reveal test**
> (was passing because `normalize` rewrote its `"EXPIRED01"` fixture) with a normalize-stable id + positive
> control. New M13/L10 tests; covered by the current full test suite.
> **Done in merge review:** **L1** now uses weighted current/previous windows, closing the ~2× boundary.
> **Resolved by implementation and policy:** **L2b** keeps exact live, capability-free public aggregates as
> an accepted transparency choice. Active-ban reporting is O(1), and health checks use `/healthz` and
> `/readyz`, so stats are not on their hot path.

**Batch 4 detail —**

- **M13 — expiry-bucketed per-source byte budget.** Default `PER_IP_BUDGET` = **2 %** of
  `MAX_SECRETS × max_blob`. Each create's **bytes** enter a ~15-minute expiry bucket under a RAM-keyed HMAC
  source token; `Abuse.admit_create(key, bytes, ttl)` sums future buckets and atomically reserves capacity.
  Sweeping drops past buckets, and a failed Store capacity write rolls its reservation back. The metadata
  table is capped at `MAX_SECRETS`. `Store` remains source-free — **no source ↔ secret link.** Over budget
  ⇒ `429`.
- **L1:** weight the previous and current windows so the previous bucket fades out instead of allowing a
  boundary 2× burst.
- **L10:** `normalize/1` rejects non-ASCII **before** `String.upcase/1` (Unicode id-aliasing).
- **L2ᵇ:** retain exact live `/api/stats` aggregates by design; document the accepted timing/volume exposure.
  Active-ban count is O(1), and health/readiness have dedicated endpoints. Fix the vacuous expired-reveal
  store test.

**Tests:** over-budget ⇒ `429`; budget recovers as buckets expire; non-ASCII id ⇒ `404`.

### ✅ Batch 5 — Client UX & residue  *(DONE — core; L5/L8 noted)*

> **Done:** **M11** — `spellcheck/autocomplete/autocapitalize/autocorrect` off on the secret textarea +
> `translate="no"` on the revealed block (pages.ex). **L4** — create submit now **blocks a weakened phrase**
> (`genWords.size < MIN`), enforcing the entropy floor the UI computed. **L7** — a `pagehide` handler purges
> the revealed plaintext + the secret input from the DOM. **L5** — the parsed blob assignment is atomic and
> a `revealing` guard blocks double-submit. **Deferred:** L8 (retain prior `{id, mgmt}` on "Create another"
> — minor UX). `test.core` and the full suite are green.

**Batch 5 detail —**

- **M11:** `spellcheck/autocomplete/autocapitalize/autocorrect` off on the secret textarea; `translate="no"`
  on the revealed block.
- **L4:** gate submit on the number of *generated* words remaining (enforce the entropy floor).
- **L5:** commit `heldBlob` only after it parses; guard double-submit.
- **L7:** clear decrypted plaintext from the DOM on `pagehide`/navigate.
- **L8:** keep prior `{id, mgmt}` in a session list so "Create another" doesn't discard a management token.

### ✅ Batch 6 — Docs + integrity finalize  *(M1 and top-level M6 DONE)*

> **Done:** **M1** — `CryptoAssets.@expected` holds **committed** `sha384` hashes for the bundle / app /
> theme / css; `verify!/0` runs at boot and **refuses to start on any mismatch** (fail-closed — live-tested:
> a tampered `crypto-app.js` won't boot); `mix bp.sri` regenerates the hashes (round-trip tested). The
> page's `integrity=` now comes from the committed hashes, not the served file. **M6 (partial):** README API
> updated (Batch 3) incl. the `ttl`/budget note; `/terms §8` fair-use volume-limit line added.
> **Merge-review follow-up complete:** top-level architecture, routes, privacy wording, budgets, and
> deployment docs are reconciled. The independently versioned crypto-js repository corrected its stale
> security contact in v1.3.1, published annotated v1.3.0/v1.3.1 tags, and this repository pins v1.3.1.

**Batch 6 detail —**

- **M6:** reconcile "nothing on disk" across README / `ARCHITECTURE.md` / `/terms` (now M12 is fixed); add
  the README `ttl`/budget note and `/terms §8` fair-use line. Also update `ARCHITECTURE.md` for the
  **no-nginx** topology and the new pipeline/route order. The crypto submodule contact is fixed in v1.3.1.
- **`ARCHITECTURE.md §9`:** the M13 budget write-up + worked examples.
- **M1 (LAST):** commit `sha384` hashes for `burnerpad-crypto.js`, `crypto-app.js`, `theme.js`, `crypto.css`;
  `CryptoAssets.verify!` **hard-fails boot** on mismatch; add a `mix bp.sri` regen task. Last, because
  Batches 3 & 5 change `crypto-app.js`.

**Tests:** an altered asset ⇒ boot fails; `mix bp.sri` reproduces the committed values.

---

## Part B — Deploy (fresh VPS → live, safely)

One tool: **Ansible**, run from your laptop over Tailscale SSH. It hardens the box and deploys. The recipe
lives in [`ops/`](../ops) and is **secret-free** (safe to commit/publish); real secrets stay in gitignored
files, and `.githooks/pre-commit` blocks committing them.

### Prerequisites (one-time, on your laptop)

- [ ] Install **Ansible** and **Docker** (with buildx).
- [ ] `git config core.hooksPath .githooks` — turns on the secret guard.
- [ ] **Cloudflare** (the one click-ops step): Zero Trust → **Tunnels** → create a tunnel → copy its
      **token**; add a public hostname route → `http://app:4000`.
- [ ] **Tailscale** (this is your keyless login to the box — **no SSH key is installed on the VPS**):
      - an account, **the Tailscale app running + logged in on your laptop** (that's what proves your
        identity when Ansible connects over the tailnet),
      - a one-off **auth key** (Admin → Settings → Keys) for the box to join during bootstrap,
      - a **locked-down tailnet ACL** (see repository-root `DEPLOYMENT.md` → *Configure Tailscale*) that tags the box
        `tag:burnerpad`, lets your user Tailscale-SSH in **as `deploy`** with **`action: "accept"`**, and —
        by never listing the tag as a `src` — makes the box a **sink** (a compromised box can't reach your
        laptop). Create the bootstrap auth key **with that tag**. `action: "check"` (the default) would hang
        the non-interactive tailnet playbooks. Admin/deploy ride Tailscale SSH — **no keys travel anywhere.**
        Break-glass if Tailscale is down: your VPS provider's console.
- [ ] `cd ops && ./install-requirements-locked.sh` (downloads once, verifies the committed lock, and
      installs only those local archives).
- [ ] Fill the files:
      - `cp inventory.example.ini inventory.ini` → your box's public IP + tailnet name *(gitignored)*.
      - `cp group_vars/all/secrets.example.yml group_vars/all/secrets.yml` → tunnel token + tailscale key
        *(gitignored; optionally `ansible-vault encrypt` it)*.
      - Edit `group_vars/all/vars.yml` → `mem_limit`/`max_secrets` to the box's RAM and operator identity.
        Put `heartbeat_url` in gitignored `secrets.yml`. (No SSH key/path — access is Tailscale SSH.)

### The flow — a fresh Ubuntu 24.04 LTS box (root + password) to live

```bash
cd ops

# 1. Set up the fresh host ONCE. The playbook bootstraps over the public IP, then automatically
#    reconnects over Tailscale and hardens only after that path succeeds.
ansible-playbook step_1_setup.yml

# 2. Deploy over the tailnet. Re-run only this playbook for every release.
ansible-playbook step_2_deploy.yml
```

- **Step 1 (`step_1_setup.yml`):** its first play creates the `deploy` user, enables keyless Tailscale SSH
  + passwordless sudo, applies `ufw` default-deny-inbound, installs Docker, and enables unattended
  upgrades. Its second play automatically reconnects through the tailnet, then runs the
  `devsec.hardening` OS/SSH baselines plus extra sysctl, core-dump, and swap hardening. A failed tailnet
  connection stops before hardening, so root/password remain as the recovery path.
- **Step 2 (`step_2_deploy.yml`):** builds the image locally → `docker save | ssh 'docker load'` over the
  tailnet → renders Compose + `.env` → `compose up`, then installs/updates the heartbeat and BEAM sampler.
  It does no host bootstrap or hardening and is the only routine release command. **Idempotent.**

### Batch 0 tasks — the deploy checklist

- [ ] Complete the **Prerequisites** above.
- [ ] Run the **two-playbook flow**.
- [ ] **Verify:** `ss -lntp` on the box shows **no public ports**; `ssh deploy@<tailnet>` works and
      `ssh root@<public-ip>` no longer does; `docker inspect <app>` shows `read_only`/`mem_limit`/caps; the
      site is reachable via Cloudflare; `/healthz` is green.
- [ ] **Wire paging:** create an external hourly check (with a 30-minute grace window), put its ping URL
      in gitignored `secrets.yml` as `heartbeat_url`, and run `step_2_deploy.yml`. The box pings it *only
      while the app answers*, so a dead app stops the pings and the monitor alerts you.
- [ ] **Cloudflare edge (the other half of L12):** add a **Cache Rule** for `/crypto/*` + `/fonts/*` so the
      static assets are served from the edge and rarely hit the origin.
- [ ] **Enable 2FA** on the three control planes — VPS provider, Cloudflare, Tailscale (whoever owns those
      owns the box, regardless of host hardening).

### The recipe (already built — you fill vars + run)

```
ops/
  step_1_setup.yml              # ONCE/HOST — public bootstrap → tailnet transition → hardening
  step_2_deploy.yml             # EVERY RELEASE — build, ship, compose up, monitor
  requirements.yml              # devsec.hardening, community.docker/general, ansible.posix, geerlingguy.docker
  ansible.cfg
  inventory.example.ini         # → inventory.ini (gitignored): public IP + tailnet hosts for setup/deploy
  group_vars/all/vars.yml       # non-secret: mem_limit, operator identity, healthcheck path
  group_vars/all/secrets.example.yml   # → secrets.yml: tunnel token + tailscale key + heartbeat URL
  roles/
    provision/  # user+key, tailscale, ufw, unattended-upgrades
    harden/     # sysctl, core dumps off
    deploy/     # build local → ship over tailnet → render compose+.env → compose up   (+ compose template)
    monitor/    # dead-man's-switch heartbeat + hourly BEAM sampler
```

---

## Gaps closed in this review (G1–G6)

- **G1 — `read_only` boot:** **not a blocker.** Live-tested: the app boots read-only (`bin/burnerpad start`
  writes nothing under `/app`). `RELEASE_TMP=/tmp` kept as harmless future-proofing. *(My earlier "it will
  crash" was wrong — the test corrected it.)*
- **G2 — provisioning + lockout:** **closed.** The setup playbook creates user/Tailscale/ufw/updates,
  reconnects through the tailnet, and only then hardens; a connection failure leaves root/password intact.
- **G3 — fresh-box connection:** **closed.** Step 1 privately prompts for the root password and scopes it
  to the public-IP play; documented in the flow.
- **G4 — monitoring/alerting:** **closed.** The `monitor` role installs a dead-man's-switch heartbeat +
  BEAM sampler; you add an external monitor.
- **G5 — Cloudflare tunnel + healthcheck:** **closed.** The tunnel/hostname dashboard step is a documented
  prerequisite; the healthcheck endpoint is a var (`/healthz` after Batch 3, `/` before).
- **G6 — Ubuntu 26.04 + mem_limit:** `mem_limit`/`max_secrets` are vars; **verify role support** before
  first production use (see Risks).

## Risks — verify before first production use

- **Ubuntu 26.04 is new.** Syntax-check both playbooks and run setup against a
  **throwaway VM** first. If a `devsec`/`geerlingguy` role rejects 26.04, pin the box to **24.04 LTS** (proven)
  or update the role versions in `requirements.yml`.
- **The build happens on your laptop** → your laptop is the supply-chain trust anchor. Keep it clean.
- **A deploy recreates the app container** → all live secrets are dropped (same as a restart; fine for a
  burn-on-read service, but know it).
- **Order:** don't point real traffic at the box until at least **Batch 1 + Batch 2 + M12** are in the
  shipped image — Part B ships whatever's in the repo.

## Cross-batch dependencies (the ones that bite)

- **M1 after all client edits** — committing SRI hashes before Batch 5 forces a re-commit on every JS change.
- **Runtime bump is its own commit** with a full test run — don't fold it into the dep patch.
- **`ARCHITECTURE.md` prose (Batch 6)** assumes the `/api` routes + no-nginx topology — keep it last.
- **`mem_limit` ↔ `MAX_SECRETS`** are set together in `ops/group_vars/all/vars.yml` (Part B), sized to the
  box, or the OOM killer beats the app's own `503`.
