# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.AbusePlug do
  @moduledoc """
  Runs early in the pipeline (before static files, so every request counts). Resolves the client IP,
  asks `Burnerpad.Abuse` for a decision, and short-circuits abusive requests cheaply with `429`/`503`.
  """
  import Plug.Conn
  alias Burnerpad.Abuse
  alias BurnerpadWeb.{ClientIP, SecurityHeaders}

  def init(opts), do: opts

  def call(conn, _opts) do
    case Abuse.check(ClientIP.get(conn)) do
      :ok -> conn
      {:rate_limited, ms} -> reject(conn, 429, ms, "rate limited")
      {:banned, ms} -> reject(conn, 429, ms, "banned")
      {:global, ms} -> reject(conn, 503, ms, "service busy")
    end
  end

  defp reject(conn, status, ms, message) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(ms, 1000) + 1))
    |> put_resp_content_type("application/json")
    |> SecurityHeaders.no_store()
    |> send_resp(status, JSON.encode!(%{error: message}))
    |> halt()
  end
end
