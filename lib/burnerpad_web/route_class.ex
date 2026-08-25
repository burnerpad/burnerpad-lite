# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.RouteClass do
  @moduledoc """
  Maps parsed request paths to the small allowlist used by privacy-safe operational logs.

  The interface accepts `Plug.Conn.path_info` rather than a concrete path and returns only a fixed atom.
  Secret IDs, management tokens, query strings, and arbitrary path segments can therefore never become
  part of the returned value.
  """

  @type t ::
          :home
          | :secret_page
          | :secret_create
          | :secret_reveal
          | :secret_burn
          | :edge_source_check
          | :stats_page
          | :stats_api
          | :terms
          | :security_contact
          | :api_other
          | :unmatched

  @spec classify([String.t()]) :: t()
  def classify([]), do: :home
  def classify(["s", _id]), do: :secret_page
  def classify(["api", "secrets"]), do: :secret_create
  def classify(["api", "secrets", _id, "reveal"]), do: :secret_reveal
  def classify(["api", "secrets", _id, "burn"]), do: :secret_burn
  def classify(["api", "edge", "source-check"]), do: :edge_source_check
  def classify(["stats"]), do: :stats_page
  def classify(["api", "stats"]), do: :stats_api
  def classify(["terms"]), do: :terms
  def classify([".well-known", "security.txt"]), do: :security_contact
  def classify(["api" | _rest]), do: :api_other
  def classify(_path_info), do: :unmatched
end
