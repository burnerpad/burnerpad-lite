# Cloudflare production profile

This is part of the release contract, not an optional performance tweak. Burnerpad's origin is private
behind an authenticated Cloudflare Tunnel; only `cloudflared` may supply `CF-Connecting-IP` to the app.
The authoritative click-by-click setup and re-audit checklist is in the **Apply the complete Cloudflare zone
profile** subsection of [`../DEPLOYMENT.md`](../DEPLOYMENT.md); complete it for every new zone. This file is
the compact invariant reference.
After any zone, tunnel, hostname, or network change, run:

```bash
BURNERPAD_BASE_URL=https://burnerpad.io node ops/smoke/edge-contract.mjs
BURNERPAD_BASE_URL=https://burnerpad.io node ops/smoke/e2e-canary.mjs
```

Configure the zone as follows and export or screenshot the settings into the private operator runbook after
each change (exports can contain account identifiers and do not belong in this public repository):

- SSL/TLS mode: Full (strict); minimum TLS 1.2; Always Use HTTPS enabled under **SSL/TLS → Edge
  Certificates**; TLS 1.3 and Certificate Transparency Monitoring on; 0-RTT and Automatic HTTPS Rewrites
  off.
- Browser Cache TTL: **Respect Existing Headers** under **Caching → Configuration**. Do not leave the
  zone-wide four-hour default or set a Cache Rule that overrides origin cache eligibility/TTL. Always
  Online, APO, Cache Reserve, and stale-content overrides are off.
- HSTS: the app emits two years with `includeSubDomains; preload`. After confirming every current and future
  subdomain supports HTTPS, mirror it for Cloudflare-generated responses under **SSL/TLS → Edge
  Certificates** with a 12-month max age, **includeSubDomains**, **Preload**, and **No-Sniff**. Confirm the
  domain is eligible before separately submitting it to the browser preload service; the directive alone
  does not enroll it.
- Never cache HTML, `/api/*`, `/healthz`, or `/readyz`; preserve origin `Cache-Control: no-store`.
- `/crypto/*` uses its origin `Cache-Control: no-cache` and ETag revalidation. Do not apply Cache Everything,
  Edge Cache TTL, or an immutable override to these stable filenames. `/fonts/*` may use the origin policy.
- Disable Rocket Loader, Auto Minify, Email Address Obfuscation, Replace Insecure JavaScript, Polish,
  Web Analytics/RUM injection, Zaraz, Cloudflare Fonts, and every HTML/script rewrite. Mirage is deprecated.
- Pseudo IPv4 is off; IPv6 compatibility is on; visitor-IP removal/location transforms and any custom
  `CF-Connecting-IP`/forwarding-header transform are off. No Worker, Snippet, Access application, or
  secondary CDN may intercept the hostname unless separately reviewed.
- Bot Fight Mode, Under Attack Mode, Browser Integrity Check, managed `security.txt`, AI crawler features,
  hotlink protection, and unreviewed custom/managed challenge or block rules are off. Keep only Cloudflare's
  default managed DDoS protection and the repository-provisioned Free-plan rate-limit rule.
- Do not enable Logpush/legacy Logpull for this zone. If incident logging is unavoidable, exclude query,
  path, headers, source-IP mapping, and response bodies; keep the shortest useful retention. Do not enable
  Client-side Security/Page Shield collection or third-party request mirroring.
- The tunnel route is `https://<hostname>` → `http://app:4000`. The app trusts only the validated dedicated
  Compose `backend_subnet` (a private `/16` through `/29`); Docker IPAM and `TRUSTED_PROXIES` are rendered
  from that one value. Rerun the ClientIP tests and public checks if the network changes.

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
