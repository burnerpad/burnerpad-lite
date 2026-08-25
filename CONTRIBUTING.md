# Contributing to burnerpad-lite

Thanks for helping build Burnerpad. This repo is the standalone Elixir/Bandit server; the browser crypto
lives in its own repo, [`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js), vendored here as a
git submodule under `priv/static/vendor/crypto-js`.

## The short version

1. **Sign and sign off every commit** with `git commit -S -s` (cryptographic signature plus Developer
   Certificate of Origin — see [Signed commits and DCO](#signed-commits-and-dco)).
2. Run `mix setup` once to fetch the crypto submodule + deps. Then `mix test` and `mix test.crypto` must
   pass.
3. **No CLA.** You keep your copyright and license your contribution under this repo's existing license.
4. **Never** open a public issue for a security vulnerability — email **security@burnerpad.io** instead.

## License

> **This repository is licensed under: `AGPL-3.0-or-later`** — see [`LICENSE`](LICENSE).

This covers the Elixir server and the app's own page assets (`priv/static/crypto/crypto-app.js`,
`crypto.css`). The crypto **library** is Apache-2.0 and lives in `@burnerpad/crypto` — change it there.

**Inbound = outbound.** By contributing, you agree your contribution is licensed under the *same*
AGPL-3.0-or-later license as this repository. We do **not** ask for copyright assignment and we do **not**
dual-license to a proprietary license.

## Changing the crypto

The bundle is a **pinned submodule** — don't edit files under `priv/static/vendor/crypto-js` here. Make
crypto changes in [`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js), cut a release, then bump
the pin in this repo:

```sh
cd priv/static/vendor/crypto-js && git fetch && git checkout <new-tag> && cd -
git add priv/static/vendor/crypto-js && git commit -S -s -m "bump @burnerpad/crypto to <new-tag>"
```

`mix test.crypto` re-runs the vendored bundle's conformance test, so a bad pin fails CI.

## Signed commits and DCO

Every commit needs **two distinct things**:

- `-S` adds a cryptographic signature. GitHub verifies that the commit came from a signing key associated
  with the contributor's account; the protected `main` branch requires this.
- `-s` adds a plain-text `Signed-off-by` trailer certifying the Developer Certificate of Origin. It is not
  a cryptographic signature. The repository's `dco` workflow requires it.

The options are case-sensitive. Use both even when `commit.gpgsign=true` makes `-S` automatic.

### One-time SSH signing setup

Git supports GPG, SSH, and S/MIME signatures. This project recommends SSH signing on Git 2.34 or newer. If
an existing signing setup already produces GitHub's **Verified** badge, keep it and skip this subsection.

1. Use an existing Ed25519 key or generate a dedicated signing key. Replace the example email with a
   verified email or GitHub-provided noreply address associated with your account:

   ```sh
   ssh-keygen -t ed25519 -C "jane@example.com" -f ~/.ssh/id_ed25519_burnerpad_signing
   ssh-add ~/.ssh/id_ed25519_burnerpad_signing
   ```

2. In GitHub, open **Settings → SSH and GPG keys → New SSH key**, select **Signing Key**, and add the
   contents of `~/.ssh/id_ed25519_burnerpad_signing.pub`. A signing key is not a repository secret and must
   never be uploaded with its private-key file.

3. Configure this clone. Using `--local` avoids changing the signing format of unrelated repositories:

   ```sh
   git config --local user.name "Jane Developer"
   git config --local user.email "jane@example.com"
   git config --local gpg.format ssh
   git config --local user.signingkey ~/.ssh/id_ed25519_burnerpad_signing.pub
   git config --local commit.gpgsign true
   ```

4. Configure local verification. The allowed-signers file remains under `.git` and cannot be committed:

   ```sh
   allowed_signers_file=$(git rev-parse --path-format=absolute --git-path allowed_signers)
   printf '%s %s\n' \
     "$(git config user.email)" \
     "$(cat "$(git config user.signingkey)")" > "$allowed_signers_file"
   git config --local gpg.ssh.allowedSignersFile "$allowed_signers_file"
   ```

GitHub maintains the authoritative setup instructions for
[SSH signing keys](https://docs.github.com/en/authentication/managing-commit-signature-verification/telling-git-about-your-signing-key)
and [signed commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).

### Review, commit, and verify

Stage only the intended paths, review exactly what is staged, then sign and sign off the commit:

```sh
git status --short
git add <path> [<path> ...]
git diff --cached --check
git diff --cached
git commit -S -s -m "concise change description"
git verify-commit HEAD
git log -1 --format='%B'
```

`git verify-commit HEAD` must succeed, and the final command must show a trailer matching the commit
author, for example:

```
Signed-off-by: Jane Developer <jane@example.com>
```

A GitHub-provided `users.noreply.github.com` address associated with the contributor's account is explicitly
accepted so contributing does not require publishing a private contact address. A DCO check runs on every
pull request; a cryptographically unsigned commit or a DCO trailer that does not match the commit author
blocks the merge. After pushing, confirm GitHub shows **Verified** on every commit in the pull request.

If only the newest, unpublished commit is missing one or both requirements, repair it and verify again:

```sh
git commit --amend -S -s --no-edit
git verify-commit HEAD
```

Amending rewrites the commit ID. Never amend a commit already merged into a protected or released branch.
