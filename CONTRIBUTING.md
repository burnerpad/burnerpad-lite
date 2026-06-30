# Contributing to burnerpad-lite

Thanks for helping build Burnerpad. This repo is the standalone Elixir/Bandit server; the browser crypto
lives in its own repo, [`@burnerpad/crypto`](https://github.com/burnerpad/crypto-js), vendored here as a
git submodule under `priv/static/vendor/crypto-js`.

## The short version

1. **Sign off every commit** with `git commit -s` (Developer Certificate of Origin — see [`DCO`](DCO)).
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
git add priv/static/vendor/crypto-js && git commit -s -m "bump @burnerpad/crypto to <new-tag>"
```

`mix test.crypto` re-runs the vendored bundle's conformance test, so a bad pin fails CI.

## Sign your work — the DCO

Add a `Signed-off-by` trailer with your real name and a reachable email (`git commit -s` does it for you):

```
Signed-off-by: Jane Developer <jane@example.com>
```

A DCO check runs on every pull request; unsigned commits block the merge.
