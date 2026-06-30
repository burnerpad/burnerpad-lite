# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Config do
  @moduledoc """
  Runtime configuration, driven entirely by environment variables.

  `load!/0` is called once at application boot and copies the env vars into the
  application environment, so the rest of the code reads via `Application.get_env/3`
  (fast, ETS-backed) and tests can override any value with `Application.put_env/3`.
  """

  @defaults %{
    port: 4000,
    id_length: 8,
    max_secrets: 100_000,
    ttl_seconds: 86_400,
    max_blob: 65_536,
    rate_limit: 240,
    global_ceiling: 30_000,
    ban_threshold: 600,
    window_ms: 60_000
  }

  # Escalating ban durations (ms): 15 m -> 1 h -> 6 h -> 24 h (capped at the last).
  @ban_schedule_ms [15 * 60_000, 60 * 60_000, 6 * 60 * 60_000, 24 * 60 * 60_000]

  @doc "Read env vars into the application environment. Idempotent."
  def load! do
    int(:port, "PORT")
    int(:max_secrets, "MAX_SECRETS")
    int(:ttl_seconds, "TTL_SECONDS")
    int(:rate_limit, "RATE_LIMIT")
    int(:global_ceiling, "GLOBAL_CEILING")
    int(:ban_threshold, "BAN_THRESHOLD")

    if v = System.get_env("REAL_IP_HEADER"),
      do: Application.put_env(:burnerpad, :real_ip_header, String.downcase(v))

    if v = System.get_env("TRUSTED_PROXIES"),
      do: Application.put_env(:burnerpad, :trusted_proxies, v)

    if v = System.get_env("OPERATOR_NAME"), do: Application.put_env(:burnerpad, :operator_name, v)
    if v = System.get_env("ABUSE_EMAIL"), do: Application.put_env(:burnerpad, :abuse_email, v)
    if v = System.get_env("JURISDICTION"), do: Application.put_env(:burnerpad, :jurisdiction, v)

    :ok
  end

  @doc "Integer/typed config with a built-in default."
  def get(key), do: Application.get_env(:burnerpad, key, Map.fetch!(@defaults, key))

  def real_ip_header, do: Application.get_env(:burnerpad, :real_ip_header, "cf-connecting-ip")
  def trusted_proxies, do: Application.get_env(:burnerpad, :trusted_proxies, "")
  def ban_schedule_ms, do: @ban_schedule_ms

  # Operator-specific values for the /terms page. Default to this instance's operator (Impulsa SLU); a
  # fork MUST override these via OPERATOR_NAME / ABUSE_EMAIL / JURISDICTION to publish its own terms.
  def operator_name, do: Application.get_env(:burnerpad, :operator_name, "Impulsa SLU")
  def abuse_email, do: Application.get_env(:burnerpad, :abuse_email, "abuse@burnerpad.com")
  def jurisdiction, do: Application.get_env(:burnerpad, :jurisdiction, "Andorra")

  defp int(key, env) do
    with v when is_binary(v) <- System.get_env(env),
         {n, ""} <- Integer.parse(v) do
      Application.put_env(:burnerpad, key, n)
    else
      _ -> :ok
    end
  end
end
