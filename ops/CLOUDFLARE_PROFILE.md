# Cloudflare production profile

This is part of the release contract, not an optional performance tweak. Burnerpad's origin is private
behind an authenticated Cloudflare Tunnel; only `cloudflared` may supply `CF-Connecting-IP` to the app.
After any zone, tunnel, hostname, or network change, run:

```bash
BURNERPAD_BASE_URL=https://burnerpad.io node ops/smoke/edge-contract.mjs
BURNERPAD_BASE_URL=https://burnerpad.io node ops/smoke/e2e-canary.mjs
```

Configure the zone as follows and export/screenshoot the settings into the private operator runbook after
each change (exports can contain account identifiers and do not belong in this public repository):

- SSL/TLS mode: Full (strict); minimum TLS 1.2; Always Use HTTPS enabled.
- HSTS: domain-wide, at least one year, `includeSubDomains`, preload. Confirm the domain remains accepted at
  the browser preload service before enabling the `preload` token for a new domain.
- Never cache HTML, `/api/*`, `/healthz`, or `/readyz`; preserve origin `Cache-Control: no-store`.
- `/crypto/*` uses its origin `Cache-Control: no-cache` and ETag revalidation. Do not apply Cache Everything,
  Edge Cache TTL, or an immutable override to these stable filenames. `/fonts/*` may use the origin policy.
- Disable Rocket Loader, Auto Minify, email-address obfuscation, Mirage/Polish transformations, and any
  HTML/script rewrite for the hostname. No Worker may intercept the hostname unless separately reviewed.
- Do not enable Logpush/legacy Logpull for this zone. If incident logging is unavoidable, exclude query,
  path, headers, source-IP mapping, and response bodies; keep the shortest useful retention.
- The tunnel route is `https://<hostname>` → `http://app:4000`. The app trusts only the dedicated Compose
  bridge CIDR (`172.28.0.0/16`); rerun the ClientIP tests and public checks if that network changes.

## Required rate-limit rules

The supported production profile targets **Cloudflare Free**. Cloudflare permits one Free-plan rate-limit
rule, path-only matching, per-IP counting, and a 10-second counting and mitigation period. The source of
truth is [`cloudflare/rate-limit-policy.json`](cloudflare/rate-limit-policy.json). Provision its one enabled
zone-level rule in the `http_ratelimit` phase and preserve every committed field exactly:

| Rule ref | Protected traffic | Per-colocation, per-source threshold | Action |
|---|---|---:|---|
| `burnerpad_public_edge_free_v1` | `/healthz`, `/readyz`, `/crypto/*`, and `/fonts/*` | 100 requests per 10 seconds | Block for 10 seconds |

The one shared allowance is a deliberate Free-plan compromise. It retains the prior static-asset burst
allowance while preventing an unbounded health or cache-busting route. The rule is zone-scoped because the
Free plan does not make Host or Method available in a rate-limit expression. It includes Cloudflare's
mandatory `cf.colo.id` plus `ip.src`, and sets `requests_to_origin: false`, so cached responses and randomized
query strings consume the allowance. It relies on Cloudflare's default block response because custom block
responses are not part of the Free contract.

Cloudflare currently accepts the explicit `requests_to_origin: false` creation value but omits that field
from the returned Free-plan rule. Because Free does not permit cache exclusion, the audit treats only that
specific omission as the required false value. An explicit `true` or any other missing/different committed
field still fails the deployment audit.

Do not add IP, user-agent, query, header, verified-bot, or monitoring bypasses: those are difficult to
authenticate and can silently restore an unmetered route. Monitoring uses the ordinary allowance.
UptimeRobot contributes one health request every five minutes, while a healthy scheduled or post-deploy
canary needs only a few requests. Docker probes call the app over loopback and never traverse Cloudflare. A
Cloudflare rate-limit response is an availability failure for the public canary and must alert; monitors
must not treat it as healthy.

Do not create the rule manually in the dashboard. The committed audit requires a stable custom `ref`, and
the one-time provisioning command in [`../DEPLOYMENT.md`](../DEPLOYMENT.md) creates that exact API object.
It refuses to overwrite an existing entry point. Provision with a temporary one-zone write token, revoke
that token immediately, and retain only the separate read-only audit token for routine deployments.

Create a separate read-only Cloudflare API token scoped to Rulesets for this zone. Store it and the zone ID
only in the gitignored Ansible secrets file. Every deployment runs this control-plane audit before replacing
the app:

```bash
CLOUDFLARE_ZONE_ID=... \
CLOUDFLARE_RULESETS_READ_TOKEN=... \
node ops/cloudflare/audit-rate-limit-policy.mjs
```

The audit reads the current `http_ratelimit` entry point and rejects an extra, removed, duplicated, or
disabled rule; any expression or bypass change; a higher request threshold; a shorter block; origin-only
counting; or a different action. It never prints the token, zone ID, source addresses, or API response body.

The edge contract reads Cloudflare's managed `/cdn-cgi/trace` observation into memory, submits it to the
match-only `/api/edge/source-check`, and repeats with a forged `CF-Connecting-IP`. Only status codes are
compared or logged: the probe never returns, persists, or prints an address. A baseline mismatch detects a
missing visitor header or stale trusted-proxy CIDR; a spoof mismatch detects caller-controlled source data.

The scheduled `public-canary` GitHub workflow runs both scripts every 15 minutes. UptimeRobot remains the
independent five-minute HTTPS/content monitor, and Healthchecks.io remains the hourly VPS dead-man switch;
all three are complementary and should alert through at least one tested notification channel.
