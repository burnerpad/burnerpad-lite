# Deployment and operations runbook

This root-level runbook is the authoritative procedure for the only supported production deployment. It
covers repository controls, release publication, artifact verification, first-host provisioning, routine
deployments, rollback, monitoring, and compromise recovery. Historical plans under `docs/` are not
deployment instructions.

Burnerpad's supported production shape is deliberately narrow: **one active app container on one VPS**,
behind Cloudflare Tunnel, administered over Tailscale. It has no database, persistence, replicas, rolling
deployment, or restore path. Restarting or replacing the app destroys every resident ciphertext. The
Ansible deploy reports that count and requires `DESTROY` when it can observe a non-zero count.

The PR removes the legacy root `docker-compose.yml` and nginx configuration. Do not restore or deploy
either: Ansible renders the supported Compose definition, cloudflared connects directly to `app:4000` on
an internal Docker network, no application port is published on the host, and both the tunnel and Tailscale
administrative path are outbound-established.

Production is artifact-based, not laptop-built:

```text
push to main
  -> complete GitHub test workflow
  -> exact parent + pinned crypto source archive
     (SPDX SBOM + GitHub SBOM attestation + retained evidence bundle)
  -> public GHCR app + tunnel images for sha-<40-char commit>
     (image SBOMs + provenance + keyless Sigstore signatures)
  -> laptop verifies exact digests and attestations
  -> Ansible replaces the one VPS instance
  -> laptop runs public edge checks and create/claim/decrypt canary
```

The scheduled synthetic runs on a GitHub-hosted runner, not on the VPS. UptimeRobot also checks from
outside the deployment. Healthchecks.io is the inverse dead-man signal sent by the VPS only while local
readiness, host resources, and restart/OOM checks remain healthy.

## Availability and recovery contract

- One active instance only. Multiple replicas would have independent ETS tables and break create/peek/claim
  routing and atomicity.
- RPO is **all resident ciphertexts**; every deploy, reboot, OOM restart, or replacement may lose them.
- Target RTO is 60 minutes and the availability objective is 99.9%; see
  [`docs/RECOVERY.md`](docs/RECOVERY.md).
- There is no payload backup. Recovery means verifying or replacing infrastructure and redeploying a
  previously attested image.
- A provider or root/RAM compromise may copy ciphertext. Removing a row makes it unreachable through the
  app but the managed runtime does not promise physical RAM zeroization.

## Cost guardrail

Keep the source repository and GHCR packages public. As verified on 2026-08-23, GitHub documents standard
hosted-runner Actions use as free for public repositories and currently makes Container Registry storage
and bandwidth free. Configure a **zero-dollar Actions/Packages budget** with alerts and never add a payment
method solely for Burnerpad; if GitHub changes those terms, workflows must stop rather than incur a
recurring bill. Recheck the official [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages) pages at
launch, and see [`.github/REPOSITORY_SETTINGS.md`](.github/REPOSITORY_SETTINGS.md) for the one-time controls.

