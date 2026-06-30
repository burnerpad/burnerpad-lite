# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Burnerpad.Config.load!()

    children = [
      # Owns the in-memory secrets table + the TTL sweep.
      Burnerpad.Store,
      # Owns the rate-limit / global-ceiling / ban / stats tables + their sweep.
      Burnerpad.Abuse,
      # The HTTP server. Plain HTTP — terminate TLS at a reverse proxy.
      {Bandit, plug: BurnerpadWeb.Router, scheme: :http, port: Burnerpad.Config.get(:port)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Burnerpad.Supervisor)
  end
end
