# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.RequestLogger do
  @moduledoc """
  Privacy-safe operational request events.

  Only allowlisted method/route classes, response status, bounded duration, and release are emitted. The
  logger never copies a concrete path, query, secret ID, management token, ciphertext, phrase, body,
  header, raw/pseudonymous source, filesystem path, or source-to-route mapping. It runs after abuse/static
  bypasses so rejected floods and asset traffic cannot become a log-volume attack.
  """
  @behaviour Plug
  require Logger
  alias Burnerpad.Config
  alias BurnerpadWeb.RouteClass

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    started = System.monotonic_time(:microsecond)

    Plug.Conn.register_before_send(conn, fn response ->
      duration_ms =
        System.monotonic_time(:microsecond)
        |> Kernel.-(started)
        |> max(0)
        |> div(1_000)

      Logger.info(
        "request method=#{method_class(response.method)} route=#{RouteClass.classify(response.path_info)} " <>
          "status=#{response.status} duration_ms=#{duration_ms} release=#{Config.version()}"
      )

      response
    end)
  end

  defp method_class(method) when method in ["GET", "POST"], do: method
  defp method_class(_), do: "OTHER"
end