As verified on 2026-08-23, the [Healthchecks.io pricing page](https://healthchecks.io/pricing/) lists a free
20-job Hobbyist plan and the [UptimeRobot pricing page](https://uptimerobot.com/pricing/) lists a free
50-monitor plan with five-minute checks. Those limits and terms can change, so verify them when creating
the checks. Neither service is a durability service. The committed edge-rate policy deliberately uses the
single rule included with Cloudflare Free; do not upgrade a Cloudflare plan solely to satisfy this runbook.

## Required accounts and control planes

Use MFA/passkeys and recovery codes on all four:

| Control plane | Purpose | Required material |
|---|---|---|
| GitHub | source, CI, public GHCR, attestations, scheduled synthetic | public repository and packages |
| VPS provider | Ubuntu 24.04 LTS host and provider-console break-glass | fresh 2 GB+ VM, bootstrap password |
| Cloudflare Free | TLS, one WAF rate-limit rule, and outbound Tunnel ingress | zone, named tunnel, tunnel token |
| Tailscale | sole administrative network | tagged one-use auth key and restrictive grants |

The project assumes one tailnet user: the founder/operator. Do not grant the VPS access to other tailnet
devices. The initial host-key pin is trust-on-first-use after the setup play removes only the two exact
replacement-host entries; this accepted bootstrap risk must never become a global `StrictHostKeyChecking
no` policy. The VPS provider console is the break-glass path.

## Prepare the repository and laptop

Install Docker with buildx, Ansible, `sshpass`, `cosign`, and the GitHub CLI. The public smoke checks use
the exact Node version in `.tool-versions` (currently 24.19.0); CI also reads its Elixir, Erlang, and Node
versions from that one file.

On an x86-64 Ubuntu control machine, do not install `gh` from Ubuntu 26.04's default repository: its
2.46.0 package predates the required `gh attestation verify` command. Install these checksum-pinned
upstream packages instead (versions and asset digests verified against their official GitHub releases on
2026-08-25):

```bash
bp_tools_dir=$(mktemp -d)

curl --fail --location --output "$bp_tools_dir/gh.deb" \
  https://github.com/cli/cli/releases/download/v2.98.0/gh_2.98.0_linux_amd64.deb
printf '%s  %s\n' \
  f65a3fa2fa0eb2e97c445ee3f5e087a40aae03b64847f45a8f13805e504535d6 \
  "$bp_tools_dir/gh.deb" | sha256sum --check

curl --fail --location --output "$bp_tools_dir/cosign.deb" \
  https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign_3.1.3_amd64.deb
printf '%s  %s\n' \
  75357d96161da4d06d37c4b2831fa6978483cdce661999e5951b586f9ee1d710 \
  "$bp_tools_dir/cosign.deb" | sha256sum --check

sudo dpkg --install "$bp_tools_dir/gh.deb" "$bp_tools_dir/cosign.deb"
find "$bp_tools_dir" -depth -delete
```

The package sources and alternative platform instructions are maintained by
[GitHub CLI](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) and
[Sigstore Cosign](https://docs.sigstore.dev/cosign/system_config/installation/).

Clone recursively and enable the secret guard:

```bash
git clone --recurse-submodules https://github.com/burnerpad/burnerpad-lite
cd burnerpad-lite
git config core.hooksPath .githooks
gh auth login --hostname github.com --web
ops/check-control-tools.sh

cd ops
./install-requirements-locked.sh
cp inventory.example.ini inventory.ini
install -m 600 group_vars/all/secrets.example.yml group_vars/all/secrets.yml
```

The fail-fast check requires the exact Node version pinned in `.tool-versions`, a reachable Docker daemon,
a runnable Cosign, a GitHub CLI that provides `gh attestation verify`, and an authenticated GitHub.com
session. It prints no authentication material.
Before committing any deployment change, follow
[`CONTRIBUTING.md` → Signed commits and DCO](CONTRIBUTING.md#signed-commits-and-dco): review staged paths,
use `git commit -S -s`, verify locally, and confirm GitHub marks every pull-request commit **Verified**.

Create `secrets.yml` only once. If it already exists, edit it in place—do not copy the example over it or
you will overwrite working credentials. Fill every field in that local file before its corresponding
step. It deliberately contains two kinds of deployment input:

- capability-bearing secrets: the Tunnel and Rulesets tokens, Tailscale key, and heartbeat URL; and
- public but instance-specific metadata: the legal operator, contact addresses, jurisdiction, policy URL,
  and public origin.

The second group is local not because it is confidential, but because committing one operator's identity
would let a fork accidentally deploy under that operator's name. The public OCI image contains neither
group; Ansible supplies them to the container at runtime.

`install-requirements-locked.sh` downloads each direct and transitive Galaxy input once, rejects any
missing, extra, or checksum-mismatched archive, and installs only those verified local archives with
dependency resolution disabled. It stages a complete fresh dependency tree before replacing the generated
`.collections/` and `.roles/` directories, so stale artifacts cannot remain active.

`inventory.ini`, `secrets.yml`, `.vault_pass`, and generated runtime credentials are gitignored and blocked
by the pre-commit guard. Keep `secrets.yml` mode `0600`. On the VPS, Ansible owns the generated
`/opt/burnerpad/.env` as `root:root` with mode `0600`; direct Compose commands that need to read it must run
through `sudo`. Encrypt `secrets.yml` with Ansible Vault if it may be backed up or shared:

```bash
ansible-vault encrypt group_vars/all/secrets.yml
```

Never pass the deployment `.env` wholesale to the app container. It also holds the tunnel token; Compose
uses an explicit app allowlist and gives `TUNNEL_TOKEN` only to cloudflared.

## Understand the release contract

The parent repository publishes **two public OCI images** to GitHub Container Registry (GHCR):

| Artifact | Build definition | Immutable discovery tag | Deployment identity |
|---|---|---|---|
| Application | `Dockerfile` | `ghcr.io/burnerpad/burnerpad-lite:sha-<full-sha>` | resolved `@sha256:<digest>` |
| Tunnel | `ops/cloudflared.Dockerfile` | `ghcr.io/burnerpad/burnerpad-lite-cloudflared:sha-<full-sha>` | resolved `@sha256:<digest>` |

The release workflow also moves a `main` tag for operator discovery, but deployment must never consume it.
Only the full-SHA tag may be pulled to discover a release, and Compose receives the resolved digest. There
is no `latest` deployment path.

A same-repository push to `main` first runs the complete `test` workflow: Elixir and browser/crypto tests,
full parent and submodule history secret scanning, dependency audits, app/tunnel builds, high/critical
Trivy gates, production-container tests, smoke-script tests, workflow/shell linting, and Ansible/Compose
validation. Only a successful `test` workflow triggers `.github/workflows/release.yml`. Pull requests,
forks, failed test runs, and non-`main` branches cannot publish.

Before publishing either image, the release workflow packages the exact parent commit plus its pinned
crypto submodule commit into a deterministic source archive. Pinned Syft generates an SPDX JSON SBOM from
that extracted tree; GitHub attests the archive/SBOM relationship, verifies it immediately, and retains the
archive, SBOM, Sigstore bundle, and checksums as one workflow artifact for 90 days.

For each image, the release workflow then:

1. checks out the exact tested full SHA, including the pinned crypto submodule (currently independently
   released as `@burnerpad/crypto` v1.4.2);
2. builds only `linux/amd64` and embeds the parent revision in OCI labels (and in the app runtime);
3. pushes both `sha-<full-sha>` and `main` tags to GHCR;
4. asks BuildKit for an **image SBOM** and maximum-mode provenance;
5. attaches a GitHub build-provenance attestation to the pushed digest;
6. adds and immediately verifies a keyless Sigstore signature whose certificate identity is the
   repository's `release.yml` on `refs/heads/main`.

The source SBOM and both image SBOMs are distinct release records: the former describes the reviewed source
tree, while the latter describe the built runtime contents.

The tunnel artifact is not an unreviewed mutable upstream image. `ops/cloudflared.Dockerfile` fetches an
exact upstream release commit, compiles its vendored dependencies with the pinned Go toolchain, and copies
the static binary into a digest-pinned distroless image. The daily dependency audit rebuilds and scans both
project images, checks for a newer cloudflared release, and requires removing this compatibility build once
Cloudflare's official current image passes the repository's vulnerability policy.

Publication and deployment are deliberately separate. The release workflow has no VPS, Cloudflare,
Tailscale, heartbeat, operator, or Erlang-cookie secret and cannot contact production. Deployment is an
operator-initiated Ansible action from a clean checkout after independently verifying the public artifacts.

In particular, deployment never builds on the laptop, pushes an image, trusts a mutable tag, exposes an
origin port, creates a payload backup, or performs an automatic rollback. A failed post-replacement public
check is an incident because the prior in-memory rows have already been destroyed.

## Configure GitHub releases and canary variables

Apply the branch/ruleset controls in [`.github/REPOSITORY_SETTINGS.md`](.github/REPOSITORY_SETTINGS.md).
After the first successful `main` release:

1. Open both packages, `burnerpad-lite` and `burnerpad-lite-cloudflared`, under the repository/organization
   package settings.
2. Confirm each is linked to this source repository and set its visibility to **Public**.
3. Confirm anonymous `docker pull ghcr.io/burnerpad/burnerpad-lite:sha-<full-sha>` works.
4. Verify the package exposes provenance/SBOM data and that `cosign verify` and `gh attestation verify`
   work using the identity in the deploy role.

Set the scheduled public canary's non-secret origin before enabling it:

```bash
gh variable set BURNERPAD_PUBLIC_ORIGIN --body 'https://burnerpad.example'
```

After the first successful deployment, set its independently maintained expected release:

```bash
gh variable set BURNERPAD_PRODUCTION_REVISION --body '<deployed-full-40-character-git-sha>'
```

Update `BURNERPAD_PRODUCTION_REVISION` immediately after every successful forward deployment or rollback.
Do not use `github.sha`: a scheduled workflow checks out the current default branch, which need not be the
release running in production. The scheduled canary intentionally fails closed when the expected revision
is absent, malformed, or differs from `/api/stats`.

## Configure Tailscale

Create the `tag:burnerpad` tag, owned only by your user, and grants with these effects:

- your user/device may reach `tag:burnerpad` and use Tailscale SSH as `deploy` or break-glass `root`;
- `tag:burnerpad` cannot initiate connections to your laptop or other tailnet devices;
- no other user may reach the tag.

Use `action: accept` for the operator's SSH rule because unattended Ansible cannot complete a browser
reauthentication challenge. Generate a tagged, one-use/pre-authorized auth key and store it as
`tailscale_auth_key` in `ops/group_vars/all/secrets.yml`. The setup play consumes it and the routine deploy
does not reuse it. Review the actual policy in the Tailscale admin UI before bootstrap.

## Configure Cloudflare

Create a named Cloudflare Tunnel. The deployment needs three distinct Cloudflare values; do not confuse or
reuse them:

- the **Tunnel token** authenticates the `cloudflared` connector;
- the **Zone ID** identifies the one production domain to audit; and
- a dedicated **read-only Rulesets API token** lets routine deployment detect rate-limit policy drift.

The Rulesets token is not a Tunnel token, Global API Key, Origin CA key, or general-purpose account token.
It is deliberately unable to edit the zone.

### Obtain the production Zone ID

1. Sign in to the [Cloudflare dashboard](https://dash.cloudflare.com/).
2. Open **Domains** and select the production domain (`burnerpad.io` for the official deployment).
3. On the domain's **Overview** page, scroll to the **API** section.
4. Copy **Zone ID**. Do not copy the adjacent Account ID.

Cloudflare also documents this path in
[Find account and zone IDs](https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/).
The deploy preflight requires the Zone ID's exact 32-character lowercase hexadecimal form.

### Create the read-only Rulesets audit token

1. In the Cloudflare dashboard, open **My Profile** → **API Tokens**.
2. Select **Create Token**, then **Create Custom Token**. Do not use **Read All Resources**.
3. Give it a purpose-specific name such as `Burnerpad deployment ruleset audit`.
4. Add exactly this permission:

   | Scope | Permission | Access |
   |---|---|---|
   | Zone | Zone WAF | Read |

5. Under **Zone Resources**, select **Include** → **Specific zone** → the production domain. Do not grant
   access to all zones.
6. Leave account-level, DNS, Tunnel, and write/edit permissions absent. Add an expiry or client-IP filter
   only when there is an operational plan to rotate the token before expiry and the operator has stable
   egress; otherwise either restriction can unexpectedly block a deployment.
7. Select **Continue to summary**, verify the one-zone/read-only scope, and select **Create Token**.
8. Copy the token immediately. Cloudflare displays the secret only once.

Cloudflare's [token creation guide](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
documents the dashboard flow. `Zone WAF Read` is sufficient for the Rulesets entry-point GET used by the
deployment; see Cloudflare's
[zone custom-ruleset API documentation](https://developers.cloudflare.com/waf/custom-rules/custom-rulesets/).
Do not broaden the permission if the audit returns an error—first verify that the token is active, scoped
to the correct zone, and that the copied Zone ID is the ID for that same domain.

### Store the permanent Cloudflare values

Before creating the temporary write token, store the Tunnel token, Zone ID, and newly displayed read-only
token in the gitignored, operator-local `ops/group_vars/all/secrets.yml`:

```yaml
cloudflare_tunnel_token: "eyJ..."
cloudflare_zone_id: "0123456789abcdef0123456789abcdef"
cloudflare_rulesets_read_token: "read-only-zone-rulesets-token"
```

The Zone WAF **Edit** token used in the next subsection is temporary and must never be added to this file.
Edit `secrets.yml` directly with a local editor; never put a real token in a shell command, chat, issue,
screenshot, workflow secret, or commit. If the file is plaintext, keep it mode `0600`; if it is
Vault-encrypted, use `ansible-vault edit` rather than decrypting it beside the repository. The release
workflow does not need any Cloudflare credential.

The deploy validates these permanent values and calls the exact read-only
`/zones/{zone_id}/rulesets/phases/http_ratelimit/entrypoint` endpoint before replacing the running app. If
the read-only token is exposed, revoke it, create another token with the same narrow scope, and replace only
`cloudflare_rulesets_read_token` in the local secrets file.

### Provision the one Free-plan rate-limit rule

Cloudflare Free permits one rate-limit rule, only Path and Verified Bot in its matching expression,
per-IP counting, and 10-second counting and mitigation periods. The committed policy combines health,
readiness, crypto, and font paths into that one allowance. These limits are documented in Cloudflare's
[rate-limiting availability table](https://developers.cloudflare.com/waf/rate-limiting-rules/#availability).

Provision this rule **once**, before the first deployment. Before continuing, confirm all of these:

- the production domain is an active Cloudflare zone on the **Free** plan;
- the permanent Zone ID and `Zone WAF Read` token are already stored in `secrets.yml` as described above;
- the checkout is a reviewed `main` commit, and `node --version` matches `.tool-versions`; and
- nobody has manually created a rate-limit rule for the zone.

Do not build the rule manually in the dashboard: the audit depends on the committed stable rule `ref`, and
the provisioning script supplies the exact API representation. The script has no npm dependencies and
uses Node's built-in `fetch`. Its behavior is intentionally narrow:

1. require the explicit `--apply` option and validate only the shape of the Zone ID and write token;
2. `GET` the fixed Cloudflare `http_ratelimit` entry-point endpoint for that zone;
3. if it is absent (`404`), `POST` the exact committed `ops/cloudflare/rate-limit-policy.json` rule;
4. if it exists, validate it and exit successfully only when it already matches; and
5. refuse every mismatch. It never sends `PUT`, `PATCH`, or `DELETE`, never overwrites a rule, and never
   prints the token, Zone ID, authorization header, or Cloudflare response body.

Create a separate, temporary API token:

1. Open **My Profile** → **API Tokens** → **Create Token** → **Create Custom Token**.
2. Name it `Burnerpad one-time rate-limit provisioning`.
3. Add exactly **Zone → Zone WAF → Edit**.
4. Include only **Specific zone** → the production domain.
5. Confirm that no account, DNS, Tunnel, or other permission is present; create and copy the token.

From the repository root, enter both values at hidden/non-history prompts and explicitly apply the policy:

```bash
cd "$(git rev-parse --show-toplevel)"
read -rsp "Cloudflare Zone ID: " CLOUDFLARE_ZONE_ID
printf '\n'
read -rsp "Temporary Zone WAF write token: " CLOUDFLARE_RULESETS_WRITE_TOKEN
printf '\n'
export CLOUDFLARE_ZONE_ID CLOUDFLARE_RULESETS_WRITE_TOKEN
node ops/cloudflare/provision-rate-limit-policy.mjs --apply
unset CLOUDFLARE_RULESETS_WRITE_TOKEN CLOUDFLARE_ZONE_ID
```

Expect `Cloudflare Free-plan rate-limit policy created`. If it reports `already-configured`, the deployed
rule already matches exactly. Any other result is a hard stop. Do not put the temporary write token in
`secrets.yml`, an Ansible variable, shell history, chat, or Git.

Independently verify the result with the permanent read-only token—the same capability routine deployments
will use. Re-entering both values at hidden prompts makes this check self-contained and keeps them out of
shell history:

```bash
cd "$(git rev-parse --show-toplevel)"
read -rsp "Cloudflare Zone ID: " CLOUDFLARE_ZONE_ID
printf '\n'
read -rsp "Permanent Zone WAF read token: " CLOUDFLARE_RULESETS_READ_TOKEN
printf '\n'
export CLOUDFLARE_ZONE_ID CLOUDFLARE_RULESETS_READ_TOKEN
node ops/cloudflare/audit-rate-limit-policy.mjs
unset CLOUDFLARE_RULESETS_READ_TOKEN CLOUDFLARE_ZONE_ID
```

Expect exactly `Cloudflare Free-plan rate-limit policy passed rules=1`. Only after that independent check
passes, revoke the temporary write token in **My Profile** → **API Tokens**. Confirm it is no longer listed
as active. Keep the distinct read-only token in `secrets.yml`; routine deployment needs only that token.
Cloudflare documents the 404-then-create flow for a missing phase entry point in its
[rate-limit API procedure](https://developers.cloudflare.com/waf/rate-limiting-rules/create-api/).

Failure handling is deliberately conservative:

- A path containing `/ops/ops/cloudflare/` means the command was run from `ops/`; return to the repository
  root and use the command exactly as shown.
- `already exists but differs` means the Free plan's one rule is occupied. Inspect **Security → Security
  rules → Rate limiting rules** and identify its owner; do not delete or replace it blindly.
- `created a ruleset that does not match` may mean the creation succeeded but Cloudflare normalized a new
  field. Do not retry, delete, or recreate it. Run the read-only audit, retain only its fixed error message
  and the repository commit ID, and request review without sharing either token or the Zone ID.
- An access rejection means the token, permission, resource scope, or Zone ID is wrong. Correct the narrow
  token instead of granting broader account access.

The Free-plan rule setup is complete only when every item below is true:

- [ ] the Zone ID and permanent read-only token are stored in mode-`0600` or Vault-encrypted `secrets.yml`;
- [ ] the provisioner returned `created` or `already-configured`;
- [ ] the independent read-only audit returned `passed rules=1`;
- [ ] the temporary `Zone WAF Edit` token was revoked; and
- [ ] no write-capable Cloudflare credential exists in Git, GitHub, Ansible, or the VPS.

Do not run Cloudflare's host installer; Compose runs the independently built and attested tunnel image.
After the first connector is healthy, publish an application route:

| Field | Value |
|---|---|
| Hostname | your Burnerpad hostname |
| Service | HTTP |
| URL | `app:4000` |

Apply every setting in [`ops/CLOUDFLARE_PROFILE.md`](ops/CLOUDFLARE_PROFILE.md). In particular:

- redirect HTTP to HTTPS; minimum TLS 1.2;
- preserve the application's domain-wide HSTS `includeSubDomains; preload` contract;
- never cache HTML, API, reveal, create, stats, health, or capability paths;
- static `/crypto/*` and `/fonts/*` may be cached only with exact byte preservation;
- provision the one exact Free-plan `http_ratelimit` rule in `ops/cloudflare/rate-limit-policy.json`; the
  deploy play audits it before replacing the running application;
- disable Rocket Loader, Auto Minify, email rewriting, HTML/JS transforms, and response-body modification;
- do not enable Logpush/Logpull for this zone; Cloudflare metadata can include client IP plus a secret-ID
  URL, so use the shortest suitable retention.

The public `ops/smoke/edge-contract.mjs` check enforces redirect, TLS, headers, cache behavior, SRI bytes,
transformation markers, and the trusted-proxy source path after every deploy and on schedule. Its
match-only probe compares Cloudflare's edge observation with the app's resolved `/32` or `/64`, repeats
with a forged `CF-Connecting-IP`, and never prints or returns either address.

## Configure identity and capacity

Add the public identity for this one deployment to the existing gitignored
`ops/group_vars/all/secrets.yml`. For the official `burnerpad.io` service, the block is:

```yaml
operator_name: "Impulsa SLU"
abuse_email: "abuse@burnerpad.io"
jurisdiction: "Andorra"
security_email: "security@burnerpad.io"
security_policy_url: "https://github.com/burnerpad/burnerpad-lite/blob/main/SECURITY.md"
public_origin: "https://burnerpad.io"
```

These values remain runtime configuration. They are not Docker build arguments, labels, or files copied
into the image. Another operator can pull the same immutable image and supply its own values through these
environment-variable names; an operator using this Ansible deployment changes only its local
`secrets.yml`.

Edit committed `ops/group_vars/all/vars.yml` only when changing reusable capacity or host defaults. Size
`MAX_SECRETS`, byte budget, row budget, memory, and CPU together. The payload floor is roughly
`MAX_SECRETS × 64 KiB`, before BEAM/ETS overhead; leave material RAM for the OS and tunnel. The default
10,000 rows / 1,500 MB app cap is intended for a 2 GB host, with a 2% per-source byte and row ceiling.

For larger hosts, use the measured 4/8/12/16 GiB starting points and caveats in
[`docs/CAPACITY_PLANNING.md`](docs/CAPACITY_PLANNING.md), then rerun its constrained matrix on the intended
VPS provider before raising the limit.

The generated Compose environment currently overrides `MAX_SECRETS`, `GLOBAL_CREATE_CEILING`,
`PER_IP_BUDGET`, and `PER_IP_ROW_BUDGET`; other application limits retain the boot-validated defaults in
`Burnerpad.Config`. If you expose more of them through Ansible, preserve
`RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING`, `GLOBAL_CREATE_CEILING < GLOBAL_CEILING`, byte budget no
greater than `MAX_SECRETS × 64 KiB`, and row budget no greater than `MAX_SECRETS`. Do not use `0` to mean
unlimited: invalid or out-of-range production configuration refuses to boot.

Replace every operator placeholder in the local `secrets.yml` and have the rendered
Terms/Acceptable-Use wording and linked security policy reviewed for the actual operator and jurisdiction
before launch. The deployment preflight names an invalid public field without printing any value. Each
capability task identifies its field but keeps the value fully censored. The production image independently
refuses `.invalid`/`CHANGE_ME` identity values; those technical checks are not legal review.

The production app also requires a full source SHA, exact OCI digest, and a runtime Erlang cookie. Do not
put those in inventory: the release/deploy process derives the first two and generates a fresh cookie on
every deployment.

`remote_dir` controls only where generated deployment files live. `compose_project_name` is the independent,
stable identity used by existing-container discovery, every Compose command, monitoring, compliance, and
deployment. Changing `remote_dir` therefore cannot bypass resident-row discovery or the `DESTROY` prompt.

The isolated `backend` bridge defaults to `172.29.0.0/29`. This intentionally differs from the pre-1.0
`burnerpad_internal` bridge (`172.28.0.0/16`), allowing the first v1 deployment to create its hardened
replacement while the legacy containers are still running. Before rendering or replacing anything, the
deploy play compares the planned CIDR with every Docker IPAM allocation and permits overlap only with the
exact `backend` network already owned by the same Compose project. If it reports a conflict on an unusual
host, inspect the allocated ranges on the VPS:

```bash
docker network inspect $(docker network ls -q) \
  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

Then add an unused canonical RFC 1918 CIDR, preferably a `/29`, to the gitignored local `secrets.yml`:

```yaml
backend_subnet_override: "172.30.0.0/29"
```

Do not choose a range contained by—or containing—an existing allocation. The same validated value configures
both Docker IPAM and the app's `TRUSTED_PROXIES`; never widen the latter independently.

## Runtime properties the deployment must preserve

The generated deployment is part of the security contract. After any Compose, network, image, or host-role
change, verify all of these remain true:

| Area | Required production property |
|---|---|
| Process | App and tunnel run non-root with read-only roots, all Linux capabilities dropped, `no-new-privileges`, PID/CPU/memory limits, and core dumps disabled. |
| Memory | App scratch space is a bounded `/tmp` tmpfs; the memory-plus-swap limit equals the memory limit and host swap is disabled, so ciphertext and credentials are not intentionally paged to disk. |
| Network | Nothing is published on the host. The app joins only the validated private `/16`–`/29` internal `backend` network; cloudflared alone also joins `egress` and dials Cloudflare. UFW denies inbound traffic except the Tailscale interface. |
| BEAM | EPMD/distribution bind to loopback, the image contains no release cookie, and Ansible supplies a fresh strong runtime cookie on every deployment. |
| HTTP | HTTP/2 and WebSockets remain disabled because the service uses neither. GET/HEAD `/healthz` is liveness; GET/HEAD `/readyz` checks Store/Abuse processes and ETS tables and drives container readiness. Mutation methods are rejected. |
| Edge identity | Only the dedicated Compose bridge CIDR may supply `CF-Connecting-IP`; the public baseline-and-forgery probe must pass after every tunnel/network change. |
| Browser delivery | Strict CSP/security headers and boot-verified SRI remain intact; dynamic/API/capability responses are `no-store`, while stable crypto assets require revalidation and exact bytes. |
| Configuration | Production refuses placeholder operator/security identity, a non-full source revision, an invalid image digest, weak cookie, non-HTTPS or whitespace/control-bearing policy URL, or invalid numeric/capacity relations. |
| Data/logs | Ciphertext exists only in bounded ETS memory. Application logs contain fixed route classes and release/status/timing data, never concrete capability paths or source identifiers. |

Do not weaken one row in isolation to fix an operational symptom. For example, publishing the app port to
debug a tunnel, adding `env_file` to the app, enabling swap, or loosening trusted proxies changes the threat
model and requires a new security review.

## Configure availability monitors

Create both external services before the first deploy:

1. **Healthchecks.io dead-man check:** expected period one hour with about 30 minutes grace. Put the secret
   HTTPS ping URL in `heartbeat_url` inside `secrets.yml`. The root-only local diagnostic withholds the ping
   when readiness fails, disk/inodes/memory/CPU exceed thresholds, or a restart/OOM transition is observed.
2. **UptimeRobot HTTP check:** monitor `https://<public-origin>/readyz`, require HTTP 200, and alert the
   operator. This measures public reachability independently of the VPS.
3. **GitHub scheduled synthetic:** `.github/workflows/canary.yml` runs every 15 minutes from a hosted
   runner. It checks the edge contract (including loss/spoofing of client-IP resolution), uses a 60-second
   TTL for random Unicode plaintext, claims/decrypts it, verifies exact plaintext, and requires a second
   claim to return 404. Set the non-secret repository variable `BURNERPAD_PRODUCTION_REVISION` to the
   deployed full Git SHA after every deployment or rollback. Each check obtains the observed revision from
   `/api/stats`; failures and the refreshed durable GitHub issue identify the fixed stage, observed or
   expected release, and workflow run. They never include exception text, secret IDs, links, phrases,
   tokens, ciphertext, plaintext, full paths, addresses, or source mappings.

The root-only hourly sampler retains 52 weekly rotations, with a 365-day maximum age (approximately 12
months), of capability-free operational counters and host/VM resource measurements. Application JSON logs
are capped at 100 MB and tunnel error logs at 30 MB. None of these logs may contain secret IDs, management
tokens, ciphertext, phrases/plaintext, concrete request paths, raw or pseudonymous source identifiers, or
source-to-secret mappings.

Exercise each alert path once. A green dashboard with untested notification routing is not monitoring.

## Bootstrap and deploy

Put the fresh public IP under `[bootstrap]` and the intended tailnet hostname under `[burnerpad]` in
`ops/inventory.ini`, verify both targets visually, then:

```bash
cd ops
ansible-playbook step_1_setup.yml   # exactly once per fresh VPS
ansible-playbook step_2_deploy.yml  # first and every routine release
ansible-playbook step_3_compliance.yml
```

The setup play first establishes the `deploy` user and Tailscale path while the original recovery path
still works. Only after reconnecting over the tailnet and verifying `tailscale0` does it disable public
root/password SSH and apply OS/SSH, firewall, dump, and swap hardening. Routine deploys never remove host
keys or rerun bootstrap.

The deploy play refuses a dirty working tree. Its full local `HEAD` must already have successful CI and
public `sha-<HEAD>` app/tunnel images. It then:

1. pulls the full-SHA discovery tags and resolves their exact registry digests;
2. requires both OCI revision labels to equal `HEAD`;
3. verifies keyless Sigstore signatures and GitHub build-provenance attestations;
4. audits the exact Cloudflare Free-plan rate-limit rule with the read-only token;
5. rejects a backend CIDR that overlaps another Docker allocation, then generates a new runtime-only Erlang
   cookie and renders root-owned, mode-`0600` runtime configuration;
6. reads `/api/stats` and accepts the legacy `stored` name only for upgrading a pre-1.0 release; if any
   resident ciphertext exists, requires literal `DESTROY`;
7. starts digest-pinned, read-only, cap-dropped, CPU/memory/PID-bounded containers and waits for `/readyz`;
8. verifies the reported full revision and app image digest;
9. runs the public edge contract and create/claim/decrypt canary from the laptop.

The Compose task waits for both container health checks and may print no additional Ansible output for up
to 120 seconds. The tunnel image checks cloudflared's explicit loopback metrics readiness endpoint; a timeout
or unhealthy result stops the play before the revision/public canaries and must be diagnosed rather than
treated as a successful deployment.

The full-SHA tag is used only to locate the two GHCR artifacts. The root-owned, mode-`0600` `.env` and the
non-secret Compose template together resolve their immutable digest references, the app image digest exposed
by `/api/stats`, a fresh 64-character runtime-only Erlang cookie, operator configuration, resource limits,
and the tunnel token. The app receives an explicit environment allowlist and never receives the tunnel
token. The release cookie created by `mix release` is removed from the public image, so every deployment has
a different runtime credential.

After all nine steps pass, update the scheduled canary's expected release:

```bash
gh variable set BURNERPAD_PRODUCTION_REVISION --body "$(git rev-parse HEAD)"
```

If the post-deploy public canary fails, the app may already have been replaced and its prior rows lost.
Treat that as an incident; do not blindly repeat a claim or deployment.

## Verify the live system

On the VPS over Tailscale:

```bash
ssh deploy@burnerpad
cd /opt/burnerpad
sudo docker compose --project-name burnerpad ps
sudo docker inspect burnerpad-app-1 \
  --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Memory}} {{.HostConfig.CapDrop}} {{.RestartCount}}'
```

Expect no published app port, a healthy app, a tunnel container, read-only root filesystems, bounded logs,
and no host swap. From the laptop:

```bash
curl -fsS https://burnerpad.example/healthz
curl -fsS https://burnerpad.example/readyz
curl -fsS https://burnerpad.example/api/stats
```

Confirm `/api/stats` reports the expected full revision and `sha256:` digest. Do not paste the output of
capability endpoints into tickets, terminals with recording, or monitoring systems.

## Day-to-day operations

**Deploy:** merge/push a clean commit, wait for `test` and `release`, then run `step_2_deploy.yml` from that
exact checkout. Every deployment is destructive to resident ciphertext; choose a quiet period but do not
pretend zero loss is possible. After the public checks pass, update `BURNERPAD_PRODUCTION_REVISION` to that
checkout's full SHA.

**Rollback:** use a separate clean checkout/worktree at a previously published full SHA and run the same
deploy play. It verifies that old artifact exactly like a forward deployment. Never edit `.env` to point at
a mutable tag. The host retains five verified releases per project image; pruning targets only images with
the exact Burnerpad OCI source/title labels. After rollback verification, reset
`BURNERPAD_PRODUCTION_REVISION` to the rolled-back full SHA.

**Takedown:** from inside the app container, call `Burnerpad.Store.purge("THEID")`. This necessarily uses
the reported ID but no command, application log, shell history, or incident record should retain it. Use a
non-recording shell and clear the command from history immediately. An ID alone can claim/copy ciphertext;
it cannot decrypt a strong phrase, but it is still a sensitive destructive capability.

**Logs:** the app retains only sanitized route class/method/status/duration/release events. Keep
cloudflared at `error`. Temporary verbose diagnostics can contain paths/headers and must be tightly scoped
and deleted after the incident. Never log secret IDs,
management tokens, ciphertext, phrases, plaintext, full request paths, or source-IP mappings.

**Compliance drift:** run `step_3_compliance.yml` after host/repository dependency updates and quarterly.
The quarterly workflow opens a recovery-drill issue; perform the drill against a throwaway VPS, not the
production instance.

**Compromise:** rotate the Cloudflare tunnel token, Tailscale node/auth key, GitHub sessions/tokens, VPS
credentials, operator contact credentials, and monitoring URLs as applicable. Rebuild on a fresh VPS and
revoke the old node/tunnel connector. Do not attempt to certify an attacker-controlled host as clean.

## Troubleshooting

- **No full-SHA image:** wait for the `test` workflow and its subsequent `release` workflow. Confirm GHCR
  visibility is public and the commit is on `main`; never substitute `main` or `latest` in Compose.
- **Signature/attestation failure:** stop. Confirm the repository and workflow identity are exactly the
  configured values. Do not add `--insecure-ignore-*` flags.
- **Host-key failure during routine deploy:** stop and inspect through the provider console. Only fresh-host
  setup intentionally resets the two exact first-seen entries.
- **Tunnel 502:** the Cloudflare service URL is `app:4000`, both containers must share `backend`, the app
  must be ready, and host IP forwarding must remain enabled for Docker.
- **No heartbeat:** run the root diagnostic locally and inspect disk, inodes, memory, CPU, readiness,
  restart, and OOM state. Do not manually ping success merely to silence the alert.
- **Locked out:** use the VPS provider console. It is the accepted break-glass channel.

See also [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/RECOVERY.md`](docs/RECOVERY.md),
[`docs/PRODUCTION_READINESS_REVIEW.md`](docs/PRODUCTION_READINESS_REVIEW.md), and
[`ops/CLOUDFLARE_PROFILE.md`](ops/CLOUDFLARE_PROFILE.md).
