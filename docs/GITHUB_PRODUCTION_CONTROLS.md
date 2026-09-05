# GitHub production controls runbook

**Repository:** `burnerpad/burnerpad-lite`

**Organization:** `burnerpad`

**Prepared:** 2026-08-25

**Scope:** instructions and read-only verification only; preparing this runbook did not change any GitHub setting.

This runbook turns the requirements in `.github/REPOSITORY_SETTINGS.md` into an exact operator procedure.
Use the web UI for the final application unless the API path is specifically useful for repeatability. Rulesets
are available for public repositories on GitHub Free, and a repository administrator can manage them.
([GitHub: creating repository rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository))

## What is already true

The following state was observed through GitHub's public, read-only APIs on 2026-08-25:

- The repository is public and its default branch is `main`.
- Active branch ruleset `21448182`, `Protect main`, targets `~DEFAULT_BRANCH`. It currently blocks deletion and
  force-pushes and requires a pull request with zero approvals. It does **not** yet require signatures, linear
  history, status checks, an up-to-date branch, or resolved conversations. The unauthenticated API deliberately
  omits bypass actors, so the current bypass list was not verified.
  ([live ruleset](https://api.github.com/repos/burnerpad/burnerpad-lite/rulesets/21448182))
- PR head `7596e7d148ea8ffea74e0719def263d5ff593987` reported the five expected successful check contexts:
  `test`, `browser`, `images`, `ops`, and `dco`. All were emitted by the GitHub Actions app, integration ID
  `15368`.
  ([live check runs](https://api.github.com/repos/burnerpad/burnerpad-lite/commits/7596e7d148ea8ffea74e0719def263d5ff593987/check-runs))
- The release workflow will create the GHCR packages `burnerpad-lite` and `burnerpad-lite-cloudflared` only after
  a successful same-repository push to `main`. Package visibility therefore comes after the first successful
  main release workflow.
- Private vulnerability reporting is currently **disabled** on both `burnerpad/burnerpad-lite` and
  `burnerpad/crypto-js`. GitHub's public status endpoint returned `{"enabled":false}` for each repository.
  ([burnerpad-lite status](https://api.github.com/repos/burnerpad/burnerpad-lite/private-vulnerability-reporting),
  [crypto-js status](https://api.github.com/repos/burnerpad/crypto-js/private-vulnerability-reporting))
- Public CodeQL-database queries returned an empty list for both repositories. This does not prove the complete
  authenticated code-scanning configuration, but there is no public evidence of a CodeQL database yet. The
  other security-analysis settings are deliberately hidden from unauthenticated repository responses and must
  be checked by an administrator as described in section 6.

## Required authority and safe setup

| Control | Required authority | Supported automation |
|---|---|---|
| Repository rulesets | Repository admin, or a custom role with edit-rules permission | Web UI or REST; a fine-grained token needs repository **Administration: write** |
| Organization budgets | Organization owner or billing manager | Web UI or REST; a fine-grained token needs organization **Administration: write** |
| GHCR visibility | Admin permission on each package | Web UI; GitHub's documented Packages REST API has no package-visibility update operation |
| Personal notifications | The operator's own GitHub account | Web UI; REST can set only coarse repository watching, not Actions/security delivery preferences |
| Repository security features | Repository admin, organization owner, or security manager | Web UI or REST; write operations generally require repository **Administration: write** |

The authority requirements and REST permissions come from GitHub's
[ruleset REST documentation](https://docs.github.com/en/rest/repos/rules?apiVersion=2026-03-10) and
[budget REST documentation](https://docs.github.com/en/rest/billing/budgets?apiVersion=2026-03-10).
GitHub's documented [Packages REST surface](https://docs.github.com/en/rest/packages/packages?apiVersion=2026-03-10)
supports reading, deleting, and restoring packages and versions, but does not expose a visibility mutation.

If using the API, authenticate `gh` on a trusted workstation or put a short-lived fine-grained token in
`GH_TOKEN`. Never place a token in shell history, this repository, a command-line argument, or captured launch
evidence. The examples below use the current GitHub API version, `2026-03-10`.

The commits and GitHub API identify the apparent founder as `Cinderella-Man`, user ID `1019893`. The operator
must confirm that this is the intended sole release-tag creator before applying either tag payload. If it is
not, substitute the verified founder's immutable numeric user ID; do not guess from a display name.
([live GitHub user](https://api.github.com/users/Cinderella-Man))

## 1. Finish protecting `main`

### Preferred web-UI procedure

1. Open **burnerpad-lite → Settings → Rules → Rulesets → Protect main**.
2. Set enforcement to **Active** and retain the target **Default branch** (or explicitly `main`).
3. Leave **Bypass list** empty. Rulesets apply to administrators unless they are explicitly added to that list.
4. Enable these branch protections:
   - **Restrict deletions**.
   - **Block force pushes**.
   - **Require linear history**.
   - **Require signed commits**.
   - **Require a pull request before merging** with **0** required approvals.
   - Under the pull-request rule, enable **Require conversation resolution before merging**.
   - **Require status checks to pass** and enable **Require branches to be up to date before merging**.
5. Add these five required status checks, selecting **GitHub Actions** as the expected source for each:
   - `test`
   - `browser`
   - `images`
   - `ops`
   - `dco`
6. Under **Settings → General → Pull Requests**, ensure at least squash or rebase merging is enabled. The
   intended ruleset permits those two methods and the linear-history rule excludes merge commits.
7. Save the active ruleset, then reopen it and confirm that the bypass list is still empty.

GitHub documents the UI path, bypass list, targets, status-check entry, and strict/up-to-date option in
[Creating rulesets for a repository](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).
GitHub's rule reference explains that verified signatures are checked on matching commits and that a linear
history requires squash or rebase merging. It also recommends selecting an expected GitHub App because any
writer or integration can otherwise report a context with the same name.
([GitHub: available rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets))

Do not require the scheduled `audit`, `capacity`, `e2e`, or `open-drill` jobs. They do not run on every pull
request and would permanently block merging. The required contexts above are exactly the jobs that run on this
PR.

### Equivalent REST payload

`PUT /repos/burnerpad/burnerpad-lite/rulesets/21448182` replaces the mutable ruleset fields, so submit the
complete intended state rather than a partial `rules` array. The authenticated caller must be able to see and
verify `bypass_actors` before and after the update. GitHub documents the endpoint and schema in
[REST API endpoints for rules](https://docs.github.com/en/rest/repos/rules?apiVersion=2026-03-10#update-a-repository-ruleset).

```json
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {"type": "required_signatures"},
    {
      "type": "pull_request",
      "parameters": {
        "allowed_merge_methods": ["squash", "rebase"],
        "dismiss_stale_reviews_on_push": false,
        "dismissal_restriction": {
          "enabled": false,
          "allowed_actors": []
        },
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_approving_review_count": 0,
        "required_review_thread_resolution": true,
        "required_reviewers": []
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "do_not_enforce_on_create": false,
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          {"context": "test", "integration_id": 15368},
          {"context": "browser", "integration_id": 15368},
          {"context": "images", "integration_id": 15368},
          {"context": "ops", "integration_id": 15368},
          {"context": "dco", "integration_id": 15368}
        ]
      }
    }
  ]
}
```

Before using integration ID `15368`, re-read a current check run and confirm that `.app.slug` is
`github-actions` and `.app.id` is still `15368`. With the payload saved outside the repository as
`main-ruleset.json`, the supported `gh` call is:

```bash
gh api --method PUT \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/rulesets/21448182 \
  --input main-ruleset.json
```

### Verification

As an authenticated repository administrator, fetch the ruleset and verify all of the following: `active`
enforcement, `bypass_actors == []`, the six protection types, five exact checks, GitHub Actions integration ID,
strict status policy, zero approvals, and resolved conversations.

```bash
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/rulesets/21448182
```

Also test behavior with a harmless PR: an unsigned commit, stale branch, unresolved conversation, or failed
required check must not be mergeable. Verify direct-push, deletion, and force-push restrictions from the
authenticated ruleset response; do not risk the real branch merely to test a destructive failure mode.

## 2. Protect `v*` release tags without weakening immutability

Create **two** active tag rulesets targeting `v*`, not one:

| Ruleset | Bypass list | Rules | Result |
|---|---|---|---|
| `Release tag creation` | `Cinderella-Man` (user ID `1019893`) and GitHub Actions (integration ID `15368`) | Restrict creations | Only the founder or the gated release workflow can create `v*` |
| `Release tag immutability` | Empty | Restrict updates; restrict deletions | Nobody, including the founder, can move or delete a published `v*` through routine Git operations |

This split is essential. A bypass actor bypasses the ruleset, not one selected rule within it. If creation,
update, and deletion were in one ruleset, a creation bypass would also permit moving or deleting the tag.
Overlapping rulesets aggregate, so the founder and GitHub Actions can bypass only creation while remaining
bound by the separate no-bypass immutability rules. GitHub documents creation, update, deletion, User and
Integration bypass actors, and bypass modes in the [ruleset REST schema](https://docs.github.com/en/rest/repos/rules?apiVersion=2026-03-10#create-a-repository-ruleset).
GitHub also documents that multiple rulesets can apply to one ref at the same time in
[About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets).

### Web-UI procedure

For each ruleset, open **burnerpad-lite → Settings → Rules → Rulesets → New ruleset → New tag ruleset**:

1. Set the name from the table and enforcement to **Active**.
2. Under target tags, include the pattern `v*`.
3. For `Release tag creation`, add user **Cinderella-Man** and the **GitHub Actions** app to the bypass list
   with **Always allow**, then select **Restrict creations**.
4. For `Release tag immutability`, leave the bypass list empty, then select **Restrict updates** and
   **Restrict deletions**.
5. Save and reopen both rulesets to verify their target, enforcement, rules, and bypass lists.

If the UI does not offer either actor, use the documented REST `User` and `Integration` actors shown below.
Do not broaden the creation authority to every repository administrator or organization owner.

The UI and `fnmatch` targeting procedure are documented by GitHub in
[Creating rulesets for a repository](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).

### Equivalent REST payloads

Create the restricted tag-creation ruleset with `POST /repos/burnerpad/burnerpad-lite/rulesets`:

```json
{
  "name": "Release tag creation",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 1019893,
      "actor_type": "User",
      "bypass_mode": "always"
    },
    {
      "actor_id": 15368,
      "actor_type": "Integration",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": ["refs/tags/v*"],
      "exclude": []
    }
  },
  "rules": [
    {"type": "creation"}
  ]
}
```

Create the no-bypass immutability ruleset through the same endpoint:

```json
{
  "name": "Release tag immutability",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["refs/tags/v*"],
      "exclude": []
    }
  },
  "rules": [
    {
      "type": "update",
      "parameters": {
        "update_allows_fetch_and_merge": false
      }
    },
    {"type": "deletion"}
  ]
}
```

After saving each JSON payload outside the repository, submit it with:

```bash
gh api --method POST \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/rulesets \
  --input tag-ruleset.json
```

Creating a ruleset requires repository **Administration: write**. Reading the ruleset with sufficient write
access is also necessary because GitHub intentionally withholds `bypass_actors` from callers that cannot write
the ruleset.

### Automated release procedure and tag-signature limitation

The rulesets above control who may create, move, and delete refs. GitHub's `required_signatures` rule validates
the commits pushed to matching refs; it does not sign the annotated Git tag object. Routine parent releases
therefore trust the narrowly permissioned workflow, immutable tag ruleset, exact tested revision, OIDC build
provenance, source SBOM attestation, digest-bound vulnerability attestation, and keyless image signature—not
a long-lived tag-signing secret.

After a same-repository `main` run passes all required tests, `.github/workflows/release.yml` serially selects
the next patch after the latest reachable `vX.Y.Z` tag. It creates the annotated tag and GitHub Release only
after the exact source archive and both images pass all release gates. A rerun reuses a tag already naming the
same revision, and a failed release creates no tag, so neither case consumes another version. Routine
Dependabot merges therefore require no version edit, release branch, or manual tag.

Never force-push a tag, and never disable the immutability ruleset to correct a release. Publish a new patch
version instead. Once the no-bypass deletion rule is active, any matching test tag is intentionally permanent.

## 3. Create hard USD 0 Actions and Packages budgets

Use **organization-scoped, product-level** budgets so both public repositories are covered and no paid overage
can begin elsewhere in the `burnerpad` organization. Avoid overlapping repository/SKU budgets unless there is
a deliberate reason: GitHub warns that the most restrictive overlapping budget can unexpectedly block use.
([GitHub: setting up budgets](https://docs.github.com/en/billing/how-tos/set-up-budgets))

### Web-UI procedure

1. Open **burnerpad organization → Settings → Billing & Licensing → Budgets and alerts**.
2. Click **New budget** and create this Actions budget:
   - Type: **Product-level budget**.
   - Product: **Actions**.
   - Scope: **Organization** (`burnerpad`).
   - Amount: **USD 0 per month**.
   - Enable **Stop usage when budget limit is reached**.
   - Enable **Receive budget threshold alerts**; GitHub sends the fixed 75%, 90%, and 100% alerts.
   - Add the founder/operator as an alert recipient.
3. Repeat with product **Packages**, also USD 0, hard stop, alerting enabled, and the operator as recipient.
4. Under **Included usage alerts**, enable alerts at 90% and 100%.

A hard budget is the control that blocks further metered spending; alerts alone do not stop usage. GitHub notes
that a newly created budget applies only to usage from its creation onward in the first billing cycle.
([GitHub: budgets and alerts](https://docs.github.com/en/billing/concepts/budgets-and-alerts))

The application uses standard GitHub-hosted runners in public repositories, which GitHub documents as free.
Larger runners remain billable. Container Registry storage and bandwidth are currently free, but retaining the
Packages budget protects against other package products and future billing-policy changes.
([GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[GitHub Packages billing](https://docs.github.com/en/billing/concepts/product-billing/github-packages))

### Equivalent REST payloads

GitHub's organization budget API accepts product identifiers `actions` and `packages`. For each payload below,
use `POST /organizations/burnerpad/settings/billing/budgets`. The caller must be an organization owner or billing
manager with organization **Administration: write**. Replace `Cinderella-Man` only if the actual billing-alert
recipient is different.

```json
{
  "budget_amount": 0,
  "prevent_further_usage": true,
  "budget_scope": "organization",
  "budget_entity_name": "",
  "budget_type": "ProductPricing",
  "budget_product_sku": "actions",
  "budget_alerting": {
    "will_alert": true,
    "alert_recipients": ["Cinderella-Man"]
  }
}
```

```json
{
  "budget_amount": 0,
  "prevent_further_usage": true,
  "budget_scope": "organization",
  "budget_entity_name": "",
  "budget_type": "ProductPricing",
  "budget_product_sku": "packages",
  "budget_alerting": {
    "will_alert": true,
    "alert_recipients": ["Cinderella-Man"]
  }
}
```

Submit each saved payload with:

```bash
gh api --method POST \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  organizations/burnerpad/settings/billing/budgets \
  --input budget.json
```

List and inspect the resulting budget IDs:

```bash
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  organizations/burnerpad/settings/billing/budgets
```

Verify two organization-scoped `ProductPricing` entries with SKUs `actions` and `packages`, amount `0`,
`prevent_further_usage: true`, and alerting enabled. The REST API does not configure the separate **Included
usage alerts** switch; verify that switch in the web UI.

## 4. Make both GHCR packages public

This step is intentionally deferred until the first successful release workflow on `main` has created:

- `ghcr.io/burnerpad/burnerpad-lite`
- `ghcr.io/burnerpad/burnerpad-lite-cloudflared`

For **each** package:

1. Open **burnerpad organization → Packages → _package name_ → Package settings**.
2. Verify the package is connected to `burnerpad/burnerpad-lite` and that the repository has the intended
   Actions access.
3. Under **Danger Zone**, choose **Change visibility → Public**.
4. Type the package name and confirm **I understand the consequences, change package visibility**.

Public is irreversible through the normal control: GitHub warns that a public package cannot later be made
private. The Container Registry supports granular package visibility, and public containers allow anonymous
pulls without authentication.
([GitHub: configuring package visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility),
[GitHub: package permissions](https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages))

There is no supported visibility-changing operation in GitHub's documented Packages REST API or `gh package`
command. Use the UI rather than an undocumented GraphQL mutation or browser endpoint.

### Anonymous-pull verification

After both visibility changes, use a machine or temporary Docker configuration that has never authenticated to
GHCR. Resolve the exact `sha-<40-character-main-revision>` tags produced by the release workflow and verify both:

```bash
docker pull ghcr.io/burnerpad/burnerpad-lite:sha-<full-main-revision>
docker pull ghcr.io/burnerpad/burnerpad-lite-cloudflared:sha-<full-main-revision>
```

An anonymous pull must succeed. Continue to deploy by digest, not by the discovery tag. Do not use a logged-in
workstation for this acceptance test, because cached credentials can hide a private package.

## 5. Enable workflow and security notifications

These are **personal account** preferences, not repository settings. Configure them for every human operator
who must receive alerts.

### Failed workflow runs

1. Open <https://github.com/settings/notifications>.
2. Under **System → Actions**, choose **Email** (and optionally **On GitHub**).
3. Select **Only notify for failed workflows** and save.

GitHub documents this exact path in
[Managing GitHub Actions notifications](https://docs.github.com/en/subscriptions-and-notifications/how-tos/managing-github-actions-notifications).
These notifications are actor-based: they cover workflow runs the user triggered. Scheduled-workflow
notifications go to the user who initially created the workflow, later changed its cron expression, or
re-enabled it. Confirm that the founder/operator owns the scheduled notifications after merging, and exercise
one safe `workflow_dispatch` failure path rather than assuming delivery.
([GitHub: notifications for workflow runs](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs))

### Security alerts and private vulnerability reports

1. On the `burnerpad-lite` repository page, open **Watch → Custom**.
2. Select **Security alerts** and apply the watch setting. Repeat for `burnerpad/crypto-js`.
3. At <https://github.com/settings/notifications>, under **Subscriptions → Watching**, enable **Email** (and
   optionally GitHub Mobile/push).
4. Verify the destination email address. If the founder belongs to multiple organizations, set the organization
   email route to the intended verified mailbox.
5. Apply and independently verify the exact repository controls in section 6. Do this for both
   `burnerpad/burnerpad-lite` and `burnerpad/crypto-js`.

GitHub requires watching **All Activity** or a custom watch that includes **Security alerts**, plus email delivery
under Watching, for Dependabot and secret-scanning email notifications.
([GitHub: managing security notifications](https://docs.github.com/en/subscriptions-and-notifications/how-tos/managing-security-notifications))
Private vulnerability reports use the same watch and delivery prerequisites.
([GitHub: private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository))
The security feature UI and public-repository availability are documented in
[Managing security and analysis settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-security-and-analysis-settings-for-your-repository).

GitHub's watching REST endpoint can subscribe an account to **all** repository activity using a classic PAT:

```bash
gh api --method PUT \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/subscription \
  -F subscribed=true -F ignored=false
```

However, it cannot select custom Security alerts, email/push delivery, or Actions failure-only preferences.
GitHub's notification APIs manage subscriptions and notification threads, not those personal delivery settings.
Use the web UI for this section.
([GitHub: REST endpoints for watching](https://docs.github.com/en/rest/activity/watching?apiVersion=2026-03-10),
[GitHub: REST endpoints for notifications](https://docs.github.com/en/rest/activity/notifications?apiVersion=2026-03-10))

## 6. Enable and independently verify repository security features

Apply this section to **both** public organization repositories. The launch policy requires private
vulnerability reporting, Dependabot alerts, secret-scanning alerts for users, and repository push protection.
The dependency graph and dependency review are part of the intended supply-chain baseline but GitHub already
enables them by default for public repositories and does not allow them to be disabled. Dependabot security
updates and CodeQL are useful, separately controlled extensions; they are not requirements stated in
`.github/REPOSITORY_SETTINGS.md`.

### Feature and plan matrix

| GitHub feature name | Public-repository availability | Launch disposition | Conclusive verification |
|---|---|---|---|
| Dependency graph and dependency review | Free; on by default and cannot be disabled | Required baseline; no enable action | Public **Insights → Dependency graph** page |
| Dependabot alerts | Available for public repositories; not on by default | **Enable** in both repositories | Authenticated `GET .../vulnerability-alerts` returns HTTP `204` |
| Dependabot security updates | Available after the graph and alerts are enabled; not on by default | Recommended, not currently required | Authenticated `GET .../automated-security-fixes` returns enabled and not paused |
| Dependabot version updates | Available, but enabled by a committed `.github/dependabot.yml`, not a repository switch | Already configured in `burnerpad-lite`; absent from `crypto-js` at time of review | Review the default branch's configuration file and recent Dependabot runs |
| Secret Protection / secret-scanning alerts for users | Secret scanning runs automatically for public repositories; alerts for users are free and enabled through **Secret Protection** | **Enable** in both repositories | Authenticated repository response has `secret_scanning.status == "enabled"` |
| Push protection for repositories | Available after Secret Protection; repository control is off by default | **Enable** in both repositories | Authenticated repository response has `secret_scanning_push_protection.status == "enabled"`, then perform the inert-token block test |
| Private vulnerability reporting | Available for public repositories | **Enable** in both repositories | Public status endpoint says `true`; independent account sees **Report a vulnerability** |
| CodeQL code scanning default setup | Free for public repositories | Recommended extension, not currently required | Authenticated default-setup response is configured and a CodeQL analysis completes |

GitHub documents public dependency-graph/review defaults, and distinguishes alerts, security updates, and
version updates, in its
[supply-chain feature availability](https://docs.github.com/en/code-security/concepts/supply-chain-security/supply-chain-security#feature-availability).
It documents free public secret scanning and the current **Secret Protection** UI name in
[Enabling secret scanning](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/detect-secret-leaks/enable-secret-scanning),
and public CodeQL eligibility in
[Configuring default setup](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/configure-code-scanning/configure-code-scanning).

### 6.1 Dependency graph and dependency review

No mutation is required. From a signed-out browser, open:

- <https://github.com/burnerpad/burnerpad-lite/network/dependencies>
- <https://github.com/burnerpad/crypto-js/network/dependencies>

The page must load and identify the repository's detected manifests/dependencies. A graph with no dependency
rows can still be enabled when GitHub does not recognize a manifest; do not invent a dependency to make the
page non-empty. An SPDX SBOM can also be requested through
`GET /repos/{owner}/{repo}/dependency-graph/sbom`, including without authentication for a public resource, but
HTTP `404` is ambiguous and is not evidence that the public graph is disabled.
([Dependency graph](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependency-graph),
[SBOM REST API](https://docs.github.com/en/rest/dependency-graph/sboms?apiVersion=2026-03-10))

### 6.2 Dependabot alerts

For each repository, open **Settings → Security and quality → Advanced Security** and, next to
**Dependabot alerts**, click **Enable**. GitHub should populate any current results within minutes.
([Configuring Dependabot alerts](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/configure-dependabot-alerts))

An administrator must then run these read-only checks:

```bash
gh api --include -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/vulnerability-alerts
gh api --include -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/crypto-js/vulnerability-alerts
```

HTTP `204` means enabled; `404` means disabled. An unauthenticated request returns `401`, so it cannot verify
this setting. The endpoint needs repository **Administration: read**; the corresponding `PUT` enable operation
needs **Administration: write**.
([GitHub REST: vulnerability-alert status and enablement](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#check-if-vulnerability-alerts-are-enabled-for-a-repository))

Do not add a known-vulnerable package to manufacture an alert. GitHub has no documented harmless “send test
Dependabot alert” control. Configuration evidence is the status endpoint; the private-report test in 6.5 can
exercise the operator's shared security-notification route without weakening the dependency set.

**Optional security updates.** If the release owner chooses automatic remediation PRs, enable
**Dependabot security updates** on the same page after alerts, then verify:

```bash
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/automated-security-fixes
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/crypto-js/automated-security-fixes
```

The desired response is `{"enabled":true,"paused":false}`; `404` means not enabled. Security updates do not
require a Dependabot configuration file. Version updates are different: they require a committed
`.github/dependabot.yml`. The current PR provides that file in `burnerpad-lite`; adding one to `crypto-js`
would be a separate repository change.
([GitHub REST: Dependabot security updates](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#check-if-dependabot-security-updates-are-enabled-for-a-repository))

### 6.3 Secret Protection and repository push protection

For each repository:

1. Open **Settings → Security and quality → Advanced Security**.
2. Next to **Secret Protection**, click **Enable**, review the impact, then click **Enable Secret Protection**.
3. In the resulting **Secret Protection** section, next to **Push protection**, click **Enable**.
4. Do not confuse this with personal-account **Push protection for users**. That personal control is on by
   default for public pushes, while repository push protection is a separate control that records bypasses and
   is off by default.

GitHub documents the exact paths in
[Enabling secret scanning](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/detect-secret-leaks/enable-secret-scanning)
and
[Enabling push protection](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/prevent-future-leaks/enable-push-protection).
The distinction between repository and user protection is documented in
[Push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection#types-of-push-protection).

The public repository API intentionally omits these administrative fields from unauthenticated responses.
An administrator, organization owner, or security manager must verify both exact statuses:

```bash
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite \
  --jq '{secret_scanning: .security_and_analysis.secret_scanning.status, push_protection: .security_and_analysis.secret_scanning_push_protection.status}'
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/crypto-js \
  --jq '{secret_scanning: .security_and_analysis.secret_scanning.status, push_protection: .security_and_analysis.secret_scanning_push_protection.status}'
```

Both fields must be `enabled` for both repositories. GitHub only exposes `security_and_analysis` to a
repository administrator, organization owner, or security manager, so a missing/null block in a signed-out
response is not a failure and not evidence of enablement.
([GitHub REST: get a repository](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#get-a-repository))

### 6.4 Safe independent push-protection test

Use GitHub's documented inert dummy token; never create or paste a real credential. Copy the current dummy
value directly from GitHub's linked procedure immediately before testing. Do not reproduce it in this
repository, because a correctly configured push-protection rule will block the documentation commit itself.

For each repository, using a separate test account with normal contributor access:

1. In GitHub's web editor, start a new disposable file on a disposable branch and paste only the dummy token.
2. Select **Commit changes**, then attempt the commit.
3. Record the push-protection block. Do **not** choose any bypass reason.
4. Click **Cancel**, cancel editing, and discard the unsaved change. Confirm no branch, commit, or file was
   created.

GitHub publishes this exact dummy token and cancellation flow in
[Storing your secrets safely](https://docs.github.com/en/get-started/learning-to-code/storing-your-secrets-safely#2-trying-out-push-protection).
A block alone does not prove repository push protection: personal **push protection for users** can also block
public commits. The authenticated two-field API result above is therefore required evidence of the repository
control; the dummy-token attempt is its safe functional companion. Do not bypass merely to provoke an email or
alert.

Do not rely on a custom-pattern canary on GitHub Free. GitHub currently documents repository custom patterns
for organization-owned repositories on GitHub Team or Enterprise with Secret Protection. If the organization
later has that entitlement, a custom pattern can be dry-run without alerts, published, and enabled for push
protection, but it is unnecessary while GitHub's official dummy token is available.
([Defining custom patterns](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/customize-leak-detection/define-custom-patterns))

### 6.5 Private vulnerability reporting

For each repository, open **Settings → Security and quality → Advanced Security** and click **Enable** next to
**Private vulnerability reporting**. Owners, administrators, organization owners, and security managers can
enable this for public repositories.
([Configuring private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository))

The equivalent mutation is `PUT /repos/{owner}/{repo}/private-vulnerability-reporting`; it returns HTTP `204`
and requires repository **Administration: write**. Independently verify from a signed-out shell, because the
status endpoint explicitly supports public unauthenticated requests:

```bash
curl --fail --silent --show-error \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  https://api.github.com/repos/burnerpad/burnerpad-lite/private-vulnerability-reporting
curl --fail --silent --show-error \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  https://api.github.com/repos/burnerpad/crypto-js/private-vulnerability-reporting
```

Each response must be `{"enabled":true}`. Then sign in with a non-admin account, open each repository's
**Security and quality → Advisories** page, and confirm **Report a vulnerability** is present. This proves the
researcher-facing route without creating data.
([GitHub REST: private-vulnerability-reporting status](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#check-if-private-vulnerability-reporting-is-enabled-for-a-repository),
[Privately reporting a vulnerability](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately))

If end-to-end notification delivery must also be tested, submit one report from the non-admin account titled
**PVR notification delivery test — no vulnerability**, with the body stating that it is a harmless control
test. Verify that the watched security mailbox receives it, then have an administrator close it as an invalid
test report. Never publish it, request a CVE, or create a temporary private fork. Retain only the advisory URL
and timestamps in the acceptance record; do not capture mailbox addresses in screenshots. This optional test
creates a real private advisory record, so use it only after the notification watch settings in section 5 are
complete.

### 6.6 Optional CodeQL default setup

CodeQL is free for these public repositories, but it is not named in the current launch policy. It is a strong
follow-up control, not a substitute for the project's existing advisory/image gates. `crypto-js` is JavaScript;
`burnerpad-lite` contains JavaScript and Elixir. CodeQL supports `javascript-typescript` and GitHub Actions, but
does **not** support Elixir, so enabling it would leave the Elixir application to the existing tests and audit
tooling.

For each repository, open **Settings → Security and quality → Advanced Security → Code Security**. Next to
**CodeQL analysis**, select **Set up → Default**. Review the detected languages, retain JavaScript/TypeScript
and GitHub Actions where offered, use the default query suite and standard runner, then click **Enable CodeQL**.
This triggers a validation workflow; no intentionally vulnerable fixture is needed.

After the initial run, verify with an authenticated admin token:

```bash
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/burnerpad-lite/code-scanning/default-setup
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  repos/burnerpad/crypto-js/code-scanning/default-setup
```

Require `state: configured`, the intended language list, and the expected query suite. Then check
**Security and quality → Code scanning → Tool status** for a completed CodeQL analysis and scan coverage, or
read `GET /repos/{owner}/{repo}/code-scanning/analyses`. An unauthenticated empty CodeQL-database list does not
prove configuration; the default-setup endpoint requires repository **Administration: read**. Do not add
CodeQL as a required `main` status check until its first successful check context is observed and the launch
policy is deliberately amended.
([Configuring CodeQL default setup](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/configure-code-scanning/configure-code-scanning),
[CodeQL default-setup REST API](https://docs.github.com/en/rest/code-scanning/code-scanning?apiVersion=2026-03-10#get-a-code-scanning-default-setup-configuration))

## Final acceptance record

Record completion in the production launch checklist only after all checks below are evidenced. Screenshots must
not contain tokens, private URLs, email addresses, capability IDs, personal recovery codes, or billing details.

- [ ] `Protect main` is active, targets only the default branch, and has an authenticated result of
  `bypass_actors: []`.
- [ ] `main` requires PRs, zero approvals, resolved conversations, current branches, verified signatures,
  linear history, and exactly the five GitHub-Actions-sourced checks.
- [ ] A harmless PR demonstrates that a failed check, stale branch, or unresolved conversation blocks merging.
- [ ] `Release tag creation` targets `refs/tags/v*`, contains only the founder User and GitHub Actions
  Integration bypasses, and restricts creation.
- [ ] `Release tag immutability` targets `refs/tags/v*`, has no bypass actors, and restricts update and deletion.
- [ ] The release workflow creates the next immutable annotated patch tag only after the exact `main` revision
  and both published images pass every release gate; a rerun reuses the existing version.
- [ ] Organization Actions budget: USD 0, hard stop, alerts on, correct recipient.
- [ ] Organization Packages budget: USD 0, hard stop, alerts on, correct recipient.
- [ ] Included-usage alerts at 90% and 100% are enabled.
- [ ] Both expected GHCR packages are linked to the source repository, public, and anonymously pullable by exact
  revision tag; the deployment digest is recorded separately.
- [ ] Workflow failure notifications are enabled and a safe delivery test reaches the operator.
- [ ] Security-alert watches and email delivery are enabled for both repositories; any optional PVR delivery
  test reaches the operator and its harmless report is closed without publication/CVE/fork activity.
- [ ] Public dependency-graph pages load for both repositories; no anonymous SBOM `404` was misread as a
  disabled graph.
- [ ] Authenticated Dependabot-alert status is HTTP `204` for both repositories. No vulnerable dependency was
  added merely to generate a test alert.
- [ ] Authenticated `security_and_analysis` reports both `secret_scanning` and repository
  `secret_scanning_push_protection` as `enabled` for both repositories.
- [ ] GitHub's inert dummy token is blocked in both repositories and the web-editor attempt is canceled without
  creating a commit, branch, or file; no real secret and no bypass were used.
- [ ] Public private-vulnerability-reporting status is `{"enabled":true}` for both repositories and a non-admin
  account sees **Report a vulnerability** on both advisory pages.
- [ ] Dependabot security updates and CodeQL have an explicit release-owner decision recorded as optional
  extensions. If CodeQL is enabled, default setup is configured, the initial analysis succeeds, and its known
  Elixir coverage gap is recorded.
