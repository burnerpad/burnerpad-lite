# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.CryptoAssets do
  @moduledoc """
  Subresource-Integrity (SRI) hashes for the static crypto-page scripts, computed from the exact bytes
  on disk at first use and memoized. Every `<script integrity>` on a crypto page therefore matches the
  served file, so a host that tampered with a script would be refused by the browser.
  """
  # The crypto lib is vendored as a git submodule (@burnerpad/crypto); the app driver is local.
  @bundle "vendor/crypto-js/burnerpad-crypto.js"
  @app "crypto/crypto-app.js"
  # The theme bootstrap (sets data-theme before paint); SRI-pinned like the rest since it loads `self`.
  @theme "crypto/theme.js"

  def bundle_sri, do: sri(@bundle)
  def app_sri, do: sri(@app)
  def theme_sri, do: sri(@theme)

  defp sri(rel) do
    case :persistent_term.get({__MODULE__, rel}, nil) do
      nil ->
        value = "sha384-" <> Base.encode64(:crypto.hash(:sha384, File.read!(path(rel))))
        :persistent_term.put({__MODULE__, rel}, value)
        value

      value ->
        value
    end
  end

  defp path(rel), do: Path.join([:code.priv_dir(:burnerpad), "static", rel])
end
