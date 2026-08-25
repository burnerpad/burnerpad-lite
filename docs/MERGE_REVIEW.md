# Security branch merge review

> **Historical review snapshot.** This describes an earlier branch state and is retained as evidence, not
> as current launch status. See [`PRODUCTION_IMPLEMENTATION.md`](PRODUCTION_IMPLEMENTATION.md).

**Reviewed:** `security_audit` against `main` (`155b76fa`)
**Date:** 2026-08-22
**Scope:** Elixir application, browser assets, pinned crypto submodule, CI supply chain, container image,
Ansible deployment, runtime behavior, privacy claims, and the production documentation.

## Verdict

The corrected branch is technically green and suitable to merge after its required CI checks pass. Its
complete change set is represented by one DCO-signed commit on top of `main`; the live-host swap controls
and every merge-review correction are included in that final tree.

The prior crypto release-hygiene blocker is also resolved: upstream `main` contains the DCO-signed v1.3.1
metadata commit, annotated v1.3.0/v1.3.1 tags are published, and this repository pins v1.3.1. The runtime
bundle and wire format are byte-identical to v1.3.0.

Production was initially converged from signed commit `67d4401` on 2026-08-22 with a replacement tunnel
credential and heartbeat, followed by a successful reboot and post-boot verification. The final
branch-head application was subsequently deployed through `step_2_deploy.yml` and verified publicly; only
the one-time fresh-host transition in `step_1_setup.yml` awaits the planned clean VPS rebuild.

## Original audit finding coverage

| Finding | Status after this review |
|---|---|
| C1 — remotely exposed BEAM distribution | Fixed; EPMD and distribution listen on loopback, and release RPC still works |
| H1 — vulnerable Bandit/HPAX path | Fixed; Bandit 1.12.5, advisory audit clean, HTTP/2 and WebSocket disabled |
| M1 — self-derived asset integrity | Fixed; committed SHA-384 values, fail-closed boot verification, browser SRI |
| M2 — cross-site burn/reveal | Fixed; mutating API is JSON-only POST and no GET burns a secret |
| M3 — spoofable real-client header | Fixed; forwarded IP is honored only from a valid configured proxy CIDR |
| M4 — image ignored `mix.lock` | Fixed; lock copied and audited in the image build |
| M5 — unsafe numeric config | Fixed; bounded parsing fails closed |
| M6 — documentation/privacy drift | Fixed, including the crypto submodule security contact and release tags |
| M7 — inherited operator identity | Fixed; production refuses to boot without explicit identity |
| M8 — logging before abuse control | Fixed; limiter precedes the allowlisted route-shape logger |
| M9 — no dependency advisory gate | Fixed; PR/build and scheduled audit gates |
| M10 — over-privileged/movable CI actions | Fixed; least privilege and current immutable official action SHAs |
| M11 — secret-field browser residue | Fixed; browser assistance disabled and revealed text marked no-translate |
| M12 — capability IDs written to logs | Fixed; known routes are shaped, unknown paths are collapsed, error text is generic |
| M13 — one-source memory exhaustion | Fixed; serialized TTL-bucketed budget, rollback, HMAC source tokens, hard metadata cap |
| L1, L3, L4, L5, L6, L7, L9–L12 | Fixed or otherwise applied as documented in `IMPLEMENTATION_PLAN.md` |
| L2b — exact live public stats | Accepted by design: capability-free O(1) aggregates remain live; timing/volume exposure is documented, and health/readiness use separate endpoints |
| L8 — retain earlier revoke tokens after “Create another” | Deferred UX improvement; it is not a server-side confidentiality/integrity bypass |

Additional merge-review fixes close concurrent `MAX_SECRETS` overflow, invalid CIDR widths, failed-create
budget leakage, unbounded budget metadata churn, unreliable ban escalation, raw IP prefixes in abuse tables,
arbitrary unmatched-path logging, exception-message logging, app exposure to the tunnel token, unpinned
Ansible dependencies, a bearer-like heartbeat URL in public vars, container access to host swap, and
production-only compile warnings.

## Daily activity chart and privacy boundary

`Burnerpad.DailyStats` keeps only `{UTC Gregorian day, homepage request count, successful secret-create
count}` in ETS. It retains 31 days, renders 14 days, and resets on VM restart. It does **not** set a cookie
or store an IP, fingerprint, session, user-agent, referrer, secret ID, or any per-visitor/per-secret record.
The UI and JSON call homepage activity a request/visit count, not a unique-person count. Secret creates
increment only after a successful Store insertion. The grouped bar chart is server-rendered inline SVG
with an accessible HTML data table—no JavaScript, remote asset, or chart library.

