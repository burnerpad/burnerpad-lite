# Availability and recovery runbook

Burnerpad targets **99.9% monthly availability**, a **60-minute RTO**, and an intentionally destructive
**RPO of every live secret**. It has one active ETS-backed instance: restart, deployment, host loss, or
rebuild destroys all unclaimed ciphertext. There is no persistence, snapshot restore, rolling deployment,
or second replica. Backing up the VPS is neither useful nor allowed as a secret-recovery mechanism.

## Quarterly recovery drill

Use a throwaway VPS and record start/end timestamps plus evidence links in the quarterly GitHub issue.
Never point the drill at production credentials or the production hostname.

1. Generate fresh, drill-only Tailscale auth, Cloudflare tunnel, Healthchecks, and VPS credentials.
2. Run `step_1_setup.yml` against the throwaway inventory and verify the public IP has no inbound service.
3. Resolve the latest passing full-SHA GHCR tags, verify cosign signatures and GitHub attestations, then
   deploy their exact digests with `step_2_deploy.yml` to a drill hostname.
4. Run `edge-contract.mjs` and `e2e-canary.mjs`; verify a second reveal is gone and no capability appears
   in Actions, Ansible, Cloudflare, tunnel, or host logs.
5. Force-stop the app and tunnel in turn. Confirm UptimeRobot and Healthchecks.io reach the tested alert
   channel, then confirm recovery notifications after restoration.
6. Run `step_3_compliance.yml --check --diff`; record any drift. Confirm the total elapsed time is <60 min.
7. Destroy the VPS, tunnel, DNS route, tailnet node/key, heartbeat, and drill credentials. Close the issue
   with the timestamps, RTO result, alert evidence, artifact digests, and follow-up work—never credentials.

## Suspected compromise

Do not repair or reuse the host. Preserve only sanitized provider/control-plane audit evidence, then:

1. Disable the public tunnel route and revoke the tunnel token and Tailscale node/session/auth keys.
2. Revoke/rotate VPS, GitHub, GHCR, heartbeat, Cloudflare, registrar, and notification credentials that the
   host or compromised control plane could have reached. Every deploy already rotates the Erlang cookie.
3. Remove the old host from Tailscale and the VPS provider; terminate any active console/API sessions.
4. Review GitHub workflow history, signatures, attestations, branch changes, package versions, Cloudflare
   zone/tunnel changes, and domain/registrar audit logs. Do not log secret IDs or source-IP mappings.
5. Build a fresh VPS and fresh tunnel from the last independently verified digest, run both public checks,
   and communicate that all formerly live secrets were lost. Do not claim cryptographic deletion.

Healthchecks.io is the hourly VPS dead-man switch; UptimeRobot is the independent five-minute public
HTTPS/content probe; the GitHub `public-canary` performs the full encrypted transaction every 15 minutes.
Scheduled Actions can be delayed or disabled after repository inactivity, so none replaces the others.
