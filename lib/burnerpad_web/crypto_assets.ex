# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.CryptoAssets do
  @moduledoc """
  Subresource-Integrity (SRI) hashes for the static crypto-page assets.

  The `<script integrity>` on every page is served from `@expected` below — hashes **committed to this
  repo** — not recomputed from whatever bytes happen to be on disk. `verify!/0` (called at boot) recomputes
  each asset and **refuses to start** if it doesn't match the committed hash (M1). So the guarantee is:

    * a build/deploy that ships different asset bytes than were reviewed **fails to boot** (tamper-evident),
    * and the browser's SRI check pins the served bytes to the committed hash it sees in the page.

  Committing the hash (rather than deriving it from the served file, as before) separates the reviewed
  expectation from the asset bytes and catches build drift or static-file tampering. It does not protect a
  future visitor from an attacker who controls both the live HTML response and the script; no same-origin
  SRI design can, because that attacker can replace the hash in the page too.

  Regenerate `@expected` after a legitimate asset change with:  `mix bp.sri`
  """
  # This is the only asset registry. Boot verification and `mix bp.sri` both consume it, so adding or
  # removing a pinned file cannot update one path while silently omitting the other.
  @expected %{
    "crypto/crypto-app.js" =>
      "sha384-vkBheS6XBgK2BPM5KMHMKo4pBGoPjoDCNg/XAtWK8EPyyyiH82T/FNKBLFRIsD2z",
    "crypto/crypto.css" =>
      "sha384-uJOuVSd6eFuO2bHlLD8AAO9VNE5io+g6AKvsbXITJoKWrLIFqkNUCA0Wb9GCck9B",
    "crypto/theme.js" =>
      "sha384-j+VfV677hIGpr1j4pZuMbP9EY4K85M7Rn05g61lxCnbkRXzFYHOWgCc9cjy1NkbC",
    "vendor/crypto-js/burnerpad-crypto.js" =>
      "sha384-LOnXN+lAGlbmv3t5ogWEE2A5izTs8EqWsAJOjngyjHQKP0dLpgH0EHZSdXaPUOaG"
  }

  @doc "The set of pinned assets (relative path => committed SRI). Used by `verify!/0` and `mix bp.sri`."
  def expected, do: @expected

  # `<script integrity>` values on the crypto pages — from the COMMITTED hashes, never the served file.
  def bundle_sri, do: Map.fetch!(@expected, "vendor/crypto-js/burnerpad-crypto.js")
  def app_sri, do: Map.fetch!(@expected, "crypto/crypto-app.js")
  def theme_sri, do: Map.fetch!(@expected, "crypto/theme.js")
  def css_sri, do: Map.fetch!(@expected, "crypto/crypto.css")

  @doc """
  Verify every served asset matches its committed hash. Raises (refusing boot) on any mismatch (M1).
  """
  def verify! do
    for {rel, want} <- @expected do
      got = compute(rel)

      if got != want do
        raise "SRI mismatch for #{rel}: served bytes hash #{got}, committed #{want}. " <>
                "A crypto asset differs from what was reviewed — refusing to boot. " <>
                "If the change is intentional, run `mix bp.sri` and commit."
      end
    end

    :ok
  end

  @doc "sha384 SRI of the asset at relative path `rel`, from the bytes on disk."
  def compute(rel), do: "sha384-" <> Base.encode64(:crypto.hash(:sha384, File.read!(path(rel))))

  defp path(rel), do: Path.join([:code.priv_dir(:burnerpad), "static", rel])
end
