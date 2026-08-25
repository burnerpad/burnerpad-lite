# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.Config do
  @moduledoc """
  Runtime configuration, driven entirely by environment variables.

  `load!/0` is called once at application boot and copies the env vars into the
  application environment, so the rest of the code reads via `Application.get_env/3`
  (fast, ETS-backed) and tests can override any value with `Application.put_env/3`.
  """

  # Build-time env: prod requires operator identity (M7); dev/test use a clearly-fake placeholder so a
  # developer never accidentally serves the canonical operator's terms.
  @env Mix.env()

  @defaults %{
    port: 4000,
    max_secrets: 10_000,
    ttl_seconds: 86_400,
    max_blob: 65_536,
    rate_limit: 240,
    global_ceiling: 30_000,
    global_create_ceiling: 1_000,
    ban_threshold: 600,
    window_ms: 60_000,
    state_call_timeout_ms: 1_000
  }

  # Sane bounds per numeric env var — a value outside these is always a misconfiguration, so we fail the
  # boot loudly instead of silently accepting e.g. RATE_LIMIT=0 (which disables protection) (M5).
  @ranges %{
    port: {1, 65_535},
    # At the fixed 64 KiB blob ceiling, 100k rows already permit ~6.5 GB of ciphertext before ETS/VM
    # overhead. Larger values are almost certainly an accidental missing container/memory calculation.
    max_secrets: {1, 100_000},
    # This service is ephemeral sharing, not storage. Callers may request less than 24h, never more.
    ttl_seconds: {60, 86_400},
    rate_limit: {1, 100_000_000},
    global_ceiling: {1, 100_000_000},
    global_create_ceiling: {1, 100_000_000},
    ban_threshold: {1, 100_000_000},
    per_ip_budget: {1, 1_000_000_000_000},
    per_ip_row_budget: {1, 100_000},
    state_call_timeout_ms: {100, 10_000}
  }

  # Escalating ban durations (ms): 15 m -> 1 h -> 6 h -> 24 h (capped at the last).
  @ban_schedule_ms [15 * 60_000, 60 * 60_000, 6 * 60 * 60_000, 24 * 60 * 60_000]
  @revision_pattern ~r/\A(?:dev|unknown|[0-9a-f]{7,40})\z/
  @full_revision_pattern ~r/\A[0-9a-f]{40}\z/
  @digest_pattern ~r/\Asha256:[0-9a-f]{64}\z/
  @email_pattern ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
  @url_forbidden_ascii ~r/[\x00-\x20\x7F]/

  @doc """
  Read env vars into the application environment. Fails closed at boot: an out-of-range numeric raises
  (M5), and in a prod build a missing operator identity raises (M7). Idempotent.
  """
  def load! do
    int(:port, "PORT")
    int(:max_secrets, "MAX_SECRETS")
    int(:ttl_seconds, "TTL_SECONDS")
    int(:rate_limit, "RATE_LIMIT")
    int(:global_ceiling, "GLOBAL_CEILING")
    int(:global_create_ceiling, "GLOBAL_CREATE_CEILING")
    int(:ban_threshold, "BAN_THRESHOLD")
    int(:per_ip_budget, "PER_IP_BUDGET")
    int(:per_ip_row_budget, "PER_IP_ROW_BUDGET")
    int(:state_call_timeout_ms, "STATE_CALL_TIMEOUT_MS")

    real_ip_header!()
    trusted_proxies!()
    validate_relations!()

    operator!(:operator_name, "OPERATOR_NAME")
    email!(:abuse_email, "ABUSE_EMAIL")
    operator!(:jurisdiction, "JURISDICTION")
    email!(:security_email, "SECURITY_EMAIL")
    policy_url!()
    release_revision!()
    release_digest!()

    :ok
  end

  @doc "Integer/typed config with a built-in default."
  def get(key), do: Application.get_env(:burnerpad, key, Map.fetch!(@defaults, key))

  def real_ip_header, do: Application.get_env(:burnerpad, :real_ip_header, "cf-connecting-ip")
  def trusted_proxies, do: Application.get_env(:burnerpad, :trusted_proxies, [])
  def ban_schedule_ms, do: @ban_schedule_ms

  @doc "Application version plus the immutable deployed git revision shown on the transparency page."
  def version do
    app_version =
      case Application.spec(:burnerpad, :vsn) do
        nil -> "dev"
        vsn -> to_string(vsn)
      end

    "#{app_version}+#{Application.get_env(:burnerpad, :release_revision, "dev")}"
  end

  @doc """
  Per-IP ciphertext-byte budget (M13). Env `PER_IP_BUDGET`, else 2 % of the whole store's worst-case size
  (`MAX_SECRETS × max_blob`) — so one source can hold ~2 % of capacity before it's throttled.
  """
  def per_ip_budget do
    Application.get_env(:burnerpad, :per_ip_budget) ||
      max(get(:max_blob), div(get(:max_secrets) * get(:max_blob) * 2, 100))
  end

  @doc """
  Per-IP unexpired-row budget. Env `PER_IP_ROW_BUDGET`, else 2 % of `MAX_SECRETS`, with a one-row
  minimum. This complements the byte budget: tiny ciphertexts cannot exhaust every Store row.
  """
  def per_ip_row_budget do
    Application.get_env(:burnerpad, :per_ip_row_budget) ||
      max(1, div(get(:max_secrets) * 2, 100))
  end

  @doc false
  def parse_proxy_cidrs!(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(fn cidr ->
      with [addr, prefix_text] <- String.split(String.trim(cidr), "/"),
           {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
           {prefix, ""} <- Integer.parse(prefix_text),
           width = if(tuple_size(ip) == 4, do: 32, else: 128),
           true <- prefix >= 0 and prefix <= width do
        {ip, prefix}
      else
        _ ->
          raise "Invalid TRUSTED_PROXIES entry #{inspect(cidr)} — expected an IPv4/IPv6 CIDR."
      end
    end)
  end

  # Operator-specific values for the /terms page. `load!/0` sets these from the env at boot (required in
  # prod, M7); the `||` is only a belt for a call before `load!/0` ran (e.g. an isolated unit test).
  def operator_name,
    do: Application.get_env(:burnerpad, :operator_name) || dev_placeholder(:operator_name)

  def abuse_email,
    do: Application.get_env(:burnerpad, :abuse_email) || dev_placeholder(:abuse_email)

  def jurisdiction,
    do: Application.get_env(:burnerpad, :jurisdiction) || dev_placeholder(:jurisdiction)

  def security_email,
    do: Application.get_env(:burnerpad, :security_email) || dev_placeholder(:security_email)

  def security_policy_url,
    do:
      Application.get_env(:burnerpad, :security_policy_url) ||
        dev_placeholder(:security_policy_url)

  def image_digest,
    do: Application.get_env(:burnerpad, :image_digest, "dev")

  # Range-validated integer env var. Unset ⇒ use the built-in default; invalid ⇒ raise.
  defp int(key, env) do
    case System.get_env(env) do
      v when v in [nil, ""] ->
        Application.delete_env(:burnerpad, key)

      v ->
        {min, max} = Map.fetch!(@ranges, key)

        case Integer.parse(v) do
          {n, ""} when n >= min and n <= max ->
            Application.put_env(:burnerpad, key, n)

          _ ->
            raise "Invalid #{env}=#{inspect(v)} — expected an integer in #{min}..#{max}."
        end
    end
  end

  # Operator identity. Required in a prod build (M7 — a fork can't accidentally publish the canonical
  # operator's terms); a dev/test build gets an obviously-fake placeholder.
  defp operator!(key, env) do
    case System.get_env(env) do
      v when is_binary(v) ->
        trimmed = String.trim(v)

        if trimmed != "" and byte_size(trimmed) <= 254 and String.valid?(trimmed) and
             not control_chars?(trimmed) and not prod_placeholder?(trimmed) do
          Application.put_env(:burnerpad, key, trimmed)
        else
          raise "Invalid #{env} — expected 1..254 bytes of trimmed UTF-8 text without control characters."
        end

      _ ->
        missing_operator!(key, env)
    end
  end

  defp email!(key, env) do
    case System.get_env(env) do
      v when is_binary(v) ->
        email = String.trim(v)

        if byte_size(email) <= 254 and Regex.match?(@email_pattern, email) and
             not (@env == :prod and String.ends_with?(String.downcase(email), ".invalid")) do
          Application.put_env(:burnerpad, key, email)
        else
          raise "Invalid #{env} — expected one email address."
        end

      _ ->
        missing_operator!(key, env)
    end
  end

  defp policy_url! do
    case System.get_env("SECURITY_POLICY_URL") do
      value when is_binary(value) ->
        value = String.trim(value)
        uri = URI.parse(value)

        if byte_size(value) <= 2_048 and not Regex.match?(@url_forbidden_ascii, value) and
             uri.scheme == "https" and is_binary(uri.host) and
             uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.fragment) and
             not (@env == :prod and
                    (String.ends_with?(String.downcase(uri.host), ".invalid") or
                       String.contains?(String.upcase(value), "CHANGE_ME"))) do
          Application.put_env(:burnerpad, :security_policy_url, value)
        else
          raise "Invalid SECURITY_POLICY_URL — expected one HTTPS URL without credentials, fragment, or literal whitespace/control characters."
        end

      _ ->
        missing_operator!(:security_policy_url, "SECURITY_POLICY_URL")
    end
  end

  defp real_ip_header! do
    case System.get_env("REAL_IP_HEADER") do
      v when v in [nil, ""] ->
        Application.delete_env(:burnerpad, :real_ip_header)

      v ->
        header = String.downcase(v)

        if Regex.match?(~r/\A[a-z0-9!#$%&'*+.^_`|~-]+\z/, header) do
          Application.put_env(:burnerpad, :real_ip_header, header)
        else
          raise "Invalid REAL_IP_HEADER — expected one HTTP header name."
        end
    end
  end

  defp trusted_proxies! do
    case System.get_env("TRUSTED_PROXIES") do
      v when v in [nil, ""] ->
        Application.delete_env(:burnerpad, :trusted_proxies)

      v ->
        Application.put_env(:burnerpad, :trusted_proxies, parse_proxy_cidrs!(v))
    end
  end

  defp validate_relations! do
    max_blob = get(:max_blob)
    source_budget = per_ip_budget()
    total_bytes = get(:max_secrets) * max_blob

    if source_budget < max_blob do
      raise "Invalid PER_IP_BUDGET — it must be at least the maximum blob size (#{max_blob} bytes)."
    end

    if source_budget > total_bytes do
      raise "Invalid PER_IP_BUDGET — it cannot exceed MAX_SECRETS × the 64 KiB blob limit."
    end

    if per_ip_row_budget() > get(:max_secrets) do
      raise "Invalid PER_IP_ROW_BUDGET — it cannot exceed MAX_SECRETS."
    end

    unless get(:rate_limit) < get(:ban_threshold) and
             get(:ban_threshold) < get(:global_ceiling) do
      raise "Invalid abuse thresholds — require RATE_LIMIT < BAN_THRESHOLD < GLOBAL_CEILING."
    end

    unless get(:global_create_ceiling) < get(:global_ceiling) do
      raise "Invalid creation threshold — require GLOBAL_CREATE_CEILING < GLOBAL_CEILING."
    end
  end

  defp control_chars?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp prod_placeholder?(value) do
    @env == :prod and
      (String.contains?(String.upcase(value), "CHANGE_ME") or
         String.ends_with?(String.downcase(value), ".invalid"))
  end

  # The revision is rendered into HTML and JSON, so accept only a git SHA or the explicit local/fallback
  # labels. An arbitrary environment value must never become an HTML-injection seam.
  defp release_revision! do
    revision = System.get_env("BURNERPAD_REVISION", "dev")

    validate_release_revision!(revision, @env)
    Application.put_env(:burnerpad, :release_revision, revision)
  end

  @doc false
  def validate_release_revision!(revision, :prod) do
    unless is_binary(revision) and Regex.match?(@full_revision_pattern, revision) do
      raise "Invalid BURNERPAD_REVISION — production requires a full 40-character lowercase git SHA."
    end

    :ok
  end

  def validate_release_revision!(revision, _env) do
    unless is_binary(revision) and Regex.match?(@revision_pattern, revision) do
      raise "Invalid BURNERPAD_REVISION — expected dev, unknown, or a 7–40 character lowercase git SHA."
    end

    :ok
  end

  defp release_digest! do
    digest = System.get_env("BURNERPAD_IMAGE_DIGEST", if(@env == :prod, do: "", else: "dev"))

    if (@env != :prod and digest == "dev") or Regex.match?(@digest_pattern, digest) do
      Application.put_env(:burnerpad, :image_digest, digest)
    else
      raise "Invalid BURNERPAD_IMAGE_DIGEST — production requires sha256 plus 64 lowercase hex digits."
    end
  end

  defp missing_operator!(key, env) do
    if @env == :prod do
      raise "#{env} is required in production. Refusing to boot with incomplete operator identity."
    else
      Application.put_env(:burnerpad, key, dev_placeholder(key))
    end
  end

  defp dev_placeholder(:operator_name), do: "Burnerpad (dev — set OPERATOR_NAME)"
  defp dev_placeholder(:abuse_email), do: "dev@example.invalid"
  defp dev_placeholder(:jurisdiction), do: "Nowhere (dev — set JURISDICTION)"
  defp dev_placeholder(:security_email), do: "security@example.invalid"
  defp dev_placeholder(:security_policy_url), do: "https://example.invalid/security-policy"
end
