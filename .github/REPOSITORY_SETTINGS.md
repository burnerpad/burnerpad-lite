# Required GitHub repository settings

These are one-time control-plane settings and cannot be enforced by repository files alone. The founder is
the sole maintainer, so the design uses automated, auditable gates rather than pretending a second reviewer
exists.

## Repository and billing

- Keep both `burnerpad-lite` and `crypto-js` public.
- Set Actions and Packages budgets to **USD 0**, enable 75/90/100% alerts, and do not enable paid overage.
- Enable email/push notification for failed workflows and security alerts.
- Keep Actions' default `GITHUB_TOKEN` permission read-only; allow write only where a workflow declares it.
- Do not add VPS, Cloudflare, Tailscale, heartbeat, operator, or Erlang-cookie secrets to GitHub.

## `main` ruleset

Create an active repository ruleset targeting `main`, applying to administrators, with:

- pull requests required, but zero human approvals (solo-maintainer compensating control);
- required checks: `test`, `browser`, `images`, `ops`, and `dco`;
- branch must be current before merge and all conversations resolved;
- signed commits and linear history required;
- force pushes and branch deletion blocked;
- bypass list empty for routine work.

An emergency settings change is itself a security event: record why, restore the ruleset immediately, and
run every required check on the resulting commit. Never use an emergency bypass to publish crypto changes.

## Tag and release controls

- Create two active tag rulesets for `v*`:
  - a creation-only ruleset that restricts creation and lists only the founder as a bypass actor;
  - an immutability ruleset that blocks update and deletion with an empty bypass list.
  Keeping these controls separate prevents the founder's creation bypass from also permitting tag mutation.
- Create release tags locally with `git tag -s`, verify with `git tag -v`, then push the one tag.
- Never move or recreate a published tag. A correction gets a new patch version.
- The parent repository publishes containers only from a successful same-repository `main` workflow run.
- The crypto repository publishes the universal CLI package only when a tag exactly matches `package.json`.

After the first container release, link both GHCR packages to the source repository and set visibility to
**Public**. Confirm anonymous pulls. Do not deploy `main`, `latest`, or a tag without resolving and verifying
its digest, Sigstore identity, GitHub build provenance, and the digest-bound Trivy scan attestation with
predicate type `https://burnerpad.io/attestations/trivy/v1`. The release workflow creates the signature and
scan attestation only after the exact published digest passes the HIGH/CRITICAL vulnerability policy.

## Security features

- Enable Private Vulnerability Reporting and secret scanning/push protection where GitHub offers them.
- Enable Dependabot alerts; repository workflows remain the authoritative advisory/image gates.
- Review installed GitHub Apps and deploy keys quarterly; neither production repository needs a deploy key.
- Review Actions usage and package visibility quarterly and after any GitHub billing-policy change.

## Public canary release identity

- Set the non-secret repository variable `BURNERPAD_PUBLIC_ORIGIN` to the canonical production HTTPS
  origin, without a path or trailing slash. Forks must not rely on the burnerpad.io workflow fallback.
- Set the non-secret repository variable `BURNERPAD_PRODUCTION_REVISION` to the full 40-character lowercase
  Git revision currently deployed in production.
- Update it immediately after every successful deployment or rollback. The scheduled canary fails closed
  when the variable is absent, malformed, or differs from the revision observed through `/api/stats`.
- Do not substitute `github.sha`: a scheduled run checks out the repository's current default branch, which
  is not necessarily the release currently running in production.

Record completion of these external settings in the production launch checklist; screenshots must not
contain tokens, private URLs, capability IDs, or personal recovery codes.
