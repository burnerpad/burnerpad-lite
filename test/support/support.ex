# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Support do
  @moduledoc "Shared test helpers: table reset, scoped config overrides, and router invocation."
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Clear all in-memory state between tests."
  def reset do
    Burnerpad.Store.reset()
    Burnerpad.Abuse.reset()
    :ok
  end

  @doc "Override a config key for the duration of the test, restoring it afterwards."
  def put_config(key, value) do
    previous = Application.fetch_env(:burnerpad, key)
    Application.put_env(:burnerpad, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:burnerpad, key, v)
        :error -> Application.delete_env(:burnerpad, key)
      end
    end)
  end

  @doc "Invoke the router on a built conn."
  def call(conn), do: BurnerpadWeb.Router.call(conn, BurnerpadWeb.Router.init([]))
end