Abuse control still has to recognize repeated requests from one source. It now HMAC-tokenizes the transient
IP prefix with a random RAM-only key before any ETS write, never stores the raw prefix, never links a token
to a secret id, and exposes only aggregate violation counts.

## Verification evidence

- Elixir: production and development compilation with warnings as errors; **71 tests passed**.
- Dependencies: `mix hex.audit` reports no retired or advisory-listed packages.
- JavaScript: app Core **8/8**; vendored crypto conformance **45/45**.
- Nested repository: clean at v1.3.1 (`c54c25400666e0319aab8eb365240f5fd04de318`); DCO-signed commit and
  annotated v1.3.0/v1.3.1 tags are published. Its full suite passes: 47 reproducible vectors, 47 self-tests,
  45 conformance tests, and 66 edge/fuzz/supply-chain tests.
- Ansible: both lifecycle playbooks (`step_1_setup.yml` and `step_2_deploy.yml`) pass syntax checks;
  setup's second play is gated on a successful tailnet reconnection, and all tracked YAML parses.
- Compose: rendered and normalized successfully; app gets only allowlisted config, cloudflared alone gets
  `TUNNEL_TOKEN`; no host port is published; read-only, tmpfs, memory/PID bounds, cap drop, and
  `no-new-privileges` are present.
- Image: digest-pinned production build succeeds, including the advisory and warnings-as-errors gates;
  its OCI revision label, runtime environment, `/stats`, and `/api/stats` all report the deployed Git SHA.
- Hardened runtime: `/healthz` succeeds; two homepage requests change only today's aggregate to 2; the
  stats page renders a 14-day grouped activity chart; concrete IDs/unmatched text do not enter logs; BEAM distribution is
  loopback-only; RPC works; HTTP/2 prior knowledge is refused.
- Stats UI: desktop and 390 px browser checks show the grouped visit/create bar chart, the chart
  heading/privacy copy outside the chart card, no horizontal overflow, and the running version.
- Repository hygiene: `mix format --check-formatted` and `git diff --check` pass.

## Live VPS review

Read-only inspection over Tailscale SSH on 2026-08-22 confirmed Ubuntu 24.04, active UFW with default-deny
inbound and only `tailscale0` allowed, key-only/no-root SSH, active unattended upgrades, hardened sysctls,
no published container ports or mounts, healthy read-only containers, memory/PID limits, all capabilities
dropped, `no-new-privileges`, capped logs, loopback-only BEAM distribution, working release RPC, and the
expected external HTTPS security headers. Cloudflare serves fonts from cache and revalidates crypto assets.

The initial inspection found the older `d7c6f49` image, app access to `TUNNEL_TOKEN`, cloudflared 2025.8.0,
no heartbeat, a world-executable monitor, an SCTP warning, active host/container swap allowances, and a
pending reboot. The subsequent production convergence and post-reboot review confirmed:

- the current branch-head application is deployed and healthy with zero restarts; the automated
  public-IP-to-tailnet transition in `step_1_setup.yml` awaits the planned clean rebuild;
- only cloudflared receives `TUNNEL_TOKEN`, and it runs the digest-pinned 2026.8.2 image;
- both containers remain read-only, portless, mountless, capability-free, memory/PID bounded, and denied
  swap by setting their combined RAM-plus-swap allowance equal to the RAM limit;
- host swap is inactive and absent from active `fstab` entries after reboot;
- the root-only hourly monitor successfully reaches the configured dead-man endpoint when release RPC works;
- the app logs contain no SCTP/runtime warning, BEAM distribution is loopback-only, and release RPC works;
- the Cloudflare tunnel is healthy over QUIC, with upstream-recommended UDP socket-buffer ceilings applied;
- `/healthz`, `/api/stats`, the 14-day in-memory activity chart, HTTPS security headers, UFW, hardened SSH,
  Tailscale, Docker, and unattended upgrades all pass their post-boot checks; and
- no reboot remains pending.

Still external/manual: confirm the superseded Cloudflare credential is revoked, verify control-plane 2FA
and the Tailscale ACL in their respective dashboards, confirm the desired Healthchecks.io alert integration
receives a test notification (successful pings were verified), and perform an intentional rollback drill.
